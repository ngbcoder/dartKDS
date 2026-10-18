import 'dart:convert';

import 'package:drift/drift.dart' as drift;
import 'package:uuid/uuid.dart';

import '../models/connected_client.dart';
import '../models/database.dart';
import '../services/host_server.dart';
import 'host_store.dart';
import 'order_ops.dart';

/// Native implementation: reads and writes Drift directly and pushes kitchen
/// updates through the running [HostServer].
class DriftHostStore implements HostStore {
  final KDSDatabase db;
  final HostServer server;

  DriftHostStore({required this.db, required this.server});

  @override
  Stream<List<MenuItemData>> watchMenuItems() => db.select(db.menuItems).watch();

  @override
  Stream<List<MenuItemData>> watchTrackedStockItems() => (db.select(
    db.menuItems,
  )..where((t) => t.trackStock.equals(true))).watch();

  @override
  Stream<List<MenuItemData>> watchLowStockItems() => (db.select(db.menuItems)
        ..where((t) => t.trackStock.equals(true))
        ..where((t) => t.stockQuantity.isSmallerOrEqualValue(5)))
      .watch();

  @override
  Stream<List<StationData>> watchStations() => db.select(db.stations).watch();

  @override
  Stream<List<GlobalModifierData>> watchGlobalModifiers() =>
      db.select(db.globalModifiers).watch();

  @override
  Stream<List<KDSOrderData>> watchOrders() => (db.select(db.kDSOrders)
        ..orderBy([(t) => drift.OrderingTerm.desc(t.timestamp)]))
      .watch();

  @override
  Stream<List<KDSItemData>> watchOrderItems(String orderUuid) => (db.select(
    db.kDSItems,
  )..where((t) => t.orderUuid.equals(orderUuid))).watch();

  @override
  Stream<List<ItemSalesStat>> watchItemSalesStats() => db.getItemSalesStats();

  @override
  Stream<List<ConnectedClient>> watchClients() {
    // The server mutates an authoritative list and signals via `onClientsChanged`
    // rather than exposing a stream, so bridge it to one here. Polling instead
    // would start a fresh timer on every StreamBuilder resubscription.
    return Stream<List<ConnectedClient>>.multi((controller) {
      final listener = () {
        if (!controller.isClosed) controller.add(server.connectedClients);
      };

      // Registers/unregisters symmetrically. This used to chain into a single
      // shared `onClientsChanged` field and restore the captured `previous` on
      // cancel — so if this listener left before another subscriber's, the
      // restore threw the other subscriber's wrapper away and it silently
      // stopped updating.
      server.addClientListener(listener);
      controller.onCancel = () => server.removeClientListener(listener);

      listener();
    });
  }

  @override
  Future<List<MenuItemData>> getMenuItems() => db.select(db.menuItems).get();

  @override
  Future<List<StationData>> getStations() => db.select(db.stations).get();

  @override
  Future<List<KDSItemData>> getOrderItems(String orderUuid) => (db.select(
    db.kDSItems,
  )..where((t) => t.orderUuid.equals(orderUuid))).get();

  @override
  Future<List<MenuItemData>> getLowStockItems() => (db.select(db.menuItems)
        ..where((t) => t.trackStock.equals(true))
        ..where((t) => t.stockQuantity.isSmallerOrEqualValue(5)))
      .get();

  @override
  Future<Map<String, dynamic>> exportLibrary() async {
    final items = await db.select(db.menuItems).get();
    final stations = await db.select(db.stations).get();
    final modifiers = await db.select(db.globalModifiers).get();
    return {
      'version': 1,
      'menuItems': items
          .map(
            (i) => {
              'guid': i.guid,
              'name': i.name,
              'category': i.category,
              'defaultStation': i.defaultStation,
              'modifiers': i.modifiers,
              'requiredModifiers': i.requiredModifiers,
              'tags': i.tags,
              'price': i.price,
              'stockQuantity': i.stockQuantity,
              'trackStock': i.trackStock,
              'oneTouch': i.oneTouch,
            },
          )
          .toList(),
      'stations': stations.map((s) => {'name': s.name}).toList(),
      'globalModifiers': modifiers.map((m) => {'name': m.name}).toList(),
    };
  }

  @override
  Future<List<String>> getConnectedStations() async => server.connectedStations;

  @override
  Future<List<Map<String, String>>> getKnownHosts() async => [
    {'hostId': server.hostId, 'role': server.role, 'url': ''},
    ...?server.knownPeersProvider?.call(),
  ];

  @override
  Future<String> getHostEndpoint() async => server.selfUrl;

  @override
  Future<void> saveMenuItem(MenuItemDraft draft) async {
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    if (draft.id != null) {
      await (db.update(db.menuItems)..where((t) => t.id.equals(draft.id!))).write(
        MenuItemsCompanion(
          name: drift.Value(draft.name),
          category: drift.Value(draft.category),
          defaultStation: drift.Value(draft.defaultStation),
          modifiers: drift.Value(draft.modifiers),
          requiredModifiers: drift.Value(draft.requiredModifiers),
          tags: drift.Value(draft.tags),
          price: drift.Value(draft.price),
          stockQuantity: drift.Value(draft.stockQuantity),
          trackStock: drift.Value(draft.trackStock),
          oneTouch: drift.Value(draft.oneTouch),
          updatedAtMs: drift.Value(nowMs),
        ),
      );
    } else {
      await db.into(db.menuItems).insert(
        MenuItemsCompanion.insert(
          guid: drift.Value(
            draft.guid.isEmpty ? const Uuid().v4() : draft.guid,
          ),
          name: draft.name,
          category: draft.category,
          defaultStation: draft.defaultStation,
          modifiers: draft.modifiers,
          requiredModifiers: drift.Value(draft.requiredModifiers),
          tags: drift.Value(draft.tags),
          price: drift.Value(draft.price),
          stockQuantity: drift.Value(draft.stockQuantity),
          trackStock: drift.Value(draft.trackStock),
          oneTouch: drift.Value(draft.oneTouch),
          updatedAtMs: drift.Value(nowMs),
        ),
      );
    }
  }

  @override
  Future<void> deleteMenuItem(int id) =>
      (db.delete(db.menuItems)..where((t) => t.id.equals(id))).go();

  @override
  Future<void> setStock(int id, int quantity) =>
      (db.update(db.menuItems)..where((t) => t.id.equals(id))).write(
        MenuItemsCompanion(
          stockQuantity: drift.Value(quantity < 0 ? 0 : quantity),
          updatedAtMs: drift.Value(DateTime.now().millisecondsSinceEpoch),
        ),
      );

  @override
  Future<void> saveStation({int? id, required String name}) async {
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    if (id != null) {
      await (db.update(db.stations)..where((t) => t.id.equals(id))).write(
        StationsCompanion(
          name: drift.Value(name),
          updatedAtMs: drift.Value(nowMs),
        ),
      );
    } else {
      await db.into(db.stations).insert(
        StationsCompanion.insert(name: name, updatedAtMs: drift.Value(nowMs)),
      );
    }
  }

  @override
  Future<void> deleteStation(int id) =>
      (db.delete(db.stations)..where((t) => t.id.equals(id))).go();

  @override
  Future<void> saveGlobalModifier({int? id, required String name}) async {
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    if (id != null) {
      await (db.update(
        db.globalModifiers,
      )..where((t) => t.id.equals(id))).write(
        GlobalModifiersCompanion(
          name: drift.Value(name),
          updatedAtMs: drift.Value(nowMs),
        ),
      );
    } else {
      await db.into(db.globalModifiers).insert(
        GlobalModifiersCompanion.insert(
          name: name,
          updatedAtMs: drift.Value(nowMs),
        ),
      );
    }
  }

  @override
  Future<void> deleteGlobalModifier(int id) =>
      (db.delete(db.globalModifiers)..where((t) => t.id.equals(id))).go();

  @override
  Future<void> importLibrary(Map<String, dynamic> data) async {
    await db.transaction(() async {
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      final existingStations = await db.select(db.stations).get();
      for (final s in (data['stations'] as List? ?? [])) {
        final name = (s['name'] ?? '').toString();
        if (name.isEmpty) continue;
        final existing = existingStations.where((e) => e.name == name).firstOrNull;
        if (existing != null) {
          await (db.update(db.stations)..where((t) => t.id.equals(existing.id))).write(
            StationsCompanion(
              name: drift.Value(name),
              updatedAtMs: drift.Value(nowMs),
            ),
          );
        } else {
          await db.into(db.stations).insert(
            StationsCompanion.insert(
              name: name,
              updatedAtMs: drift.Value(nowMs),
            ),
          );
        }
      }

      final existingModifiers = await db.select(db.globalModifiers).get();
      for (final m in (data['globalModifiers'] as List? ?? [])) {
        final name = (m['name'] ?? '').toString();
        if (name.isEmpty) continue;
        final existing = existingModifiers.where((e) => e.name == name).firstOrNull;
        if (existing != null) {
          await (db.update(db.globalModifiers)..where((t) => t.id.equals(existing.id))).write(
            GlobalModifiersCompanion(
              name: drift.Value(name),
              updatedAtMs: drift.Value(nowMs),
            ),
          );
        } else {
          await db.into(db.globalModifiers).insert(
            GlobalModifiersCompanion.insert(
              name: name,
              updatedAtMs: drift.Value(nowMs),
            ),
          );
        }
      }
      final existingItems = await db.select(db.menuItems).get();
      for (final i in (data['menuItems'] as List? ?? [])) {
        final name = (i['name'] ?? 'Unknown Item').toString();
        final companion = MenuItemsCompanion(
          guid: drift.Value(
            (i['guid'] ?? const Uuid().v4()).toString(),
          ),
          name: drift.Value(name),
          category: drift.Value((i['category'] ?? 'All Items').toString()),
          defaultStation: drift.Value(
            (i['defaultStation'] ?? 'Main Station').toString(),
          ),
          modifiers: drift.Value(_strList(i['modifiers'])),
          requiredModifiers: drift.Value(_strList(i['requiredModifiers'])),
          tags: drift.Value(_strList(i['tags'])),
          price: drift.Value((i['price'] as num?)?.toDouble() ?? 0.0),
          stockQuantity: drift.Value((i['stockQuantity'] as num?)?.toInt() ?? 0),
          trackStock: drift.Value(i['trackStock'] == true),
          oneTouch: drift.Value(i['oneTouch'] == true),
          updatedAtMs: drift.Value(nowMs),
        );
        final existing = existingItems
            .where((e) => e.name == name)
            .firstOrNull;
        if (existing != null) {
          await (db.update(
            db.menuItems,
          )..where((t) => t.id.equals(existing.id))).write(companion);
        } else {
          await db.into(db.menuItems).insert(companion);
        }
      }
    });
  }

  @override
  Future<void> clearLibrary() async {
    await db.transaction(() async {
      await db.delete(db.menuItems).go();
      await db.delete(db.stations).go();
      await db.delete(db.globalModifiers).go();
      await db
          .into(db.stations)
          .insert(StationsCompanion.insert(name: 'Main Station'));
    });
  }

  @override
  Future<void> submitOrder({
    required String orderUuid,
    required String customerName,
    required List<OrderLine> lines,
    required bool isEditing,
  }) async {
    final order = await submitOrderToDatabase(
      db: db,
      orderUuid: orderUuid,
      customerName: customerName,
      lines: lines,
      isEditing: isEditing,
    );
    server.broadcast(
      jsonEncode({
        'type': isEditing ? 'OrderUpdated' : 'OrderCreated',
        'orderUuid': orderUuid,
        'order': order,
      }),
    );
  }

  @override
  Future<void> deleteOrder(String orderUuid) async {
    await deleteOrderInDatabase(db: db, orderUuid: orderUuid);
    server.broadcast(
      jsonEncode({'type': 'OrderDeleted', 'orderUuid': orderUuid}),
    );
  }

  @override
  Future<void> recallOrder(String orderUuid) async {
    final order = await recallOrderInDatabase(db: db, orderUuid: orderUuid);
    if (order == null) return;
    server.broadcast(
      jsonEncode({'type': 'OrderCreated', 'order': order}),
    );
  }

  @override
  Future<void> clearSalesAndHistory() async {
    await db.transaction(() async {
      await db.delete(db.kDSItems).go();
      await db.delete(db.kDSOrders).go();
    });
    server.broadcast(jsonEncode({'type': 'OrderHistoryCleared'}));
  }

  @override
  void broadcastKitchenMessage(String message, {String? station}) {
    final payload = jsonEncode({
      'type': 'KitchenBroadcast',
      'message': message,
      if (station != null && station.isNotEmpty) 'station': station,
    });
    if (station != null && station.isNotEmpty) {
      server.broadcastToStation(station, payload);
    } else {
      server.broadcast(payload);
    }
  }

  @override
  void setRushMode(bool enabled) {
    server.broadcast(
      jsonEncode({'type': 'RushModeChanged', 'enabled': enabled}),
    );
  }

  @override
  void sendToClient(String clientId, Map<String, dynamic> message) =>
      server.sendToClient(clientId, message);

  @override
  Future<void> shutdownHostServices() => server.stop();

  @override
  void dispose() {}
}

List<String> _strList(dynamic value) {
  if (value is List) return value.map((e) => e.toString()).toList();
  if (value is String) {
    return value
        .split(',')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
  }
  return [];
}
