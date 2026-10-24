import 'dart:io' if (dart.library.js_interop) '../web_io_stub.dart';
import 'dart:isolate';
import 'package:drift/drift.dart';
import 'package:drift/native.dart' if (dart.library.js_interop) '../web_drift_native_stub.dart';
import 'package:drift/isolate.dart' if (dart.library.js_interop) '../web_drift_isolate_stub.dart';
import 'package:path_provider/path_provider.dart' if (dart.library.js_interop) '../web_path_provider_stub.dart';
import 'package:path/path.dart' as p;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'order_status.dart';
import 'item_status.dart';

part 'database.g.dart';

@DataClassName('KDSOrderData')
@TableIndex(name: 'order_status', columns: {#status})
@TableIndex(name: 'order_time', columns: {#timestamp})
class KDSOrders extends Table {
  TextColumn get uuid => text().withLength(min: 36, max: 36)();
  TextColumn get customerName => text().withLength(min: 1, max: 255)();
  DateTimeColumn get timestamp => dateTime()();
  IntColumn get status => intEnum<OrderStatus>()();
  IntColumn get updatedAtMs => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {uuid};
}

@DataClassName('MenuItemData')
class MenuItems extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get guid => text().withDefault(const Constant(''))();
  TextColumn get name => text().withLength(min: 1, max: 255)();
  TextColumn get category => text().withLength(min: 1, max: 255)();
  TextColumn get defaultStation => text().withLength(min: 1, max: 50)();
  TextColumn get modifiers => text().map(const ListStringConverter())();
  RealColumn get price => real().withDefault(const Constant(0.0))();
  TextColumn get requiredModifiers =>
      text().map(const NullableListStringConverter()).nullable()();
  TextColumn get tags =>
      text().map(const NullableListStringConverter()).nullable()();
  IntColumn get stockQuantity => integer().withDefault(const Constant(0))();
  BoolColumn get trackStock => boolean().withDefault(const Constant(false))();
  BoolColumn get oneTouch => boolean().withDefault(const Constant(false))();
  BoolColumn get isCombo => boolean().withDefault(const Constant(false))();
  IntColumn get updatedAtMs => integer().withDefault(const Constant(0))();
}

@DataClassName('StationData')
class Stations extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get name => text().withLength(min: 1, max: 50).unique()();
  IntColumn get updatedAtMs => integer().withDefault(const Constant(0))();
}

@DataClassName('GlobalModifierData')
class GlobalModifiers extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get name => text().withLength(min: 1, max: 100).unique()();
  IntColumn get updatedAtMs => integer().withDefault(const Constant(0))();
}

@DataClassName('ComboComponentData')
class ComboComponents extends Table {
  IntColumn get id => integer().autoIncrement()();
  @ReferenceName('comboOwner')
  IntColumn get comboItemId => integer().references(MenuItems, #id)();
  @ReferenceName('comboComponent')
  IntColumn get componentItemId => integer().references(MenuItems, #id)();
  IntColumn get quantity => integer().withDefault(const Constant(1))();
  IntColumn get updatedAtMs => integer().withDefault(const Constant(0))();
}

@DataClassName('KDSItemData')
@TableIndex(name: 'item_order', columns: {#orderUuid})
@TableIndex(name: 'item_name', columns: {#name})
class KDSItems extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get uuid => text().withLength(min: 36, max: 36)();
  TextColumn get orderUuid => text().references(KDSOrders, #uuid)();
  TextColumn get name => text().withLength(min: 1, max: 255)();
  TextColumn get modifiers => text().map(const ListStringConverter())();
  TextColumn get stationTag => text().withLength(min: 1, max: 50)();
  IntColumn get status => intEnum<ItemStatus>()();
  RealColumn get price => real().withDefault(const Constant(0.0))();
  IntColumn get updatedAtMs => integer().withDefault(const Constant(0))();
}

@DataClassName('SyncTombstoneData')
class SyncTombstones extends Table {
  TextColumn get sourceTable => text().withLength(min: 1, max: 50)();
  TextColumn get rowKey => text().withLength(min: 1, max: 255)();
  IntColumn get updatedAtMs => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {sourceTable, rowKey};
}

class ListStringConverter extends TypeConverter<List<String>, String> {
  const ListStringConverter();
  @override
  List<String> fromSql(String fromDb) {
    return fromDb.split('|').where((s) => s.isNotEmpty).toList();
  }

  @override
  String toSql(List<String> value) => value.join('|');
}

class NullableListStringConverter extends TypeConverter<List<String>, String?> {
  const NullableListStringConverter();
  @override
  List<String> fromSql(String? fromDb) {
    if (fromDb == null) return [];
    return fromDb.split('|').where((s) => s.isNotEmpty).toList();
  }

  @override
  String? toSql(List<String> value) {
    if (value.isEmpty) return null;
    return value.join('|');
  }
}

@DriftDatabase(
  tables: [
    KDSOrders,
    KDSItems,
    MenuItems,
    Stations,
    GlobalModifiers,
    ComboComponents,
    SyncTombstones,
  ],
)
class KDSDatabase extends _$KDSDatabase {
  KDSDatabase() : super(_openConnection());

  /// Opens an in-memory database so migrations can be exercised in tests
  /// without touching the device's `db.sqlite`.
  KDSDatabase.forTesting(super.executor);

  @override
  int get schemaVersion => 14;

  @override
  MigrationStrategy get migration {
    return MigrationStrategy(
      onCreate: (m) async {
        await m.createAll();
        // Seed default station
        await into(
          stations,
        ).insert(StationsCompanion.insert(name: 'Main Station'));

        // Seed some common modifiers
        await into(
          globalModifiers,
        ).insert(GlobalModifiersCompanion.insert(name: 'No Bun'));
        await into(
          globalModifiers,
        ).insert(GlobalModifiersCompanion.insert(name: 'No Cheese'));
        await into(
          globalModifiers,
        ).insert(GlobalModifiersCompanion.insert(name: 'See Cashier'));
      },
      onUpgrade: (m, from, to) async {
        if (from < 2) {
          await m.createTable(menuItems);
        }
        if (from < 3) {
          await m.createTable(stations);
          await batch((batch) {
            batch.insertAll(stations, [
              StationsCompanion.insert(name: 'Main Station'),
            ]);
          });
        }
        if (from < 4) {
          await m.createTable(globalModifiers);
        }
        if (from < 5) {
          await m.addColumn(menuItems, menuItems.price);
          await m.addColumn(kDSItems, kDSItems.price);
        }
        if (from < 6) {
          // Version 6 added requiredModifiers. If it already exists, ignore error.
          try {
            await m.addColumn(menuItems, menuItems.requiredModifiers);
          } catch (e) {
            // Likely already exists
          }
        }
        if (from < 7) {
          await m.addColumn(menuItems, menuItems.stockQuantity);
          await m.addColumn(menuItems, menuItems.trackStock);
        }
        if (from < 8) {
          // Version 8 added tags. If it already exists, ignore error.
          try {
            await m.addColumn(menuItems, menuItems.tags);
          } catch (e) {
            // Likely already exists
          }
        }
        if (from < 9) {
          // Version 9: sync infrastructure — updatedAtMs on all tables,
          // guid on MenuItems, and SyncTombstones table.
          try {
            await m.addColumn(kDSOrders, kDSOrders.updatedAtMs);
          } catch (e) {}
          try {
            await m.addColumn(kDSItems, kDSItems.updatedAtMs);
          } catch (e) {}
          try {
            await m.addColumn(menuItems, menuItems.updatedAtMs);
          } catch (e) {}
          try {
            await m.addColumn(menuItems, menuItems.guid);
          } catch (e) {}
          try {
            await m.addColumn(stations, stations.updatedAtMs);
          } catch (e) {}
          try {
            await m.addColumn(globalModifiers, globalModifiers.updatedAtMs);
          } catch (e) {}
          await m.createTable(syncTombstones);
        }
        if (from < 10) {
          await m.createIndex(
            Index(
              'order_status',
              'CREATE INDEX order_status ON k_d_s_orders (status)',
            ),
          );
          await m.createIndex(
            Index(
              'order_time',
              'CREATE INDEX order_time ON k_d_s_orders (timestamp)',
            ),
          );
          await m.createIndex(
            Index(
              'item_order',
              'CREATE INDEX item_order ON k_d_s_items (order_uuid)',
            ),
          );
          await m.createIndex(
            Index('item_name', 'CREATE INDEX item_name ON k_d_s_items (name)'),
          );
        }
        if (from < 11) {
          // Version 11: one-touch menu items (add to ticket on single tap).
          try {
            await m.addColumn(menuItems, menuItems.oneTouch);
          } catch (e) {}
        }
        if (from < 13) {
          // Version 13 retired the tabs feature, so the `is_tab` flag is gone.
          // `ALTER TABLE ... DROP COLUMN` needs SQLite 3.35+, which holds: the
          // Android build bundles its own libsqlite3 via `sqlite3_flutter_libs`
          // rather than using the system one. Rebuilding the table instead
          // would trip the `k_d_s_items.order_uuid` foreign key, since dropping
          // a parent table under `PRAGMA foreign_keys = ON` deletes its rows.
          try {
            await m.database.customStatement(
              'ALTER TABLE "k_d_s_orders" DROP COLUMN "is_tab"',
            );
          } catch (e) {
            // Nothing declares is_tab any more, so a database that predates
            // version 12 never had the column to begin with.
          }
        }
        if (from < 14) {
          // Version 14: combo/meal deals — isCombo flag on menu items and
          // ComboComponents linking table.
          try {
            await m.addColumn(menuItems, menuItems.isCombo);
          } catch (e) {}
          await m.createTable(comboComponents);
        }
      },
    );
  }

  Stream<List<ItemSalesStat>> getItemSalesStats() =>
      select(kDSItems).watch().map(aggregateItemSalesStats);

  /// Shared by the reactive stream above and the host snapshot, so the native
  /// and browser analytics tabs always show identical numbers.
  static List<ItemSalesStat> aggregateItemSalesStats(List<KDSItemData> rows) {
    final statsMap = <String, ItemSalesStat>{};

    for (final row in rows) {
      final stat = statsMap.putIfAbsent(
        row.name,
        () => ItemSalesStat(
          name: row.name,
          quantity: 0,
          revenue: 0.0,
          modifierCounts: {},
        ),
      );

      stat.quantity++;
      stat.revenue += row.price;
      for (final mod in row.modifiers) {
        if (mod.isNotEmpty) {
          stat.modifierCounts[mod] = (stat.modifierCounts[mod] ?? 0) + 1;
        }
      }
    }

    final sorted = statsMap.values.toList()
      ..sort((a, b) => b.revenue.compareTo(a.revenue));
    return sorted.take(25).toList();
  }
}

class ItemSalesStat {
  final String name;
  int quantity;
  double revenue;
  final Map<String, int> modifierCounts;

  ItemSalesStat({
    required this.name,
    required this.quantity,
    required this.revenue,
    this.modifierCounts = const {},
  });
}

LazyDatabase _openConnection() {
  if (kIsWeb) {
    return LazyDatabase(() async {
      throw UnsupportedError(
        'Local database is not available on web. Use the web build as a '
        'display client connected to a host device.',
      );
    });
  }
  return LazyDatabase(() async {
    try {
      final dbFolder = await getApplicationDocumentsDirectory();
      final file = File(p.join(dbFolder.path, 'db.sqlite'));

      // Use isolate for all database operations to keep UI thread smooth
      final driftIsolate = await _createDriftIsolate(file.path);
      // Awaited, not returned bare: returning the Future let it complete outside
      // this try, so any failure surfaced as an unhandled async error instead of
      // the wrapped, actionable message below.
      return await driftIsolate.connect();
    } catch (e) {
      throw Exception("Failed to open database: $e");
    }
  });
}

Future<DriftIsolate> _createDriftIsolate(String path) async {
  final receivePort = ReceivePort();
  await Isolate.spawn(
    _startBackground,
    _IsolateStartRequest(receivePort.sendPort, path),
  );

  return await receivePort.first as DriftIsolate;
}

void _startBackground(_IsolateStartRequest request) {
  final executor = NativeDatabase(
    File(request.path),
    setup: (db) {
      // Performance optimizations for SQLite
      db.execute('PRAGMA journal_mode = WAL');
      db.execute('PRAGMA synchronous = NORMAL');
      db.execute('PRAGMA foreign_keys = ON');
    },
  );
  final driftIsolate = DriftIsolate.inCurrent(
    () => DatabaseConnection(executor),
  );
  request.sendPort.send(driftIsolate);
}

class _IsolateStartRequest {
  final SendPort sendPort;
  final String path;
  _IsolateStartRequest(this.sendPort, this.path);
}
