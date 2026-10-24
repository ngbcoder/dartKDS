import 'package:dartkds/data/host_store.dart';
import 'package:dartkds/models/connected_client.dart';
import 'package:dartkds/models/database.dart';
import 'package:dartkds/providers/host_store_provider.dart';
import 'package:dartkds/ui/host/views/order_intake_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Phone-sized checks for the intake screen's scroll behaviour.
///
/// The regression: the order summary was a `Positioned` overlay on top of the
/// menu, so on a phone the bottom rows of the menu grid sat underneath the sheet
/// and the sheet's own list swallowed the drag. Adding the first item is what
/// made the sheet appear, which is why it only went wrong once you added
/// something.
void main() {
  const phone = Size(420, 800);

  MenuItemData item(int id, String name) => MenuItemData(
    id: id,
    guid: 'g$id',
    name: name,
    category: 'Mains',
    defaultStation: 'GRILL',
    modifiers: const [],
    requiredModifiers: const [],
    tags: const [],
    price: 9.5,
    stockQuantity: 20,
    trackStock: false,
    oneTouch: false,
    isCombo: false,
    updatedAtMs: 0,
  );

  Widget wrap(List<MenuItemData> items) {
    return ProviderScope(
      overrides: [hostStoreProvider.overrideWithValue(StubHostStore(items))],
      // Sized to the phone for every test, so a test that forgets to call
      // `usePhone` cannot quietly assert against a 800x600 default and pass for
      // the wrong reason.
      child: const MaterialApp(home: Scaffold(body: OrderIntakeView())),
    );
  }

  void usePhone(WidgetTester tester) {
    tester.view.physicalSize = phone;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  /// Mounts the screen at phone size and settles.
  ///
  /// The extra settle matters: the store hands back a `Stream.value`, which
  /// delivers on a microtask, so without it the first frame is still the
  /// loading spinner and every finder comes up empty.
  Future<void> pumpPhone(WidgetTester tester, List<MenuItemData> items) async {
    await tester.pumpWidget(wrap(items));
    await tester.pumpAndSettle();
  }

  testWidgets('the menu can be scrolled to its last item on a phone', (
    tester,
  ) async {
    usePhone(tester);
    await pumpPhone(tester, List.generate(24, (i) => item(i, 'Item ${i + 1}')));

    expect(find.text('ITEM 24'), findsOneWidget);

    await tester.drag(find.byType(GridView), const Offset(0, -2000));
    await tester.pumpAndSettle();

    expect(
      find.text('ITEM 24'),
      findsOneWidget,
      reason: 'the last menu item must be reachable by scrolling',
    );
  });

  testWidgets('adding an item does not bury the lower menu rows', (
    tester,
  ) async {
    usePhone(tester);
    await pumpPhone(tester, List.generate(24, (i) => item(i, 'Item ${i + 1}')));

    // Adding the first item is what used to reveal the overlay sheet and strand
    // the bottom of the menu underneath it.
    await tester.tap(find.text('ITEM 1'));
    await tester.pumpAndSettle();

    // The order summary is now present...
    expect(find.text('ITEMS (1)'), findsOneWidget);
    expect(find.text('COMPLETE ORDER'), findsOneWidget);

    // ...and the menu is still scrollable underneath it.
    await tester.drag(find.byType(GridView), const Offset(0, -2000));
    await tester.pumpAndSettle();

    expect(
      find.text('ITEM 24'),
      findsOneWidget,
      reason: 'the menu must still scroll after the summary appears',
    );
  });

  testWidgets('the send button stays on screen after several items', (
    tester,
  ) async {
    usePhone(tester);
    await pumpPhone(tester, List.generate(12, (i) => item(i, 'Item ${i + 1}')));

    for (final name in ['ITEM 1', 'ITEM 2', 'ITEM 3']) {
      await tester.tap(find.text(name));
      await tester.pumpAndSettle();
    }

    // The footer button sits inside the sheet, which now has a bounded height
    // rather than being an overlay, so it cannot be pushed off screen.
    final send = find.text('COMPLETE ORDER');
    expect(send, findsOneWidget);
    final rect = tester.getRect(send);
    expect(
      rect.bottom,
      lessThanOrEqualTo(phone.height),
      reason: 'the send button must be on screen',
    );
    expect(rect.top, greaterThanOrEqualTo(0));
  });

  testWidgets('a tapped item appears in the ticket with its price', (
    tester,
  ) async {
    usePhone(tester);
    await pumpPhone(tester, [item(1, 'Burger')]);

    await tester.tap(find.text('BURGER'));
    await tester.pumpAndSettle();

    expect(find.text('ITEMS (1)'), findsOneWidget);
    expect(find.text('\$9.50'), findsWidgets);
  });

  testWidgets('the overlay layout really does bury the menu', (tester) async {
    // Guards the other tests. If the assertions below were passing for a reason
    // unrelated to the fix — a filter hiding the grid, a collapsed layout —
    // they would keep passing after a regression. This proves the old layout is
    // detectable, by reproducing it and confirming the menu is covered.
    usePhone(tester);
    await pumpPhone(tester, List.generate(24, (i) => item(i, 'Item ${i + 1}')));
    final view = tester.state<OrderIntakeViewState>(
      find.byType(OrderIntakeView),
    );
    view.overlaySheetOnPhone = true;
    await tester.pumpAndSettle();

    await tester.tap(find.text('ITEM 1'));
    await tester.pumpAndSettle();

    final grid = tester.getRect(find.byType(GridView));
    final send = tester.getRect(find.text('COMPLETE ORDER'));
    expect(
      send.top,
      lessThan(grid.bottom),
      reason: 'the overlay sheet is drawn over the menu, which is the bug',
    );
  });

  testWidgets('the menu and the ticket do not overlap on a short screen', (
    tester,
  ) async {
    // A small phone where a 40% sheet plus a minimum menu would not fit. The
    // sheet has to give way, not squeeze the grid to nothing.
    tester.view.physicalSize = const Size(360, 560);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await pumpPhone(tester, List.generate(20, (i) => item(i, 'Item ${i + 1}')));
    await tester.tap(find.text('ITEM 1'));
    await tester.pumpAndSettle();

    final grid = tester.getRect(find.byType(GridView));
    final send = tester.getRect(find.text('COMPLETE ORDER'));
    expect(
      grid.bottom,
      lessThanOrEqualTo(send.top + 0.5),
      reason: 'the sheet must not be laid on top of the menu',
    );
    expect(grid.height, greaterThan(100), reason: 'the menu stays usable');
  });
}

/// Minimal store so the screen renders without a database or socket.
class StubHostStore implements HostStore {
  StubHostStore(this._menu);

  final List<MenuItemData> _menu;

  @override
  Stream<List<MenuItemData>> watchMenuItems() => Stream.value(_menu);

  @override
  Stream<List<MenuItemData>> watchTrackedStockItems() => Stream.value(_menu);

  @override
  Stream<List<MenuItemData>> watchLowStockItems() => Stream.value([]);

  @override
  Stream<List<StationData>> watchStations() =>
      Stream.value([StationData(id: 1, name: 'GRILL', updatedAtMs: 0)]);

  @override
  Stream<List<GlobalModifierData>> watchGlobalModifiers() => Stream.value([]);

  @override
  Stream<List<KDSOrderData>> watchOrders() => Stream.value([]);

  @override
  Stream<List<KDSItemData>> watchOrderItems(String orderUuid) =>
      Stream.value([]);

  @override
  Stream<List<ItemSalesStat>> watchItemSalesStats() => Stream.value([]);

  @override
  Stream<List<ConnectedClient>> watchClients() => Stream.value([]);

  @override
  Future<List<MenuItemData>> getMenuItems() async => _menu;

  @override
  Future<List<StationData>> getStations() async => [];

  @override
  Future<List<KDSItemData>> getOrderItems(String orderUuid) async => [];

  @override
  Future<List<MenuItemData>> getLowStockItems() async => [];

  @override
  Future<Map<String, dynamic>> exportLibrary() async => {};

  @override
  Future<List<String>> getConnectedStations() async => [];

  @override
  Future<List<Map<String, String>>> getKnownHosts() async => [];

  @override
  Future<String> getHostEndpoint() async => '127.0.0.1:8080';

  @override
  Future<void> saveMenuItem(MenuItemDraft draft) async {}

  @override
  Future<void> deleteMenuItem(int id) async {}

  @override
  Future<void> setStock(int id, int quantity) async {}

  @override
  Future<void> saveStation({int? id, required String name}) async {}

  @override
  Future<void> deleteStation(int id) async {}

  @override
  Future<void> saveGlobalModifier({int? id, required String name}) async {}

  @override
  Future<void> deleteGlobalModifier(int id) async {}

  @override
  Future<void> importLibrary(Map<String, dynamic> data) async {}

  @override
  Future<void> clearLibrary() async {}

  @override
  Future<void> submitOrder({
    required String orderUuid,
    required String customerName,
    required List<OrderLine> lines,
    required bool isEditing,
  }) async {}

  @override
  Future<void> deleteOrder(String orderUuid) async {}

  @override
  Future<void> recallOrder(String orderUuid) async {}

  @override
  Future<void> clearSalesAndHistory() async {}

  @override
  void broadcastKitchenMessage(String message, {String? station}) {}

  @override
  void setRushMode(bool enabled) {}

  @override
  void sendToClient(String clientId, Map<String, dynamic> message) {}

  @override
  Future<void> shutdownHostServices() async {}

  @override
  void dispose() {}

  @override
  Stream<List<MenuItemData>> watchCombos() => Stream.value([]);

  @override
  Future<List<MenuItemData>> getComboComponents(int comboId) async => [];

  @override
  Future<void> saveCombo({
    required String name,
    required double price,
    required String category,
    required String defaultStation,
    required List<int> componentItemIds,
    required List<int> componentQuantities,
  }) async {}

  @override
  Future<void> deleteCombo(int id) async {}

  @override
  Future<void> addComboComponent(
    int comboId,
    int componentItemId,
    int quantity,
  ) async {}

  @override
  Future<void> removeComboComponent(int comboId, int componentItemId) async {}
}
