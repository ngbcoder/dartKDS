import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import 'package:confetti/confetti.dart';
import '../../../models/database.dart';
import '../../../data/host_store.dart';
import '../../../providers/intake_provider.dart';
import '../../../providers/host_store_provider.dart';
import '../../../providers/settings_provider.dart';
import '../../shared/responsive_utils.dart';

double parseModifierPrice(String modifier) {
  final regex = RegExp(r'\+\s*\$?([0-9]+(\.[0-9]+)?)');
  final match = regex.firstMatch(modifier);
  if (match != null) {
    return double.tryParse(match.group(1) ?? '0') ?? 0.0;
  }
  return 0.0;
}

class OrderIntakeView extends ConsumerStatefulWidget {
  const OrderIntakeView({super.key});

  @override
  ConsumerState<OrderIntakeView> createState() => OrderIntakeViewState();
}

@visibleForTesting
class OrderIntakeViewState extends ConsumerState<OrderIntakeView> {
  late ConfettiController _confettiController;
  String _searchQuery = '';
  String _selectedCategory = 'ALL';
  String _selectedTag = 'ALL';
  String _sortBy = 'name';
  bool _filtersExpanded = false;
  Timer? _searchDebounce;

  /// Held for the lifetime of the view rather than built inline. Creating a
  /// `TextEditingController` inside `build` gave every rebuild a fresh
  /// controller seeded from provider state, and since every keystroke writes
  /// through `onChanged` and therefore rebuilds, the caret was thrown back to
  /// the end of the field after each character — typing into the middle of a
  /// guest name was impossible. It also leaked one controller per rebuild.
  final TextEditingController _customerNameController = TextEditingController();
  final TextEditingController _orderNoteController = TextEditingController();

  /// Pushes provider state into the fields only when the two actually differ,
  /// so externally-driven changes (`loadOrder`, `clear`) still land without
  /// disturbing the caret while the user is typing.
  void _syncField(TextEditingController controller, String value) {
    if (controller.text != value) {
      controller.value = TextEditingValue(
        text: value,
        selection: TextSelection.collapsed(offset: value.length),
      );
    }
  }

  /// Restores the old phone behaviour, where the order summary was laid over
  /// the menu instead of beside it. Kept so a regression test can assert that
  /// the sheet really does cover the menu when this is on — otherwise "the menu
  /// is still scrollable" would pass for the wrong reason if the layout changed
  /// shape again.
  @visibleForTesting
  bool overlaySheetOnPhone = false;

  @override
  void initState() {
    super.initState();
    _confettiController = ConfettiController(
      duration: const Duration(milliseconds: 800),
    );
  }

  @override
  void dispose() {
    _confettiController.dispose();
    _searchDebounce?.cancel();
    _customerNameController.dispose();
    _orderNoteController.dispose();
    super.dispose();
  }

  int _calcColumns(double width) {
    if (width < 400) return 3;
    if (width < 700) return 4;
    if (width < 1000) return 5;
    if (width < 1300) return 6;
    return 7;
  }

  @override
  Widget build(BuildContext context) {
    final isTablet =
        Responsive.isTablet(context) || Responsive.isDesktop(context);
    final theme = Theme.of(context);
    final intakeState = ref.watch(intakeProvider);

    // On a phone the order summary used to be a `Positioned` overlay on top of
    // the menu, with no space reserved for it. The bottom rows of the menu grid
    // sat underneath the sheet and its own ListView swallowed the drag, so
    // adding the first item made the lower half of the menu unreachable. The
    // sheet is a real row here instead, so the menu shrinks and stays scrollable.
    final showSummary = intakeState.items.isNotEmpty;
    final summaryHeight = showSummary ? _bottomSheetHeight(context) : 0.0;

    final menu = RepaintBoundary(child: _buildMenuSection(context));

    return Stack(
      children: [
        if (isTablet)
          Row(
            children: [
              Expanded(flex: 3, child: menu),
              if (showSummary)
                Container(
                  width: 360,
                  decoration: BoxDecoration(
                    border: Border(
                      left: BorderSide(color: theme.dividerColor, width: 2),
                    ),
                  ),
                  // Explicit height. `panelContent` is a Column with an Expanded
                  // list, so an unbounded height here would throw instead of
                  // laying out.
                  height: MediaQuery.sizeOf(context).height,
                  child: RepaintBoundary(
                    child: _buildOrderSummarySection(
                      context,
                      isSidePanel: true,
                    ),
                  ),
                ),
            ],
          )
        else if (overlaySheetOnPhone)
          Stack(
            children: [
              menu,
              if (showSummary)
                Positioned(
                  bottom: 0,
                  left: 0,
                  right: 0,
                  child: RepaintBoundary(
                    child: SizedBox(
                      height: summaryHeight,
                      child: _buildOrderSummarySection(
                        context,
                        isSidePanel: false,
                      ),
                    ),
                  ),
                ),
            ],
          )
        else
          Column(
            children: [
              Expanded(child: menu),
              if (showSummary)
                RepaintBoundary(
                  child: SizedBox(
                    height: summaryHeight,
                    child: _buildOrderSummarySection(
                      context,
                      isSidePanel: false,
                    ),
                  ),
                ),
            ],
          ),
        IgnorePointer(
          child: Align(
            alignment: Alignment.center,
            child: ConfettiWidget(
              confettiController: _confettiController,
              blastDirectionality: BlastDirectionality.explosive,
              emissionFrequency: 0.1,
              numberOfParticles: 50,
              shouldLoop: false,
              colors: const [
                Colors.blue,
                Colors.green,
                Colors.yellow,
                Colors.red,
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildMenuSection(BuildContext context) {
    final store = ref.watch(hostStoreProvider);
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Column(
      children: [
        Container(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          decoration: BoxDecoration(
            color: theme.scaffoldBackgroundColor,
            border: Border(bottom: BorderSide(color: theme.dividerColor)),
          ),
          child: Column(
            children: [
              // Not `Expanded`. This Column lives inside a Container with no
              // fixed height, so it is laid out with unbounded height and a
              // flex child is invalid there. The search field and the FILTERS
              // button are also stacked vertically, so they never compete for
              // width — the field needs no flex. See the FILTERS row below for
              // where the real horizontal overflow was.
              TextField(
                onChanged: (val) {
                  _searchDebounce?.cancel();
                  _searchDebounce = Timer(
                    const Duration(milliseconds: 300),
                    () {
                      setState(() => _searchQuery = val.toLowerCase());
                    },
                  );
                },
                style: const TextStyle(
                  fontWeight: FontWeight.w600,
                  fontSize: 14,
                ),
                decoration: InputDecoration(
                  hintText: 'Search menu...',
                  hintStyle: TextStyle(
                    color: theme.hintColor,
                    fontWeight: FontWeight.normal,
                  ),
                  prefixIcon: Icon(
                    Icons.search,
                    size: 18,
                    color: theme.hintColor,
                  ),
                  filled: true,
                  fillColor: isDark ? const Color(0xFF1A1A1A) : Colors.white,
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 10,
                  ),
                ),
              ),
              InkWell(
                onTap: () =>
                    setState(() => _filtersExpanded = !_filtersExpanded),
                child: Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Row(
                    children: [
                      Icon(Icons.tune, size: 14, color: theme.hintColor),
                      const SizedBox(width: 6),
                      // This is the row that actually overflowed on a 360px
                      // phone — not the search field, which sits above it and
                      // never competes for width. `HIDE FILTERS` plus the
                      // active-filter badge plus the sort dropdown did not fit
                      // in the 328px the header leaves, and the caret at the end
                      // was clipped off the right edge. The label and the badge
                      // are the only children that can grow, so they are the
                      // ones made shrinkable; the `Spacer` and the dropdown keep
                      // their natural size.
                      Flexible(
                        child: Text(
                          _filtersExpanded ? 'HIDE FILTERS' : 'FILTERS',
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w800,
                            color: theme.hintColor,
                            letterSpacing: 0.5,
                          ),
                        ),
                      ),
                      if (!_filtersExpanded &&
                          (_selectedCategory != 'ALL' ||
                              _selectedTag != 'ALL')) ...[
                        const SizedBox(width: 8),
                        Flexible(
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: theme.colorScheme.primary.withValues(
                                alpha: 0.1,
                              ),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              '$_selectedCategory${_selectedTag != 'ALL' ? ' · $_selectedTag' : ''}',
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 9,
                                fontWeight: FontWeight.w800,
                                color: theme.colorScheme.primary,
                              ),
                            ),
                          ),
                        ),
                      ],
                      const Spacer(),
                      DropdownButton<String>(
                        value: _sortBy,
                        underline: const SizedBox(),
                        isDense: true,
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 11,
                          color: theme.colorScheme.onSurface,
                        ),
                        items: const [
                          DropdownMenuItem(
                            value: 'name',
                            child: Text('Sort: Name'),
                          ),
                          DropdownMenuItem(
                            value: 'price_asc',
                            child: Text(r'Sort: Price ($–$$)'),
                          ),
                          DropdownMenuItem(
                            value: 'price_desc',
                            child: Text(r'Sort: Price ($$$–$)'),
                          ),
                          DropdownMenuItem(
                            value: 'category',
                            child: Text('Sort: Category'),
                          ),
                          DropdownMenuItem(
                            value: 'station',
                            child: Text('Sort: Station'),
                          ),
                        ],
                        onChanged: (val) {
                          if (val != null) setState(() => _sortBy = val);
                        },
                      ),
                      const SizedBox(width: 8),
                      Icon(
                        _filtersExpanded
                            ? Icons.keyboard_arrow_up
                            : Icons.keyboard_arrow_down,
                        size: 16,
                        color: theme.hintColor,
                      ),
                    ],
                  ),
                ),
              ),
              if (_filtersExpanded) ...[
                const SizedBox(height: 8),
                _buildFilterChipRow(
                  stream: store.watchMenuItems().map((items) {
                    final cats = items
                        .map((i) => i.category.trim().toUpperCase())
                        .where(
                          (c) => c.isNotEmpty && c != 'ALL' && c != 'ALL ITEMS',
                        )
                        .toSet();
                    return ['ALL', ...cats];
                  }),
                  selected: _selectedCategory,
                  onSelected: (c) => setState(() => _selectedCategory = c),
                ),
                const SizedBox(height: 8),
                _buildFilterChipRow(
                  stream: store.watchMenuItems().map((items) {
                    final tags = items
                        .expand((i) => i.tags)
                        .map((t) => t.trim().toUpperCase())
                        .where((t) => t.isNotEmpty && t != 'ALL')
                        .toSet();
                    return ['ALL', ...tags];
                  }),
                  selected: _selectedTag,
                  onSelected: (t) => setState(() => _selectedTag = t),
                ),
              ],
            ],
          ),
        ),
        Expanded(
          child: StreamBuilder<List<MenuItemData>>(
            stream: store.watchMenuItems(),
            builder: (context, snapshot) {
              if (snapshot.hasError) {
                return Center(child: Text('Error: ${snapshot.error}'));
              }
              if (!snapshot.hasData) {
                return const Center(child: CircularProgressIndicator());
              }

              var items = snapshot.data!;
              if (_selectedCategory != 'ALL') {
                items = items
                    .where((i) => i.category.toUpperCase() == _selectedCategory)
                    .toList();
              }
              if (_searchQuery.isNotEmpty) {
                items = items
                    .where((i) => i.name.toLowerCase().contains(_searchQuery))
                    .toList();
              }
              if (_selectedTag != 'ALL') {
                items = items
                    .where(
                      (i) => i.tags.any((t) => t.toUpperCase() == _selectedTag),
                    )
                    .toList();
              }

              final sortedItems = [...items];
              switch (_sortBy) {
                case 'name':
                  sortedItems.sort(
                    (a, b) =>
                        a.name.toLowerCase().compareTo(b.name.toLowerCase()),
                  );
                  break;
                case 'price_asc':
                  sortedItems.sort((a, b) => a.price.compareTo(b.price));
                  break;
                case 'price_desc':
                  sortedItems.sort((a, b) => b.price.compareTo(a.price));
                  break;
                case 'category':
                  sortedItems.sort(
                    (a, b) => a.category.toLowerCase().compareTo(
                      b.category.toLowerCase(),
                    ),
                  );
                  break;
                case 'station':
                  sortedItems.sort(
                    (a, b) => a.defaultStation.toLowerCase().compareTo(
                      b.defaultStation.toLowerCase(),
                    ),
                  );
                  break;
              }

              if (sortedItems.isEmpty) {
                return Center(
                  child: Text(
                    'No items found',
                    style: TextStyle(
                      color: theme.hintColor,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                );
              }

              return LayoutBuilder(
                builder: (context, constraints) {
                  final crossCount = _calcColumns(constraints.maxWidth);
                  return GridView.builder(
                    padding: const EdgeInsets.all(10),
                    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: crossCount,
                      crossAxisSpacing: 8,
                      mainAxisSpacing: 8,
                      childAspectRatio: 1.0,
                    ),
                    itemCount: sortedItems.length,
                    itemBuilder: (context, index) {
                      final item = sortedItems[index];
                      final isOut = item.trackStock && item.stockQuantity <= 0;

                      return AnimatedContainer(
                        duration: const Duration(milliseconds: 200),
                        child: Material(
                          color: isOut
                              ? theme.dividerColor.withValues(alpha: 0.2)
                              : theme.cardColor,
                          borderRadius: BorderRadius.circular(16),
                          clipBehavior: Clip.antiAlias,
                          child: InkWell(
                            onTap: isOut
                                ? null
                                : () {
                                    HapticFeedback.mediumImpact();
                                    _handleItemTap(context, ref, item);
                                  },
                            child: Container(
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(16),
                                border: Border.all(
                                  color: isOut
                                      ? Colors.transparent
                                      : theme.dividerColor,
                                  width: 1.5,
                                ),
                              ),
                              padding: const EdgeInsets.all(16),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    item.name.toUpperCase(),
                                    style: TextStyle(
                                      fontWeight: FontWeight.w800,
                                      fontSize: 13,
                                      color: isOut
                                          ? theme.hintColor
                                          : theme.textTheme.bodyLarge?.color,
                                      letterSpacing: -0.3,
                                    ),
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  const Spacer(),
                                  if (item.oneTouch || item.tags.isNotEmpty)
                                    Padding(
                                      padding: const EdgeInsets.only(bottom: 6),
                                      child: Text(
                                        [
                                          if (item.oneTouch) '⚡ QUICK',
                                          ...item.tags
                                              .take(1)
                                              .map((t) => t.toUpperCase()),
                                        ].join(' • '),
                                        style: TextStyle(
                                          fontSize: 8,
                                          fontWeight: FontWeight.w900,
                                          color: theme.colorScheme.primary,
                                        ),
                                      ),
                                    ),
                                  Row(
                                    mainAxisAlignment:
                                        MainAxisAlignment.spaceBetween,
                                    children: [
                                      // Flexible on both sides: at four columns
                                      // on a narrow phone the tile is barely
                                      // wider than the two labels, and a rigid
                                      // Row overflowed by a couple of pixels.
                                      Flexible(
                                        child: Text(
                                          '\$${item.price.toStringAsFixed(2)}',
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            fontWeight: FontWeight.w900,
                                            fontSize: 12,
                                            color: isOut
                                                ? theme.hintColor
                                                : theme.colorScheme.primary,
                                          ),
                                        ),
                                      ),
                                      if (item.trackStock)
                                        Flexible(
                                          child: Text(
                                            isOut
                                                ? 'OUT'
                                                : '${item.stockQuantity}',
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            textAlign: TextAlign.end,
                                            style: TextStyle(
                                              fontSize: 9,
                                              fontWeight: FontWeight.w900,
                                              color: isOut
                                                  ? Colors.red
                                                  : theme.hintColor,
                                            ),
                                          ),
                                        ),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      );
                    },
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildOrderSummarySection(
    BuildContext context, {
    required bool isSidePanel,
  }) {
    final intakeState = ref.watch(intakeProvider);
    final theme = Theme.of(context);

    _syncField(_customerNameController, intakeState.customerName);
    _syncField(_orderNoteController, intakeState.orderNote);

    final isEditingOrder = intakeState.editingOrderUuid != null;
    final cartTotal = _cartTotal(intakeState);

    final panelContent = Material(
      color: theme.cardColor,
      child: Column(
        children: [
          // Everything above the send button now scrolls as one unit, with the
          // button pinned. Previously the header, the ITEMS count row and the
          // order-note field were rigid and only the item list had an
          // `Expanded`, so on a short screen the fixed chrome alone exceeded
          // the sheet's height: the list was squeezed to zero and the Column
          // overflowed by ~20px. `_bottomSheetHeight` cannot rescue that — it
          // hands out `screenHeight * 0.4`, which on a 560px phone is 224px,
          // less than the chrome needs. Letting the whole ticket region scroll
          // removes the assumption that the chrome always fits, while the
          // button stays visible and tappable, which is the one thing that
          // must never scroll away.
          Expanded(
            child: SingleChildScrollView(
              child: Column(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 10,
                    ),
                    decoration: BoxDecoration(
                      color: isEditingOrder
                          ? theme.colorScheme.primary.withValues(alpha: 0.1)
                          : theme.dividerColor.withValues(alpha: 0.1),
                      border: Border(
                        bottom: BorderSide(color: theme.dividerColor),
                      ),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          Icons.receipt_long_rounded,
                          size: 16,
                          color: isEditingOrder
                              ? theme.colorScheme.primary
                              : theme.hintColor,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: TextField(
                            controller: _customerNameController,
                            onChanged: (val) => ref
                                .read(intakeProvider.notifier)
                                .setCustomerName(val),
                            style: const TextStyle(
                              fontWeight: FontWeight.w900,
                              fontSize: 14,
                              letterSpacing: 0.5,
                            ),
                            decoration: InputDecoration(
                              hintText: 'GUEST / ORDER NAME',
                              hintStyle: TextStyle(
                                color: theme.hintColor,
                                fontWeight: FontWeight.normal,
                                fontSize: 12,
                              ),
                              isDense: true,
                              border: InputBorder.none,
                            ),
                          ),
                        ),
                        if (isEditingOrder)
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: theme.colorScheme.primary.withValues(
                                alpha: 0.15,
                              ),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              'EDITING',
                              style: TextStyle(
                                fontWeight: FontWeight.w900,
                                fontSize: 10,
                                color: theme.colorScheme.primary,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 4,
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          'ITEMS (${intakeState.items.length})',
                          style: theme.textTheme.labelLarge,
                        ),
                        TextButton(
                          onPressed: () {
                            showDialog(
                              context: context,
                              builder: (ctx) => AlertDialog(
                                title: const Text(
                                  'CLEAR TICKET?',
                                  style: TextStyle(
                                    fontWeight: FontWeight.w900,
                                    fontSize: 16,
                                  ),
                                ),
                                content: const Text(
                                  'This will clear items from the current view.',
                                ),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                actions: [
                                  TextButton(
                                    onPressed: () => Navigator.pop(ctx),
                                    child: const Text(
                                      'CANCEL',
                                      style: TextStyle(
                                        fontWeight: FontWeight.w800,
                                      ),
                                    ),
                                  ),
                                  TextButton(
                                    onPressed: () {
                                      Navigator.pop(ctx);
                                      ref.read(intakeProvider.notifier).clear();
                                      if (!context.mounted) return;
                                    },
                                    child: const Text(
                                      'CLEAR',
                                      style: TextStyle(
                                        color: Colors.red,
                                        fontWeight: FontWeight.w900,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            );
                          },
                          child: const Text(
                            'CLEAR',
                            style: TextStyle(
                              color: Colors.red,
                              fontWeight: FontWeight.w900,
                              fontSize: 11,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 6,
                    ),
                    child: TextField(
                      controller: _orderNoteController,
                      onChanged: (val) =>
                          ref.read(intakeProvider.notifier).setOrderNote(val),
                      style: const TextStyle(fontSize: 12),
                      decoration: InputDecoration(
                        hintText: 'Special instructions / order note...',
                        hintStyle: TextStyle(
                          color: theme.hintColor,
                          fontSize: 11,
                        ),
                        isDense: true,
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 8,
                        ),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(6),
                          borderSide: BorderSide(color: theme.dividerColor),
                        ),
                      ),
                    ),
                  ),
                  const Divider(height: 1),
                  ListView.separated(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    itemCount: intakeState.items.length,
                    separatorBuilder: (context, index) =>
                        Divider(color: theme.dividerColor, height: 1),
                    itemBuilder: (context, index) {
                      final item = intakeState.items[index];
                      return ListTile(
                        contentPadding: EdgeInsets.zero,
                        visualDensity: VisualDensity.compact,
                        leading: const SizedBox.shrink(),
                        title: Text(
                          item.menuItem.name,
                          style: const TextStyle(
                            fontWeight: FontWeight.w700,
                            fontSize: 14,
                          ),
                        ),
                        subtitle: item.selectedModifiers.isNotEmpty
                            ? Text(
                                item.selectedModifiers.join(' • '),
                                style: const TextStyle(
                                  fontSize: 11,
                                  color: Color(0xFF666666),
                                ),
                              )
                            : null,
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              icon: const Icon(
                                Icons.remove_circle_outline,
                                size: 16,
                              ),
                              visualDensity: VisualDensity.compact,
                              onPressed: () {
                                if (item.quantity > 1) {
                                  ref
                                      .read(intakeProvider.notifier)
                                      .updateItem(
                                        index,
                                        quantity: item.quantity - 1,
                                      );
                                } else {
                                  ref
                                      .read(intakeProvider.notifier)
                                      .removeItem(index);
                                }
                              },
                            ),
                            Text(
                              '${item.quantity}',
                              style: const TextStyle(
                                fontWeight: FontWeight.w900,
                                fontSize: 13,
                              ),
                            ),
                            IconButton(
                              icon: const Icon(
                                Icons.add_circle_outline,
                                size: 16,
                              ),
                              visualDensity: VisualDensity.compact,
                              onPressed: () {
                                ref
                                    .read(intakeProvider.notifier)
                                    .updateItem(
                                      index,
                                      quantity: item.quantity + 1,
                                    );
                              },
                            ),
                            const SizedBox(width: 4),
                            Text(
                              '\$${(((item.menuItem.price + item.selectedModifiers.fold(0.0, (sum, m) => sum + parseModifierPrice(m))) * item.quantity)).toStringAsFixed(2)}',
                              style: const TextStyle(
                                fontWeight: FontWeight.w800,
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                        onTap: () => _showModifierDialog(
                          context,
                          ref,
                          item.menuItem,
                          editIndex: index,
                          initialSelected: item.selectedModifiers,
                          initialQuantity: item.quantity,
                        ),
                      );
                    },
                  ),
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              children: [
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: intakeState.items.isEmpty
                          ? theme.dividerColor
                          : const Color(0xFF10B981),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                    icon: Icon(
                      isEditingOrder ? Icons.sync_rounded : Icons.bolt_rounded,
                      size: 18,
                    ),
                    label: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          isEditingOrder ? 'UPDATE ORDER' : 'COMPLETE ORDER',
                          style: const TextStyle(
                            fontWeight: FontWeight.w900,
                            fontSize: 12,
                            letterSpacing: 0.5,
                          ),
                        ),
                        // A recalled order is re-sent, not re-charged, so it
                        // carries no total.
                        if (!isEditingOrder && cartTotal > 0)
                          Text(
                            '\$${cartTotal.toStringAsFixed(2)}',
                            style: const TextStyle(
                              fontWeight: FontWeight.w900,
                              fontSize: 14,
                            ),
                          ),
                      ],
                    ),
                    onPressed: intakeState.items.isEmpty
                        ? null
                        : () {
                            // Change calculation belongs to taking money on a
                            // new order. Editing a recalled order re-sends the
                            // ticket, so it goes straight through.
                            if (!isEditingOrder && cartTotal > 0) {
                              _showPaymentDialog(context, ref, cartTotal);
                            } else {
                              _sendToKitchen(context, ref);
                            }
                          },
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );

    if (isSidePanel) {
      return panelContent;
    } else {
      return Container(
        decoration: BoxDecoration(
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.1),
              blurRadius: 10,
              spreadRadius: 0,
            ),
          ],
          border: Border(top: BorderSide(color: theme.dividerColor, width: 2)),
        ),
        child: panelContent,
      );
    }
  }

  /// Height of the order summary sheet on a phone.
  ///
  /// Kept as a fraction of the screen but capped, and never so tall that the
  /// menu is left with nothing to scroll. The caller lays this out as a row, so
  /// whatever the sheet takes, the menu keeps the rest.
  double _bottomSheetHeight(BuildContext context) {
    final screenHeight = MediaQuery.sizeOf(context).height;
    final clamped = (screenHeight * 0.4).clamp(200.0, 340.0);
    // Leave the menu at least this much, so the grid never collapses to a
    // sliver on a short screen.
    final ceiling = (screenHeight - 220).clamp(120.0, screenHeight);
    return clamped > ceiling ? ceiling : clamped;
  }

  Widget _buildFilterChipRow({
    required Stream<List<String>> stream,
    required String selected,
    required ValueChanged<String> onSelected,
  }) {
    final theme = Theme.of(context);
    return StreamBuilder<List<String>>(
      stream: stream,
      builder: (context, snapshot) {
        final values = snapshot.data ?? ['ALL'];
        return SizedBox(
          height: 32,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: values.length,
            separatorBuilder: (context, index) => const SizedBox(width: 8),
            itemBuilder: (context, index) {
              final value = values[index];
              final isSelected = selected == value;
              return InkWell(
                onTap: () => onSelected(value),
                borderRadius: BorderRadius.circular(6),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: isSelected
                        ? const Color(0xFF111111)
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(
                      color: isSelected
                          ? const Color(0xFF111111)
                          : theme.dividerColor,
                    ),
                  ),
                  child: Text(
                    value,
                    style: TextStyle(
                      color: isSelected
                          ? Colors.white
                          : theme.textTheme.bodyMedium?.color,
                      fontWeight: isSelected
                          ? FontWeight.w900
                          : FontWeight.w600,
                      fontSize: 10,
                      letterSpacing: 0.5,
                    ),
                  ),
                ),
              );
            },
          ),
        );
      },
    );
  }

  void _handleItemTap(BuildContext context, WidgetRef ref, MenuItemData item) {
    final hasModifiers =
        item.modifiers.isNotEmpty || item.requiredModifiers.isNotEmpty;
    if (!hasModifiers || item.oneTouch) {
      ref.read(intakeProvider.notifier).addItem(item);
      HapticFeedback.lightImpact();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Added: ${item.name}',
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
          duration: const Duration(milliseconds: 800),
          backgroundColor: const Color(0xFF111111),
        ),
      );
      return;
    }
    _showModifierDialog(context, ref, item);
  }

  void _showModifierDialog(
    BuildContext context,
    WidgetRef ref,
    MenuItemData item, {
    int? editIndex,
    List<String>? initialSelected,
    int initialQuantity = 1,
  }) {
    List<String> selected = List.from(initialSelected ?? []);
    int quantity = initialQuantity;
    final store = ref.read(hostStoreProvider);

    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) =>
            StreamBuilder<List<GlobalModifierData>>(
              stream: store.watchGlobalModifiers(),
              builder: (context, snapshot) {
                final globals = snapshot.data ?? [];
                final requiredMods = item.requiredModifiers;
                final allModifiers = {
                  ...requiredMods,
                  ...item.modifiers,
                  ...globals.map((g) => g.name),
                }.toList();
                bool isRequirementMet =
                    requiredMods.isEmpty ||
                    selected.any((s) => requiredMods.contains(s));

                return AlertDialog(
                  backgroundColor: Theme.of(context).cardColor,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                    side: BorderSide(color: Theme.of(context).dividerColor),
                  ),
                  titlePadding: const EdgeInsets.fromLTRB(24, 24, 24, 8),
                  contentPadding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
                  title: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        item.name.toUpperCase(),
                        style: const TextStyle(
                          fontWeight: FontWeight.w900,
                          fontSize: 20,
                          letterSpacing: -0.4,
                        ),
                      ),
                      if (requiredMods.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 4.0),
                          child: Text(
                            'REQUIREMENT: SELECT ONE (${requiredMods.join(", ")})',
                            style: TextStyle(
                              fontSize: 10,
                              color: isRequirementMet
                                  ? const Color(0xFF22C55E)
                                  : Colors.red,
                              fontWeight: FontWeight.w900,
                              letterSpacing: 0.5,
                            ),
                          ),
                        ),
                    ],
                  ),
                  content: SizedBox(
                    width: 400,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'QUANTITY',
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w900,
                            color: Color(0xFF666666),
                            letterSpacing: 1,
                          ),
                        ),
                        const SizedBox(height: 12),
                        Container(
                          height: 60,
                          decoration: BoxDecoration(
                            border: Border.all(
                              color: Theme.of(context).dividerColor,
                            ),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Row(
                            children: [
                              Expanded(
                                child: IconButton(
                                  icon: const Icon(Icons.remove, size: 20),
                                  onPressed: quantity > 1
                                      ? () => setDialogState(() => quantity--)
                                      : null,
                                ),
                              ),
                              const VerticalDivider(width: 1),
                              Expanded(
                                flex: 2,
                                child: Center(
                                  child: Text(
                                    '$quantity',
                                    style: const TextStyle(
                                      fontSize: 22,
                                      fontWeight: FontWeight.w900,
                                    ),
                                  ),
                                ),
                              ),
                              const VerticalDivider(width: 1),
                              Expanded(
                                child: IconButton(
                                  icon: const Icon(Icons.add, size: 20),
                                  onPressed:
                                      (item.trackStock &&
                                          quantity >= item.stockQuantity)
                                      ? null
                                      : () => setDialogState(() => quantity++),
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 24),
                        Row(
                          children: [
                            const Text(
                              'MODIFIERS',
                              style: TextStyle(
                                fontSize: 10,
                                fontWeight: FontWeight.w900,
                                color: Color(0xFF666666),
                                letterSpacing: 1,
                              ),
                            ),
                            const Spacer(),
                            if (requiredMods.isNotEmpty)
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 6,
                                  vertical: 2,
                                ),
                                decoration: BoxDecoration(
                                  color: Colors.red.withValues(alpha: 0.1),
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: const Text(
                                  'SELECTION REQUIRED',
                                  style: TextStyle(
                                    color: Colors.red,
                                    fontSize: 8,
                                    fontWeight: FontWeight.w900,
                                  ),
                                ),
                              ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: allModifiers.map((mod) {
                            final isSelected = selected.contains(mod);
                            final isReq = requiredMods.contains(mod);
                            return FilterChip(
                              label: Text(mod),
                              selected: isSelected,
                              onSelected: (val) => setDialogState(
                                () => val
                                    ? selected.add(mod)
                                    : selected.remove(mod),
                              ),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(6),
                                side: BorderSide(
                                  color: isReq && !isSelected
                                      ? Colors.red
                                      : (isSelected
                                            ? Colors.transparent
                                            : Theme.of(context).dividerColor),
                                  width: isReq && !isSelected ? 1.5 : 1,
                                ),
                              ),
                              backgroundColor: Colors.transparent,
                              selectedColor: const Color(0xFF111111),
                              labelStyle: TextStyle(
                                color: isSelected
                                    ? Colors.white
                                    : (isReq
                                          ? Colors.red.shade700
                                          : Theme.of(
                                              context,
                                            ).textTheme.bodyMedium?.color),
                                fontWeight: (isSelected || isReq)
                                    ? FontWeight.w900
                                    : FontWeight.w700,
                                fontSize: 12,
                              ),
                              showCheckmark: false,
                            );
                          }).toList(),
                        ),
                      ],
                    ),
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text(
                        'CANCEL',
                        style: TextStyle(
                          fontWeight: FontWeight.w800,
                          color: Color(0xFF666666),
                        ),
                      ),
                    ),
                    ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: isRequirementMet
                            ? const Color(0xFF111111)
                            : Theme.of(context).dividerColor,
                        foregroundColor: Colors.white,
                        elevation: 0,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                      onPressed: isRequirementMet
                          ? () {
                              if (editIndex != null) {
                                ref
                                    .read(intakeProvider.notifier)
                                    .updateItem(
                                      editIndex,
                                      modifiers: selected,
                                      quantity: quantity,
                                    );
                              } else {
                                ref
                                    .read(intakeProvider.notifier)
                                    .addItem(
                                      item,
                                      selectedModifiers: selected,
                                      quantity: quantity,
                                    );
                              }
                              HapticFeedback.mediumImpact();
                              Navigator.pop(context);
                            }
                          : null,
                      child: Text(
                        editIndex != null ? 'SAVE CHANGES' : 'ADD ITEM',
                      ),
                    ),
                  ],
                );
              },
            ),
      ),
    );
  }

  /// Order total for the payment calculator.
  ///
  /// Mirrors what [_sendToKitchen] bills per line — menu price plus every
  /// modifier delta, times the quantity — so the amount the cashier is handed
  /// is the amount the kitchen sees on the ticket. The old calculator read
  /// `price * quantity` and left modifiers out, which made every change
  /// calculation wrong by however much the modifiers added up to.
  double _cartTotal(IntakeState intakeState) {
    var total = 0.0;
    for (final item in intakeState.items) {
      var unitPrice = item.menuItem.price;
      for (final mod in item.selectedModifiers) {
        unitPrice += parseModifierPrice(mod);
      }
      total += unitPrice * item.quantity;
    }
    return total;
  }

  /// Cash-tendered dialog for a new order: shows the total, takes the amount
  /// handed over and reports the change due.
  ///
  /// Nothing is focused or pre-filled on open — the field stays cold until the
  /// cashier taps it, so the on-screen keyboard never covers the change figure
  /// and no amount is selected on their behalf. The chips and EXACT CHANGE
  /// fill the field only when deliberately tapped.
  void _showPaymentDialog(BuildContext context, WidgetRef ref, double total) {
    final controller = TextEditingController();
    double received = 0;
    final theme = Theme.of(context);

    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) {
          final change = (received - total).clamp(0.0, 999999.0);
          final isShort = received > 0 && received < total;

          return AlertDialog(
            backgroundColor: theme.cardColor,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: BorderSide(color: theme.dividerColor),
            ),
            title: const Text(
              'PAYMENT CALCULATOR',
              style: TextStyle(fontWeight: FontWeight.w900, fontSize: 18),
            ),
            content: SizedBox(
              width: 400,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: theme.dividerColor.withValues(alpha: 0.2),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text(
                          'TOTAL DUE',
                          style: TextStyle(fontWeight: FontWeight.w800),
                        ),
                        Text(
                          '\$${total.toStringAsFixed(2)}',
                          style: const TextStyle(
                            fontSize: 22,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 20),
                  TextField(
                    controller: controller,
                    autofocus: false,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    style: const TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.w900,
                    ),
                    textAlign: TextAlign.center,
                    decoration: InputDecoration(
                      labelText: 'CASH RECEIVED',
                      labelStyle: const TextStyle(fontSize: 12),
                      prefixText: '\$ ',
                      filled: true,
                      fillColor: theme.scaffoldBackgroundColor,
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide(color: theme.dividerColor),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide(
                          color: theme.colorScheme.primary,
                          width: 2,
                        ),
                      ),
                    ),
                    onChanged: (val) {
                      setState(() {
                        received = double.tryParse(val) ?? 0;
                      });
                    },
                  ),
                  const SizedBox(height: 20),
                  if (received > 0)
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: isShort
                            ? Colors.orange.withValues(alpha: 0.1)
                            : const Color(0xFF22C55E).withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: isShort
                              ? Colors.orange
                              : const Color(0xFF22C55E),
                          width: 2,
                        ),
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            isShort ? 'REMAINING:' : 'CHANGE DUE:',
                            style: const TextStyle(fontWeight: FontWeight.w900),
                          ),
                          Text(
                            '\$${(isShort ? total - received : change).toStringAsFixed(2)}',
                            style: TextStyle(
                              fontSize: 28,
                              fontWeight: FontWeight.w900,
                              color: isShort
                                  ? Colors.orange
                                  : const Color(0xFF22C55E),
                            ),
                          ),
                        ],
                      ),
                    ),
                  const SizedBox(height: 20),
                  Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    alignment: WrapAlignment.center,
                    children: [5, 10, 20, 50, 100].map((amt) {
                      return ActionChip(
                        label: Text('\$$amt'),
                        labelStyle: const TextStyle(
                          fontWeight: FontWeight.w900,
                        ),
                        onPressed: () {
                          controller.text = amt.toString();
                          setState(() => received = amt.toDouble());
                        },
                      );
                    }).toList(),
                  ),
                  const SizedBox(height: 10),
                  TextButton(
                    onPressed: () {
                      controller.text = total.toStringAsFixed(2);
                      setState(() => received = total);
                    },
                    child: const Text(
                      'EXACT CHANGE',
                      style: TextStyle(fontWeight: FontWeight.w900),
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text(
                  'CANCEL',
                  style: TextStyle(color: Colors.grey),
                ),
              ),
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF111111),
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 24,
                    vertical: 12,
                  ),
                ),
                onPressed: () {
                  Navigator.pop(context);
                  _sendToKitchen(context, ref);
                },
                child: const Text('COMPLETE ORDER'),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _sendToKitchen(BuildContext context, WidgetRef ref) async {
    HapticFeedback.heavyImpact();
    final state = ref.read(intakeProvider);

    final isEditing = state.editingOrderUuid != null;
    final orderUuid = state.editingOrderUuid ?? const Uuid().v4();
    final baseName = state.customerName.isEmpty ? 'Guest' : state.customerName;
    final orderName = state.orderNote.isNotEmpty
        ? '$baseName (${state.orderNote})'
        : baseName;

    // Stock decrements, order edits and the kitchen broadcast all live behind
    // the store, so this is identical on a native host and in a browser.
    await ref
        .read(hostStoreProvider)
        .submitOrder(
          orderUuid: orderUuid,
          customerName: orderName,
          lines: state.items.map((i) {
            double itemUnitPrice = i.menuItem.price;
            for (final mod in i.selectedModifiers) {
              itemUnitPrice += parseModifierPrice(mod);
            }
            return OrderLine(
              menuItemId: i.menuItem.id,
              name: i.menuItem.name,
              modifiers: i.selectedModifiers,
              stationTag: i.menuItem.defaultStation,
              quantity: i.quantity,
              price: itemUnitPrice,
            );
          }).toList(),
          isEditing: isEditing,
        );
    ref.read(intakeProvider.notifier).clear();
    if (!context.mounted) return;

    if (ref.read(settingsProvider).enableConfetti) {
      _confettiController.play();
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          isEditing
              ? 'Order "$orderName" Updated!'
              : 'Sent to Kitchen: $orderName!',
          style: const TextStyle(fontWeight: FontWeight.w700),
        ),
        backgroundColor: const Color(0xFF111111),
      ),
    );
  }
}
