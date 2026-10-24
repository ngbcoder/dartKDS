import 'package:drift/drift.dart' show Value;

import '../models/connected_client.dart';
import '../models/database.dart';
import '../models/item_status.dart';
import '../models/order_status.dart';

T _enumAt<T>(List<T> values, int index) =>
    values[index.clamp(0, values.length - 1)];

/// One line of a submitted order, decoupled from any particular UI state type
/// so both the Drift-backed and the WebSocket-backed store can consume it.
class OrderLine {
  final String name;
  final String stationTag;
  final List<String> modifiers;
  final int quantity;
  final double price;
  final int menuItemId;

  const OrderLine({
    required this.name,
    required this.stationTag,
    required this.modifiers,
    required this.quantity,
    required this.price,
    required this.menuItemId,
  });

  Map<String, dynamic> toMap() => {
    'name': name,
    'stationTag': stationTag,
    'modifiers': modifiers,
    'quantity': quantity,
    'price': price,
    'menuItemId': menuItemId,
  };

  factory OrderLine.fromMap(Map<dynamic, dynamic> m) => OrderLine(
    name: (m['name'] ?? '').toString(),
    stationTag: (m['stationTag'] ?? 'GENERAL').toString(),
    modifiers: _strList(m['modifiers']),
    quantity: (m['quantity'] as num?)?.toInt() ?? 1,
    price: (m['price'] as num?)?.toDouble() ?? 0.0,
    menuItemId: (m['menuItemId'] as num?)?.toInt() ?? -1,
  );
}

/// Fields describing a menu item being created or edited through the library.
class MenuItemDraft {
  final int? id;
  final String guid;
  final String name;
  final String category;
  final String defaultStation;
  final List<String> modifiers;
  final List<String> requiredModifiers;
  final List<String> tags;
  final double price;
  final int stockQuantity;
  final bool trackStock;
  final bool oneTouch;
  final bool isCombo;

  const MenuItemDraft({
    this.id,
    this.guid = '',
    required this.name,
    required this.category,
    required this.defaultStation,
    required this.modifiers,
    required this.requiredModifiers,
    required this.tags,
    required this.price,
    required this.stockQuantity,
    required this.trackStock,
    required this.oneTouch,
    this.isCombo = false,
  });

  Map<String, dynamic> toMap() => {
    if (id != null) 'id': id,
    'guid': guid,
    'name': name,
    'category': category,
    'defaultStation': defaultStation,
    'modifiers': modifiers,
    'requiredModifiers': requiredModifiers,
    'tags': tags,
    'price': price,
    'stockQuantity': stockQuantity,
    'trackStock': trackStock,
    'oneTouch': oneTouch,
    'isCombo': isCombo,
  };

  MenuItemsCompanion toCompanion(int nowMs) => MenuItemsCompanion(
    guid: Value(guid),
    name: Value(name),
    category: Value(category),
    defaultStation: Value(defaultStation),
    modifiers: Value(modifiers),
    requiredModifiers: Value(requiredModifiers),
    tags: Value(tags),
    price: Value(price),
    stockQuantity: Value(stockQuantity),
    trackStock: Value(trackStock),
    oneTouch: Value(oneTouch),
    isCombo: Value(isCombo),
    updatedAtMs: Value(nowMs),
  );
}

/// Single data-access surface for the host application. Implemented once
/// against Drift (native devices) and once against the host's WebSocket
/// bridge (browser), so every host view renders identically on both.
abstract class HostStore {
  // ── Reads (streams) ────────────────────────────────────────────
  Stream<List<MenuItemData>> watchMenuItems();
  Stream<List<MenuItemData>> watchTrackedStockItems();
  Stream<List<MenuItemData>> watchLowStockItems();
  Stream<List<StationData>> watchStations();
  Stream<List<GlobalModifierData>> watchGlobalModifiers();
  Stream<List<KDSOrderData>> watchOrders();
  Stream<List<KDSItemData>> watchOrderItems(String orderUuid);
  Stream<List<ItemSalesStat>> watchItemSalesStats();
  Stream<List<ConnectedClient>> watchClients();

  // ── Reads (one-shot) ──────────────────────────────────────────
  Future<List<MenuItemData>> getMenuItems();
  Future<List<StationData>> getStations();
  Future<List<KDSItemData>> getOrderItems(String orderUuid);
  Future<List<MenuItemData>> getLowStockItems();
  Future<Map<String, dynamic>> exportLibrary();
  Future<List<String>> getConnectedStations();
  Future<List<Map<String, String>>> getKnownHosts();

  /// Origin the UI should present to the user, e.g. `192.168.1.20:8080` on the
  /// device itself or the host address when driving it from a browser.
  Future<String> getHostEndpoint();

  // ── Library writes ────────────────────────────────────────────
  Future<void> saveMenuItem(MenuItemDraft draft);
  Future<void> deleteMenuItem(int id);
  Future<void> setStock(int id, int quantity);
  Future<void> saveStation({int? id, required String name});
  Future<void> deleteStation(int id);
  Future<void> saveGlobalModifier({int? id, required String name});
  Future<void> deleteGlobalModifier(int id);
  Future<void> importLibrary(Map<String, dynamic> data);
  Future<void> clearLibrary();

  // ── Combo writes ──────────────────────────────────────────────
  Stream<List<MenuItemData>> watchCombos();
  Future<List<MenuItemData>> getComboComponents(int comboId);
  Future<void> saveCombo({
    required String name,
    required double price,
    required String category,
    required String defaultStation,
    required List<int> componentItemIds,
    required List<int> componentQuantities,
  });
  Future<void> deleteCombo(int id);
  Future<void> addComboComponent(int comboId, int componentItemId, int quantity);
  Future<void> removeComboComponent(int comboId, int componentItemId);

  // ── Order writes ──────────────────────────────────────────────
  /// Creates an order, or rewrites an existing one when [isEditing]. Handles
  /// stock decrements/restorations and notifies the kitchen displays.
  Future<void> submitOrder({
    required String orderUuid,
    required String customerName,
    required List<OrderLine> lines,
    required bool isEditing,
  });
  Future<void> deleteOrder(String orderUuid);
  Future<void> recallOrder(String orderUuid);
  Future<void> clearSalesAndHistory();

  // ── Kitchen communications ────────────────────────────────────
  void broadcastKitchenMessage(String message, {String? station});
  void setRushMode(bool enabled);
  void sendToClient(String clientId, Map<String, dynamic> message);

  // ── Lifecycle ─────────────────────────────────────────────────
  /// Stops the host server/discovery when running natively. No-op remotely.
  Future<void> shutdownHostServices();

  void dispose();
}

List<String> _strList(dynamic v) {
  if (v is List) return v.map((e) => e.toString()).toList();
  if (v is String) return v.split('|').where((s) => s.isNotEmpty).toList();
  return [];
}

// ── Snapshot JSON codecs ────────────────────────────────────────
// The host serialises its database into a `HostSnapshot` message. The browser
// rebuilds the same Drift data classes from it, so the shared views never need
// to know which store they are talking to.

MenuItemData menuItemFromMap(Map<dynamic, dynamic> m) => MenuItemData(
  id: (m['id'] as num?)?.toInt() ?? -1,
  guid: (m['guid'] ?? '').toString(),
  name: (m['name'] ?? '').toString(),
  category: (m['category'] ?? 'All Items').toString(),
  defaultStation: (m['defaultStation'] ?? 'Main Station').toString(),
  modifiers: _strList(m['modifiers']),
  requiredModifiers: _strList(m['requiredModifiers']),
  tags: _strList(m['tags']),
  price: (m['price'] as num?)?.toDouble() ?? 0.0,
  stockQuantity: (m['stockQuantity'] as num?)?.toInt() ?? 0,
  trackStock: m['trackStock'] == true,
  oneTouch: m['oneTouch'] == true,
  isCombo: m['isCombo'] == true,
  updatedAtMs: (m['updatedAtMs'] as num?)?.toInt() ?? 0,
);

StationData stationFromMap(Map<dynamic, dynamic> m) => StationData(
  id: (m['id'] as num?)?.toInt() ?? -1,
  name: (m['name'] ?? '').toString(),
  updatedAtMs: (m['updatedAtMs'] as num?)?.toInt() ?? 0,
);

GlobalModifierData globalModifierFromMap(Map<dynamic, dynamic> m) =>
    GlobalModifierData(
      id: (m['id'] as num?)?.toInt() ?? -1,
      name: (m['name'] ?? '').toString(),
      updatedAtMs: (m['updatedAtMs'] as num?)?.toInt() ?? 0,
    );

KDSItemData orderItemFromMap(Map<dynamic, dynamic> m) => KDSItemData(
  id: (m['id'] as num?)?.toInt() ?? 0,
  uuid: (m['uuid'] ?? '').toString(),
  orderUuid: (m['orderUuid'] ?? '').toString(),
  name: (m['name'] ?? '').toString(),
  modifiers: _strList(m['modifiers']),
  stationTag: (m['stationTag'] ?? 'GENERAL').toString(),
  status: _enumAt(ItemStatus.values, (m['status'] as num?)?.toInt() ?? 0),
  price: (m['price'] as num?)?.toDouble() ?? 0.0,
  updatedAtMs: (m['updatedAtMs'] as num?)?.toInt() ?? 0,
);

KDSOrderData orderFromMap(Map<dynamic, dynamic> m) => KDSOrderData(
  uuid: (m['uuid'] ?? '').toString(),
  customerName: (m['customerName'] ?? 'Guest').toString(),
  timestamp: DateTime.tryParse((m['timestamp'] ?? '').toString()) ??
      DateTime.fromMillisecondsSinceEpoch(0),
  status: _enumAt(OrderStatus.values, (m['status'] as num?)?.toInt() ?? 0),
  updatedAtMs: (m['updatedAtMs'] as num?)?.toInt() ?? 0,
);

ItemSalesStat salesStatFromMap(Map<dynamic, dynamic> m) {
  final counts = <String, int>{};
  final rawCounts = m['modifierCounts'];
  if (rawCounts is Map) {
    rawCounts.forEach((k, v) {
      counts[k.toString()] = (v as num?)?.toInt() ?? 0;
    });
  }
  return ItemSalesStat(
    name: (m['name'] ?? '').toString(),
    quantity: (m['quantity'] as num?)?.toInt() ?? 0,
    revenue: (m['revenue'] as num?)?.toDouble() ?? 0.0,
    modifierCounts: counts,
  );
}

ConnectedClient clientFromMap(Map<dynamic, dynamic> m) => ConnectedClient(
  id: (m['id'] ?? '').toString(),
  deviceName: (m['deviceName'] ?? 'Unknown Device').toString(),
  currentStation: (m['currentStation'] ?? 'GENERAL').toString(),
  connectedAt:
      DateTime.tryParse((m['connectedAt'] ?? '').toString()) ??
      DateTime.fromMillisecondsSinceEpoch(0),
);
