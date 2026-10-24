import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:uuid/uuid.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../data/host_store.dart';
import '../models/connected_client.dart';
import '../models/database.dart';

enum WebHostStatus { disconnected, connecting, connected, error }

/// Everything the host pushed in a single `HostSnapshot` message, decoded into
/// the same Drift data classes the native UI uses.
class HostSnapshotData {
  final String hostId;
  final String role;
  final List<KDSOrderData> orders;
  final List<KDSItemData> items;
  final Map<String, List<KDSItemData>> itemsByOrder;
  final List<MenuItemData> menu;
  final List<StationData> stations;
  final List<GlobalModifierData> modifiers;
  final List<ConnectedClient> clients;
  final List<ItemSalesStat> analytics;
  final List<Map<String, String>> hosts;

  HostSnapshotData({
    required this.hostId,
    required this.role,
    required this.orders,
    required this.items,
    required this.itemsByOrder,
    required this.menu,
    required this.stations,
    required this.modifiers,
    required this.clients,
    required this.analytics,
    required this.hosts,
  });

  factory HostSnapshotData.fromMap(Map<String, dynamic> m) {
    final orders = <KDSOrderData>[];
    final items = <KDSItemData>[];
    final byOrder = <String, List<KDSItemData>>{};

    for (final raw in (m['orders'] as List? ?? [])) {
      final o = raw is Map ? raw : const {};
      final order = orderFromMap(o);
      final orderItems = <KDSItemData>[];
      for (final rawItem in (o['items'] as List? ?? [])) {
        if (rawItem is! Map) continue;
        final item = orderItemFromMap({...rawItem, 'orderUuid': order.uuid});
        items.add(item);
        orderItems.add(item);
      }
      orders.add(order);
      byOrder[order.uuid] = orderItems;
    }

    return HostSnapshotData(
      hostId: m['host']?['hostId'] ?? '',
      role: m['host']?['role'] ?? 'primary',
      orders: orders,
      items: items,
      itemsByOrder: byOrder,
      menu: (m['menu'] as List? ?? [])
          .whereType<Map>()
          .map(menuItemFromMap)
          .toList(),
      stations: (m['stations'] as List? ?? [])
          .whereType<Map>()
          .map(stationFromMap)
          .toList(),
      modifiers: (m['modifiers'] as List? ?? [])
          .whereType<Map>()
          .map(globalModifierFromMap)
          .toList(),
      clients: (m['clients'] as List? ?? [])
          .whereType<Map>()
          .map(clientFromMap)
          .toList(),
      analytics: (m['analytics'] as List? ?? [])
          .whereType<Map>()
          .map(salesStatFromMap)
          .toList(),
      hosts: (m['hosts'] as List? ?? [])
          .whereType<Map>()
          .map((h) => h.map((k, v) => MapEntry(k.toString(), v.toString())))
          .toList(),
    );
  }
}

/// WebSocket bridge between the browser-hosted UI and the native host that
/// served it. Owns reconnection and caches the latest snapshot so subscribers
/// that attach late (or re-attach after a rebuild) always receive data.
class WebHostClient {
  WebSocketChannel? _channel;
  StreamSubscription? _streamSub;
  final _eventsController = StreamController<Map<String, dynamic>>.broadcast();
  final _statusController = StreamController<WebHostStatus>.broadcast();
  final _snapshotController = StreamController<HostSnapshotData>.broadcast();
  final _clientId = const Uuid().v4();
  String _hostUrl = '';
  int _hostPort = 8080;
  String _role = 'primary';
  WebHostStatus _status = WebHostStatus.disconnected;
  HostSnapshotData? _latest;
  Timer? _retryTimer;
  Timer? _heartbeatTimer;
  bool _disposed = false;
  int _attempt = 0;

  Stream<Map<String, dynamic>> get events => _eventsController.stream;

  /// Replays the current status to each new subscriber, then live updates.
  late final Stream<WebHostStatus> statusStream = Stream<WebHostStatus>.multi((
    controller,
  ) {
    controller.add(_status);
    final sub = _statusController.stream.listen(
      controller.add,
      onError: controller.addError,
      onDone: controller.close,
    );
    controller.onCancel = sub.cancel;
  });

  /// Snapshot feed that always starts a new subscriber off with the most
  /// recent snapshot before forwarding live ones.
  ///
  /// A `Stream.multi` callback runs per subscription, which is what makes this
  /// safe: a plain broadcast controller drops the event when it fires with no
  /// listener yet, and a single-subscription generator can only ever replay to
  /// its one subscriber. Both left the menu library spinning forever, because
  /// the first `HostSnapshot` usually lands before the first view subscribes.
  late final Stream<HostSnapshotData> snapshots =
      Stream<HostSnapshotData>.multi((controller) {
        final cached = _latest;
        if (cached != null) controller.add(cached);
        final sub = _snapshotController.stream.listen(
          controller.add,
          onError: controller.addError,
          onDone: controller.close,
        );
        controller.onCancel = sub.cancel;
      });

  HostSnapshotData? get latestSnapshot => _latest;

  /// Set when a frame arrived but could not be applied. Surfaced by the shell
  /// so a stalled view can explain itself instead of spinning forever.
  String? get lastFrameError => _lastFrameError;
  String? _lastFrameError;

  WebHostStatus get status => _status;

  bool get isConnected => _status == WebHostStatus.connected;

  void _setStatus(WebHostStatus value) {
    if (_status == value || _disposed) return;
    _status = value;
    if (!_statusController.isClosed) _statusController.add(value);
  }

  Future<void> connect({String? host, int? port, String? role}) async {
    if (role != null) _role = role;
    await _open(host ?? Uri.base.host, port ?? _defaultPort);
  }

  /// Port the page was served from. The host is the thing that served this
  /// document, so its port is the right default and survives a non-8080 setup.
  int get _defaultPort => Uri.base.hasPort ? Uri.base.port : 8080;

  /// How long to wait for the WebSocket handshake before giving up.
  static const Duration _connectTimeout = Duration(seconds: 8);

  /// Re-entrancy guard, matching `ClientService._open`.
  bool _connecting = false;

  Future<void> _open(String host, int port) async {
    // The RETRY button calls `connect()` directly, so it can fire while a
    // scheduled reconnect is already in flight. Without this guard both runs
    // reach the `await` below, and whichever finishes second overwrites
    // `_channel`/`_streamSub` — orphaning the loser's socket (never closed) and
    // its subscription (never cancelled, so it keeps delivering frames from a
    // dead socket).
    if (_connecting || isConnected) return;
    _connecting = true;
    try {
      await _openInner(host, port);
    } finally {
      _connecting = false;
    }
  }

  Future<void> _openInner(String host, int port) async {
    _hostUrl = host;
    _hostPort = port;
    _setStatus(WebHostStatus.connecting);

    // Drop any previous link first. Reconnecting without this orphaned the old
    // stream subscription, which kept delivering frames from a dead socket.
    // The sink is closed as well as the subscription cancelled — the retry loop
    // runs every few seconds, so a host that is down would otherwise leak one
    // socket descriptor per attempt and eventually exhaust them.
    await _streamSub?.cancel();
    _streamSub = null;
    _heartbeatTimer?.cancel();
    await _channel?.sink.close().catchError((_) {});
    _channel = null;

    final scheme = Uri.base.scheme == 'https' ? 'wss' : 'ws';
    final wsUrl = Uri(scheme: scheme, host: host, port: port, path: '/ws');

    WebSocketChannel? channel;
    try {
      channel = WebSocketChannel.connect(wsUrl);
      _channel = channel;
      // Bounded, unlike the bare `await channel.ready` this replaces. A host
      // that accepts the TCP connection but never finishes the handshake used
      // to hang here forever: the retry was never scheduled and the shell sat
      // on "Connecting to host..." permanently. `ClientService._open` already
      // applies the same timeout.
      await channel.ready.timeout(_connectTimeout);

      _streamSub = channel.stream.listen(
        _onMessage,
        onError: (_) {
          _setStatus(WebHostStatus.error);
          _scheduleReconnect();
        },
        onDone: () {
          _setStatus(WebHostStatus.disconnected);
          _scheduleReconnect();
        },
        cancelOnError: true,
      );

      _heartbeatTimer?.cancel();
      _heartbeatTimer = Timer.periodic(const Duration(seconds: 20), (_) {
        send({'type': 'ping'});
      });

      _attempt = 0;
      send({
        'type': 'RegisterWebHost',
        'id': _clientId,
        'deviceName': 'Web Host',
        'role': _role,
      });
      // The host pushes a snapshot on registration, but ask explicitly in case
      // that registration raced the listener attaching.
      requestSnapshot();
    } catch (_) {
      // Close the half-open socket before giving up, for the same descriptor
      // reason as above, then clear `_channel` so a later `_open` does not try
      // to reuse a dead one.
      await channel?.sink.close().catchError((_) {});
      if (identical(_channel, channel)) _channel = null;
      _setStatus(WebHostStatus.error);
      _scheduleReconnect();
      rethrow;
    }
  }

  void _onMessage(dynamic message) => handleFrame(message.toString());

  /// Decodes one inbound frame. Public so the snapshot pipeline can be tested
  /// without a live socket.
  @visibleForTesting
  void handleFrame(String raw) {
    Map<String, dynamic>? event;
    try {
      final data = jsonDecode(raw);
      if (data is! Map) return;
      event = data.cast<String, dynamic>();
    } catch (_) {
      return; // Not JSON at all; nothing useful to do.
    }

    switch (event['type']) {
      case 'WebHostReady':
        _setStatus(WebHostStatus.connected);
        break;

      case 'HostSnapshot':
        try {
          final snapshot = HostSnapshotData.fromMap(event);
          _latest = snapshot;
          _lastFrameError = null;
          if (!_snapshotController.isClosed) _snapshotController.add(snapshot);
        } catch (e) {
          // Surface this instead of dropping the frame: a silently discarded
          // snapshot leaves every view spinning with no explanation.
          _lastFrameError = 'Malformed host snapshot: $e';
        }
        break;

      case 'DataChanged':
        // The host signals that its database moved on. Pull a fresh snapshot so
        // menu/station/modifier edits made elsewhere show up here.
        if (isConnected) requestSnapshot();
        break;

      case 'SnapshotError':
        _lastFrameError =
            'Host could not build a snapshot: ${event['message']}';
        break;
    }

    if (!_eventsController.isClosed) _eventsController.add(event);
  }

  void _scheduleReconnect() {
    if (_disposed || _retryTimer != null) return;
    _attempt++;
    final delay = Duration(milliseconds: (500 * _attempt).clamp(500, 5000));
    _retryTimer = Timer(delay, () async {
      _retryTimer = null;
      if (_disposed) return;
      try {
        await _open(_hostUrl.isEmpty ? Uri.base.host : _hostUrl, _hostPort);
      } catch (_) {
        _scheduleReconnect();
      }
    });
  }

  void requestSnapshot() => send({'type': 'RequestSnapshot'});

  /// Test seam: intercepts outbound frames so frame handling can be asserted
  /// without a live socket.
  @visibleForTesting
  void Function(Map<String, dynamic>)? debugSendOverride;

  void send(dynamic message) {
    if (message is Map<String, dynamic>) debugSendOverride?.call(message);
    try {
      _channel?.sink.add(jsonEncode(message));
    } catch (_) {}
  }

  // ── Commands ──────────────────────────────────────────────────

  void submitOrder({
    required String orderUuid,
    required String customerName,
    required List<Map<String, dynamic>> lines,
    required bool isEditing,
  }) {
    send({
      'type': 'SubmitOrder',
      'orderUuid': orderUuid,
      'customerName': customerName,
      'items': lines,
      'isEditing': isEditing,
    });
  }

  void deleteOrder(String orderUuid) =>
      send({'type': 'DeleteOrder', 'orderUuid': orderUuid});

  void recallOrder(String orderUuid) =>
      send({'type': 'RecallOrder', 'orderUuid': orderUuid});

  void clearSalesAndHistory() => send({'type': 'ClearSalesAndHistory'});

  void saveMenuItem(Map<String, dynamic> draft) =>
      send({'type': 'SaveMenuItem', 'draft': draft});

  void deleteMenuItem(int id) => send({'type': 'DeleteMenuItem', 'id': id});

  void setStock(int id, int quantity) =>
      send({'type': 'SetStock', 'id': id, 'quantity': quantity});

  void saveStation({int? id, required String name}) =>
      send({'type': 'SaveStationItem', 'id': id, 'name': name});

  void deleteStation(int id) => send({'type': 'DeleteStationItem', 'id': id});

  void saveGlobalModifier({int? id, required String name}) =>
      send({'type': 'SaveGlobalModifierItem', 'id': id, 'name': name});

  void deleteGlobalModifier(int id) =>
      send({'type': 'DeleteGlobalModifierItem', 'id': id});

  void importLibrary(Map<String, dynamic> data) =>
      send({'type': 'ImportLibrary', 'data': data});

  void clearLibrary() => send({'type': 'ClearLibrary'});

  void saveCombo({
    required String name,
    required double price,
    required String category,
    required String defaultStation,
    required List<int> componentItemIds,
    required List<int> componentQuantities,
  }) =>
      send({
        'type': 'SaveCombo',
        'name': name,
        'price': price,
        'category': category,
        'defaultStation': defaultStation,
        'componentItemIds': componentItemIds,
        'componentQuantities': componentQuantities,
      });

  void deleteCombo(int id) => send({'type': 'DeleteCombo', 'id': id});

  void broadcastMessage(String message, {String? station}) => send({
    'type': 'BroadcastMessage',
    'message': message,
    if (station != null && station.isNotEmpty) 'station': station,
  });

  void setRushMode(bool enabled) =>
      send({'type': 'SetRushMode', 'enabled': enabled});

  void sendToClient(String clientId, Map<String, dynamic> message) => send({
    ...message,
    'type': message['type'] ?? 'DirectMessage',
    'targetClientId': clientId,
  });

  // ── Lifecycle ─────────────────────────────────────────────────

  Future<void> disconnect() async {
    _retryTimer?.cancel();
    _retryTimer = null;
    _heartbeatTimer?.cancel();
    await _streamSub?.cancel();
    _streamSub = null;
    try {
      await _channel?.sink.close();
    } catch (_) {}
    _channel = null;
    _setStatus(WebHostStatus.disconnected);
  }

  void dispose() {
    _disposed = true;
    _retryTimer?.cancel();
    _heartbeatTimer?.cancel();
    _streamSub?.cancel();
    _channel?.sink.close();
    _eventsController.close();
    _statusController.close();
    _snapshotController.close();
  }
}
