import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'views/order_intake_view.dart';
import 'views/inventory_view.dart';
import 'views/more_view.dart';
import 'views/sent_queue_view.dart';
import '../../providers/app_state_providers.dart';
import '../../providers/settings_provider.dart';
import '../../providers/host_store_provider.dart';
import '../../providers/service_providers.dart' show startHostServices;
import '../shared/responsive_utils.dart';
import '../../models/connected_client.dart';

class HostHome extends ConsumerStatefulWidget {
  const HostHome({super.key});

  @override
  ConsumerState<HostHome> createState() => _HostHomeState();
}

class _HostHomeState extends ConsumerState<HostHome> {
  final List<Widget> _views = [
    const OrderIntakeView(),
    const SentQueueView(),
    const InventoryView(),
    const MoreView(),
  ];

  bool _initialized = false;
  Set<String> _knownClientIds = {};

  /// True in the browser, where this device is a remote control for a host
  /// that is already running elsewhere on the LAN.
  bool get _isRemote => ref.read(webHostClientProvider) != null;

  @override
  void initState() {
    super.initState();
    // On app restart the persisted host role lands directly on HostHome
    // without going through role selection, so (re)start host services here.
    // Remote (browser) sessions talk to an existing host instead.
    WidgetsBinding.instance.addPostFrameCallback((_) => _startHostServices());
  }

  Future<void> _startHostServices() async {
    if (_isRemote) return;
    try {
      await startHostServices(ref);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'HOST START FAILED: $e',
            style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 12),
          ),
          backgroundColor: Colors.redAccent,
        ),
      );
    }
  }

  void _onClientsChanged(List<ConnectedClient> clients) {
    final ids = clients.map((c) => c.id).toSet();
    if (!_initialized) {
      _initialized = true;
      _knownClientIds = ids;
      return;
    }
    final newClients = clients
        .where((c) => !_knownClientIds.contains(c.id))
        .toList();
    _knownClientIds = ids;
    for (final client in newClients) {
      _showClientConnectedDialog(client);
    }
  }

  Future<void> _confirmSwitchRole() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('SWITCH DEVICE ROLE?',
            style: TextStyle(fontWeight: FontWeight.w900, fontSize: 16)),
        content: const Text(
          'Return to the role selection screen? Host services will stop.',
          style: TextStyle(fontSize: 14),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('CANCEL'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('SWITCH ROLE'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await ref.read(hostStoreProvider).shutdownHostServices();
    ref.read(deviceRoleProvider.notifier).setRole(DeviceRole.unset);
  }

  Future<void> _showClientConnectedDialog(ConnectedClient client) async {
    if (!mounted) return;
    final theme = Theme.of(context);
    await showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: theme.cardColor,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: BorderSide(color: theme.dividerColor),
        ),
        title: Row(
          children: [
            Container(
              width: 10,
              height: 10,
              decoration: const BoxDecoration(
                color: Color(0xFF22C55E),
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 10),
            const Text(
              'NEW CLIENT CONNECTED',
              style: TextStyle(
                fontWeight: FontWeight.w900,
                fontSize: 15,
                letterSpacing: 0.5,
              ),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${client.deviceName} joined the kitchen display network.',
              style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
            ),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: const Color(0xFF22C55E).withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(
                  color: const Color(0xFF22C55E).withValues(alpha: 0.25),
                ),
              ),
              child: Row(
                children: [
                  const Icon(
                    Icons.tune_rounded,
                    size: 16,
                    color: Color(0xFF15803D),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    'STATION: ${client.currentStation.toUpperCase()}',
                    style: const TextStyle(
                      fontWeight: FontWeight.w900,
                      fontSize: 12,
                      letterSpacing: 0.5,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text(
              'OK',
              style: TextStyle(
                fontWeight: FontWeight.w800,
                color: Color(0xFF2AA31F),
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);
    final theme = Theme.of(context);
    final timeFormat = settings.use24HourFormat ? 'HH:mm' : 'h:mm a';
    final currentIndex = ref.watch(hostTabIndexProvider);

    // New-client notifications come straight from the active store, so a
    // browser session reports exactly the same devices as the host device.
    ref.listen<AsyncValue<List<ConnectedClient>>>(
      hostClientsProvider,
      (previous, next) {
        if (previous == null || !next.hasValue) return;
        _onClientsChanged(next.value ?? []);
      },
    );

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      appBar: AppBar(
        toolbarHeight: 70,
        title: Row(
          children: [
            Container(
              width: 8,
              height: 8,
              decoration: const BoxDecoration(
                color: Color(0xFF22C55E),
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                currentIndex == 0
                    ? 'TERMINAL'
                    : (currentIndex == 1
                          ? 'HISTORY'
                          : (currentIndex == 2 ? 'STOCK' : 'SYSTEM')),
                style: const TextStyle(letterSpacing: 1.5, fontSize: 13),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        actions: [
          if (!_isRemote)
            IconButton(
              tooltip: 'Switch device role',
              icon: const Icon(Icons.swap_horiz_rounded, size: 18),
              onPressed: () => _confirmSwitchRole(),
            ),
          IconButton(
            tooltip: 'Toggle theme',
            icon: Icon(
              theme.brightness == Brightness.dark
                  ? Icons.light_mode_rounded
                  : Icons.dark_mode_rounded,
              size: 18,
            ),
            onPressed: () {
              final currentMode = ref.read(settingsProvider).themeMode;
              final newMode = currentMode == ThemeMode.dark ? ThemeMode.light : ThemeMode.dark;
              ref.read(settingsProvider.notifier).setThemeMode(newMode);
            },
          ),
          Row(
            children: [
              Text(
                'RUSH',
                style: TextStyle(
                  fontWeight: FontWeight.w900,
                  fontSize: 10,
                  color: ref.watch(rushModeProvider)
                      ? const Color(0xFFDC2626)
                      : Colors.grey,
                ),
              ),
              Transform.scale(
                scale: 0.7,
                child: Switch(
                  value: ref.watch(rushModeProvider),
                  activeThumbColor: const Color(0xFFDC2626),
                  onChanged: (val) {
                    ref.read(rushModeProvider.notifier).state = val;
                    ref.read(hostStoreProvider).setRushMode(val);
                  },
                ),
              ),
            ],
          ),
          Container(
            margin: const EdgeInsets.symmetric(vertical: 14),
            padding: const EdgeInsets.symmetric(horizontal: 16),
            decoration: BoxDecoration(
              border: Border(left: BorderSide(color: theme.dividerColor)),
            ),
            alignment: Alignment.center,
            child: StreamBuilder(
              stream: Stream.periodic(const Duration(seconds: 1)),
              builder: (context, snapshot) {
                return Text(
                  DateFormat(timeFormat).format(DateTime.now()),
                  style: const TextStyle(
                    fontWeight: FontWeight.w900,
                    fontFamily: 'monospace',
                    fontSize: 15,
                  ),
                );
              },
            ),
          ),
        ],
      ),
      body: ContentWidth(maxWidth: 1400, child: _views[currentIndex]),
      bottomNavigationBar: Container(
        decoration: BoxDecoration(
          border: Border(
            top: BorderSide(color: theme.dividerColor, width: 1.5),
          ),
        ),
        child: BottomNavigationBar(
          currentIndex: currentIndex,
          onTap: (index) =>
              ref.read(hostTabIndexProvider.notifier).state = index,
          items: const [
            BottomNavigationBarItem(
              icon: Icon(Icons.apps_outlined, size: 22),
              activeIcon: Icon(Icons.apps_rounded, size: 22),
              label: 'ORDER',
            ),
            BottomNavigationBarItem(
              icon: Icon(Icons.history_outlined, size: 22),
              activeIcon: Icon(Icons.history_rounded, size: 22),
              label: 'HISTORY',
            ),
            BottomNavigationBarItem(
              icon: Icon(Icons.inventory_2_outlined, size: 22),
              activeIcon: Icon(Icons.inventory_2_rounded, size: 22),
              label: 'STOCK',
            ),
            BottomNavigationBarItem(
              icon: Icon(Icons.settings_outlined, size: 22),
              activeIcon: Icon(Icons.settings_rounded, size: 22),
              label: 'SYSTEM',
            ),
          ],
        ),
      ),
    );
  }
}
