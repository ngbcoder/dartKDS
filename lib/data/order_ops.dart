import 'package:drift/drift.dart' as drift;
import 'package:uuid/uuid.dart';

import '../models/database.dart';
import '../models/item_status.dart';
import '../models/order_status.dart';
import 'host_store.dart';

/// Order mutations shared by the Drift-backed store (native host device) and
/// the host server (browser clients). Both call sites must produce identical
/// database state and identical kitchen broadcasts, so the logic lives here
/// rather than being duplicated.

/// Creates an order, or rewrites an existing one when [isEditing]. Returns the
/// `order` payload to broadcast to the kitchen displays.
Future<Map<String, dynamic>> submitOrderToDatabase({
  required KDSDatabase db,
  required String orderUuid,
  required String customerName,
  required List<OrderLine> lines,
  required bool isEditing,
}) {
  // Stock restore, order rewrite and item inserts have to land together. Without
  // a transaction a failure part-way through left stock decremented against an
  // order whose items were never written.
  return db.transaction(
    () => _submitOrderInTransaction(
      db: db,
      orderUuid: orderUuid,
      customerName: customerName,
      lines: lines,
      isEditing: isEditing,
    ),
  );
}

Future<Map<String, dynamic>> _submitOrderInTransaction({
  required KDSDatabase db,
  required String orderUuid,
  required String customerName,
  required List<OrderLine> lines,
  required bool isEditing,
}) async {
  final now = DateTime.now();
  final nowMs = now.millisecondsSinceEpoch;

  if (isEditing) {
    // Give back the stock the previous version of this order consumed.
    final oldItems = await (db.select(
      db.kDSItems,
    )..where((t) => t.orderUuid.equals(orderUuid))).get();
    for (final oldItem in oldItems) {
      final menuMatches = await (db.select(
        db.menuItems,
      )..where((t) => t.name.equals(oldItem.name))).get();
      if (menuMatches.isNotEmpty && menuMatches.first.trackStock) {
        await (db.update(
          db.menuItems,
        )..where((t) => t.id.equals(menuMatches.first.id))).write(
          MenuItemsCompanion(
            stockQuantity: drift.Value(menuMatches.first.stockQuantity + 1),
            updatedAtMs: drift.Value(nowMs),
          ),
        );
      }
    }
    await (db.delete(
      db.kDSItems,
    )..where((t) => t.orderUuid.equals(orderUuid))).go();
    await (db.update(
      db.kDSOrders,
    )..where((t) => t.uuid.equals(orderUuid))).write(
      KDSOrdersCompanion(
        customerName: drift.Value(customerName),
        timestamp: drift.Value(now),
        status: const drift.Value(OrderStatus.pending),
        updatedAtMs: drift.Value(nowMs),
      ),
    );
  } else {
    await db.into(db.kDSOrders).insert(
      KDSOrderData(
        uuid: orderUuid,
        customerName: customerName,
        timestamp: now,
        status: OrderStatus.pending,
        updatedAtMs: nowMs,
      ),
    );
  }

  final items = <Map<String, dynamic>>[];
  for (final line in lines) {
    // Check if this line is a combo
    MenuItemData? menuItem;
    if (line.menuItemId >= 0) {
      menuItem = await (db.select(
        db.menuItems,
      )..where((t) => t.id.equals(line.menuItemId))).getSingleOrNull();
    }

    if (menuItem != null && menuItem.isCombo) {
      // Expand combo into individual component items
      final components = await (db.select(db.comboComponents)
            ..where((t) => t.comboItemId.equals(menuItem!.id)))
          .get();

      bool firstComponent = true;
      for (final comp in components) {
        final compItem = await (db.select(db.menuItems)
              ..where((t) => t.id.equals(comp.componentItemId)))
            .getSingleOrNull();
        if (compItem == null) continue;

        // Stock decrement for component
        if (compItem.trackStock) {
          await (db.update(
            db.menuItems,
          )..where((t) => t.id.equals(compItem.id))).write(
            MenuItemsCompanion(
              stockQuantity: drift.Value(
                (compItem.stockQuantity - comp.quantity * line.quantity)
                    .clamp(0, 1 << 31),
              ),
              updatedAtMs: drift.Value(nowMs),
            ),
          );
        }

        final compQty = comp.quantity * line.quantity;
        for (var i = 0; i < compQty; i++) {
          final itemUuid = const Uuid().v4();
          // Assign combo price to first component only
          final itemPrice = firstComponent ? line.price / line.quantity : 0.0;
          firstComponent = false;

          await db.into(db.kDSItems).insert(
            KDSItemsCompanion.insert(
              uuid: itemUuid,
              orderUuid: orderUuid,
              name: compItem.name,
              modifiers: line.modifiers,
              stationTag: compItem.defaultStation,
              status: ItemStatus.pending,
              price: drift.Value(itemPrice),
              updatedAtMs: drift.Value(nowMs),
            ),
          );
          items.add({
            'uuid': itemUuid,
            'name': compItem.name,
            'modifiers': line.modifiers,
            'stationTag': compItem.defaultStation,
            'status': ItemStatus.pending.index,
            'price': itemPrice,
          });
        }
      }
    } else {
      // Regular item logic
      if (line.menuItemId >= 0 && menuItem != null && menuItem.trackStock) {
        await (db.update(
          db.menuItems,
        )..where((t) => t.id.equals(menuItem!.id))).write(
          MenuItemsCompanion(
            stockQuantity: drift.Value(
              (menuItem.stockQuantity - line.quantity).clamp(0, 1 << 31),
            ),
            updatedAtMs: drift.Value(nowMs),
          ),
        );
      }
      for (var i = 0; i < line.quantity; i++) {
        final itemUuid = const Uuid().v4();
        await db.into(db.kDSItems).insert(
          KDSItemsCompanion.insert(
            uuid: itemUuid,
            orderUuid: orderUuid,
            name: line.name,
            modifiers: line.modifiers,
            stationTag: line.stationTag,
            status: ItemStatus.pending,
            price: drift.Value(line.price),
            updatedAtMs: drift.Value(nowMs),
          ),
        );
        items.add({
          'uuid': itemUuid,
          'name': line.name,
          'modifiers': line.modifiers,
          'stationTag': line.stationTag,
          'status': ItemStatus.pending.index,
          'price': line.price,
        });
      }
    }
  }

  return {
    'uuid': orderUuid,
    'customerName': customerName,
    'timestamp': now.toIso8601String(),
    'status': OrderStatus.pending.index,
    'items': items,
  };
}

/// Re-opens a completed order and returns it as a fresh order payload for the
/// kitchen displays.
Future<Map<String, dynamic>?> recallOrderInDatabase({
  required KDSDatabase db,
  required String orderUuid,
}) async {
  final nowMs = DateTime.now().millisecondsSinceEpoch;
  await (db.update(
    db.kDSOrders,
  )..where((t) => t.uuid.equals(orderUuid))).write(
    KDSOrdersCompanion(
      status: const drift.Value(OrderStatus.pending),
      updatedAtMs: drift.Value(nowMs),
    ),
  );
  await (db.update(
    db.kDSItems,
  )..where((t) => t.orderUuid.equals(orderUuid))).write(
    KDSItemsCompanion(
      status: const drift.Value(ItemStatus.pending),
      updatedAtMs: drift.Value(nowMs),
    ),
  );
  final order = await (db.select(
    db.kDSOrders,
  )..where((t) => t.uuid.equals(orderUuid))).getSingleOrNull();
  if (order == null) return null;
  final items = await (db.select(
    db.kDSItems,
  )..where((t) => t.orderUuid.equals(orderUuid))).get();
  return {
    'uuid': order.uuid,
    'customerName': order.customerName,
    'timestamp': order.timestamp.toIso8601String(),
    'status': order.status.index,
    'items': items
        .map(
          (i) => {
            'uuid': i.uuid,
            'name': i.name,
            'modifiers': i.modifiers,
            'stationTag': i.stationTag,
            'status': i.status.index,
            'price': i.price,
          },
        )
        .toList(),
  };
}

Future<void> deleteOrderInDatabase({
  required KDSDatabase db,
  required String orderUuid,
}) async {
  await (db.delete(
    db.kDSItems,
  )..where((t) => t.orderUuid.equals(orderUuid))).go();
  await (db.delete(
    db.kDSOrders,
  )..where((t) => t.uuid.equals(orderUuid))).go();
}
