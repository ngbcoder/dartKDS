import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:file_picker/file_picker.dart';
import 'package:share_plus/share_plus.dart';
import 'package:path_provider/path_provider.dart' if (dart.library.js_interop) '../../../web_path_provider_stub.dart';
import 'package:uuid/uuid.dart';
import 'dart:io' if (dart.library.js_interop) '../../../web_io_stub.dart';
import '../../../models/database.dart';
import '../../../providers/app_state_providers.dart';
import '../../../data/host_store.dart';
import '../../../providers/host_store_provider.dart';

class LibraryView extends ConsumerStatefulWidget {
  final int initialTab;
  const LibraryView({super.key, this.initialTab = 0});

  @override
  ConsumerState<LibraryView> createState() => _LibraryViewState();
}

class _LibraryViewState extends ConsumerState<LibraryView> {
  final _nameController = TextEditingController();
  final _modifiersController = TextEditingController();
  final _requiredModifiersController = TextEditingController();
  final _tagsController = TextEditingController();
  final _stationController = TextEditingController();
  final _globalModifierController = TextEditingController();
  final _priceController = TextEditingController();
  final _stockController = TextEditingController();
  final _categoryController = TextEditingController(text: 'All Items');
  bool _trackStock = false;
  bool _oneTouch = false;
  String? _selectedStation;
  String _sortBy = 'name';

  @override
  void dispose() {
    _nameController.dispose();
    _modifiersController.dispose();
    _requiredModifiersController.dispose();
    _tagsController.dispose();
    _stationController.dispose();
    _globalModifierController.dispose();
    _priceController.dispose();
    _stockController.dispose();
    _categoryController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final store = ref.watch(hostStoreProvider);
    final theme = Theme.of(context);

    return StreamBuilder<List<StationData>>(
      stream: store.watchStations(),
      builder: (context, stationSnapshot) {
        if (stationSnapshot.hasError) {
          return Center(
            child: Text('Database Error: ${stationSnapshot.error}'),
          );
        }
        if (!stationSnapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }

        final stations = stationSnapshot.data ?? [];
        // Resolve the effective station locally. This used to assign the
        // `_selectedStation` field during build, which is a build side effect:
        // a discarded build left the field mutated anyway, and the routing
        // dropdown could show a station that was not in the list.
        final effectiveStation = _selectedStation != null &&
                stations.any((s) => s.name == _selectedStation)
            ? _selectedStation
            : (stations.isNotEmpty ? stations.first.name : null);

        final initialTab = ref.watch(libraryTabIndexProvider);

        return DefaultTabController(
          length: 5,
          initialIndex: initialTab,
          key: ValueKey('library_tab_$initialTab'),
          child: Column(
            children: [
              TabBar(
                onTap: (index) =>
                    ref.read(libraryTabIndexProvider.notifier).state = index,
                isScrollable: false,
                tabAlignment: TabAlignment.fill,
                labelColor: Theme.of(context).colorScheme.onSurface,
                unselectedLabelColor: Theme.of(
                  context,
                ).colorScheme.onSurfaceVariant,
                // Primary, matching sent_queue_view. This was `onSurface`, so the two tabbed
                // screens drew their indicator in different colours and neither
                // read as the deliberate choice.
                indicatorColor: Theme.of(context).colorScheme.primary,
                indicatorWeight: 3,
                labelStyle: const TextStyle(
                  fontWeight: FontWeight.w900,
                  fontSize: 12,
                  letterSpacing: 0.5,
                ),
                unselectedLabelStyle: const TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 12,
                ),
                dividerColor: theme.dividerColor,
                tabs: const [
                  Tab(text: 'ITEMS'),
                  Tab(text: 'STATIONS'),
                  Tab(text: 'MODIFIERS'),
                  Tab(text: 'COMBOS'),
                  Tab(text: 'BACKUP'),
                ],
              ),
              Expanded(
                child: TabBarView(
                  children: [
                    _buildItemsTab(store, theme, stations, effectiveStation),
                    _buildStationsTab(store, theme, stations),
                    _buildGlobalModifiersTab(store, theme),
                    _buildCombosTab(store, theme, stations),
                    _buildBackupTab(store, theme),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildItemsTab(
    HostStore store,
    ThemeData theme,
    List<StationData> stations,
    String? effectiveStation,
  ) {
    return StreamBuilder<List<MenuItemData>>(
      stream: store.watchMenuItems(),
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Center(child: Text('Error: ${snapshot.error}'));
        }
        if (!snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        final items = snapshot.data!;
        final sortedItems = [...items];
        switch (_sortBy) {
          case 'name':
            sortedItems.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
            break;
          case 'price_asc':
            sortedItems.sort((a, b) => a.price.compareTo(b.price));
            break;
          case 'price_desc':
            sortedItems.sort((a, b) => b.price.compareTo(a.price));
            break;
          case 'category':
            sortedItems.sort((a, b) => a.category.toLowerCase().compareTo(b.category.toLowerCase()));
            break;
          case 'station':
            sortedItems.sort((a, b) => a.defaultStation.toLowerCase().compareTo(b.defaultStation.toLowerCase()));
            break;
        }

        return CustomScrollView(
          slivers: [
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Container(
                  decoration: BoxDecoration(
                    color: theme.cardColor,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: theme.dividerColor),
                  ),
                  padding: const EdgeInsets.all(20.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Text(
                        'NEW MENU ITEM',
                        style: TextStyle(
                          fontWeight: FontWeight.w900,
                          fontSize: 11,
                          color: Color(0xFF666666),
                          letterSpacing: 1.2,
                        ),
                      ),
                      const SizedBox(height: 16),
                      _buildTextField(
                        _nameController,
                        'Item Name',
                        hint: 'e.g. Smash Burger',
                      ),
                      const SizedBox(height: 12),
                      _buildTextField(
                        _priceController,
                        'Price',
                        hint: '0.00',
                        prefix: r'$',
                        keyboard: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                      ),
                      const SizedBox(height: 12),
                      _buildTextField(
                        _modifiersController,
                        'Available Modifiers',
                        hint: 'Bacon, Cheese, Egg',
                      ),
                      const SizedBox(height: 12),
                      _buildTextField(
                        _requiredModifiersController,
                        'Required Modifiers',
                        hint: 'Rare, Medium, Well',
                      ),
                      const SizedBox(height: 12),
                      _buildTextField(
                        _tagsController,
                        'Tags (for menu filters)',
                        hint: 'Gluten Free, Spicy, Chef Special',
                      ),
                      const SizedBox(height: 12),
                      _buildTextField(
                        _categoryController,
                        'Category',
                        hint: 'e.g. Burgers, Sides, Drinks',
                      ),
                      const SizedBox(height: 12),
                      DropdownButtonFormField<String>(
                        initialValue: effectiveStation,
                        decoration: _inputDecoration('Routing Station'),
                        items: stations
                            .map(
                              (s) => DropdownMenuItem(
                                value: s.name,
                                child: Text(
                                  s.name,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                            )
                            .toList(),
                        onChanged: (val) =>
                            setState(() => _selectedStation = val),
                      ),
                      const SizedBox(height: 12),
                      Material(
                        color: Colors.transparent,
                        child: SwitchListTile(
                          title: const Text(
                            'TRACK INVENTORY',
                            style: TextStyle(
                              fontWeight: FontWeight.w800,
                              fontSize: 12,
                              letterSpacing: 0.5,
                            ),
                          ),
                          value: _trackStock,
                          onChanged: (val) => setState(() => _trackStock = val),
                          activeThumbColor: const Color(0xFF111111),
                          contentPadding: EdgeInsets.zero,
                          dense: true,
                        ),
                      ),
                      if (_trackStock) ...[
                        const SizedBox(height: 8),
                        _buildTextField(
                          _stockController,
                          'Current Stock',
                          keyboard: TextInputType.number,
                        ),
                      ],
                      Material(
                        color: Colors.transparent,
                        child: SwitchListTile(
                          title: const Text(
                            'ONE TOUCH ADD',
                            style: TextStyle(
                              fontWeight: FontWeight.w800,
                              fontSize: 12,
                              letterSpacing: 0.5,
                            ),
                          ),
                          subtitle: const Text(
                            'Adds to ticket instantly on tap (skips modifier screen).',
                            style: TextStyle(fontSize: 10),
                          ),
                          value: _oneTouch,
                          onChanged: (val) => setState(() => _oneTouch = val),
                          activeThumbColor: const Color(0xFF2AA31F),
                          contentPadding: EdgeInsets.zero,
                          dense: true,
                        ),
                      ),
                      const SizedBox(height: 20),
                      ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF111111),
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(6),
                          ),
                          elevation: 0,
                        ),
                        onPressed: () async {
                          if (_nameController.text.isNotEmpty &&
                              effectiveStation != null) {
                            final mods = _modifiersController.text
                                .split(',')
                                .map((e) => e.trim())
                                .where((e) => e.isNotEmpty)
                                .toList();
                            final reqs = _requiredModifiersController.text
                                .split(',')
                                .map((e) => e.trim())
                                .where((e) => e.isNotEmpty)
                                .toList();
                            final tags = _tagsController.text
                                .split(',')
                                .map((e) => e.trim())
                                .where((e) => e.isNotEmpty)
                                .toList();
                            await store.saveMenuItem(
                              MenuItemDraft(
                                guid: const Uuid().v4(),
                                name: _nameController.text,
                                category: _categoryController.text.isEmpty
                                    ? 'All Items'
                                    : _categoryController.text.trim(),
                                defaultStation: effectiveStation,
                                modifiers: mods,
                                requiredModifiers: reqs,
                                tags: tags,
                                price:
                                    double.tryParse(_priceController.text) ?? 0.0,
                                stockQuantity:
                                    int.tryParse(_stockController.text) ?? 0,
                                trackStock: _trackStock,
                                oneTouch: _oneTouch,
                              ),
                            );
                            _nameController.clear();
                            _modifiersController.clear();
                            _requiredModifiersController.clear();
                            _tagsController.clear();
                            _priceController.clear();
                            _stockController.clear();
                            _categoryController.text = 'All Items';
                            setState(() {
                              _trackStock = false;
                              _oneTouch = false;
                            });
                          }
                        },
                        child: const Text(
                          'SAVE TO LIBRARY',
                          style: TextStyle(
                            fontWeight: FontWeight.w900,
                            letterSpacing: 0.5,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                child: Row(
                  children: [
                    Text(
                      'MENU ITEMS (${sortedItems.length})',
                      style: TextStyle(
                        fontWeight: FontWeight.w900,
                        fontSize: 12,
                        color: theme.hintColor,
                        letterSpacing: 1.2,
                      ),
                    ),
                    const Spacer(),
                    DropdownButton<String>(
                      value: _sortBy,
                      underline: const SizedBox(),
                      isDense: true,
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 12,
                        color: theme.colorScheme.onSurface,
                      ),
                      items: const [
                        DropdownMenuItem(value: 'name', child: Text('Sort: Name (A-Z)')),
                        DropdownMenuItem(value: 'price_asc', child: Text('Sort: Price (Low-High)')),
                        DropdownMenuItem(value: 'price_desc', child: Text('Sort: Price (High-Low)')),
                        DropdownMenuItem(value: 'category', child: Text('Sort: Category')),
                        DropdownMenuItem(value: 'station', child: Text('Sort: Station')),
                      ],
                      onChanged: (val) {
                        if (val != null) setState(() => _sortBy = val);
                      },
                    ),
                  ],
                ),
              ),
            ),
            SliverPadding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              sliver: SliverList(
                delegate: SliverChildBuilderDelegate((context, index) {
                  final item = sortedItems[index];
                  return Material(
                    color: theme.cardColor,
                    borderRadius: BorderRadius.circular(8),
                    clipBehavior: Clip.antiAlias,
                    child: Container(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: theme.dividerColor),
                      ),
                      child: ListTile(
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 8,
                        ),
                        title: Row(
                          children: [
                            Text(
                              item.name.toUpperCase(),
                              style: const TextStyle(
                                fontWeight: FontWeight.w900,
                                fontSize: 14,
                                letterSpacing: -0.2,
                              ),
                            ),
                            const Spacer(),
                            Text(
                              '\$${item.price.toStringAsFixed(2)}',
                              style: const TextStyle(
                                fontWeight: FontWeight.w900,
                                color: Color(0xFF2AA31F),
                                fontSize: 14,
                              ),
                            ),
                          ],
                        ),
                        subtitle: Padding(
                          padding: const EdgeInsets.only(top: 8.0),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Wrap(
                                spacing: 6,
                                runSpacing: 6,
                                children: [
                                  _buildTag(
                                    item.defaultStation.toUpperCase(),
                                    const Color(0xFFF3F4F6),
                                    const Color(0xFF666666),
                                  ),
                                  if (item.trackStock)
                                    _buildTag(
                                      'STOCK: ${item.stockQuantity}',
                                      const Color(0xFFFFF7ED),
                                      const Color(0xFFC2410C),
                                    ),
                                  if (item.oneTouch)
                                    _buildTag(
                                      'ONE TOUCH',
                                      const Color(0xFFEFF6FF),
                                      const Color(0xFF2AA31F),
                                    ),
                                  ...item.tags.map(
                                    (t) => _buildTag(
                                      t,
                                      const Color(0xFFEFF6FF),
                                      const Color(0xFF2AA31F),
                                    ),
                                  ),
                                ],
                              ),
                              if (item.requiredModifiers.isNotEmpty)
                                Padding(
                                  padding: const EdgeInsets.only(top: 4.0),
                                  child: Text(
                                    'REQUIRED: ${item.requiredModifiers.join(", ")}',
                                    style: const TextStyle(
                                      fontSize: 10,
                                      color: Colors.red,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                        trailing: MenuAnchor(
                          builder: (context, controller, child) => IconButton(
                            icon: const Icon(Icons.more_vert_rounded, size: 20),
                            onPressed: () => controller.isOpen
                                ? controller.close()
                                : controller.open(),
                          ),
                          menuChildren: [
                            MenuItemButton(
                              onPressed: () => _showEditItemDialog(
                                context,
                                store,
                                item,
                                stations,
                              ),
                              leadingIcon: const Icon(
                                Icons.edit_outlined,
                                size: 18,
                              ),
                              child: const Text(
                                'EDIT ITEM',
                                style: TextStyle(
                                  fontWeight: FontWeight.w700,
                                  fontSize: 12,
                                ),
                              ),
                            ),
                            MenuItemButton(
                              onPressed: () => _confirmDelete(
                                  title: 'DELETE ITEM?',
                                  message: '"${item.name}" will be removed '
                                      'from the menu. This cannot be undone.',
                                  onConfirm: () => store.deleteMenuItem(item.id),
                                ),
                              leadingIcon: const Icon(
                                Icons.delete_outline,
                                color: Colors.red,
                                size: 18,
                              ),
                              child: const Text(
                                'DELETE',
                                style: TextStyle(
                                  fontWeight: FontWeight.w700,
                                  fontSize: 12,
                                  color: Colors.red,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  );
                }, childCount: items.length),
              ),
            ),
          ],
        );
      },
    );
  }

  // Common UI Helper for refined tags
  Widget _buildTag(String text, Color bg, Color textCol) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w900,
          color: textCol,
          letterSpacing: 0.5,
        ),
      ),
    );
  }

  // Refined Input Styling
  InputDecoration _inputDecoration(
    String label, {
    String? hint,
    String? prefix,
  }) {
    return InputDecoration(
      labelText: label,
      hintText: hint,
      prefixText: prefix,
      labelStyle: const TextStyle(
        fontWeight: FontWeight.w700,
        fontSize: 13,
        color: Color(0xFF666666),
      ),
      floatingLabelStyle: const TextStyle(
        fontWeight: FontWeight.w900,
        color: Color(0xFF111111),
      ),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(6),
        borderSide: BorderSide(color: Theme.of(context).dividerColor),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(6),
        borderSide: BorderSide(color: Theme.of(context).dividerColor),
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
      isDense: true,
    );
  }

  Widget _buildTextField(
    TextEditingController controller,
    String label, {
    String? hint,
    String? prefix,
    TextInputType? keyboard,
  }) {
    return TextField(
      controller: controller,
      keyboardType: keyboard,
      style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14),
      decoration: _inputDecoration(label, hint: hint, prefix: prefix),
    );
  }

  Widget _buildStationsTab(
    HostStore store,
    ThemeData theme,
    List<StationData> stations,
  ) {
    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.all(16.0),
            child: Container(
              decoration: BoxDecoration(
                color: theme.cardColor,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: theme.dividerColor),
              ),
              padding: const EdgeInsets.all(20.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text(
                    'NEW STATION',
                    style: TextStyle(
                      fontWeight: FontWeight.w900,
                      fontSize: 11,
                      color: Color(0xFF666666),
                      letterSpacing: 1.2,
                    ),
                  ),
                  const SizedBox(height: 16),
                  _buildTextField(
                    _stationController,
                    'Station Name',
                    hint: 'e.g. Grill',
                  ),
                  const SizedBox(height: 16),
                  ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF111111),
                      foregroundColor: Colors.white,
                      elevation: 0,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(6),
                      ),
                      padding: const EdgeInsets.symmetric(vertical: 16),
                    ),
                    onPressed: () async {
                      if (_stationController.text.isNotEmpty) {
                        await store.saveStation(
                          name: _stationController.text.trim(),
                        );
                        _stationController.clear();
                      }
                    },
                    child: const Text(
                      'CREATE STATION',
                      style: TextStyle(fontWeight: FontWeight.w900),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        SliverPadding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          sliver: SliverList(
            delegate: SliverChildBuilderDelegate((context, index) {
              final station = stations[index];
              return Container(
                margin: const EdgeInsets.only(bottom: 8),
                child: Material(
                  color: theme.cardColor,
                  borderRadius: BorderRadius.circular(8),
                  clipBehavior: Clip.antiAlias,
                  child: Container(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: theme.dividerColor),
                    ),
                    child: ListTile(
                      title: Text(
                        station.name.toUpperCase(),
                        style: const TextStyle(
                          fontWeight: FontWeight.w800,
                          fontSize: 13,
                        ),
                      ),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            icon: const Icon(Icons.edit_outlined, size: 20),
                            onPressed: () =>
                                _showEditStationDialog(context, store, station),
                          ),
                          IconButton(
                            icon: const Icon(
                              Icons.delete_outline,
                              size: 20,
                              color: Colors.redAccent,
                            ),
                            onPressed: () => _confirmDelete(
                                  title: 'DELETE STATION?',
                                  message: '"${station.name}" will be removed, '
                                      'along with its items. This cannot be undone.',
                                  onConfirm: () => store.deleteStation(station.id),
                                ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              );
            }, childCount: stations.length),
          ),
        ),
      ],
    );
  }

  Widget _buildGlobalModifiersTab(HostStore store, ThemeData theme) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(16.0),
          child: SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF2AA31F),
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 16),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
                elevation: 0,
              ),
              icon: const Icon(Icons.add_rounded, size: 22),
              label: const Text(
                'ADD MODIFIER',
                style: TextStyle(
                  fontWeight: FontWeight.w900,
                  fontSize: 13,
                  letterSpacing: 0.5,
                ),
              ),
              onPressed: () => _showAddModifierDialog(context, store),
            ),
          ),
        ),
        Expanded(
          child: StreamBuilder<List<GlobalModifierData>>(
            stream: store.watchGlobalModifiers(),
            builder: (context, snapshot) {
              if (!snapshot.hasData) {
                return const Center(child: CircularProgressIndicator());
              }
              final mods = snapshot.data!;
              if (mods.isEmpty) {
                return Center(
                  child: Text(
                    'No modifiers yet. Tap "+ ADD MODIFIER" above.',
                    style: TextStyle(
                      color: theme.hintColor,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                );
              }
              return ListView.builder(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                itemCount: mods.length,
                itemBuilder: (context, index) {
                  final mod = mods[index];
                  return Container(
                    margin: const EdgeInsets.only(bottom: 8),
                    child: Material(
                      color: theme.cardColor,
                      borderRadius: BorderRadius.circular(8),
                      clipBehavior: Clip.antiAlias,
                      child: Container(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: theme.dividerColor),
                        ),
                        child: ListTile(
                          title: Text(
                            mod.name.toUpperCase(),
                            style: const TextStyle(
                              fontWeight: FontWeight.w800,
                              fontSize: 13,
                            ),
                          ),
                          trailing: IconButton(
                            icon: const Icon(Icons.delete_outline, size: 20),
                            onPressed: () => _confirmDelete(
                              title: 'DELETE MODIFIER?',
                              message: '"${mod.name}" will be removed from '
                                  'every item. This cannot be undone.',
                              onConfirm: () =>
                                  store.deleteGlobalModifier(mod.id),
                            ),
                          ),
                        ),
                      ),
                    ),
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildCombosTab(
    HostStore store,
    ThemeData theme,
    List<StationData> stations,
  ) {
    return StreamBuilder<List<MenuItemData>>(
      stream: store.watchMenuItems(),
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        final allItems = snapshot.data!;
        final combos = allItems.where((i) => i.isCombo).toList();
        final regularItems = allItems.where((i) => !i.isCombo).toList();

        return CustomScrollView(
          slivers: [
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Container(
                  decoration: BoxDecoration(
                    color: theme.cardColor,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: theme.dividerColor),
                  ),
                  padding: const EdgeInsets.all(20.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Text(
                        'NEW COMBO / MEAL DEAL',
                        style: TextStyle(
                          fontWeight: FontWeight.w900,
                          fontSize: 11,
                          color: Color(0xFF666666),
                          letterSpacing: 1.2,
                        ),
                      ),
                      const SizedBox(height: 16),
                      _ComboEditor(
                        store: store,
                        theme: theme,
                        stations: stations,
                        regularItems: regularItems,
                      ),
                    ],
                  ),
                ),
              ),
            ),
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                child: Text(
                  'COMBOS (${combos.length})',
                  style: TextStyle(
                    fontWeight: FontWeight.w900,
                    fontSize: 12,
                    color: theme.hintColor,
                    letterSpacing: 1.2,
                  ),
                ),
              ),
            ),
            SliverPadding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              sliver: SliverList(
                delegate: SliverChildBuilderDelegate((context, index) {
                  final combo = combos[index];
                  return Container(
                    margin: const EdgeInsets.only(bottom: 8),
                    child: Material(
                      color: theme.cardColor,
                      borderRadius: BorderRadius.circular(8),
                      clipBehavior: Clip.antiAlias,
                      child: Container(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: theme.dividerColor),
                        ),
                        child: ListTile(
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 8,
                          ),
                          title: Row(
                            children: [
                              Text(
                                combo.name.toUpperCase(),
                                style: const TextStyle(
                                  fontWeight: FontWeight.w900,
                                  fontSize: 14,
                                  letterSpacing: -0.2,
                                ),
                              ),
                              const Spacer(),
                              Text(
                                '\$${combo.price.toStringAsFixed(2)}',
                                style: const TextStyle(
                                  fontWeight: FontWeight.w900,
                                  color: Color(0xFF2AA31F),
                                  fontSize: 14,
                                ),
                              ),
                            ],
                          ),
                          subtitle: Padding(
                            padding: const EdgeInsets.only(top: 4.0),
                            child: FutureBuilder<List<MenuItemData>>(
                              future: store.getComboComponents(combo.id),
                              builder: (context, snap) {
                                if (!snap.hasData) return const SizedBox.shrink();
                                final comps = snap.data!;
                                return Text(
                                  'Includes: ${comps.map((c) => c.name).join(' + ')}',
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: theme.hintColor,
                                    fontWeight: FontWeight.w600,
                                  ),
                                );
                              },
                            ),
                          ),
                          trailing: IconButton(
                            icon: const Icon(
                              Icons.delete_outline,
                              color: Colors.red,
                              size: 20,
                            ),
                            onPressed: () => _confirmDelete(
                              title: 'DELETE COMBO?',
                              message: '"${combo.name}" will be removed. '
                                  'This cannot be undone.',
                              onConfirm: () => store.deleteCombo(combo.id),
                            ),
                          ),
                        ),
                      ),
                    ),
                  );
                }, childCount: combos.length),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildBackupTab(HostStore store, ThemeData theme) {
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        const Text(
          'SYSTEM BACKUP',
          style: TextStyle(
            fontWeight: FontWeight.w900,
            fontSize: 11,
            color: Color(0xFF666666),
            letterSpacing: 1.2,
          ),
        ),
        const SizedBox(height: 16),
        Material(
          color: theme.cardColor,
          borderRadius: BorderRadius.circular(8),
          clipBehavior: Clip.antiAlias,
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: theme.dividerColor),
            ),
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(
                    Icons.download_rounded,
                    color: Color(0xFF2AA31F),
                  ),
                  title: const Text(
                    'EXPORT LIBRARY',
                    style: TextStyle(fontWeight: FontWeight.w900, fontSize: 13),
                  ),
                  subtitle: const Text(
                    'Backup menu, stations, and modifiers',
                    style: TextStyle(fontSize: 11),
                  ),
                  onTap: () => _exportLibrary(store),
                ),
                Divider(height: 1, color: theme.dividerColor),
                ListTile(
                  leading: const Icon(
                    Icons.upload_rounded,
                    color: Color(0xFF22C55E),
                  ),
                  title: const Text(
                    'IMPORT LIBRARY',
                    style: TextStyle(fontWeight: FontWeight.w900, fontSize: 13),
                  ),
                  subtitle: const Text(
                    'Restore from a backup file',
                    style: TextStyle(fontSize: 11),
                  ),
                  onTap: () => _importLibrary(store),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 32),
        const Text(
          'DANGER ZONE',
          style: TextStyle(
            fontWeight: FontWeight.w900,
            fontSize: 11,
            color: Color(0xFFDC2626),
            letterSpacing: 1.2,
          ),
        ),
        const SizedBox(height: 16),
        Material(
          color: theme.cardColor,
          borderRadius: BorderRadius.circular(8),
          clipBehavior: Clip.antiAlias,
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: theme.dividerColor),
            ),
            child: ListTile(
              leading: const Icon(
                Icons.delete_forever_rounded,
                color: Color(0xFFDC2626),
              ),
              title: const Text(
                'CLEAR ALL LIBRARY DATA',
                style: TextStyle(
                  fontWeight: FontWeight.w900,
                  fontSize: 13,
                  color: Color(0xFFDC2626),
                ),
              ),
              subtitle: const Text(
                'Wipe all items, stations, and modifiers',
                style: TextStyle(fontSize: 11),
              ),
              onTap: () => _showResetLibraryConfirmation(store),
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _exportLibrary(HostStore store) async {
    try {
      final data = await store.exportLibrary();

      final jsonString = jsonEncode(data);
      final bytes = utf8.encode(jsonString);
      final fileName = 'dartkds_backup_${DateTime.now().toIso8601String().substring(0, 10)}.json';

      String? path;
      try {
        path = await FilePicker.platform.saveFile(
          dialogTitle: 'Export DartKDS Backup',
          fileName: fileName,
          bytes: bytes,
          type: FileType.custom,
          allowedExtensions: ['json'],
        );
      } catch (_) {
        // saveFile might not be supported on some platforms
      }

      if (path != null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Backup exported successfully to $path'),
              backgroundColor: const Color(0xFF22C55E),
            ),
          );
        }
      } else if (kIsWeb) {
        return;
      } else {
        // Mobile fallback: save to documents directory and share
        try {
          final directory = await getApplicationDocumentsDirectory();
          final file = File('${directory.path}/$fileName');
          await file.writeAsString(jsonString);
          await Share.shareXFiles([XFile(file.path)], text: 'DartKDS Backup');
        } catch (_) {}
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Export failed: $e')));
      }
    }
  }

  Future<void> _importLibrary(HostStore store) async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['json'],
        withData: true,
      );
      if (result == null || result.files.isEmpty) return;
      final file = result.files.single;

      final confirmation = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text(
            'IMPORT LIBRARY',
            style: TextStyle(fontWeight: FontWeight.w900),
          ),
          content: const Text(
            'This will merge the backup data with your current library. Existing items with the same name will be updated.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('CANCEL'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text(
                'PROCEED',
                style: TextStyle(fontWeight: FontWeight.w900),
              ),
            ),
          ],
        ),
      );

      if (confirmation != true) return;

      String fileContent;
      if (file.bytes != null) {
        fileContent = utf8.decode(file.bytes!);
      } else if (file.path != null) {
        fileContent = await File(file.path!).readAsString();
      } else {
        throw Exception('Could not read selected file');
      }

      final data = jsonDecode(fileContent) as Map<String, dynamic>;

      if (data['menuItems'] == null) throw Exception('Invalid backup file');

      await store.importLibrary(data);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Import Successful'),
            backgroundColor: Color(0xFF22C55E),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Import failed: $e'),
            backgroundColor: Colors.red,
          ),
        );
        // Log the full stack trace for debugging
        print('Import failed: $e\nStackTrace: ${StackTrace.current}');
      }
    }
  }

  Future<void> _showResetLibraryConfirmation(HostStore store) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text(
          'CLEAR ALL LIBRARY DATA?',
          style: TextStyle(fontWeight: FontWeight.w900, color: Colors.red),
        ),
        content: const Text(
          'This will delete all Menu Items, Stations, and Global Modifiers. Order history will be preserved.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('CANCEL'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text(
              'CLEAR ALL',
              style: TextStyle(color: Colors.red, fontWeight: FontWeight.w900),
            ),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await store.clearLibrary();
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Library Cleared')));
      }
    }
  }

  /// Confirmation for a single-row delete in the library.
  ///
  /// The item, station and modifier deletes used to fire straight from the
  /// button, so one stray tap on a small trash icon destroyed a row with no way
  /// back. Every other destructive action in the app already confirms
  /// (`CLEAR TICKET?`, `IMPORT LIBRARY`, `CLEAR ALL LIBRARY DATA?`), so these
  /// were the odd ones out.
  Future<void> _confirmDelete({
    required String title,
    required String message,
    required Future<void> Function() onConfirm,
  }) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: Theme.of(context).cardColor,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: BorderSide(color: Theme.of(context).dividerColor),
        ),
        title: Text(
          title,
          style: const TextStyle(
            fontWeight: FontWeight.w900,
            fontSize: 16,
            color: Colors.red,
          ),
        ),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('CANCEL'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text(
              'DELETE',
              style: TextStyle(color: Colors.red, fontWeight: FontWeight.w900),
            ),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;
    await onConfirm();
  }

  void _showAddModifierDialog(BuildContext context, HostStore store) {
    final controller = TextEditingController();
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: Theme.of(context).cardColor,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: BorderSide(color: Theme.of(context).dividerColor),
        ),
        title: const Text(
          'NEW GLOBAL MODIFIER',
          style: TextStyle(fontWeight: FontWeight.w900, fontSize: 16),
        ),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: _inputDecoration('Modifier Name'),
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
              backgroundColor: const Color(0xFF111111),
              foregroundColor: Colors.white,
              elevation: 0,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(6),
              ),
            ),
            onPressed: () async {
              final name = controller.text.trim();
              if (name.isEmpty) return;
              await store.saveGlobalModifier(name: name);
              if (context.mounted) Navigator.pop(context);
            },
            child: const Text('ADD'),
          ),
        ],
      ),
    ).whenComplete(controller.dispose);
  }

  void _showEditStationDialog(
    BuildContext context,
    HostStore store,
    StationData station,
  ) {
    final controller = TextEditingController(text: station.name);
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: Theme.of(context).cardColor,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: BorderSide(color: Theme.of(context).dividerColor),
        ),
        title: const Text(
          'EDIT STATION',
          style: TextStyle(fontWeight: FontWeight.w900, fontSize: 16),
        ),
        content: TextField(
          controller: controller,
          decoration: _inputDecoration('Station Name'),
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
              backgroundColor: const Color(0xFF111111),
              foregroundColor: Colors.white,
              elevation: 0,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(6),
              ),
            ),
            onPressed: () async {
              if (controller.text.isNotEmpty) {
                await store.saveStation(
                  id: station.id,
                  name: controller.text.trim(),
                );
                if (context.mounted) Navigator.pop(context);
              }
            },
            child: const Text('SAVE'),
          ),
        ],
      ),
    );
  }

  void _showEditItemDialog(
    BuildContext context,
    HostStore store,
    MenuItemData item,
    List<StationData> stations,
  ) {
    final nameCtrl = TextEditingController(text: item.name);
    final modCtrl = TextEditingController(text: item.modifiers.join(', '));
    final reqModCtrl = TextEditingController(
      text: item.requiredModifiers.join(', '),
    );
    final tagsCtrl = TextEditingController(text: item.tags.join(', '));
    final categoryCtrl = TextEditingController(text: item.category);
    final priceCtrl = TextEditingController(text: item.price.toString());
    final stockCtrl = TextEditingController(
      text: item.stockQuantity.toString(),
    );
    bool trackStock = item.trackStock;
    bool oneTouch = item.oneTouch;
    String selectedStation = item.defaultStation;

    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          backgroundColor: Theme.of(context).cardColor,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
            side: BorderSide(color: Theme.of(context).dividerColor),
          ),
          title: const Text(
            'EDIT MENU ITEM',
            style: TextStyle(fontWeight: FontWeight.w900, fontSize: 16),
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _buildTextField(nameCtrl, 'Item Name'),
                const SizedBox(height: 12),
                _buildTextField(
                  priceCtrl,
                  'Price',
                  prefix: r'$',
                  keyboard: TextInputType.number,
                ),
                const SizedBox(height: 12),
                _buildTextField(modCtrl, 'Available Modifiers'),
                const SizedBox(height: 12),
                _buildTextField(reqModCtrl, 'Required Modifiers'),
                const SizedBox(height: 12),
                _buildTextField(tagsCtrl, 'Tags (for menu filters)'),
                const SizedBox(height: 12),
                _buildTextField(categoryCtrl, 'Category'),
                const SizedBox(height: 12),
                SwitchListTile(
                  title: const Text(
                    'TRACK INVENTORY',
                    style: TextStyle(fontWeight: FontWeight.w800, fontSize: 12),
                  ),
                  value: trackStock,
                  onChanged: (val) => setDialogState(() => trackStock = val),
                  contentPadding: EdgeInsets.zero,
                ),
                if (trackStock)
                  _buildTextField(
                    stockCtrl,
                    'Current Stock',
                    keyboard: TextInputType.number,
                  ),
                const SizedBox(height: 12),
                SwitchListTile(
                  title: const Text(
                    'ONE TOUCH ADD',
                    style: TextStyle(fontWeight: FontWeight.w800, fontSize: 12),
                  ),
                  subtitle: const Text(
                    'Adds to ticket instantly on tap (skips modifier screen).',
                    style: TextStyle(fontSize: 10),
                  ),
                  value: oneTouch,
                  onChanged: (val) => setDialogState(() => oneTouch = val),
                  activeThumbColor: const Color(0xFF2AA31F),
                  contentPadding: EdgeInsets.zero,
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: stations.any((s) => s.name == selectedStation)
                      ? selectedStation
                      : (stations.isNotEmpty ? stations.first.name : null),
                  decoration: _inputDecoration('Station'),
                  items: stations
                      .map(
                        (s) => DropdownMenuItem(
                          value: s.name,
                          child: Text(
                            s.name,
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                        ),
                      )
                      .toList(),
                  onChanged: (val) =>
                      setDialogState(() => selectedStation = val!),
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
                backgroundColor: const Color(0xFF111111),
                foregroundColor: Colors.white,
                elevation: 0,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(6),
                ),
              ),
              onPressed: () async {
                if (nameCtrl.text.isNotEmpty) {
                  final tags = tagsCtrl.text
                      .split(',')
                      .map((e) => e.trim())
                      .where((e) => e.isNotEmpty)
                      .toList();
                  await store.saveMenuItem(
                    MenuItemDraft(
                      id: item.id,
                      guid: item.guid,
                      name: nameCtrl.text.trim(),
                      category: categoryCtrl.text.isEmpty
                          ? 'All Items'
                          : categoryCtrl.text.trim(),
                      defaultStation: selectedStation,
                      modifiers: modCtrl.text
                          .split(',')
                          .map((e) => e.trim())
                          .where((e) => e.isNotEmpty)
                          .toList(),
                      requiredModifiers: reqModCtrl.text
                          .split(',')
                          .map((e) => e.trim())
                          .where((e) => e.isNotEmpty)
                          .toList(),
                      tags: tags,
                      price: double.tryParse(priceCtrl.text) ?? 0.0,
                      stockQuantity: int.tryParse(stockCtrl.text) ?? 0,
                      trackStock: trackStock,
                      oneTouch: oneTouch,
                    ),
                  );
                  if (context.mounted) Navigator.pop(context);
                }
              },
              child: const Text('SAVE CHANGES'),
            ),
          ],
        ),
      ),
    );
  }
}

/// Combo editor widget for creating new combos.
class _ComboEditor extends StatefulWidget {
  final HostStore store;
  final ThemeData theme;
  final List<StationData> stations;
  final List<MenuItemData> regularItems;

  const _ComboEditor({
    required this.store,
    required this.theme,
    required this.stations,
    required this.regularItems,
  });

  @override
  State<_ComboEditor> createState() => _ComboEditorState();
}

class _ComboEditorState extends State<_ComboEditor> {
  final _nameController = TextEditingController();
  final _priceController = TextEditingController();
  String _category = 'All Items';
  String? _selectedStation;
  final Set<int> _selectedComponentIds = {};
  final Map<int, int> _componentQuantities = {};

  @override
  void dispose() {
    _nameController.dispose();
    _priceController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = widget.theme;
    final effectiveStation = _selectedStation ??
        (widget.stations.isNotEmpty ? widget.stations.first.name : null);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildField(_nameController, 'Combo Name', hint: 'e.g. Burger Combo'),
        const SizedBox(height: 12),
        _buildField(
          _priceController,
          'Combo Price',
          hint: '0.00',
          prefix: r'$',
          keyboard: const TextInputType.numberWithOptions(decimal: true),
        ),
        const SizedBox(height: 12),
        DropdownButtonFormField<String>(
          initialValue: effectiveStation,
          decoration: _inputDecoration('Routing Station'),
          items: widget.stations
              .map(
                (s) => DropdownMenuItem(
                  value: s.name,
                  child: Text(
                    s.name,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
              )
              .toList(),
          onChanged: (val) => setState(() => _selectedStation = val),
        ),
        const SizedBox(height: 16),
        const Text(
          'COMPONENTS',
          style: TextStyle(
            fontWeight: FontWeight.w900,
            fontSize: 11,
            color: Color(0xFF666666),
            letterSpacing: 1.2,
          ),
        ),
        const SizedBox(height: 8),
        ...widget.regularItems.map((item) {
          final isSelected = _selectedComponentIds.contains(item.id);
          final qty = _componentQuantities[item.id] ?? 1;
          return CheckboxListTile(
            value: isSelected,
            onChanged: (val) {
              setState(() {
                if (val == true) {
                  _selectedComponentIds.add(item.id);
                  _componentQuantities[item.id] = 1;
                } else {
                  _selectedComponentIds.remove(item.id);
                  _componentQuantities.remove(item.id);
                }
              });
            },
            title: Text(
              item.name.toUpperCase(),
              style: const TextStyle(
                fontWeight: FontWeight.w700,
                fontSize: 13,
              ),
            ),
            subtitle: Text(
              '\$${item.price.toStringAsFixed(2)} • ${item.defaultStation}',
              style: const TextStyle(fontSize: 10),
            ),
            secondary: isSelected
                ? Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        icon: const Icon(Icons.remove, size: 16),
                        onPressed: qty > 1
                            ? () => setState(
                                () => _componentQuantities[item.id] = qty - 1,
                              )
                            : null,
                      ),
                      Text(
                        '$qty',
                        style: const TextStyle(fontWeight: FontWeight.w900),
                      ),
                      IconButton(
                        icon: const Icon(Icons.add, size: 16),
                        onPressed: () => setState(
                          () => _componentQuantities[item.id] = qty + 1,
                        ),
                      ),
                    ],
                  )
                : null,
            dense: true,
            contentPadding: EdgeInsets.zero,
            activeColor: const Color(0xFF7C3AED),
          );
        }),
        const SizedBox(height: 16),
        ElevatedButton(
          style: ElevatedButton.styleFrom(
            backgroundColor: const Color(0xFF7C3AED),
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(vertical: 16),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(6),
            ),
            elevation: 0,
          ),
          onPressed: _selectedComponentIds.isEmpty
              ? null
              : () async {
                  final name = _nameController.text.trim();
                  final price =
                      double.tryParse(_priceController.text) ?? 0.0;
                  if (name.isEmpty) return;
                  final componentIds = _selectedComponentIds.toList();
                  final componentQtys = componentIds
                      .map((id) => _componentQuantities[id] ?? 1)
                      .toList();
                  await widget.store.saveCombo(
                    name: name,
                    price: price,
                    category: _category,
                    defaultStation: effectiveStation ?? 'Main Station',
                    componentItemIds: componentIds,
                    componentQuantities: componentQtys,
                  );
                  _nameController.clear();
                  _priceController.clear();
                  setState(() {
                    _selectedComponentIds.clear();
                    _componentQuantities.clear();
                  });
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Combo saved!'),
                        backgroundColor: Color(0xFF22C55E),
                      ),
                    );
                  }
                },
          child: const Text(
            'SAVE COMBO',
            style: TextStyle(
              fontWeight: FontWeight.w900,
              letterSpacing: 0.5,
            ),
          ),
        ),
      ],
    );
  }

  InputDecoration _inputDecoration(String label) {
    return InputDecoration(
      labelText: label,
      labelStyle: const TextStyle(
        fontWeight: FontWeight.w700,
        fontSize: 13,
        color: Color(0xFF666666),
      ),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(6),
        borderSide: BorderSide(color: widget.theme.dividerColor),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(6),
        borderSide: BorderSide(color: widget.theme.dividerColor),
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
      isDense: true,
    );
  }

  Widget _buildField(
    TextEditingController controller,
    String label, {
    String? hint,
    String? prefix,
    TextInputType? keyboard,
  }) {
    return TextField(
      controller: controller,
      keyboardType: keyboard,
      style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14),
      decoration: _inputDecoration(label).copyWith(hintText: hint, prefixText: prefix),
    );
  }
}








