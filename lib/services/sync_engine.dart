import 'dart:convert';
import 'package:drift/drift.dart';
import '../models/database.dart';
import '../models/order_status.dart';
import '../models/item_status.dart';

class SyncEngine {
  final KDSDatabase db;
  SyncEngine(this.db);

  static const int recentWindowMs = 120000;

  /// Clamps an inbound enum index instead of indexing with it directly.
  ///
  /// `applyChanges` consumes whatever a peer POSTs to `/api/sync/apply`, and a
  /// peer on a different build — or simply a hand-crafted request — can send a
  /// status index this build has no value for. Indexing would throw a
  /// `RangeError` mid-transaction and silently drop the entire change set, so
  /// an out-of-range value degrades to the nearest valid status instead.
  static T _enumAt<T>(List<T> values, Object? index) {
    final i = (index is num) ? index.toInt() : 0;
    return values[i.clamp(0, values.length - 1)];
  }

  /// Coerces an inbound list into a list of strings.
  ///
  /// `.cast<String>()` defers its type check to element access, so a payload
  /// containing a non-string would throw from inside Drift's insert and roll
  /// back the whole transaction. Non-string entries are dropped instead.
  static List<String> _strList(Object? raw) {
    if (raw is! List) return const [];
    return [
      for (final e in raw)
        if (e != null) '$e',
    ];
  }

  Future<String> getSnapshot() async {
    final orders = await db.select(db.kDSOrders).get();
    final items = await db.select(db.kDSItems).get();
    final menuItems = await db.select(db.menuItems).get();
    final stations = await db.select(db.stations).get();
    final modifiers = await db.select(db.globalModifiers).get();
    final tombstones = await db.select(db.syncTombstones).get();

    final data = {
      'orders': orders.map(_orderToMap).toList(),
      'items': items.map(_itemToMap).toList(),
      'menuItems': menuItems.map(_menuToMap).toList(),
      'stations': stations.map(_stationToMap).toList(),
      'modifiers': modifiers.map(_modifierToMap).toList(),
      'tombstones': tombstones.map(_tombstoneToMap).toList(),
    };
    return jsonEncode(data);
  }

  Future<String> getChanges(int sinceMs) async {
    // Clamp the window: a client that has been offline long enough would
    // otherwise ask for a full-table diff. This value was computed but never
    // used, so every query below used the raw (possibly ancient) timestamp.
    final windowStart = DateTime.now().millisecondsSinceEpoch - recentWindowMs;
    final effectiveSince = sinceMs < windowStart ? windowStart : sinceMs;

    final orders = await (db.select(
      db.kDSOrders,
    )..where((t) => t.updatedAtMs.isBiggerOrEqualValue(effectiveSince))).get();
    final items = await (db.select(
      db.kDSItems,
    )..where((t) => t.updatedAtMs.isBiggerOrEqualValue(effectiveSince))).get();
    final menuItems = await (db.select(
      db.menuItems,
    )..where((t) => t.updatedAtMs.isBiggerOrEqualValue(effectiveSince))).get();
    final stations = await (db.select(
      db.stations,
    )..where((t) => t.updatedAtMs.isBiggerOrEqualValue(sinceMs))).get();
    final modifiers = await (db.select(
      db.globalModifiers,
    )..where((t) => t.updatedAtMs.isBiggerOrEqualValue(sinceMs))).get();
    final tombstones = await (db.select(
      db.syncTombstones,
    )..where((t) => t.updatedAtMs.isBiggerOrEqualValue(sinceMs))).get();

    final data = {
      'orders': orders.map(_orderToMap).toList(),
      'items': items.map(_itemToMap).toList(),
      'menuItems': menuItems.map(_menuToMap).toList(),
      'stations': stations.map(_stationToMap).toList(),
      'modifiers': modifiers.map(_modifierToMap).toList(),
      'tombstones': tombstones.map(_tombstoneToMap).toList(),
    };
    return jsonEncode(data);
  }

  Future<void> applyChanges(String jsonPayload) async {
    final data = jsonDecode(jsonPayload) as Map<String, dynamic>;

    await db.transaction(() async {
      // Apply tombstones (deletes)
      final tombstones = (data['tombstones'] as List? ?? []);
      for (final t in tombstones) {
        await _applyTombstone(t as Map<String, dynamic>);
      }

      // Apply orders
      final orders = (data['orders'] as List? ?? []);
      for (final o in orders) {
        await _mergeOrder(o as Map<String, dynamic>);
      }

      // Apply items
      final items = (data['items'] as List? ?? []);
      for (final i in items) {
        await _mergeItem(i as Map<String, dynamic>);
      }

      // Apply menu items
      final menuItems = (data['menuItems'] as List? ?? []);
      for (final m in menuItems) {
        await _mergeMenuItem(m as Map<String, dynamic>);
      }

      // Apply stations
      final stations = (data['stations'] as List? ?? []);
      for (final s in stations) {
        await _mergeStation(s as Map<String, dynamic>);
      }

      // Apply modifiers
      final modifiers = (data['modifiers'] as List? ?? []);
      for (final m in modifiers) {
        await _mergeModifier(m as Map<String, dynamic>);
      }
    });
  }

  Future<void> addTombstone(String tableName, String rowKey) async {
    await db
        .into(db.syncTombstones)
        .insert(
          SyncTombstonesCompanion.insert(
            sourceTable: tableName,
            rowKey: rowKey,
            updatedAtMs: Value(DateTime.now().millisecondsSinceEpoch),
          ),
        );
  }

  Future<void> _applyTombstone(Map<String, dynamic> t) async {
    final tableName = t['sourceTable'] as String;
    final rowKey = t['rowKey'] as String;
    final updatedAtMs = t['updatedAtMs'] as int;

    // Check if we already have a newer tombstone
    final existing =
        await (db.select(db.syncTombstones)..where(
              (tbl) =>
                  tbl.sourceTable.equals(tableName) & tbl.rowKey.equals(rowKey),
            ))
            .getSingleOrNull();

    if (existing != null && existing.updatedAtMs >= updatedAtMs) return;

    // Upsert tombstone
    await db
        .into(db.syncTombstones)
        .insert(
          SyncTombstonesCompanion.insert(
            sourceTable: tableName,
            rowKey: rowKey,
            updatedAtMs: Value(updatedAtMs),
          ),
          mode: InsertMode.replace,
        );

    // Physically delete the row
    switch (tableName) {
      case 'kDSOrders':
        await (db.delete(
          db.kDSOrders,
        )..where((t) => t.uuid.equals(rowKey))).go();
        await (db.delete(
          db.kDSItems,
        )..where((t) => t.orderUuid.equals(rowKey))).go();
        break;
      case 'kDSItems':
        await (db.delete(
          db.kDSItems,
        )..where((t) => t.uuid.equals(rowKey))).go();
        break;
      case 'menuItems':
        final id = int.tryParse(rowKey);
        if (id != null)
          await (db.delete(db.menuItems)..where((t) => t.id.equals(id))).go();
        break;
      case 'stations':
        await (db.delete(
          db.stations,
        )..where((t) => t.name.equals(rowKey))).go();
        break;
      case 'globalModifiers':
        await (db.delete(
          db.globalModifiers,
        )..where((t) => t.name.equals(rowKey))).go();
        break;
    }
  }

  Future<void> _mergeOrder(Map<String, dynamic> o) async {
    final uuid = o['uuid'] as String;
    final updatedAtMs = o['updatedAtMs'] as int;

    final existing = await (db.select(
      db.kDSOrders,
    )..where((t) => t.uuid.equals(uuid))).getSingleOrNull();

    if (existing != null && existing.updatedAtMs >= updatedAtMs) return;

    // Deliberately an UPDATE rather than `InsertMode.replace`. SQLite implements
    // INSERT OR REPLACE as DELETE-then-INSERT, and `kDSItems.orderUuid`
    // references `kDSOrders.uuid` with foreign keys enabled (see the v13
    // migration note in database.dart). Replacing a parent order therefore
    // cascaded a delete over its own item rows, or raised SQLITE_CONSTRAINT —
    // and because the whole change set is applied inside one transaction, a
    // single order update could roll back every other change in the round.
    if (existing != null) {
      await (db.update(db.kDSOrders)..where((t) => t.uuid.equals(uuid))).write(
        KDSOrdersCompanion(
          customerName: Value(o['customerName'] as String),
          timestamp: Value(
            DateTime.fromMillisecondsSinceEpoch(o['timestamp'] as int),
          ),
          status: Value(_enumAt(OrderStatus.values, o['status'])),
          updatedAtMs: Value(updatedAtMs),
        ),
      );
    } else {
      await db
          .into(db.kDSOrders)
          .insert(
            KDSOrdersCompanion(
              uuid: Value(uuid),
              customerName: Value(o['customerName'] as String),
              timestamp: Value(
                DateTime.fromMillisecondsSinceEpoch(o['timestamp'] as int),
              ),
              status: Value(_enumAt(OrderStatus.values, o['status'])),
              updatedAtMs: Value(updatedAtMs),
            ),
          );
    }
  }

  Future<void> _mergeItem(Map<String, dynamic> i) async {
    final uuid = i['uuid'] as String;
    final updatedAtMs = i['updatedAtMs'] as int;

    final existing = await (db.select(
      db.kDSItems,
    )..where((t) => t.uuid.equals(uuid))).getSingleOrNull();

    if (existing != null && existing.updatedAtMs >= updatedAtMs) return;

    if (existing != null) {
      await (db.update(db.kDSItems)..where((t) => t.uuid.equals(uuid))).write(
        KDSItemsCompanion(
          orderUuid: Value(i['orderUuid'] as String),
          name: Value(i['name'] as String),
          modifiers: Value(_strList(i['modifiers'])),
          stationTag: Value(i['stationTag'] as String),
          status: Value(_enumAt(ItemStatus.values, i['status'])),
          price: Value((i['price'] as num).toDouble()),
          updatedAtMs: Value(updatedAtMs),
        ),
      );
    } else {
      await db
          .into(db.kDSItems)
          .insert(
            KDSItemsCompanion(
              uuid: Value(uuid),
              orderUuid: Value(i['orderUuid'] as String),
              name: Value(i['name'] as String),
              modifiers: Value(_strList(i['modifiers'])),
              stationTag: Value(i['stationTag'] as String),
              status: Value(_enumAt(ItemStatus.values, i['status'])),
              price: Value((i['price'] as num).toDouble()),
              updatedAtMs: Value(updatedAtMs),
            ),
          );
    }
  }

  Future<void> _mergeMenuItem(Map<String, dynamic> m) async {
    final guid = m['guid'] as String;
    final updatedAtMs = m['updatedAtMs'] as int;

    // Try to find by guid first (cross-host stable key), then by name
    MenuItemData? existing;
    if (guid.isNotEmpty) {
      final byGuid = await (db.select(
        db.menuItems,
      )..where((t) => t.guid.equals(guid))).get();
      existing = byGuid.isEmpty ? null : byGuid.first;
    }
    // `menuItems.name` carries no unique index, so two items are allowed to
    // share a name (and the library restore path used to create exactly that).
    // `getSingleOrNull()` throws on more than one match, which aborted the
    // entire change set; take the most recently touched row instead.
    if (existing == null) {
      final byName =
          await (db.select(db.menuItems)
                ..where((t) => t.name.equals(m['name'] as String))
                ..orderBy([(t) => OrderingTerm.desc(t.updatedAtMs)]))
              .get();
      existing = byName.isEmpty ? null : byName.first;
    }

    if (existing != null && existing.updatedAtMs >= updatedAtMs) return;

    if (existing != null) {
      await (db.update(
        db.menuItems,
      )..where((t) => t.id.equals(existing!.id))).write(
        MenuItemsCompanion(
          guid: guid.isNotEmpty ? Value(guid) : Value(existing.guid),
          name: Value(m['name'] as String),
          category: Value(m['category'] as String),
          defaultStation: Value(m['defaultStation'] as String),
          modifiers: Value(_strList(m['modifiers'])),
          price: Value((m['price'] as num).toDouble()),
          requiredModifiers: Value(_strList(m['requiredModifiers'])),
          tags: Value(_strList(m['tags'])),
          stockQuantity: Value(m['stockQuantity'] as int),
          trackStock: Value(m['trackStock'] as bool),
          oneTouch: Value(m['oneTouch'] as bool? ?? false),
          updatedAtMs: Value(updatedAtMs),
        ),
      );
    } else {
      await db
          .into(db.menuItems)
          .insert(
            MenuItemsCompanion(
              guid: Value(guid.isNotEmpty ? guid : m['guid'] as String? ?? ''),
              name: Value(m['name'] as String),
              category: Value(m['category'] as String),
              defaultStation: Value(m['defaultStation'] as String),
              modifiers: Value(_strList(m['modifiers'])),
              price: Value((m['price'] as num).toDouble()),
              requiredModifiers: Value(_strList(m['requiredModifiers'])),
              tags: Value(_strList(m['tags'])),
              stockQuantity: Value(m['stockQuantity'] as int),
              trackStock: Value(m['trackStock'] as bool),
              oneTouch: Value(m['oneTouch'] as bool? ?? false),
              updatedAtMs: Value(updatedAtMs),
            ),
            mode: InsertMode.replace,
          );
    }
  }

  Future<void> _mergeStation(Map<String, dynamic> s) async {
    final name = s['name'] as String;
    final updatedAtMs = s['updatedAtMs'] as int;

    final existing = await (db.select(
      db.stations,
    )..where((t) => t.name.equals(name))).getSingleOrNull();

    if (existing != null && existing.updatedAtMs >= updatedAtMs) return;

    if (existing != null) {
      await (db.update(
        db.stations,
      )..where((t) => t.id.equals(existing.id))).write(
        StationsCompanion(name: Value(name), updatedAtMs: Value(updatedAtMs)),
      );
    } else {
      await db
          .into(db.stations)
          .insert(
            StationsCompanion(
              name: Value(name),
              updatedAtMs: Value(updatedAtMs),
            ),
            mode: InsertMode.replace,
          );
    }
  }

  Future<void> _mergeModifier(Map<String, dynamic> m) async {
    final name = m['name'] as String;
    final updatedAtMs = m['updatedAtMs'] as int;

    final existing = await (db.select(
      db.globalModifiers,
    )..where((t) => t.name.equals(name))).getSingleOrNull();

    if (existing != null && existing.updatedAtMs >= updatedAtMs) return;

    if (existing != null) {
      await (db.update(
        db.globalModifiers,
      )..where((t) => t.id.equals(existing.id))).write(
        GlobalModifiersCompanion(
          name: Value(name),
          updatedAtMs: Value(updatedAtMs),
        ),
      );
    } else {
      await db
          .into(db.globalModifiers)
          .insert(
            GlobalModifiersCompanion(
              name: Value(name),
              updatedAtMs: Value(updatedAtMs),
            ),
            mode: InsertMode.replace,
          );
    }
  }

  // ── Serialization helpers ──────────────────────────────────────

  Map<String, dynamic> _orderToMap(KDSOrderData o) => {
    'uuid': o.uuid,
    'customerName': o.customerName,
    'timestamp': o.timestamp.millisecondsSinceEpoch,
    'status': o.status.index,
    'updatedAtMs': o.updatedAtMs,
  };

  Map<String, dynamic> _itemToMap(KDSItemData i) => {
    'id': i.id,
    'uuid': i.uuid,
    'orderUuid': i.orderUuid,
    'name': i.name,
    'modifiers': i.modifiers,
    'stationTag': i.stationTag,
    'status': i.status.index,
    'price': i.price,
    'updatedAtMs': i.updatedAtMs,
  };

  Map<String, dynamic> _menuToMap(MenuItemData m) => {
    'id': m.id,
    'guid': m.guid,
    'name': m.name,
    'category': m.category,
    'defaultStation': m.defaultStation,
    'modifiers': m.modifiers,
    'price': m.price,
    'requiredModifiers': m.requiredModifiers,
    'tags': m.tags,
    'stockQuantity': m.stockQuantity,
    'trackStock': m.trackStock,
    'oneTouch': m.oneTouch,
    'updatedAtMs': m.updatedAtMs,
  };

  Map<String, dynamic> _stationToMap(StationData s) => {
    'id': s.id,
    'name': s.name,
    'updatedAtMs': s.updatedAtMs,
  };

  Map<String, dynamic> _modifierToMap(GlobalModifierData m) => {
    'id': m.id,
    'name': m.name,
    'updatedAtMs': m.updatedAtMs,
  };

  Map<String, dynamic> _tombstoneToMap(SyncTombstoneData t) => {
    'sourceTable': t.sourceTable,
    'rowKey': t.rowKey,
    'updatedAtMs': t.updatedAtMs,
  };
}
