import 'dart:async';
import 'dart:convert';
import 'dart:io' if (dart.library.js_interop) '../../web_io_stub.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:confetti/confetti.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import '../../providers/service_providers.dart';
import '../../providers/client_state_provider.dart';
import '../../providers/app_state_providers.dart';
import '../../providers/settings_provider.dart';
import '../../services/client_service.dart';
import '../../models/order_status.dart';
import '../shared/responsive_utils.dart';

/// Whether the board should be drawn dark.
///
/// `system` is resolved against the platform brightness. Reading the setting
/// directly treated anything that was not literally `dark` as light, so a
/// display left on the system default rendered a light board regardless of what
/// the OS was actually doing — and there was no way to change it from the
/// display's own settings screen.
///
/// Top-level so the ticket cards, which are a separate widget class, resolve the
/// same way the screen around them does.
bool isDarkBoard(BuildContext context, AppSettings settings) {
  if (settings.clientHighContrast) return true;
  return switch (settings.themeMode) {
    ThemeMode.dark => true,
    ThemeMode.light => false,
    ThemeMode.system =>
      MediaQuery.platformBrightnessOf(context) == Brightness.dark,
  };
}

/// Widest a ticket column is allowed to get before another one is added.
const double kTicketColumnTarget = 240;

/// Upper bound on ticket columns, so an ultrawide board does not end up with a
/// grid of unreadable slivers.
const int kTicketMaxColumns = 14;

/// Grid layout for the ticket board.
///
/// Height comes from the board rather than from the tile's width. This used to
/// be `childAspectRatio: 1.05`, which derived the height from the width and so
/// handed a 12-item ticket on a 1080p board about 240px of item list — roughly
/// two rows. Everything below that scrolled silently: no scrollbar, no edge
/// fade, no count of what was hidden (issue #6). Sizing by height gives each
/// card every pixel the board has instead.
///
/// `mainAxisExtent` takes precedence over `childAspectRatio`, which the delegate
/// defaults to 1.0 whether or not it is passed — so the ratio is simply not in
/// play here. Cross count still derives from the width, which means the number
/// of tickets on screen is unchanged.
///
/// Top-level with a plain signature so the geometry is testable without standing
/// up [ClientHome] and its socket and discovery work.
SliverGridDelegate ticketGridDelegate({
  required double maxWidth,
  required double maxHeight,
}) {
  // `EdgeInsets.all(8)` on the grid (16) plus the `mainAxisSpacing` beneath a
  // single full-height row.
  const double gutter = 24;

  // Floor rather than allowing zero, so a board squeezed into a tiny sliver
  // degrades into "too small to read" instead of throwing on a negative extent.
  const double minExtent = 120;

  final double extent = maxHeight.isFinite
      ? (maxHeight - gutter).clamp(minExtent, double.infinity)
      : minExtent.toDouble();

  return SliverGridDelegateWithFixedCrossAxisCount(
    crossAxisCount: (maxWidth / kTicketColumnTarget).floor().clamp(
      1,
      kTicketMaxColumns,
    ),
    crossAxisSpacing: 8,
    mainAxisSpacing: 8,
    mainAxisExtent: extent,
  );
}

class ClientHome extends ConsumerStatefulWidget {
  const ClientHome({super.key});

  @override
  ConsumerState<ClientHome> createState() => _ClientHomeState();
}

class _ClientHomeState extends ConsumerState<ClientHome>
    with WidgetsBindingObserver {
  bool _isConnected = false;
  StreamSubscription<dynamic>? _wsSubscription;
  StreamSubscription<ClientConnectionStatus>? _statusSubscription;
  StreamSubscription? _discoverySub;
  String _deviceIp = '...';
  final _audioPlayer = AudioPlayer();
  late ConfettiController _confettiController;
  bool _isRushMode = false;
  String? _clientId;

  /// Distinguishes "never reached a host" from "lost one". First run gets the
  /// full connection screen; a drop keeps the board visible under a banner.
  bool _hasConnectedBefore = false;
  String? _lastConnectedHost;
  int? _lastConnectedPort;
  int _discoveryRetries = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _confettiController = ConfettiController(
      duration: const Duration(seconds: 1),
    );
    // Allow both orientations for flexibility, though landscape is preferred
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
      DeviceOrientation.portraitUp,
    ]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadLastHostAndStart();
      _fetchIp();
    });

    _watchHostLink();
  }

  /// Subscribes to the host link once, for the lifetime of this screen.
  ///
  /// Reconnection lives in [ClientService], so the stream handed out there
  /// survives a dropped socket. Previously every connect attempt re-subscribed
  /// and the old subscription was only cancelled on the code paths that
  /// remembered to, which left dead sockets delivering frames and ran the
  /// handler several times per message.
  void _watchHostLink() {
    final service = ref.read(clientServiceProvider);
    _wsSubscription = service.stream.listen(
      (message) => _handleIncomingMessage(message.toString()),
      // A read error is not fatal: the service tears the socket down and
      // reconnects on its own.
      onError: (Object error) => debugPrint('KDS frame stream error: $error'),
    );
    _statusSubscription = service.statusStream.listen((status) {
      final connected = status == ClientConnectionStatus.connected;
      if (!mounted || connected == _isConnected) return;
      setState(() {
        _isConnected = connected;
        if (connected) _hasConnectedBefore = true;
      });
      if (connected) {
        // Register on every fresh socket. The host replays the active orders to
        // whoever registers, which is what brings a dropped display back in
        // sync with the kitchen rather than leaving it showing a stale board.
        _registerWithHost();
      }
    });
  }

  /// Identity is minted once and reused, so a reconnect is recognisably the
  /// same display to the host rather than a second device.
  Future<String> _resolveClientId() async {
    final cached = _clientId;
    if (cached != null) return cached;
    final prefs = await SharedPreferences.getInstance();
    var id = prefs.getString('client_uuid');
    if (id == null || id.isEmpty) {
      id = const Uuid().v4();
      await prefs.setString('client_uuid', id);
    }
    return _clientId = id;
  }

  void _registerWithHost() {
    final id = _clientId;
    if (id == null) return;
    ref.read(clientServiceProvider).send({
      'type': 'RegisterClient',
      'id': id,
      'deviceName': Platform.localHostname,
      'station': ref.read(stationTagProvider) ?? 'GENERAL',
    });
  }

  Future<void> _loadLastHostAndStart() async {
    final prefs = await SharedPreferences.getInstance();
    _lastConnectedHost = prefs.getString('last_host');
    _lastConnectedPort = prefs.getInt('last_port');
    _startDiscovery();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      // Save battery by stopping discovery in background
      _discoverySub?.cancel();
    } else if (state == AppLifecycleState.resumed) {
      if (_isConnected) return;
      // The network just came back, so there is no reason to sit out the
      // remaining backoff before dialling again.
      unawaited(ref.read(clientServiceProvider).reconnectNow());
      _startDiscovery();
    }
  }

  Future<void> _playSound() async {
    final settings = ref.read(settingsProvider);
    try {
      await _audioPlayer.setVolume(settings.clientVolume);
      await _audioPlayer.play(AssetSource('notification.mp3'));
    } catch (e) {
      debugPrint('Error playing sound: $e');
    }
  }

  void _handleIncomingMessage(String message) {
    final Map<String, dynamic> data;
    try {
      final decoded = jsonDecode(message);
      if (decoded is! Map) return;
      data = decoded.cast<String, dynamic>();
    } catch (e) {
      // One unreadable frame is not worth taking the display down for, and this
      // runs inside a stream listener where an uncaught throw surfaces as an
      // unhandled zone error and takes the app with it.
      debugPrint('KDS dropped an unreadable frame: $e');
      return;
    }
    if (data['type'] == 'ping') {
      // Answer the host's liveness probe. Its roster sweep only keeps clients
      // that are heard from, so staying silent here gets this display evicted.
      ref.read(clientServiceProvider).send({'type': 'pong'});
      return;
    }
    if (data['type'] == 'pong') return;

    if (data['type'] == 'KitchenBroadcast') {
      _showBroadcastOverlay(
        data['message'],
        station: data['station']?.toString(),
      );
    }
    if (data['type'] == 'RushModeChanged') {
      if (mounted) setState(() => _isRushMode = data['enabled'] == true);
    }
    if (data['type'] == 'OrderCreated' || data['type'] == 'OrderUpdated') {
      final stationTag = ref.read(stationTagProvider) ?? 'GENERAL';
      bool shouldNotify = false;
      if (stationTag == 'GENERAL' || stationTag == 'EXPO') {
        shouldNotify = true;
      } else {
        final orderData = data['order'];
        final items = orderData['items'] as List;
        shouldNotify = items.any(
          (i) =>
              (i['stationTag'] as String).toUpperCase() ==
              stationTag.toUpperCase(),
        );
      }

      if (shouldNotify) {
        _playSound();
        HapticFeedback.vibrate();
      }
    }
    if (data['type'] == 'SetStation') {
      ref
          .read(stationTagProvider.notifier)
          .set((data['station'] as String).toUpperCase());
    }
    if (data['type'] == 'ReplayFinished') {
      final orderData = data['order'];
      final order = ClientOrder(
        uuid: orderData['uuid'],
        customerName: orderData['customerName'] ?? 'Guest',
        timestamp: DateTime.parse(orderData['timestamp']),
        status: OrderStatus.complete,
        items: (orderData['items'] as List)
            .map(
              (i) => ClientItem(
                uuid: i['uuid'],
                name: i['name'],
                modifiers: List<String>.from(i['modifiers'] ?? []),
                stationTag: i['stationTag'] ?? 'GENERAL',
                isBumped: true,
              ),
            )
            .toList(),
      );
      ref.read(recentBumpsProvider.notifier).add(order);
      return;
    }
    if (data['type'] == 'OrderDeleted') {
      final orderUuid = data['orderUuid'] as String?;
      if (orderUuid != null) {
        ref.read(clientStateProvider.notifier).removeOrder(orderUuid);
      }
      return;
    }
    final finishedOrder = ref
        .read(clientStateProvider.notifier)
        .handleEvent(message);
    if (finishedOrder != null) {
      ref.read(recentBumpsProvider.notifier).add(finishedOrder);
    }
  }

  Future<void> _fetchIp() async {
    try {
      final interfaces = await NetworkInterface.list();
      final addr = interfaces
          .expand((i) => i.addresses)
          .where((a) => a.type == InternetAddressType.IPv4 && !a.isLoopback)
          .map((a) => a.address)
          .join(', ');
      if (mounted) setState(() => _deviceIp = addr.isEmpty ? 'NO IP' : addr);
    } catch (e) {
      if (mounted) setState(() => _deviceIp = 'ERROR');
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    _wsSubscription?.cancel();
    _statusSubscription?.cancel();
    _discoverySub?.cancel();
    _confettiController.dispose();
    _audioPlayer.dispose();
    super.dispose();
  }

  void _startDiscovery() async {
    if (_isConnected) return;
    _discoverySub?.cancel();
    _discoveryRetries = 0;

    // On web, mDNS/UDP discovery is unavailable — this page is usually served
    // by the host itself, so just connect back to the origin.
    if (kIsWeb) {
      final originHost = Uri.base.host;
      if (originHost.isNotEmpty) {
        _connectToHost(originHost, 8080);
        return;
      }
    }

    // Direct attempt if we have cached credentials
    if (_lastConnectedHost != null && _lastConnectedPort != null) {
      _connectToHost(_lastConnectedHost!, _lastConnectedPort!);
      return;
    }

    _listenForHosts();
  }

  void _listenForHosts() {
    if (_isConnected || !mounted) return;
    _discoverySub?.cancel();
    _discoverySub = ref.read(discoveryServiceProvider).discover().listen((
      host,
    ) {
      if (!_isConnected && host.address.isNotEmpty) {
        _connectToHost(host.address, host.port);
      }
    }, onError: (e) => debugPrint('Discovery error: $e'));

    // Backoff logic for battery optimization
    Timer(const Duration(seconds: 30), () {
      if (!_isConnected && mounted) {
        _discoveryRetries++;
        if (_discoveryRetries > 2) {
          _discoverySub?.cancel();
          // Wait 60s before retrying to save battery
          Future.delayed(const Duration(seconds: 60), () {
            if (!_isConnected && mounted) _listenForHosts();
          });
        }
      }
    });
  }

  Future<void> _connectToHost(
    String host,
    int port, {
    bool manual = false,
  }) async {
    final hostTrim = host.trim();
    if (hostTrim.isEmpty) return;
    _discoverySub?.cancel();

    await _resolveClientId();

    try {
      await ref.read(clientServiceProvider).connect(hostTrim, port);
    } catch (e) {
      debugPrint('KDS could not reach ${hostTrim}:$port — $e');
      if (mounted) setState(() => _isConnected = false);
      // Fall back to discovery only when there is nothing to retry against.
      // A known host is already being retried by the service with backoff, and
      // bouncing back into discovery here re-entered this method immediately,
      // spinning the reconnect loop with no delay until the app was backgrounded.
      if (!manual && _lastConnectedHost == null) _startDiscovery();
      return;
    }

    // Save successful connection for future boot speed & battery optimization
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('last_host', hostTrim);
    await prefs.setInt('last_port', port);
    _lastConnectedHost = hostTrim;
    _lastConnectedPort = port;
    // Registration is sent by the status listener once the socket reports
    // connected, so this screen does not have to track connection state to know
    // when the host is listening.
  }

  @override
  Widget build(BuildContext context) {
    final tickets = ref.watch(filteredTicketsProvider);
    final stationTag = ref.watch(stationTagProvider) ?? 'GENERAL';
    final settings = ref.watch(settingsProvider);
    final timeFormat = settings.use24HourFormat ? 'HH:mm:ss' : 'h:mm:ss a';
    final isTablet =
        Responsive.isTablet(context) || Responsive.isDesktop(context);

    final isDark = isDarkBoard(context, settings);

    // First run: no host has ever been reached, so offer the full set of ways
    // in rather than an empty board.
    if (!_isConnected && !_hasConnectedBefore) {
      return _buildConnectionScreen(stationTag);
    }

    return MediaQuery(
      data: MediaQuery.of(
        context,
      ).copyWith(textScaler: TextScaler.linear(settings.clientTextScale)),
      child: Stack(
        children: [
          Scaffold(
            // Follows the resolved brightness rather than the raw setting, so
            // `system` no longer paints a light board on a display set to dark.
            backgroundColor: settings.clientHighContrast
                ? Colors.black
                : (isDark
                      ? const Color(0xFF030712)
                      : Colors.white),
            body: Column(
              children: [
                _buildHeader(stationTag, timeFormat, settings),
                // Only after a drop, never on first run.
                if (!_isConnected) _buildReconnectingBanner(),
                Expanded(
                  child: tickets.isEmpty
                      ? _buildEmptyState(isDark)
                      : LayoutBuilder(
                          builder: (context, constraints) {
                            if (isTablet) {
                              // Grid for tablets (denser = smaller tiles).
                              // Each tile takes the full board height rather
                              // than a share of it — see [ticketGridDelegate].
                              return GridView.builder(
                                padding: const EdgeInsets.all(8),
                                gridDelegate: ticketGridDelegate(
                                  maxWidth: constraints.maxWidth,
                                  maxHeight: constraints.maxHeight,
                                ),
                                itemCount: tickets.length,
                                itemBuilder: (context, index) =>
                                    _buildAnimatedTicket(
                                      tickets[index],
                                      settings,
                                      stationTag,
                                    ),
                              );
                            } else {
                              // Horizontal list for phones
                              return ListView.builder(
                                scrollDirection: Axis.horizontal,
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 8,
                                ),
                                itemCount: tickets.length,
                                itemBuilder: (context, index) =>
                                    _buildAnimatedTicket(
                                      tickets[index],
                                      settings,
                                      stationTag,
                                    ),
                              );
                            }
                          },
                        ),
                ),
              ],
            ),
          ),
          _buildConfetti(),
        ],
      ),
    );
  }

  Widget _buildAnimatedTicket(
    ClientOrder ticket,
    AppSettings settings,
    String stationTag,
  ) {
    return TweenAnimationBuilder<double>(
      duration: const Duration(milliseconds: 600),
      curve: Curves.elasticOut,
      tween: Tween(begin: 0.0, end: 1.0),
      builder: (context, value, child) {
        return Transform.scale(
          scale: 0.8 + (0.2 * value),
          child: Opacity(opacity: value.clamp(0.0, 1.0), child: child),
        );
      },
      child: RepaintBoundary(
        child: _TicketCard(
          key: ValueKey(ticket.uuid),
          order: ticket,
          stationFilter: stationTag,
          isRushMode: _isRushMode,
          onFinished: () {
            if (settings.enableConfetti) {
              _confettiController.play();
            }
          },
          settings: settings,
        ),
      ),
    );
  }

  /// Shown before this display has ever reached a host.
  ///
  /// This was unreachable before: `build` never referenced it, so QR scanning,
  /// station selection and re-scan had no entry point. That mattered most
  /// exactly when discovery fails — an AP that blocks broadcast traffic leaves a
  /// display with no way to connect at all short of the header's dot, which is
  /// not discoverable as a control.
  Widget _buildConnectionScreen(String stationTag) {
    return Scaffold(
      backgroundColor: const Color(0xFF030712),
      body: Center(
        child: SingleChildScrollView(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const CircularProgressIndicator(color: Color(0xFF22C55E)),
              const SizedBox(height: 24),
              const Text(
                'SEARCHING FOR KITCHEN HOST...',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 2,
                ),
              ),
              const SizedBox(height: 32),
              ElevatedButton(
                onPressed: () => _showStationSelectionDialog(),
                child: Text('STATION: ${stationTag.toUpperCase()}'),
              ),
              const SizedBox(height: 16),
              ElevatedButton.icon(
                onPressed: () => _showScannerDialog(context),
                icon: const Icon(Icons.qr_code_scanner_rounded),
                label: const Text('SCAN QR CODE'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF22C55E),
                  foregroundColor: Colors.black,
                ),
              ),
              const SizedBox(height: 12),
              ElevatedButton(
                onPressed: () => _startDiscovery(),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF1F2937),
                ),
                child: const Text('RE-SCAN FOR HOST'),
              ),
              const SizedBox(height: 16),
              TextButton(
                onPressed: () => _showManualConnectDialog(),
                child: const Text(
                  'MANUAL CONNECT',
                  style: TextStyle(color: Color(0xFF6B7280)),
                ),
              ),
              const SizedBox(height: 8),
              TextButton(
                onPressed: () {
                  _discoverySub?.cancel();
                  ref
                      .read(deviceRoleProvider.notifier)
                      .setRole(DeviceRole.unset);
                },
                child: const Text(
                  'CANCEL',
                  style: TextStyle(
                    color: Color(0xFF6B7280),
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Slim banner shown when the link drops after a display was already working.
  ///
  /// The board stays visible on purpose — a chef needs to see the tickets in
  /// front of them — but it is now visibly marked as not backed by the host, so
  /// bumps are not fired at a board the host no longer agrees with.
  Widget _buildReconnectingBanner() {
    return Material(
      color: const Color(0xFFB45309),
      child: InkWell(
        onTap: () => unawaited(ref.read(clientServiceProvider).reconnectNow()),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            children: [
              const SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Colors.white,
                ),
              ),
              const SizedBox(width: 10),
              const Expanded(
                child: Text(
                  'RECONNECTING TO HOST — TICKETS MAY BE OUT OF DATE',
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w800,
                    fontSize: 11,
                    letterSpacing: 0.5,
                  ),
                ),
              ),
              Text(
                'RETRY NOW',
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w900,
                  fontSize: 11,
                  decoration: TextDecoration.underline,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showScannerDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (context) => Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          leading: IconButton(
            icon: const Icon(Icons.close, color: Colors.white),
            onPressed: () => Navigator.pop(context),
          ),
          title: const Text(
            'SCAN PAIRING CODE',
            style: TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w900,
              fontSize: 14,
            ),
          ),
        ),
        body: Stack(
          children: [
            MobileScanner(
              onDetect: (capture) {
                final List<Barcode> barcodes = capture.barcodes;
                for (final barcode in barcodes) {
                  final String? code = barcode.rawValue;
                  if (code != null && code.startsWith('dartkds://connect')) {
                    final uri = Uri.parse(code);
                    final ip = uri.queryParameters['ip'];
                    final port =
                        int.tryParse(uri.queryParameters['port'] ?? '8080') ??
                        8080;

                    if (ip != null) {
                      Navigator.pop(context);
                      _connectToHost(ip, port, manual: true);
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text('Pairing with $ip...'),
                          backgroundColor: const Color(0xFF22C55E),
                        ),
                      );
                      return;
                    }
                  }
                }
              },
            ),
            Center(
              child: Container(
                width: 250,
                height: 250,
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.white54, width: 2),
                  borderRadius: BorderRadius.circular(20),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildConfetti() {
    return IgnorePointer(
      child: Stack(
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: ConfettiWidget(
              confettiController: _confettiController,
              blastDirection: 0,
              emissionFrequency: 0.05,
              numberOfParticles: 20,
              maxBlastForce: 100,
              minBlastForce: 80,
              colors: const [
                Colors.green,
                Colors.blue,
                Colors.pink,
                Colors.orange,
                Colors.purple,
              ],
            ),
          ),
          Align(
            alignment: Alignment.centerRight,
            child: ConfettiWidget(
              confettiController: _confettiController,
              blastDirection: 3.14,
              emissionFrequency: 0.05,
              numberOfParticles: 20,
              maxBlastForce: 100,
              minBlastForce: 80,
              colors: const [
                Colors.green,
                Colors.blue,
                Colors.pink,
                Colors.orange,
                Colors.purple,
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHeader(String station, String timeFormat, AppSettings settings) {
    final isDark = isDarkBoard(context, settings);
    final textColor = isDark ? Colors.white : Colors.black87;

    final bool highContrast = settings.clientHighContrast;
    final bool light = !isDark;
    final BoxDecoration decoration;
    if (highContrast) {
      decoration = const BoxDecoration(
        color: Colors.black,
        border: Border(bottom: BorderSide(color: Colors.white, width: 2)),
      );
    } else if (light) {
      decoration = BoxDecoration(
        color: Colors.grey.shade200,
        border: Border(bottom: BorderSide(color: Colors.grey.shade300)),
      );
    } else {
      decoration = const BoxDecoration(color: Color(0xFF1F2937));
    }

    return Container(
      height: 60,
      decoration: decoration,
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            children: [
              GestureDetector(
                onTap: () => _showStationSelectionDialog(),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xFF22C55E),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    station.toUpperCase(),
                    style: const TextStyle(
                      color: Colors.black,
                      fontWeight: FontWeight.w900,
                      fontSize: 16,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 16),
              GestureDetector(
                onTap: () {
                  if (!_isConnected) _showManualConnectDialog();
                },
                child: Row(
                  children: [
                    Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        color: _isConnected
                            ? const Color(0xFF22C55E)
                            : Colors.red,
                        shape: BoxShape.circle,
                        boxShadow: [
                          if (_isConnected)
                            BoxShadow(
                              color: const Color(
                                0xFF22C55E,
                              ).withValues(alpha: 0.5),
                              blurRadius: 4,
                              spreadRadius: 1,
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      'KDS • $_deviceIp ${_isConnected ? "" : "(OFFLINE)"}',
                      style: TextStyle(
                        color: textColor,
                        fontWeight: FontWeight.w700,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          Row(
            children: [
              StreamBuilder(
                stream: Stream.periodic(const Duration(seconds: 1)),
                builder: (context, snapshot) {
                  return RepaintBoundary(
                    child: Text(
                      DateFormat(timeFormat).format(DateTime.now()),
                      style: TextStyle(
                        color: textColor,
                        fontFamily: 'monospace',
                        fontSize: 22,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  );
                },
              ),
              const SizedBox(width: 16),
              IconButton(
                tooltip: 'Toggle theme',
                icon: Icon(
                  isDark ? Icons.light_mode : Icons.dark_mode,
                  color: textColor,
                  size: 20,
                ),
                onPressed: () {
                  final currentMode = ref.read(settingsProvider).themeMode;
                  final newMode = currentMode == ThemeMode.dark ? ThemeMode.light : ThemeMode.dark;
                  ref.read(settingsProvider.notifier).setThemeMode(newMode);
                },
              ),
              IconButton(
                icon: Icon(Icons.history, color: textColor, size: 20),
                onPressed: () => _showRecentBumpsDialog(),
              ),
              IconButton(
                icon: Icon(Icons.swap_horiz, color: textColor, size: 20),
                onPressed: () => _confirmSwitchRole(),
              ),
              IconButton(
                icon: Icon(Icons.settings, color: textColor, size: 20),
                onPressed: () => _showClientSettings(),
              ),
            ],
          ),
        ],
      ),
    );
  }

  void _showRecentBumpsDialog() {
    showDialog(
      context: context,
      builder: (context) => Consumer(
        builder: (context, ref, _) {
          final recent = ref.watch(recentBumpsProvider);
          final settings = ref.watch(settingsProvider);
          final isLight =
              settings.themeMode == ThemeMode.light &&
              !settings.clientHighContrast;
          return AlertDialog(
            backgroundColor: isLight ? Colors.white : const Color(0xFF1F2937),
            title: Text(
              'RECENT BUMPS',
              style: TextStyle(
                color: isLight ? Colors.black : Colors.white,
                fontWeight: FontWeight.bold,
              ),
            ),
            content: recent.isEmpty
                ? Text(
                    'No recent bumps',
                    style: TextStyle(color: isLight ? Colors.black54 : Colors.grey),
                  )
                : SizedBox(
                    width: 400,
                    child: ListView.builder(
                      shrinkWrap: true,
                      itemCount: recent.length,
                      itemBuilder: (context, index) {
                        final order = recent[index];
                        return ListTile(
                          title: Text(
                            '#${order.uuid.substring(0, 4).toUpperCase()} - ${order.customerName.toUpperCase()}',
                            style: TextStyle(
                              color: isLight ? Colors.black : Colors.white,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          subtitle: Text(
                            DateFormat('HH:mm:ss').format(order.timestamp),
                            style: TextStyle(color: isLight ? Colors.black54 : Colors.grey),
                          ),
                          trailing: ElevatedButton(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xFF22C55E),
                            ),
                            onPressed: () {
                              ref
                                  .read(clientStateProvider.notifier)
                                  .addOrder(order);
                              ref
                                  .read(recentBumpsProvider.notifier)
                                  .remove(order.uuid);
                              Navigator.pop(context);
                            },
                            child: const Text(
                              'RECALL',
                              style: TextStyle(
                                color: Colors.black,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('CLOSE'),
              ),
            ],
          );
        },
      ),
    );
  }

  void _showBroadcastOverlay(String message, {String? station}) {
    if (!mounted) return;
    HapticFeedback.heavyImpact();
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFFDC2626),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: const BorderSide(color: Colors.white, width: 4),
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.campaign_rounded, color: Colors.white, size: 80),
              const SizedBox(height: 24),
              const Text(
                'NOTIFICATION',
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w900,
                  fontSize: 24,
                  letterSpacing: 1.5,
                ),
              ),
              if (station != null && station.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(
                  'TO STATION: ${station.toUpperCase()}',
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                    fontSize: 14,
                    letterSpacing: 1,
                  ),
                ),
              ],
              const SizedBox(height: 16),
              Text(
                message.toUpperCase(),
                textAlign: TextAlign.center,
                maxLines: 4,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w800,
                  fontSize: 20,
                ),
              ),
            ],
          ),
        ),
        actions: [
          Center(
            child: Padding(
              padding: const EdgeInsets.only(bottom: 12.0),
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.white,
                  foregroundColor: Colors.black,
                ),
                onPressed: () => Navigator.pop(context),
                child: const Text(
                  'ACKNOWLEDGE',
                  style: TextStyle(fontWeight: FontWeight.w900),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _confirmSwitchRole() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text(
          'SWITCH DEVICE ROLE?',
          style: TextStyle(fontWeight: FontWeight.w900, fontSize: 16),
        ),
        content: const Text(
          'Return to the role selection screen?',
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
    _wsSubscription?.cancel();
    ref.read(deviceRoleProvider.notifier).setRole(DeviceRole.unset);
  }

  void _showClientSettings() {
    showDialog(
      context: context,
      builder: (context) => Consumer(
        builder: (context, ref, _) {
          final settings = ref.watch(settingsProvider);
          final notifier = ref.read(settingsProvider.notifier);
          final isLight =
              settings.themeMode == ThemeMode.light &&
              !settings.clientHighContrast;
          return AlertDialog(
            backgroundColor: isLight ? Colors.white : const Color(0xFF1F2937),
            title: Text(
              'KDS SETTINGS',
              style: TextStyle(
                color: isLight ? Colors.black : Colors.white,
                fontWeight: FontWeight.bold,
              ),
            ),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ListTile(
                    title: const Text(
                      'APPEARANCE',
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                        color: Colors.grey,
                      ),
                    ),
                    subtitle: Padding(
                      padding: const EdgeInsets.only(top: 8.0),
                      child: SegmentedButton<ThemeMode>(
                        segments: const [
                          ButtonSegment(
                            value: ThemeMode.system,
                            label: Text('Auto'),
                            icon: Icon(Icons.brightness_auto, size: 16),
                          ),
                          ButtonSegment(
                            value: ThemeMode.light,
                            label: Text('Light'),
                            icon: Icon(Icons.light_mode, size: 16),
                          ),
                          ButtonSegment(
                            value: ThemeMode.dark,
                            label: Text('Dark'),
                            icon: Icon(Icons.dark_mode, size: 16),
                          ),
                        ],
                        // Reported honestly. This used to show `Dark` while the
                        // setting was `system`, so a display left on the system
                        // default looked like it had been forced dark and there
                        // was no way back to auto from this screen at all.
                        selected: {settings.themeMode},
                        onSelectionChanged: (val) =>
                            notifier.setThemeMode(val.first),
                      ),
                    ),
                  ),
                  const Divider(),
                  _buildSlider(
                    'TEXT SIZE',
                    settings.clientTextScale,
                    0.8,
                    2.0,
                    6,
                    (val) => notifier.setClientTextScale(val),
                  ),
                  _buildSlider(
                    'ALERT VOLUME',
                    settings.clientVolume,
                    0.0,
                    1.0,
                    null,
                    (val) => notifier.setClientVolume(val),
                  ),
                  SwitchListTile(
                    title: Text(
                      'HIGH CONTRAST',
                      style: TextStyle(
                        color: isLight ? Colors.black : Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 14,
                      ),
                    ),
                    value: settings.clientHighContrast,
                    activeThumbColor: const Color(0xFF22C55E),
                    onChanged: (val) => notifier.setClientHighContrast(val),
                  ),
                  SwitchListTile(
                    title: Text(
                      'ENABLE CONFETTI',
                      style: TextStyle(
                        color: isLight ? Colors.black : Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 14,
                      ),
                    ),
                    value: settings.enableConfetti,
                    activeThumbColor: const Color(0xFF22C55E),
                    onChanged: (val) => notifier.setEnableConfetti(val),
                  ),
                  SwitchListTile(
                    title: Text(
                      'KEEP SCREEN ON',
                      style: TextStyle(
                        color: isLight ? Colors.black : Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 14,
                      ),
                    ),
                    value: settings.keepScreenOn,
                    activeThumbColor: const Color(0xFF22C55E),
                    onChanged: (val) => notifier.setKeepScreenOn(val),
                  ),
                  ListTile(
                    title: const Text(
                      'CURRENT STATION',
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                        color: Colors.grey,
                      ),
                    ),
                    subtitle: Text(
                      (ref.watch(stationTagProvider) ?? 'GENERAL')
                          .toUpperCase(),
                      style: const TextStyle(
                        fontWeight: FontWeight.w900,
                        color: Color(0xFF22C55E),
                      ),
                    ),
                    trailing: TextButton(
                      onPressed: () {
                        Navigator.pop(context);
                        _showStationSelectionDialog();
                      },
                      child: const Text(
                        'CHANGE',
                        style: TextStyle(
                          color: Color(0xFF22C55E),
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                    ),
                  ),
                  const Divider(),
                  ListTile(
                    title: const Text(
                      'EXIT KITCHEN MODE',
                      style: TextStyle(
                        color: Colors.redAccent,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    onTap: () {
                      ref
                          .read(deviceRoleProvider.notifier)
                          .setRole(DeviceRole.unset);
                      Navigator.pop(context);
                    },
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('CLOSE'),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildSlider(
    String label,
    double value,
    double min,
    double max,
    int? divisions,
    ValueChanged<double> onChanged,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Text(
            label,
            style: const TextStyle(
              color: Colors.grey,
              fontSize: 10,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
        Slider(
          value: value,
          min: min,
          max: max,
          divisions: divisions,
          activeColor: const Color(0xFF22C55E),
          onChanged: onChanged,
        ),
      ],
    );
  }

  Widget _buildEmptyState(bool isDark) {
    final textColor = isDark
        ? Colors.white.withValues(alpha: 0.1)
        : Colors.black.withValues(alpha: 0.1);
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.check_circle_outline, size: 100, color: textColor),
          const SizedBox(height: 16),
          Text(
            'QUEUE EMPTY',
            style: TextStyle(
              color: textColor,
              fontSize: 24,
              fontWeight: FontWeight.w900,
              letterSpacing: 4,
            ),
          ),
        ],
      ),
    );
  }

  void _showStationSelectionDialog() {
    final controller = TextEditingController(
      text: ref.read(stationTagProvider),
    );
    final settings = ref.read(settingsProvider);
    final isLight =
        settings.themeMode == ThemeMode.light &&
        !settings.clientHighContrast;
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: isLight ? Colors.white : const Color(0xFF1F2937),
        title: Text(
          'SET STATION NAME',
          style: TextStyle(
            color: isLight ? Colors.black : Colors.white,
            fontWeight: FontWeight.bold,
          ),
        ),
        content: TextField(
          controller: controller,
          autofocus: true,
          style: TextStyle(color: isLight ? Colors.black : Colors.white),
          decoration: InputDecoration(
            hintText: 'e.g. GRILL, FRYER, EXPO',
            hintStyle: TextStyle(color: isLight ? Colors.black45 : Colors.grey),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('CANCEL'),
          ),
          TextButton(
            onPressed: () {
              ref.read(stationTagProvider.notifier).set(controller.text);
              Navigator.pop(context);
            },
            child: const Text(
              'SAVE',
              style: TextStyle(color: Color(0xFF22C55E)),
            ),
          ),
        ],
      ),
    );
  }

  void _showManualConnectDialog() {
    final controller = TextEditingController();
    final portController = TextEditingController(text: '8080');
    final settings = ref.read(settingsProvider);
    final isLight =
        settings.themeMode == ThemeMode.light &&
        !settings.clientHighContrast;
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: isLight ? Colors.white : const Color(0xFF1F2937),
        title: Text(
          'MANUAL CONNECT',
          style: TextStyle(
            color: isLight ? Colors.black : Colors.white,
            fontWeight: FontWeight.bold,
          ),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: controller,
              style: TextStyle(color: isLight ? Colors.black : Colors.white),
              decoration: InputDecoration(
                hintText: 'HOST IP ADDRESS',
                hintStyle: TextStyle(color: isLight ? Colors.black45 : Colors.grey),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: portController,
              style: TextStyle(color: isLight ? Colors.black : Colors.white),
              keyboardType: TextInputType.number,
              decoration: InputDecoration(
                hintText: 'PORT (8080)',
                hintStyle: TextStyle(color: isLight ? Colors.black45 : Colors.grey),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('CANCEL'),
          ),
          TextButton(
            onPressed: () {
              final port = int.tryParse(portController.text) ?? 8080;
              _connectToHost(controller.text, port, manual: true);
              Navigator.pop(context);
            },
            child: const Text(
              'CONNECT',
              style: TextStyle(color: Color(0xFF22C55E)),
            ),
          ),
        ],
      ),
    );
  }
}

class _TicketCard extends ConsumerStatefulWidget {
  final ClientOrder order;
  final String stationFilter;
  final VoidCallback? onFinished;
  final AppSettings settings;
  final bool isRushMode;

  const _TicketCard({
    super.key,
    required this.order,
    required this.stationFilter,
    this.onFinished,
    required this.settings,
    this.isRushMode = false,
  });

  @override
  ConsumerState<_TicketCard> createState() => _TicketCardState();
}

class _TicketCardState extends ConsumerState<_TicketCard> {
  /// Drives the always-visible scrollbar on the item list.
  ///
  /// An explicit controller rather than the implicit primary one: the board is
  /// a horizontal strip of these cards, so borrowing a primary controller risks
  /// two scrollables sharing one position.
  final ScrollController _itemScrollController = ScrollController();

  @override
  void dispose() {
    _itemScrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final order = widget.order;
    final stationFilter = widget.stationFilter;
    final settings = widget.settings;
    final isRushMode = widget.isRushMode;
    final isTablet =
        Responsive.isTablet(context) || Responsive.isDesktop(context);

    final elapsedMinutes = DateTime.now().difference(order.timestamp).inMinutes;
    final isDark = isDarkBoard(context, settings);
    final isLate = elapsedMinutes >= 15;
    final pulse = ref.watch(globalPulseProvider).value ?? 1.0;

    Color agingColor;
    if (elapsedMinutes < 5) {
      agingColor = const Color(0xFF22C55E);
    } else if (elapsedMinutes < 10) {
      agingColor = const Color(0xFFFACC15);
    } else {
      agingColor = const Color(0xFFDC2626);
    }

    final displayItems = order.items.where((item) {
      if (stationFilter == 'GENERAL' || stationFilter == 'EXPO') return true;
      return item.stationTag.toUpperCase() == stationFilter.toUpperCase();
    }).toList();

    if (displayItems.isEmpty) return const SizedBox.shrink();

    final borderOpacity = isLate ? pulse : 1.0;

    return AnimatedScale(
      duration: const Duration(milliseconds: 150),
      scale: 1.0,
      child: Material(
        color: settings.clientHighContrast
            ? Colors.black
            : (settings.themeMode == ThemeMode.light
                  ? Colors.white
                  : const Color(0xFF0F172A)),
        borderRadius: BorderRadius.circular(16),
        clipBehavior: Clip.antiAlias,
        child: Container(
          width: isTablet
              ? null
              : (isRushMode ? 240 : 290), // Flexible width on tablet
          margin: isTablet
              ? EdgeInsets.zero
              : const EdgeInsets.symmetric(horizontal: 8),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: settings.clientHighContrast
                  ? (elapsedMinutes >= 10
                        ? const Color(
                            0xFFDC2626,
                          ).withValues(alpha: borderOpacity)
                        : Colors.white)
                  : agingColor.withValues(alpha: borderOpacity),
              width: settings.clientHighContrast ? 4 : 2,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.1),
                blurRadius: 10,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Urgency Bar
              Container(height: 6, color: agingColor),
              Container(
                padding: EdgeInsets.all(isRushMode ? 8 : 12),
                decoration: BoxDecoration(
                  color: agingColor.withValues(alpha: 0.05),
                  border: Border(
                    bottom: BorderSide(
                      color: isDark
                          ? const Color(0xFF1E293B)
                          : Colors.grey.shade200,
                    ),
                  ),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Expanded(
                      child: Row(
                        children: [
                          if (order.customerName.startsWith('SQ:'))
                            Container(
                              margin: const EdgeInsets.only(right: 6),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 4,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color: const Color(0xFF10B981),
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: const Text(
                                'SQ',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 10,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                          Expanded(
                            child: Text(
                              '#${order.uuid.substring(0, 4).toUpperCase()}${isRushMode ? "" : " • ${order.customerName.replaceFirst('SQ: ', '').toUpperCase()}"}',
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: isDark
                                    ? Colors.white
                                    : const Color(0xFF0F172A),
                                fontSize: isRushMode ? 16 : 20,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    Text(
                      '${elapsedMinutes.clamp(0, 999)}m',
                      style: TextStyle(
                        color: agingColor,
                        fontSize: 16,
                        fontWeight: FontWeight.w900,
                        fontFamily: 'monospace',
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                // The list is still bounded even at full board height, so an
                // order with more items than fit — or a display at the top of
                // the text scale range, which grows rows without growing the
                // card — used to clip with nothing to signal there was more.
                // Always visible: a full-length thumb means everything fits, a
                // short one means read below.
                child: Scrollbar(
                  controller: _itemScrollController,
                  thumbVisibility: true,
                  child: ListView.builder(
                    controller: _itemScrollController,
                    // Gutter for the scrollbar so it never sits over the text.
                    padding: const EdgeInsets.only(right: 10),
                    itemCount: displayItems.length,
                    itemBuilder: (context, idx) {
                      final item = displayItems[idx];
                      return InkWell(
                        onTap: () {
                          HapticFeedback.lightImpact();
                          final newValue = !item.isBumped;
                          ref
                              .read(clientServiceProvider)
                              .send(
                                jsonEncode({
                                  'type': 'ItemBumped',
                                  'orderUuid': order.uuid,
                                  'itemUuid': item.uuid,
                                  'isBumped': newValue,
                                }),
                              );
                          ref
                              .read(clientStateProvider.notifier)
                              .toggleItemBump(order.uuid, item.uuid);
                        },
                        child: AnimatedOpacity(
                          duration: const Duration(milliseconds: 200),
                          opacity: item.isBumped ? 0.3 : 1.0,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 12,
                            ),
                            decoration: BoxDecoration(
                              border: Border(
                                bottom: BorderSide(
                                  color: isDark
                                      ? const Color(0xFF374151)
                                      : Colors.grey.shade200,
                                  width: 0.5,
                                ),
                              ),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    if (item.isBumped)
                                      const Padding(
                                        padding: EdgeInsets.only(right: 8.0),
                                        child: Icon(
                                          Icons.check_circle,
                                          color: Color(0xFF22C55E),
                                          size: 20,
                                        ),
                                      ),
                                    Expanded(
                                      child: Text(
                                        item.name.toUpperCase(),
                                        style: TextStyle(
                                          color: isDark
                                              ? Colors.white
                                              : const Color(0xFF0F172A),
                                          fontSize: 16,
                                          fontWeight: FontWeight.w800,
                                          decoration: item.isBumped
                                              ? TextDecoration.lineThrough
                                              : null,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                                if (item.modifiers.isNotEmpty)
                                  Container(
                                    margin: const EdgeInsets.only(top: 4.0),
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 8,
                                      vertical: 4,
                                    ),
                                    decoration: BoxDecoration(
                                      color: const Color(0xFFFACC15),
                                      borderRadius: BorderRadius.circular(4),
                                    ),
                                    child: Text(
                                      item.modifiers.join(', ').toUpperCase(),
                                      style: const TextStyle(
                                        color: Colors.black,
                                        fontWeight: FontWeight.w900,
                                        fontSize: 14,
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
              _buildFooter(displayItems, isDark),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildFooter(List<ClientItem> items, bool isDark) {
    final order = widget.order;
    final onFinished = widget.onFinished;
    final allBumped = items.every((i) => i.isBumped);

    return InkWell(
      onTap: () {
        HapticFeedback.heavyImpact();
        if (allBumped) {
          ref
              .read(clientServiceProvider)
              .send(
                jsonEncode({'type': 'TicketFinished', 'orderUuid': order.uuid}),
              );
          onFinished?.call();
          final finishedOrder = ref
              .read(clientStateProvider.notifier)
              .removeOrder(order.uuid);
          if (finishedOrder != null) {
            ref.read(recentBumpsProvider.notifier).add(finishedOrder);
          }
        } else {
          for (var item in items) {
            if (!item.isBumped) {
              ref
                  .read(clientServiceProvider)
                  .send(
                    jsonEncode({
                      'type': 'ItemBumped',
                      'orderUuid': order.uuid,
                      'itemUuid': item.uuid,
                      'isBumped': true,
                    }),
                  );
              ref
                  .read(clientStateProvider.notifier)
                  .toggleItemBump(order.uuid, item.uuid);
            }
          }
        }
      },
      child: Container(
        height: 50,
        color: allBumped
            ? const Color(0xFF22C55E)
            : (isDark ? const Color(0xFF374151) : Colors.grey.shade300),
        alignment: Alignment.center,
        child: Text(
          allBumped ? 'FINISH' : 'BUMP ALL',
          style: TextStyle(
            color: allBumped
                ? Colors.black
                : (isDark ? Colors.white : Colors.black87),
            fontWeight: FontWeight.w900,
            fontSize: 16,
            letterSpacing: 2,
          ),
        ),
      ),
    );
  }
}
