import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/database.dart';

class IntakeItem {
  final MenuItemData menuItem;
  final List<String> selectedModifiers;
  final int quantity;

  IntakeItem({
    required this.menuItem,
    this.selectedModifiers = const [],
    this.quantity = 1,
  });

  IntakeItem copyWith({List<String>? selectedModifiers, int? quantity}) {
    return IntakeItem(
      menuItem: menuItem,
      selectedModifiers: selectedModifiers ?? this.selectedModifiers,
      quantity: quantity ?? this.quantity,
    );
  }
}

class IntakeState {
  final List<IntakeItem> items;
  final String customerName;
  final String orderNote;
  final String? editingOrderUuid;

  IntakeState({
    this.items = const [],
    this.customerName = '',
    this.orderNote = '',
    this.editingOrderUuid,
  });

  IntakeState copyWith({
    List<IntakeItem>? items,
    String? customerName,
    String? orderNote,
    String? editingOrderUuid,
    bool clearEditing = false,
  }) {
    return IntakeState(
      items: items ?? this.items,
      customerName: customerName ?? this.customerName,
      orderNote: orderNote ?? this.orderNote,
      editingOrderUuid: clearEditing ? null : (editingOrderUuid ?? this.editingOrderUuid),
    );
  }
}

class IntakeNotifier extends StateNotifier<IntakeState> {
  IntakeNotifier() : super(IntakeState());

  void addItem(MenuItemData item, {List<String> selectedModifiers = const [], int quantity = 1}) {
    state = state.copyWith(
      items: [...state.items, IntakeItem(menuItem: item, selectedModifiers: selectedModifiers, quantity: quantity)],
    );
  }

  void loadOrder(String orderUuid, String customerName, List<IntakeItem> items) {
    state = IntakeState(
      items: items,
      customerName: customerName,
      editingOrderUuid: orderUuid,
    );
  }

  void updateItem(int index, {List<String>? modifiers, int? quantity}) {
    final newItems = List<IntakeItem>.from(state.items);
    newItems[index] = newItems[index].copyWith(
      selectedModifiers: modifiers,
      quantity: quantity,
    );
    state = state.copyWith(items: newItems);
  }

  void removeItem(int index) {
    final newItems = List<IntakeItem>.from(state.items)..removeAt(index);
    state = state.copyWith(items: newItems);
  }

  void setCustomerName(String name) {
    state = state.copyWith(customerName: name);
  }

  void setOrderNote(String note) {
    state = state.copyWith(orderNote: note);
  }

  void clear() {
    state = IntakeState();
  }
}

final intakeProvider = StateNotifierProvider<IntakeNotifier, IntakeState>((ref) {
  return IntakeNotifier();
});
