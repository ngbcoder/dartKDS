import 'dart:async';

import '../models/connected_client.dart';
import '../models/database.dart';
import '../services/web_host_client.dart';
import 'host_store.dart';

/// Browser implementation: every read is served from the host's latest
/// `HostSnapshot`, every write is a command over the WebSocket bridge.
///
/// Derived streams are cached so that repeated `watchX()` calls inside a build
/// method return the identical [Stream] instance. Without that, StreamBuilder
/// would unsubscribe/resubscribe on every rebuild and the replayed value would
/// trigger an endless rebuild loop.
class RemoteHostStore implements HostStore {
  final WebHostClient client;

  /// Raw snapshot feed. Each subscriber is seeded with the latest snapshot and
  /// then follows live updates — see [WebHostClient.snapshots] for why this
  /// cannot be a plain broadcast stream.
  late final Stream<HostSnapshotData> _snapshots;

  HostSnapshotData? _latest;
  final _incoming = StreamController<HostSnapshotData>.broadcast();
  late final StreamSubscription<HostSnapshotData> _incomingSub;

  RemoteHostStore(this.client) {
    _incomingSub = client.snapshots.listen(
      (snapshot) {
        _latest = snapshot;
        if (!_incoming.isClosed) _incoming.add(snapshot);
      },
      // Without this the error would escape as an unhandled async error
      // instead of reaching the views that care about it.
      onError: (Object e, StackTrace s) {
        if (!_incoming.isClosed) _incoming.addError(e, s);
      },
    );
    _snapshots = Stream<HostSnapshotData>.multi((controller) {
      final cached = _latest;
      if (cached != null) controller.add(cached);
      final sub = _incoming.stream.listen(
        controller.add,
        onError: controller.addError,
        onDone: controller.close,
      );
      controller.onCancel = sub.cancel;
    });
  }

  /// Waits for a snapshot to be available instead of reporting "no data" while
  /// the first one is still in flight. Bounded so a host that never answers
  /// degrades to empty rather than hanging a caller forever.
  Future<HostSnapshotData?> _awaitLatest() async {
    if (_latest != null) return _latest;
    try {
      return await _snapshots.first.timeout(const Duration(seconds: 10));
    } catch (_) {
      return null;
    }
  }

  // `late final` so each topic is projected once, on first use, and every
  // later `watchX()` call returns the identical stream instance.
  late final Stream<List<MenuItemData>> _menuItems = _snapshots.map((s) => s.menu);
  late final Stream<List<MenuItemData>> _trackedItems = _snapshots.map(
    (s) => s.menu.where((i) => i.trackStock).toList(),
  );
  late final Stream<List<MenuItemData>> _lowStockItems = _snapshots.map(
    (s) => s.menu.where((i) => i.trackStock && i.stockQuantity <= 5).toList(),
  );
  late final Stream<List<StationData>> _stations =
      _snapshots.map((s) => s.stations);
  late final Stream<List<GlobalModifierData>> _modifiers =
      _snapshots.map((s) => s.modifiers);
  late final Stream<List<KDSOrderData>> _orders = _snapshots.map((s) => s.orders);
  late final Stream<List<ItemSalesStat>> _analytics =
      _snapshots.map((s) => s.analytics);
  late final Stream<List<ConnectedClient>> _clients =
      _snapshots.map((s) => s.clients);

  final _orderItemStreams = <String, Stream<List<KDSItemData>>>{};

  @override
  Stream<List<MenuItemData>> watchMenuItems() {
    return _menuItems;
  }

  @override
  Stream<List<MenuItemData>> watchTrackedStockItems() {
    return _trackedItems;
  }

  @override
  Stream<List<MenuItemData>> watchLowStockItems() {
    return _lowStockItems;
  }

  @override
  Stream<List<StationData>> watchStations() {
    return _stations;
  }

  @override
  Stream<List<GlobalModifierData>> watchGlobalModifiers() {
    return _modifiers;
  }

  @override
  Stream<List<KDSOrderData>> watchOrders() {
    return _orders;
  }

  @override
  Stream<List<KDSItemData>> watchOrderItems(String orderUuid) {
    final cached = _orderItemStreams[orderUuid];
    if (cached != null) return cached;

    // Cap the cache: a busy service runs all day, and without a bound this
    // map retained one derived stream per order ever opened.
    if (_orderItemStreams.length >= 64) {
      _orderItemStreams.remove(_orderItemStreams.keys.first);
    }
    return _orderItemStreams[orderUuid] = _snapshots.map(
      (s) => s.itemsByOrder[orderUuid] ?? const <KDSItemData>[],
    );
  }

  @override
  Stream<List<ItemSalesStat>> watchItemSalesStats() {
    return _analytics;
  }

  @override
  Stream<List<ConnectedClient>> watchClients() {
    return _clients;
  }

  // ── Reads (one-shot) ──────────────────────────────────────────

  @override
  Future<List<MenuItemData>> getMenuItems() async =>
      (await _awaitLatest())?.menu ?? const [];

  @override
  Future<List<StationData>> getStations() async =>
      (await _awaitLatest())?.stations ?? const [];

  @override
  Future<List<KDSItemData>> getOrderItems(String orderUuid) async =>
      (await _awaitLatest())?.itemsByOrder[orderUuid] ?? const [];

  @override
  Future<List<MenuItemData>> getLowStockItems() async =>
      (await _awaitLatest())?.menu
          .where((i) => i.trackStock && i.stockQuantity <= 5)
          .toList() ??
      const [];

  @override
  Future<Map<String, dynamic>> exportLibrary() async {
    final s = await _awaitLatest();
    if (s == null) {
      return {
        'version': 1,
        'menuItems': [],
        'stations': [],
        'globalModifiers': [],
      };
    }
    return {
      'version': 1,
      'menuItems': s.menu
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
              'isCombo': i.isCombo,
            },
          )
          .toList(),
      'stations': s.stations.map((x) => {'name': x.name}).toList(),
      'globalModifiers': s.modifiers.map((x) => {'name': x.name}).toList(),
    };
  }

  @override
  Future<List<String>> getConnectedStations() async {
    final s = await _awaitLatest();
    final stations = <String>{
      for (final c in s?.clients ?? const <ConnectedClient>[])
        c.currentStation.toUpperCase(),
    }..removeWhere((s) => s.isEmpty);
    return stations.toList()..sort();
  }

  @override
  Future<List<Map<String, String>>> getKnownHosts() async =>
      (await _awaitLatest())?.hosts ?? const [];

  @override
  Future<String> getHostEndpoint() async =>
      Uri.base.hasPort ? '${Uri.base.host}:${Uri.base.port}' : Uri.base.host;

  // ── Library writes ────────────────────────────────────────────

  @override
  Future<void> saveMenuItem(MenuItemDraft draft) async =>
      client.saveMenuItem(draft.toMap());

  @override
  Future<void> deleteMenuItem(int id) async => client.deleteMenuItem(id);

  @override
  Future<void> setStock(int id, int quantity) async =>
      client.setStock(id, quantity);

  @override
  Future<void> saveStation({int? id, required String name}) async =>
      client.saveStation(id: id, name: name);

  @override
  Future<void> deleteStation(int id) async => client.deleteStation(id);

  @override
  Future<void> saveGlobalModifier({int? id, required String name}) async =>
      client.saveGlobalModifier(id: id, name: name);

  @override
  Future<void> deleteGlobalModifier(int id) async =>
      client.deleteGlobalModifier(id);

  @override
  Future<void> importLibrary(Map<String, dynamic> data) async =>
      client.importLibrary(data);

  @override
  Future<void> clearLibrary() async => client.clearLibrary();

  @override
  Stream<List<MenuItemData>> watchCombos() {
    return _menuItems.map((items) => items.where((i) => i.isCombo).toList());
  }

  @override
  Future<List<MenuItemData>> getComboComponents(int comboId) async {
    // Components are stored on the host; the web client doesn't have direct
    // access. Return empty for now — the host snapshot includes combo data
    // via the menu items list.
    return [];
  }

  @override
  Future<void> saveCombo({
    required String name,
    required double price,
    required String category,
    required String defaultStation,
    required List<int> componentItemIds,
    required List<int> componentQuantities,
  }) async {
    client.saveCombo(
      name: name,
      price: price,
      category: category,
      defaultStation: defaultStation,
      componentItemIds: componentItemIds,
      componentQuantities: componentQuantities,
    );
  }

  @override
  Future<void> deleteCombo(int id) async => client.deleteCombo(id);

  @override
  Future<void> addComboComponent(
    int comboId,
    int componentItemId,
    int quantity,
  ) async {
    // Not supported via web client bridge yet
  }

  @override
  Future<void> removeComboComponent(int comboId, int componentItemId) async {
    // Not supported via web client bridge yet
  }

  // ── Order writes ──────────────────────────────────────────────

  @override
  Future<void> submitOrder({
    required String orderUuid,
    required String customerName,
    required List<OrderLine> lines,
    required bool isEditing,
  }) async {
    client.submitOrder(
      orderUuid: orderUuid,
      customerName: customerName,
      lines: lines.map((l) => l.toMap()).toList(),
      isEditing: isEditing,
    );
  }

  @override
  Future<void> deleteOrder(String orderUuid) async =>
      client.deleteOrder(orderUuid);

  @override
  Future<void> recallOrder(String orderUuid) async =>
      client.recallOrder(orderUuid);

  @override
  Future<void> clearSalesAndHistory() async =>
      client.clearSalesAndHistory();

  // ── Kitchen communications ────────────────────────────────────

  @override
  void broadcastKitchenMessage(String message, {String? station}) =>
      client.broadcastMessage(message, station: station);

  @override
  void setRushMode(bool enabled) => client.setRushMode(enabled);

  @override
  void sendToClient(String clientId, Map<String, dynamic> message) =>
      client.sendToClient(clientId, message);

  @override
  Future<void> shutdownHostServices() async {}

  @override
  void dispose() {
    _incomingSub.cancel();
    _incoming.close();
  }
}
