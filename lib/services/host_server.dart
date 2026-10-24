import 'dart:async';
import 'dart:convert';
import 'dart:io' if (dart.library.js_interop) '../web_io_stub.dart';
import 'dart:typed_data';
import 'package:flutter/services.dart' show rootBundle;
import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart'
    if (dart.library.js_interop) '../web_shelf_io_stub.dart'
    as io;
import 'package:shelf_router/shelf_router.dart';
import 'package:shelf_web_socket/shelf_web_socket.dart'
    if (dart.library.js_interop) '../web_shelf_ws_stub.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:uuid/uuid.dart';
import 'package:drift/drift.dart' as drift;
import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;
import '../models/database.dart';
import '../models/connected_client.dart';
import '../models/order_status.dart';
import '../models/item_status.dart';
import '../data/host_store.dart' show MenuItemDraft, OrderLine;
import '../data/order_ops.dart';
import 'sync_engine.dart';

const _webUiDirOverride = String.fromEnvironment('WEB_UI_DIR');

const _webMimeTypes = <String, String>{
  '.html': 'text/html',
  '.htm': 'text/html',
  '.js': 'text/javascript',
  '.mjs': 'text/javascript',
  '.css': 'text/css',
  '.json': 'application/json',
  '.wasm': 'application/wasm',
  '.png': 'image/png',
  '.ico': 'image/x-icon',
  '.svg': 'image/svg+xml',
  '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg',
  '.gif': 'image/gif',
  '.webp': 'image/webp',
  '.mp3': 'audio/mpeg',
  '.wav': 'audio/wav',
  '.ogg': 'audio/ogg',
  '.ttf': 'font/ttf',
  '.otf': 'font/otf',
  '.woff': 'font/woff',
  '.woff2': 'font/woff2',
  '.pdf': 'application/pdf',
  '.txt': 'text/plain',
  '.map': 'application/json',
  '.frag': 'text/plain',
  '.vert': 'text/plain',
  '.bin': 'application/octet-stream',
  '.symbols': 'application/octet-stream',
};

const _webUiMissingHtml = '''
<!DOCTYPE html>
<html>
<head><meta charset="utf-8"><title>DartKDS Web UI</title></head>
<body style="background:#0f172a;color:#e2e8f0;font-family:sans-serif;display:flex;align-items:center;justify-content:center;height:100vh;margin:0">
<div style="text-align:center;max-width:560px">
  <h2 style="margin:0 0 12px">Web UI not found</h2>
  <p style="font-size:14px;line-height:1.5">The Flutter web build is not available on this host.\nRun <code style="background:#1e293b;padding:2px 8px;border-radius:4px">flutter build web</code> in the project directory and restart the host to serve it from <code style="background:#1e293b;padding:2px 8px;border-radius:4px">build/web</code>.</p>
</div>
</body>
</html>
''';

class HostServer {
  final Map<String, WebSocketChannel> _clientChannels = {};
  final Map<String, WebSocketChannel> _webHostChannels = {};

  /// When each registered client was last heard from. A half-open socket looks
  /// alive to `_clients` forever otherwise: the kitchen believes a tablet is
  /// still on the line, station routing keeps sending to a dead sink, and the
  /// display never receives the re-registration that would have fixed it.
  final Map<String, DateTime> _clientLastSeen = {};

  /// How often the roster is swept for clients that stopped answering.
  static const Duration _silentSweepInterval = Duration(seconds: 20);

  /// How long a client may go without sending anything before it is evicted.
  /// Clients answer the host's ping, so this is roughly three missed rounds —
  /// generous enough to survive a tablet waking from sleep, tight enough that a
  /// genuinely dead display leaves the roster well before service.
  static const Duration _clientSilenceLimit = Duration(seconds: 75);

  final List<ConnectedClient> _clients = [];
  final List<StreamSubscription> _dbWatchers = [];
  Timer? _webHostNotifyDebounce;
  HttpServer? _server;
  KDSDatabase? _db;

  /// What was actually bound, as opposed to what was requested. Everything that
  /// advertises this host to a display must read [port].
  int _boundPort = 0;
  String hostId = '';
  String role = 'primary';
  Timer? _heartbeatTimer;
  Timer? _suspectTimer;

  // Provides the list of known sync peers ({hostId, role, url}) so the web
  // UI can discover failover targets. Set after SyncService starts.
  List<Map<String, String>> Function()? knownPeersProvider;

  // Directory containing the compiled Flutter web build to serve at `/`.
  // Defaults to `<project>/build/web`, overridable via the WEB_UI_DIR
  // dart-define. When null/absent, a helper page is shown instead.
  String? webUiDir;

  /// Notifies UI of client changes.
  ///
  /// A set rather than a single `Function?` slot: there are two independent
  /// subscribers (the `connectedClientsProvider` stream and
  /// `DriftHostStore.watchClients`), and they used to share one field by
  /// chaining. Chaining breaks as soon as the *older* listener unsubscribes
  /// first — restoring its captured `previous` silently discards the newer
  /// listener's wrapper, which then stops receiving updates with no error
  /// anywhere. Register and unregister symmetrically instead.
  final Set<void Function()> _clientListeners = <void Function()>{};

  bool addClientListener(void Function() listener) =>
      _clientListeners.add(listener);

  void removeClientListener(void Function() listener) =>
      _clientListeners.remove(listener);

  void notifyClientsChanged() {
    // Copied first: a listener may unsubscribe during the call.
    for (final listener in List<void Function()>.of(_clientListeners)) {
      listener();
    }
  }

  List<ConnectedClient> get connectedClients => List.unmodifiable(_clients);

  bool get isRunning => _server != null;

  /// The port actually bound, or 0 when not running.
  ///
  /// Requesting port 0 asks the OS for any free port, so callers building a URL
  /// from it need this rather than the requested value. Everything the app
  /// displays to a user goes through here: with the requested port echoed back,
  /// a host on an ephemeral port would advertise `http://<ip>:0` and every
  /// display pointed at it would fail to connect.
  int get port => _boundPort;

  /// Ranks a LAN address for display, preferring the subnet a kitchen display
  /// is most likely to reach.
  ///
  /// Exposed so the settings screen can show the same address the host
  /// advertises. The two used to be separate copies that could drift apart, and
  /// the screen's copy ranked every `172.` address above a real private range.
  static int rankLanAddress(String ip) => _lanAddressRank(ip);

  Future<void>? _startFuture;

  // Idempotent: safe to call multiple times (e.g. on app restart where the
  // persisted host role routes straight to HostHome). Returns early if the
  // server is already running or a start is already in flight.
  Future<void> start(KDSDatabase db, {int port = 8080}) {
    final pending = _startFuture;
    if (pending != null) return pending;
    if (_server != null) return Future.value();
    final task = _start(db, port: port);
    _startFuture = task;
    task.whenComplete(() {
      if (identical(_startFuture, task)) _startFuture = null;
    });
    return task;
  }

  Future<void> _start(KDSDatabase db, {int port = 8080}) async {
    _db = db;
    final router = Router();

    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      broadcast(
        jsonEncode({
          'type': 'ping',
          'timestamp': DateTime.now().toIso8601String(),
        }),
      );
    });

    _suspectTimer?.cancel();
    _suspectTimer = Timer.periodic(_silentSweepInterval, (_) {
      _evictSilentClients();
    });

    // API: Get Menu Items
    router.get('/api/menu', (Request request) async {
      final items = await _db!.select(_db!.menuItems).get();
      final data = items
          .map(
            (i) => {
              'id': i.id,
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
            },
          )
          .toList();
      return Response.ok(
        jsonEncode(data),
        headers: {'Content-Type': 'application/json'},
      );
    });

    // API: Create Menu Item
    router.post('/api/menu', (Request request) async {
      final db = _db!;
      final body = await _jsonBody(request);
      if (body == null) return Response.badRequest(body: 'Invalid JSON');
      final name = (body['name'] ?? '').toString().trim();
      if (name.isEmpty) return Response.badRequest(body: 'Name required');

      final nowMs = DateTime.now().millisecondsSinceEpoch;
      final station = await _fallbackStationName(
        (body['defaultStation'] ?? '').toString(),
      );
      final id = await db
          .into(db.menuItems)
          .insert(
            MenuItemsCompanion.insert(
              guid: drift.Value(const Uuid().v4()),
              name: name,
              category: (body['category'] ?? 'All Items').toString(),
              defaultStation: station,
              modifiers: _stringList(body['modifiers']),
              requiredModifiers: drift.Value(
                _stringList(body['requiredModifiers']),
              ),
              tags: drift.Value(_stringList(body['tags'])),
              price: drift.Value((body['price'] as num?)?.toDouble() ?? 0.0),
              stockQuantity: drift.Value(
                (body['stockQuantity'] as num?)?.toInt() ?? 0,
              ),
              trackStock: drift.Value(body['trackStock'] as bool? ?? false),
              oneTouch: drift.Value(body['oneTouch'] as bool? ?? false),
              updatedAtMs: drift.Value(nowMs),
            ),
          );
      return Response.ok(
        jsonEncode({'id': id}),
        headers: {'Content-Type': 'application/json'},
      );
    });

    // API: Update Menu Item
    router.put('/api/menu/<id>', (Request request, String id) async {
      final db = _db!;
      final menuId = int.tryParse(id);
      if (menuId == null) return Response.notFound('Not found');
      final body = await _jsonBody(request);
      if (body == null) return Response.badRequest(body: 'Invalid JSON');
      final existing = await (db.select(
        db.menuItems,
      )..where((t) => t.id.equals(menuId))).getSingleOrNull();
      if (existing == null) return Response.notFound('Not found');

      final name = body['name'] != null
          ? (body['name'] as String).trim()
          : existing.name;
      if (name.isEmpty) return Response.badRequest(body: 'Name required');

      await (db.update(db.menuItems)..where((t) => t.id.equals(menuId))).write(
        MenuItemsCompanion(
          name: drift.Value(name),
          category: drift.Value(
            body['category'] != null
                ? (body['category'] as String)
                : existing.category,
          ),
          defaultStation: drift.Value(
            body['defaultStation'] != null
                ? (body['defaultStation'] as String)
                : existing.defaultStation,
          ),
          modifiers: drift.Value(
            body['modifiers'] != null
                ? _stringList(body['modifiers'])
                : existing.modifiers,
          ),
          requiredModifiers: drift.Value(
            body['requiredModifiers'] != null
                ? _stringList(body['requiredModifiers'])
                : existing.requiredModifiers,
          ),
          tags: drift.Value(
            body['tags'] != null ? _stringList(body['tags']) : existing.tags,
          ),
          price: drift.Value(
            body['price'] != null
                ? (body['price'] as num).toDouble()
                : existing.price,
          ),
          stockQuantity: drift.Value(
            body['stockQuantity'] != null
                ? (body['stockQuantity'] as num).toInt()
                : existing.stockQuantity,
          ),
          trackStock: drift.Value(
            body['trackStock'] != null
                ? (body['trackStock'] as bool)
                : existing.trackStock,
          ),
          oneTouch: drift.Value(
            body['oneTouch'] != null
                ? (body['oneTouch'] as bool)
                : existing.oneTouch,
          ),
          updatedAtMs: drift.Value(DateTime.now().millisecondsSinceEpoch),
        ),
      );
      return Response.ok(
        jsonEncode({'id': menuId}),
        headers: {'Content-Type': 'application/json'},
      );
    });

    // API: Delete Menu Item
    router.delete('/api/menu/<id>', (Request request, String id) async {
      final menuId = int.tryParse(id);
      if (menuId == null) return Response.notFound('Not found');
      await (_db!.delete(
        _db!.menuItems,
      )..where((t) => t.id.equals(menuId))).go();
      return Response.ok('{}', headers: {'Content-Type': 'application/json'});
    });

    // API: Set Stock Quantity
    router.post('/api/menu/<id>/stock', (Request request, String id) async {
      final db = _db!;
      final menuId = int.tryParse(id);
      if (menuId == null) return Response.notFound('Not found');
      final body = await _jsonBody(request);
      final existing = await (db.select(
        db.menuItems,
      )..where((t) => t.id.equals(menuId))).getSingleOrNull();
      if (existing == null) return Response.notFound('Not found');

      final raw = (body?['quantity'] as num?)?.toInt();
      final newQty = (raw == null || raw < 0) ? existing.stockQuantity : raw;
      await (db.update(db.menuItems)..where((t) => t.id.equals(menuId))).write(
        MenuItemsCompanion(
          stockQuantity: drift.Value(newQty),
          updatedAtMs: drift.Value(DateTime.now().millisecondsSinceEpoch),
        ),
      );
      return Response.ok(
        jsonEncode({'id': existing.id, 'stockQuantity': newQty}),
        headers: {'Content-Type': 'application/json'},
      );
    });

    // API: Get Stations
    router.get('/api/stations', (Request request) async {
      final stations = await _db!.select(_db!.stations).get();
      return Response.ok(
        jsonEncode(stations.map((s) => {'id': s.id, 'name': s.name}).toList()),
        headers: {'Content-Type': 'application/json'},
      );
    });

    // API: Create Station
    router.post('/api/stations', (Request request) async {
      final db = _db!;
      final body = await _jsonBody(request);
      final name = (body?['name'] ?? '').toString().trim();
      if (name.isEmpty) return Response.badRequest(body: 'Name required');
      final id = await db
          .into(db.stations)
          .insert(
            StationsCompanion.insert(
              name: name,
              updatedAtMs: drift.Value(DateTime.now().millisecondsSinceEpoch),
            ),
          );
      return Response.ok(
        jsonEncode({'id': id}),
        headers: {'Content-Type': 'application/json'},
      );
    });

    // API: Rename Station
    router.put('/api/stations/<id>', (Request request, String id) async {
      final db = _db!;
      final stationId = int.tryParse(id);
      if (stationId == null) return Response.notFound('Not found');
      final body = await _jsonBody(request);
      final name = (body?['name'] ?? '').toString().trim();
      if (name.isEmpty) return Response.badRequest(body: 'Name required');
      await (db.update(
        db.stations,
      )..where((t) => t.id.equals(stationId))).write(
        StationsCompanion(
          name: drift.Value(name),
          updatedAtMs: drift.Value(DateTime.now().millisecondsSinceEpoch),
        ),
      );
      return Response.ok('{}', headers: {'Content-Type': 'application/json'});
    });

    // API: Delete Station
    router.delete('/api/stations/<id>', (Request request, String id) async {
      final stationId = int.tryParse(id);
      if (stationId == null) return Response.notFound('Not found');
      await (_db!.delete(
        _db!.stations,
      )..where((t) => t.id.equals(stationId))).go();
      return Response.ok('{}', headers: {'Content-Type': 'application/json'});
    });

    // API: Get Global Modifiers
    router.get('/api/modifiers', (Request request) async {
      final modifiers = await _db!.select(_db!.globalModifiers).get();
      return Response.ok(
        jsonEncode(modifiers.map((m) => {'id': m.id, 'name': m.name}).toList()),
        headers: {'Content-Type': 'application/json'},
      );
    });

    // API: Create Global Modifier
    router.post('/api/modifiers', (Request request) async {
      final db = _db!;
      final body = await _jsonBody(request);
      final name = (body?['name'] ?? '').toString().trim();
      if (name.isEmpty) return Response.badRequest(body: 'Name required');
      final id = await db
          .into(db.globalModifiers)
          .insert(
            GlobalModifiersCompanion.insert(
              name: name,
              updatedAtMs: drift.Value(DateTime.now().millisecondsSinceEpoch),
            ),
          );
      return Response.ok(
        jsonEncode({'id': id}),
        headers: {'Content-Type': 'application/json'},
      );
    });

    // API: Delete Global Modifier
    router.delete('/api/modifiers/<id>', (Request request, String id) async {
      final modifierId = int.tryParse(id);
      if (modifierId == null) return Response.notFound('Not found');
      await (_db!.delete(
        _db!.globalModifiers,
      )..where((t) => t.id.equals(modifierId))).go();
      return Response.ok('{}', headers: {'Content-Type': 'application/json'});
    });

    // API: Get Orders with items
    router.get('/api/orders', (Request request) async {
      final db = _db!;
      final orders =
          await (db.select(db.kDSOrders)
                ..orderBy([(t) => drift.OrderingTerm.desc(t.timestamp)])
                ..limit(100))
              .get(); // Limit to recent 100 for web UI performance

      if (orders.isEmpty) {
        return Response.ok('[]', headers: {'Content-Type': 'application/json'});
      }

      final orderUuids = orders.map((o) => o.uuid).toList();
      final allItems = await (db.select(
        db.kDSItems,
      )..where((t) => t.orderUuid.isIn(orderUuids))).get();

      final itemsByOrder = <String, List<Map<String, dynamic>>>{};
      for (final i in allItems) {
        itemsByOrder.putIfAbsent(i.orderUuid, () => []).add({
          'uuid': i.uuid,
          'name': i.name,
          'modifiers': i.modifiers,
          'stationTag': i.stationTag,
          'status': i.status.index,
          'price': i.price,
        });
      }

      final result = orders
          .map(
            (order) => {
              'uuid': order.uuid,
              'customerName': order.customerName,
              'timestamp': order.timestamp.toIso8601String(),
              'status': order.status.index,
              'items': itemsByOrder[order.uuid] ?? [],
            },
          )
          .toList();

      return Response.ok(
        jsonEncode(result),
        headers: {'Content-Type': 'application/json'},
      );
    });

    // API: Get Connected Clients
    router.get('/api/clients', (Request request) async {
      final data = _clients
          .map(
            (c) => {
              'id': c.id,
              'deviceName': c.deviceName,
              'currentStation': c.currentStation,
              'connectedAt': c.connectedAt.toIso8601String(),
            },
          )
          .toList();
      return Response.ok(
        jsonEncode(data),
        headers: {'Content-Type': 'application/json'},
      );
    });

    // API: Known hosts (self + discovered sync peers) for web failover
    router.get('/api/hosts', (Request request) async {
      final selfUrl = await _selfHostUrl();
      final peers = knownPeersProvider?.call() ?? const <Map<String, String>>[];
      final hosts = <Map<String, String>>[
        {'hostId': hostId, 'role': role, 'url': selfUrl},
        ...peers,
      ];
      return Response.ok(
        jsonEncode({
          'self': {'hostId': hostId, 'role': role, 'url': selfUrl},
          'hosts': hosts,
        }),
        headers: {'Content-Type': 'application/json'},
      );
    });
    router.get('/api/library/export', (Request request) async {
      final db = _db!;
      final items = await db.select(db.menuItems).get();
      final stations = await db.select(db.stations).get();
      final modifiers = await db.select(db.globalModifiers).get();
      final data = {
        'version': 1,
        'menuItems': items
            .map(
              (i) => {
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
              },
            )
            .toList(),
        'stations': stations.map((s) => {'name': s.name}).toList(),
        'globalModifiers': modifiers.map((m) => {'name': m.name}).toList(),
      };
      return Response.ok(
        jsonEncode(data),
        headers: {
          'Content-Type': 'application/json',
          'Content-Disposition': 'attachment; filename="dartkds_backup.json"',
        },
      );
    });

    // API: Import Library Backup
    router.post('/api/library/import', (Request request) async {
      final db = _db!;
      final body = await _jsonBody(request);
      if (body == null) return Response.badRequest(body: 'Invalid JSON');
      try {
        await db.transaction(() async {
          final nowMs = DateTime.now().millisecondsSinceEpoch;
          for (final s in (body['stations'] as List? ?? [])) {
            await db
                .into(db.stations)
                .insertOnConflictUpdate(
                  StationsCompanion.insert(
                    name: s['name'].toString(),
                    updatedAtMs: drift.Value(nowMs),
                  ),
                );
          }
          for (final m in (body['globalModifiers'] as List? ?? [])) {
            await db
                .into(db.globalModifiers)
                .insertOnConflictUpdate(
                  GlobalModifiersCompanion.insert(
                    name: m['name'].toString(),
                    updatedAtMs: drift.Value(nowMs),
                  ),
                );
          }
          for (final i in (body['menuItems'] as List? ?? [])) {
            await db
                .into(db.menuItems)
                .insert(
                  MenuItemsCompanion.insert(
                    guid: drift.Value(const Uuid().v4()),
                    name: i['name'].toString(),
                    category: (i['category'] ?? 'All Items').toString(),
                    defaultStation: await _fallbackStationName(
                      (i['defaultStation'] ?? '').toString(),
                    ),
                    modifiers: _stringList(i['modifiers']),
                    requiredModifiers: drift.Value(
                      _stringList(i['requiredModifiers']),
                    ),
                    tags: drift.Value(_stringList(i['tags'])),
                    price: drift.Value((i['price'] as num?)?.toDouble() ?? 0.0),
                    stockQuantity: drift.Value(
                      (i['stockQuantity'] as num?)?.toInt() ?? 0,
                    ),
                    trackStock: drift.Value(i['trackStock'] as bool? ?? false),
                    oneTouch: drift.Value(i['oneTouch'] as bool? ?? false),
                    updatedAtMs: drift.Value(nowMs),
                  ),
                );
          }
        });
        return Response.ok(
          jsonEncode({'success': true}),
          headers: {'Content-Type': 'application/json'},
        );
      } catch (e) {
        return Response.internalServerError(body: 'Import failed: $e');
      }
    });

    // ── Sync Endpoints ────────────────────────────────────────

    router.get('/api/sync/changes', (Request request) async {
      final sinceStr = request.url.queryParameters['since'];
      final sinceMs = int.tryParse(sinceStr ?? '') ?? 0;
      final engine = SyncEngine(_db!);
      final payload = await engine.getChanges(sinceMs);
      return Response.ok(
        payload,
        headers: {'Content-Type': 'application/json'},
      );
    });

    router.post('/api/sync/apply', (Request request) async {
      final body = await request.readAsString();
      if (body.isEmpty) return Response.badRequest(body: 'Empty body');
      final engine = SyncEngine(_db!);
      await engine.applyChanges(body);
      return Response.ok(
        jsonEncode({'success': true}),
        headers: {'Content-Type': 'application/json'},
      );
    });

    router.post('/api/sync/reset', (Request request) async {
      final engine = SyncEngine(_db!);
      final snapshot = await engine.getSnapshot();
      return Response.ok(
        snapshot,
        headers: {'Content-Type': 'application/json'},
      );
    });

    router.get(
      '/ws',
      webSocketHandler((WebSocketChannel webSocket) {
        String? clientId;
        bool isWebHost = false;

        webSocket.stream.listen(
          (message) async {
            try {
              final data = jsonDecode(message.toString());
              _noteClientActivity(clientId);

              if (data['type'] == 'RegisterClient') {
                clientId = data['id'];
                // A client reconnecting under the same id replaces its old
                // socket. Closing the previous one stops a zombie channel from
                // lingering in the roster after the display has moved on.
                final previous = _clientChannels[clientId!];
                _clientChannels[clientId!] = webSocket;
                if (!identical(previous, webSocket)) {
                  previous?.sink.close();
                }
                // Nothing else to do with the old socket: its teardown is now a
                // no-op because it is no longer the registered channel.
                _clientLastSeen[clientId!] = DateTime.now();

                _clients.removeWhere((c) => c.id == clientId);
                _clients.add(
                  ConnectedClient(
                    id: clientId!,
                    deviceName: data['deviceName'] ?? 'Unknown Device',
                    currentStation: data['station'] ?? 'GENERAL',
                    connectedAt: DateTime.now(),
                  ),
                );

                notifyClientsChanged();
                _notifyWebHostDebounced();

                // Send active (non-complete) orders to the new client
                final allOrders = await (_db!.select(_db!.kDSOrders).get());
                final orders = allOrders
                    .where((o) => o.status != OrderStatus.complete)
                    .toList();
                for (final order in orders) {
                  final items = await (_db!.select(
                    _db!.kDSItems,
                  )..where((t) => t.orderUuid.equals(order.uuid))).get();
                  final payload = jsonEncode({
                    'type': 'OrderCreated',
                    'order': {
                      'uuid': order.uuid,
                      'customerName': order.customerName,
                      'timestamp': order.timestamp.toIso8601String(),
                      'status': order.status.index,
                      'items': items
                          .map(
                            (i) => {
                              'uuid': i.uuid,
                              'name': i.name,
                              'modifiers': i.modifiers,
                              'stationTag': i.stationTag,
                              'status': i.status.index,
                              'price': i.price,
                            },
                          )
                          .toList(),
                    },
                  });
                  webSocket.sink.add(payload);
                }

                // Replay recent finished orders into the client's bumps list
                final finishedOrders =
                    allOrders
                        .where((o) => o.status == OrderStatus.complete)
                        .toList()
                      ..sort((a, b) => b.timestamp.compareTo(a.timestamp));
                if (finishedOrders.length > 20) {
                  finishedOrders.removeRange(20, finishedOrders.length);
                }
                if (finishedOrders.isNotEmpty) {
                  final allFinishedItems =
                      await (_db!.select(_db!.kDSItems)..where(
                            (t) => t.orderUuid.isIn(
                              finishedOrders.map((o) => o.uuid).toList(),
                            ),
                          ))
                          .get();
                  _broadcastFinishedOrders(finishedOrders, allFinishedItems);
                }
              } else if (data['type'] == 'RegisterWebHost') {
                isWebHost = true;
                clientId = data['id'];
                _webHostChannels[clientId!] = webSocket;
                webSocket.sink.add(
                  jsonEncode({
                    'type': 'WebHostReady',
                    'hostId': hostId,
                    'role': role,
                  }),
                );
                _sendSnapshot(webSocket);
              } else if (data['type'] == 'CreateOrder') {
                final orderData = data['order'];
                final orderUuid = const Uuid().v4();
                final timestamp = DateTime.now();

                await _db!
                    .into(_db!.kDSOrders)
                    .insert(
                      KDSOrderData(
                        uuid: orderUuid,
                        customerName: orderData['customerName'] ?? 'Guest',
                        timestamp: timestamp,
                        status: OrderStatus.pending,
                        updatedAtMs: DateTime.now().millisecondsSinceEpoch,
                      ),
                    );

                final List<Map<String, dynamic>> jsonItems = [];
                for (final item in orderData['items']) {
                  final itemUuid = const Uuid().v4();

                  // Find menu item to handle stock
                  final menuMatches = await (_db!.select(
                    _db!.menuItems,
                  )..where((t) => t.name.equals(item['name']))).get();
                  if (menuMatches.isNotEmpty && menuMatches.first.trackStock) {
                    await (_db!.update(
                      _db!.menuItems,
                    )..where((t) => t.id.equals(menuMatches.first.id))).write(
                      MenuItemsCompanion(
                        stockQuantity: drift.Value(
                          menuMatches.first.stockQuantity - 1,
                        ),
                        updatedAtMs: drift.Value(
                          DateTime.now().millisecondsSinceEpoch,
                        ),
                      ),
                    );
                  }

                  await _db!
                      .into(_db!.kDSItems)
                      .insert(
                        KDSItemsCompanion.insert(
                          uuid: itemUuid,
                          orderUuid: orderUuid,
                          name: item['name']?.toString() ?? 'Item',
                          modifiers: List<String>.from(
                            item['modifiers'] as List? ?? [],
                          ),
                          stationTag:
                              item['stationTag']?.toString() ?? 'GENERAL',
                          status: ItemStatus.pending,
                          price: drift.Value(
                            (item['price'] as num?)?.toDouble() ??
                                double.tryParse(
                                  item['price']?.toString() ?? '',
                                ) ??
                                0.0,
                          ),
                          updatedAtMs: drift.Value(
                            DateTime.now().millisecondsSinceEpoch,
                          ),
                        ),
                      );

                  jsonItems.add({
                    'uuid': itemUuid,
                    'name': item['name'],
                    'modifiers': item['modifiers'],
                    'stationTag': item['stationTag'],
                    'status': ItemStatus.pending.index,
                    'price': item['price'],
                  });
                }

                final broadcastPayload = jsonEncode({
                  'type': 'OrderCreated',
                  'order': {
                    'uuid': orderUuid,
                    'customerName': orderData['customerName'] ?? 'Guest',
                    'timestamp': timestamp.toIso8601String(),
                    'status': OrderStatus.pending.index,
                    'items': jsonItems,
                  },
                });
                broadcast(broadcastPayload);
              } else if (data['type'] == 'SubmitOrder') {
                final order = await submitOrderToDatabase(
                  db: _db!,
                  orderUuid: (data['orderUuid'] ?? const Uuid().v4())
                      .toString(),
                  customerName: (data['customerName'] ?? 'Guest').toString(),
                  lines: (data['items'] as List? ?? [])
                      .whereType<Map>()
                      .map(
                        (i) => OrderLine(
                          menuItemId: (i['menuItemId'] as num?)?.toInt() ?? -1,
                          name: (i['name'] ?? '').toString(),
                          modifiers: _stringList(i['modifiers']),
                          stationTag: (i['stationTag'] ?? 'GENERAL').toString(),
                          quantity: (i['quantity'] as num?)?.toInt() ?? 1,
                          price: (i['price'] as num?)?.toDouble() ?? 0.0,
                        ),
                      )
                      .toList(),
                  isEditing: data['isEditing'] == true,
                );
                final orderUuid = order['uuid'];
                broadcast(
                  jsonEncode({
                    'type': data['isEditing'] == true
                        ? 'OrderUpdated'
                        : 'OrderCreated',
                    'orderUuid': orderUuid,
                    'order': order,
                  }),
                );
              } else if (data['type'] == 'ItemBumped') {
                final itemUuid = data['itemUuid'] as String?;
                final isBumped = data['isBumped'] == true;
                if (itemUuid != null) {
                  final now = DateTime.now().millisecondsSinceEpoch;
                  await (_db!.update(
                    _db!.kDSItems,
                  )..where((t) => t.uuid.equals(itemUuid))).write(
                    KDSItemsCompanion(
                      status: drift.Value(
                        isBumped ? ItemStatus.bumped : ItemStatus.pending,
                      ),
                      updatedAtMs: drift.Value(now),
                    ),
                  );
                }
                broadcast(message);
              } else if (data['type'] == 'TicketFinished') {
                final orderUuid = data['orderUuid'] as String?;
                if (orderUuid != null) {
                  final now = DateTime.now().millisecondsSinceEpoch;
                  // Mark all items as bumped
                  await (_db!.update(
                    _db!.kDSItems,
                  )..where((t) => t.orderUuid.equals(orderUuid))).write(
                    KDSItemsCompanion(
                      status: drift.Value(ItemStatus.bumped),
                      updatedAtMs: drift.Value(now),
                    ),
                  );
                  // Mark order as complete
                  await (_db!.update(
                    _db!.kDSOrders,
                  )..where((t) => t.uuid.equals(orderUuid))).write(
                    KDSOrdersCompanion(
                      status: drift.Value(OrderStatus.complete),
                      updatedAtMs: drift.Value(now),
                    ),
                  );
                }
                broadcast(message);
              } else if (data['type'] == 'UpdateOrder') {
                final orderData = data['order'] as Map<String, dynamic>;
                final orderUuid = orderData['uuid'] as String;
                final now = DateTime.now().millisecondsSinceEpoch;

                await (_db!.update(
                  _db!.kDSOrders,
                )..where((t) => t.uuid.equals(orderUuid))).write(
                  KDSOrdersCompanion(
                    customerName: drift.Value(
                      (orderData['customerName'] ?? 'Guest').toString(),
                    ),
                    updatedAtMs: drift.Value(now),
                  ),
                );
                // Replace items
                await (_db!.delete(
                  _db!.kDSItems,
                )..where((t) => t.orderUuid.equals(orderUuid))).go();
                for (final item in orderData['items'] as List) {
                  final itemUuid = (item['uuid'] as String?)?.isNotEmpty == true
                      ? item['uuid'] as String
                      : const Uuid().v4();
                  await _db!
                      .into(_db!.kDSItems)
                      .insert(
                        KDSItemsCompanion.insert(
                          uuid: itemUuid,
                          orderUuid: orderUuid,
                          name: item['name'] as String,
                          modifiers: List<String>.from(item['modifiers'] ?? []),
                          stationTag: (item['stationTag'] ?? 'GENERAL')
                              .toString(),
                          status: ItemStatus.pending,
                          price: drift.Value(
                            (item['price'] as num?)?.toDouble() ?? 0.0,
                          ),
                          updatedAtMs: drift.Value(now),
                        ),
                      );
                }
                broadcast(
                  jsonEncode({
                    'type': 'OrderUpdated',
                    'order': {
                      'uuid': orderUuid,
                      'customerName': orderData['customerName'] ?? 'Guest',
                      'timestamp': DateTime.now().toIso8601String(),
                      'status': OrderStatus.pending.index,
                      'items': (orderData['items'] as List)
                          .map(
                            (i) => {
                              'uuid': i['uuid'],
                              'name': i['name'],
                              'modifiers': List<String>.from(
                                i['modifiers'] ?? [],
                              ),
                              'stationTag': i['stationTag'] ?? 'GENERAL',
                              'status': ItemStatus.pending.index,
                              'price': i['price'] ?? 0,
                            },
                          )
                          .toList(),
                    },
                  }),
                );
              } else if (data['type'] == 'DeleteOrder') {
                final orderUuid = data['orderUuid'] as String?;
                if (orderUuid != null) {
                  await (_db!.delete(
                    _db!.kDSItems,
                  )..where((t) => t.orderUuid.equals(orderUuid))).go();
                  await (_db!.delete(
                    _db!.kDSOrders,
                  )..where((t) => t.uuid.equals(orderUuid))).go();
                }
                broadcast(
                  jsonEncode({'type': 'OrderDeleted', 'orderUuid': orderUuid}),
                );
              } else if (data['type'] == 'ClearSalesAndHistory') {
                await _db!.delete(_db!.kDSItems).go();
                await _db!.delete(_db!.kDSOrders).go();
                broadcast(jsonEncode({'type': 'OrderHistoryCleared'}));
                _notifyWebHostDebounced();
              } else if (data['type'] == 'RecallOrder') {
                final orderUuid = data['orderUuid'] as String?;
                if (orderUuid != null) {
                  final now = DateTime.now().millisecondsSinceEpoch;
                  await (_db!.update(
                    _db!.kDSOrders,
                  )..where((t) => t.uuid.equals(orderUuid))).write(
                    KDSOrdersCompanion(
                      status: drift.Value(OrderStatus.pending),
                      updatedAtMs: drift.Value(now),
                    ),
                  );
                  await (_db!.update(
                    _db!.kDSItems,
                  )..where((t) => t.orderUuid.equals(orderUuid))).write(
                    KDSItemsCompanion(
                      status: drift.Value(ItemStatus.pending),
                      updatedAtMs: drift.Value(now),
                    ),
                  );
                  // Broadcast the order back as fresh for clients
                  final order = await (_db!.select(
                    _db!.kDSOrders,
                  )..where((t) => t.uuid.equals(orderUuid))).getSingleOrNull();
                  if (order != null) {
                    final items = await (_db!.select(
                      _db!.kDSItems,
                    )..where((t) => t.orderUuid.equals(orderUuid))).get();
                    broadcast(
                      jsonEncode({
                        'type': 'OrderCreated',
                        'order': {
                          'uuid': order.uuid,
                          'customerName': order.customerName,
                          'timestamp': order.timestamp.toIso8601String(),
                          'status': OrderStatus.pending.index,
                          'items': items
                              .map(
                                (i) => {
                                  'uuid': i.uuid,
                                  'name': i.name,
                                  'modifiers': i.modifiers,
                                  'stationTag': i.stationTag,
                                  'status': ItemStatus.pending.index,
                                  'price': i.price,
                                },
                              )
                              .toList(),
                        },
                      }),
                    );
                  }
                }
              } else if (data['type'] == 'SetStock') {
                final menuId = (data['id'] as num?)?.toInt();
                final quantity = (data['quantity'] as num?)?.toInt();
                if (menuId != null && quantity != null) {
                  await (_db!.update(
                    _db!.menuItems,
                  )..where((t) => t.id.equals(menuId))).write(
                    MenuItemsCompanion(
                      stockQuantity: drift.Value(quantity),
                      updatedAtMs: drift.Value(
                        DateTime.now().millisecondsSinceEpoch,
                      ),
                    ),
                  );
                }
              } else if (data['type'] == 'SaveMenu' ||
                  data['type'] == 'SaveMenuItem') {
                final menu = data['type'] == 'SaveMenuItem'
                    ? (data['draft'] as Map).cast<String, dynamic>()
                    : data['menu'] as Map<String, dynamic>;
                final menuId = (menu['id'] as num?)?.toInt();
                final now = DateTime.now().millisecondsSinceEpoch;
                if (menuId != null) {
                  await (_db!.update(
                    _db!.menuItems,
                  )..where((t) => t.id.equals(menuId))).write(
                    MenuItemsCompanion(
                      name: drift.Value(menu['name'] as String),
                      category: drift.Value(
                        (menu['category'] ?? 'All Items').toString(),
                      ),
                      defaultStation: drift.Value(
                        (menu['defaultStation'] ?? 'Main Station').toString(),
                      ),
                      modifiers: drift.Value(_stringList(menu['modifiers'])),
                      requiredModifiers: drift.Value(
                        _stringList(menu['requiredModifiers']),
                      ),
                      tags: drift.Value(_stringList(menu['tags'])),
                      price: drift.Value(
                        (menu['price'] as num?)?.toDouble() ?? 0.0,
                      ),
                      stockQuantity: drift.Value(
                        (menu['stockQuantity'] as num?)?.toInt() ?? 0,
                      ),
                      trackStock: drift.Value(
                        menu['trackStock'] as bool? ?? false,
                      ),
                      oneTouch: drift.Value(menu['oneTouch'] as bool? ?? false),
                      updatedAtMs: drift.Value(now),
                    ),
                  );
                } else {
                  await _db!
                      .into(_db!.menuItems)
                      .insert(
                        MenuItemsCompanion.insert(
                          guid: drift.Value(
                            (menu['guid'] as String?)?.isNotEmpty == true
                                ? menu['guid'] as String
                                : const Uuid().v4(),
                          ),
                          name: menu['name'] as String,
                          category: (menu['category'] ?? 'All Items')
                              .toString(),
                          defaultStation:
                              (menu['defaultStation'] ?? 'Main Station')
                                  .toString(),
                          modifiers: _stringList(menu['modifiers']),
                          requiredModifiers: drift.Value(
                            _stringList(menu['requiredModifiers']),
                          ),
                          tags: drift.Value(_stringList(menu['tags'])),
                          price: drift.Value(
                            (menu['price'] as num?)?.toDouble() ?? 0.0,
                          ),
                          stockQuantity: drift.Value(
                            (menu['stockQuantity'] as num?)?.toInt() ?? 0,
                          ),
                          trackStock: drift.Value(
                            menu['trackStock'] as bool? ?? false,
                          ),
                          oneTouch: drift.Value(
                            menu['oneTouch'] as bool? ?? false,
                          ),
                          updatedAtMs: drift.Value(now),
                        ),
                      );
                }
              } else if (data['type'] == 'DeleteMenu' ||
                  data['type'] == 'DeleteMenuItem') {
                final menuId = (data['id'] as num?)?.toInt();
                if (menuId != null) {
                  await (_db!.delete(
                    _db!.menuItems,
                  )..where((t) => t.id.equals(menuId))).go();
                  _notifyWebHostDebounced();
                }
              } else if (data['type'] == 'SaveCombo') {
                final name = (data['name'] ?? '').toString().trim();
                final price = (data['price'] as num?)?.toDouble() ?? 0.0;
                final category = (data['category'] ?? 'All Items').toString();
                final defaultStation =
                    (data['defaultStation'] ?? 'Main Station').toString();
                final componentIds = (data['componentItemIds'] as List?)
                        ?.map((e) => (e as num).toInt())
                        .toList() ??
                    [];
                final componentQtys = (data['componentQuantities'] as List?)
                        ?.map((e) => (e as num).toInt())
                        .toList() ??
                    [];
                if (name.isNotEmpty && componentIds.isNotEmpty) {
                  final now = DateTime.now().millisecondsSinceEpoch;
                  await _db!.transaction(() async {
                    final comboId = await _db!.into(_db!.menuItems).insert(
                      MenuItemsCompanion.insert(
                        guid: drift.Value(const Uuid().v4()),
                        name: name,
                        category: category,
                        defaultStation: defaultStation,
                        modifiers: const <String>[],
                        requiredModifiers: const drift.Value(<String>[]),
                        tags: const drift.Value(<String>[]),
                        price: drift.Value(price),
                        stockQuantity: const drift.Value(0),
                        trackStock: const drift.Value(false),
                        oneTouch: const drift.Value(false),
                        isCombo: const drift.Value(true),
                        updatedAtMs: drift.Value(now),
                      ),
                    );
                    for (var i = 0; i < componentIds.length; i++) {
                      await _db!.into(_db!.comboComponents).insert(
                        ComboComponentsCompanion.insert(
                          comboItemId: comboId,
                          componentItemId: componentIds[i],
                          quantity: drift.Value(
                            i < componentQtys.length ? componentQtys[i] : 1,
                          ),
                          updatedAtMs: drift.Value(now),
                        ),
                      );
                    }
                  });
                  _notifyWebHostDebounced();
                }
              } else if (data['type'] == 'DeleteCombo') {
                final comboId = (data['id'] as num?)?.toInt();
                if (comboId != null) {
                  await _db!.transaction(() async {
                    await (_db!.delete(_db!.comboComponents)
                          ..where((t) => t.comboItemId.equals(comboId)))
                        .go();
                    await (_db!.delete(_db!.menuItems)
                          ..where((t) => t.id.equals(comboId)))
                        .go();
                  });
                  _notifyWebHostDebounced();
                }
              } else if (data['type'] == 'SaveStation' ||
                  data['type'] == 'SaveStationItem') {
                final station = data['type'] == 'SaveStationItem'
                    ? data
                    : data['station'] as Map<String, dynamic>;
                final stationId = (station['id'] as num?)?.toInt();
                final name = (station['name'] ?? '').toString().trim();
                if (name.isEmpty) return;
                final now = DateTime.now().millisecondsSinceEpoch;
                if (stationId != null) {
                  await (_db!.update(
                    _db!.stations,
                  )..where((t) => t.id.equals(stationId))).write(
                    StationsCompanion(
                      name: drift.Value(name),
                      updatedAtMs: drift.Value(now),
                    ),
                  );
                } else {
                  await _db!
                      .into(_db!.stations)
                      .insert(
                        StationsCompanion.insert(
                          name: name,
                          updatedAtMs: drift.Value(now),
                        ),
                      );
                }
              } else if (data['type'] == 'DeleteStation' ||
                  data['type'] == 'DeleteStationItem') {
                final stationId = (data['id'] as num?)?.toInt();
                if (stationId != null) {
                  await (_db!.delete(
                    _db!.stations,
                  )..where((t) => t.id.equals(stationId))).go();
                  _notifyWebHostDebounced();
                }
              } else if (data['type'] == 'SaveModifier' ||
                  data['type'] == 'SaveGlobalModifierItem') {
                final mod = data['type'] == 'SaveGlobalModifierItem'
                    ? data
                    : data['modifier'] as Map<String, dynamic>;
                final modId = (mod['id'] as num?)?.toInt();
                final name = (mod['name'] ?? '').toString().trim();
                if (name.isEmpty) return;
                final now = DateTime.now().millisecondsSinceEpoch;
                if (modId != null) {
                  await (_db!.update(
                    _db!.globalModifiers,
                  )..where((t) => t.id.equals(modId))).write(
                    GlobalModifiersCompanion(
                      name: drift.Value(name),
                      updatedAtMs: drift.Value(now),
                    ),
                  );
                } else {
                  await _db!
                      .into(_db!.globalModifiers)
                      .insert(
                        GlobalModifiersCompanion.insert(
                          name: name,
                          updatedAtMs: drift.Value(now),
                        ),
                      );
                }
              } else if (data['type'] == 'DeleteModifier' ||
                  data['type'] == 'DeleteGlobalModifierItem') {
                final modId = (data['id'] as num?)?.toInt();
                if (modId != null) {
                  await (_db!.delete(
                    _db!.globalModifiers,
                  )..where((t) => t.id.equals(modId))).go();
                  _notifyWebHostDebounced();
                }
              } else if (data['type'] == 'ImportLibrary') {
                final payload = (data['data'] as Map?)?.cast<String, dynamic>();
                if (payload != null) {
                  await _importLibrary(payload);
                  _notifyWebHostDebounced();
                }
              } else if (data['type'] == 'ClearLibrary') {
                await _clearLibrary();
                _notifyWebHostDebounced();
              } else if (data['type'] == 'BroadcastMessage') {
                final message = data['message'] ?? '';
                final station = (data['station'] as String? ?? '')
                    .trim()
                    .toUpperCase();
                final payload = jsonEncode({
                  'type': 'KitchenBroadcast',
                  'message': message,
                  if (station.isNotEmpty) 'station': station,
                });
                if (station.isNotEmpty) {
                  broadcastToStation(station, payload);
                } else {
                  broadcast(payload);
                }
              } else if (data['type'] == 'SetRushMode') {
                broadcast(
                  jsonEncode({
                    'type': 'RushModeChanged',
                    'enabled': data['enabled'] == true,
                  }),
                );
              } else if (data['type'] == 'RequestSnapshot') {
                if (isWebHost) _sendSnapshot(webSocket);
              } else if (data['type'] == 'StationChanged') {
                final idx = _clients.indexWhere((c) => c.id == clientId);
                if (idx != -1) {
                  _clients[idx].currentStation = data['station'];
                  notifyClientsChanged();
                  _notifyWebHostDebounced();
                }
              } else if (data['type'] == 'ping') {
                // The client's liveness probe. Replying keeps its watchdog
                // satisfied, and doubles as proof the socket still carries
                // traffic in both directions.
                _send(webSocket, jsonEncode({'type': 'pong'}));
              } else if (data['type'] == 'pong') {
                // Answer to the host's heartbeat.
                //
                // Anything carrying a `targetClientId` is addressed to exactly
                // one display and must never reach the others. The browser host
                // (`WebHostClient.sendToClient`) sets that field, and it used to
                // fall through to the catch-all broadcast below — so
                // reassigning a station from the web UI hit every KDS in the
                // building at once. The native path routes through
                // `sendToClient` and targeted correctly already, which is why
                // only the browser host misbehaved.
                final target = data['targetClientId'];
                if (target is String) {
                  final channel = _clientChannels[target];
                  if (channel != null) channel.sink.add(message);
                }
              } else if (data['type'] != 'RegisterClient' &&
                  data['type'] != 'RegisterWebHost') {
                broadcast(message);
              }
            } catch (e) {
              print('Error handling WS message: $e');
            }
          },
          onDone: () {
            if (isWebHost) {
              _dropWebHost(clientId, webSocket);
            } else {
              // Always run the teardown, even for a socket that never sent a
              // registration. Otherwise an unregistered connection that dies
              // leaves nothing behind but an entry nothing will ever clear.
              // Scoped to this socket so a reconnect's late close cannot evict
              // the connection that replaced it.
              _dropClient(clientId, notify: true, channel: webSocket);
            }
          },
          onError: (Object error) {
            // Without this the error reaches the zone unhandled and can take
            // down the whole host process over one misbehaving tablet.
            debugPrint('KDS websocket error: $error');
          },
        );
      }),
    );

    // ── Web UI (compiled Flutter web build) ───────────────────
    router.get('/', (Request request) => _serveIndex());
    router.get(
      '/<path|.*>',
      (Request request, String path) => _serveWebFile(path),
    );

    _startDbWatchers();

    // No onError here on purpose: shelf's `serve` installs its own error zone
    // around the request loop, so a client resetting a connection mid-response
    // is logged rather than crashing the serve loop.
    final server = await io.serve(router.call, InternetAddress.anyIPv4, port);
    // The bound port, not the requested one: they differ whenever 0 was asked
    // for, and everything that advertises this host to a display reads this.
    _boundPort = server.port;
    _server = server;
  }

  void setIdentity(String hostId, String role) {
    this.hostId = hostId;
    this.role = role;
  }

  /// Cached LAN address of this host, for display in the UI.
  Future<String> get selfUrl async => _cachedSelfUrl ??= await _selfHostUrl();
  String? _cachedSelfUrl;

  Future<void> _importLibrary(Map<String, dynamic> data) async {
    final db = _db!;
    await db.transaction(() async {
      final now = DateTime.now().millisecondsSinceEpoch;
      for (final s in (data['stations'] as List? ?? [])) {
        await db
            .into(db.stations)
            .insertOnConflictUpdate(
              StationsCompanion.insert(
                name: (s is Map ? s['name'] : s).toString(),
                updatedAtMs: drift.Value(now),
              ),
            );
      }
      for (final m in (data['globalModifiers'] as List? ?? [])) {
        await db
            .into(db.globalModifiers)
            .insertOnConflictUpdate(
              GlobalModifiersCompanion.insert(
                name: (m is Map ? m['name'] : m).toString(),
                updatedAtMs: drift.Value(now),
              ),
            );
      }
      final existing = await db.select(db.menuItems).get();
      for (final raw in (data['menuItems'] as List? ?? [])) {
        if (raw is! Map) continue;
        final companion = MenuItemDraft(
          guid: (raw['guid'] ?? '').toString(),
          name: (raw['name'] ?? 'Unknown Item').toString(),
          category: (raw['category'] ?? 'All Items').toString(),
          defaultStation: (raw['defaultStation'] ?? 'Main Station').toString(),
          modifiers: _stringList(raw['modifiers']),
          requiredModifiers: _stringList(raw['requiredModifiers']),
          tags: _stringList(raw['tags']),
          price: (raw['price'] as num?)?.toDouble() ?? 0.0,
          stockQuantity: (raw['stockQuantity'] as num?)?.toInt() ?? 0,
          trackStock: raw['trackStock'] == true,
          oneTouch: raw['oneTouch'] == true,
        ).toCompanion(now);
        final match = existing
            .where((e) => e.name == companion.name.value)
            .firstOrNull;
        if (match != null) {
          await (db.update(
            db.menuItems,
          )..where((t) => t.id.equals(match.id))).write(companion);
        } else {
          await db
              .into(db.menuItems)
              .insert(
                MenuItemsCompanion.insert(
                  guid: drift.Value(
                    companion.guid.value.isEmpty
                        ? const Uuid().v4()
                        : companion.guid.value,
                  ),
                  name: companion.name.value,
                  category: companion.category.value,
                  defaultStation: companion.defaultStation.value,
                  modifiers: companion.modifiers.value,
                  requiredModifiers: drift.Value(
                    companion.requiredModifiers.value,
                  ),
                  tags: drift.Value(companion.tags.value),
                  price: drift.Value(companion.price.value),
                  stockQuantity: drift.Value(companion.stockQuantity.value),
                  trackStock: drift.Value(companion.trackStock.value),
                  oneTouch: drift.Value(companion.oneTouch.value),
                  updatedAtMs: drift.Value(now),
                ),
              );
        }
      }
    });
  }

  Future<void> _clearLibrary() async {
    final db = _db!;
    await db.transaction(() async {
      await db.delete(db.menuItems).go();
      await db.delete(db.stations).go();
      await db.delete(db.globalModifiers).go();
      await db
          .into(db.stations)
          .insert(StationsCompanion.insert(name: 'Main Station'));
    });
  }

  Future<String> _selfHostUrl() async {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
      final ips = <String>[];
      for (final iface in interfaces) {
        for (final addr in iface.addresses) {
          if (!addr.isLoopback) ips.add(addr.address);
        }
      }
      if (ips.isNotEmpty) {
        // Prefer the interface the OS would actually route LAN traffic out of.
        // `NetworkInterface.list` order is not stable across platforms, and
        // picking a virtual adapter (VPN, Hyper-V, Docker) first produced a URL
        // no display on the real network could reach.
        ips.sort((a, b) => _lanAddressRank(a).compareTo(_lanAddressRank(b)));
        return 'http://${ips.first}:$_boundPort';
      }
    } catch (_) {}
    return 'http://localhost:$_boundPort';
  }

  /// Orders LAN addresses by how likely a kitchen display is to reach them.
  ///
  /// Shared with the settings screen so the address the host advertises and the
  /// one shown for manual entry can never disagree. The old duplicated copies
  /// ranked `172.` above everything else, which put a carrier-grade NAT or
  /// Docker subnet ahead of the actual kitchen router.
  static int _lanAddressRank(String ip) {
    if (ip.startsWith('192.168.')) return 0;
    if (ip.startsWith('10.')) return 1;
    if (ip.startsWith('172.')) {
      // Only 172.16-172.31 is RFC 1918 private space; the rest is public and
      // should never be chosen for a LAN host.
      final second = int.tryParse(ip.split('.').elementAtOrNull(1) ?? '');
      if (second != null && second >= 16 && second <= 31) return 2;
      return 6;
    }
    // Self-assigned means DHCP failed — the host has no working lease.
    if (ip.startsWith('169.254.')) return 5;
    return 4;
  }

  String? _findWebUiDir() {
    final candidates = <String>[
      ?webUiDir,
      if (_webUiDirOverride.isNotEmpty) _webUiDirOverride,
      if (Directory.current.path.isNotEmpty)
        '${Directory.current.path}${p.separator}build${p.separator}web',
      if (Platform.resolvedExecutable.isNotEmpty)
        '${p.dirname(Platform.resolvedExecutable)}${p.separator}build${p.separator}web',
    ];
    for (final candidate in candidates) {
      try {
        if (Directory(candidate).existsSync()) return candidate;
      } catch (_) {}
    }
    return null;
  }

  Future<Response> _serveIndex() async {
    final dir = _findWebUiDir();
    if (dir != null) {
      final file = File(p.join(dir, 'index.html'));
      if (file.existsSync()) {
        return Response.ok(
          file.readAsBytesSync(),
          headers: {'Content-Type': 'text/html', 'Cache-Control': 'no-cache'},
        );
      }
    }
    final bundled = await _bundleAsset('index.html');
    if (bundled != null) {
      return Response.ok(
        bundled,
        headers: {'Content-Type': 'text/html', 'Cache-Control': 'no-cache'},
      );
    }
    return Response.ok(
      _webUiMissingHtml,
      headers: {'Content-Type': 'text/html'},
    );
  }

  Future<Response> _serveWebFile(String path) async {
    if (path.contains('..') || path.startsWith('/') || path.isEmpty) {
      return Response.notFound('Not found');
    }
    final dir = _findWebUiDir();
    if (dir != null) {
      final fullPath = p.normalize(p.join(dir, path));
      if (fullPath.startsWith(p.normalize(dir))) {
        final file = File(fullPath);
        if (file.existsSync()) {
          final bytes = await file.readAsBytes();
          return _webResponse(path, bytes, cacheable: true);
        }
      }
    }
    final bundled = await _bundleAsset(path);
    // Marked cacheable to match the on-disk branch above. The same asset had
    // opposite policies depending on where it came from, and this is the branch
    // that runs on a released Android build — where the bundle is served out of
    // `assets/webui.bin` and the disk path never exists — so every
    // `main.dart.js` and canvaskit `.wasm` was re-downloaded on each page load.
    if (bundled != null) return _webResponse(path, bundled, cacheable: true);
    final ext = p.extension(path);
    if (ext.isEmpty || path == 'index.html') return _serveIndex();
    return Response.notFound('Not found');
  }

  Map<String, List<int>>? _webBundleCache;

  Future<List<int>?> _bundleAsset(String relativePath) async {
    final bundle = await _loadWebBundle();
    if (bundle == null) return null;
    return bundle[relativePath];
  }

  // Loads the single-file web bundle (assets/webui.bin) written by
  // scripts/bundle_webui.dart and decodes it into a path -> bytes map.
  Future<Map<String, List<int>>?> _loadWebBundle() async {
    final cached = _webBundleCache;
    if (cached != null) return cached;
    final ByteData data;
    try {
      data = await rootBundle.load('assets/webui.bin');
    } catch (_) {
      return null;
    }
    final bytes = data.buffer.asUint8List(
      data.offsetInBytes,
      data.lengthInBytes,
    );
    final view = ByteData.sublistView(bytes);
    var offset = 0;
    final count = view.getUint32(offset);
    offset += 4;
    final map = <String, List<int>>{};
    for (var i = 0; i < count; i++) {
      final nameLen = view.getUint16(offset);
      offset += 2;
      final name = utf8.decode(bytes.sublist(offset, offset + nameLen));
      offset += nameLen;
      final dataLen = view.getUint32(offset);
      offset += 4;
      map[name] = bytes.sublist(offset, offset + dataLen);
      offset += dataLen;
    }
    return _webBundleCache = map;
  }

  @visibleForTesting
  void debugForceEvictSilentClients() => evictSilentClients();

  Response _webResponse(
    String path,
    List<int> bytes, {
    bool cacheable = false,
  }) {
    final ext = p.extension(path).toLowerCase();
    final mime = _webMimeTypes[ext] ?? 'application/octet-stream';
    final immutable =
        cacheable &&
        (path.startsWith('assets/') || path.startsWith('canvaskit/'));
    return Response.ok(
      bytes,
      headers: {
        'Content-Type': mime,
        'Cache-Control': immutable
            ? 'public, max-age=31536000, immutable'
            : 'no-cache',
      },
    );
  }

  Future<void> stop() async {
    _startFuture = null;
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    _suspectTimer?.cancel();
    _suspectTimer = null;
    _webHostNotifyDebounce?.cancel();
    _webHostNotifyDebounce = null;
    for (final sub in _dbWatchers) {
      sub.cancel();
    }
    _dbWatchers.clear();
    // Nulled before the await, or a `start()` racing in behind the close sees a
    // still-non-null `_server`, believes the server is up, and never binds.
    final server = _server;
    _server = null;
    _boundPort = 0;
    // The cached URL embeds `_boundPort`. Clearing `_boundPort` above is not
    // enough on its own: without this, switching device role (stop, then start
    // again) keeps serving the previous run's address out of `selfUrl`, so the
    // pairing QR code and the endpoint handed to a client name a port this
    // server is no longer listening on.
    _cachedSelfUrl = null;
    await server?.close(force: true);
    for (var client in _clientChannels.values) {
      client.sink.close();
    }
    for (final ws in _webHostChannels.values) {
      ws.sink.close();
    }
    _clientChannels.clear();
    _webHostChannels.clear();
    _clientLastSeen.clear();
    _clients.clear();
  }

  void broadcast(dynamic message) {
    // Adding to a dead sink throws, and one throwing client must not stop the
    // broadcast reaching the rest of the kitchen — iterate a copy and drop the
    // offenders as we go.
    for (final entry in _clientChannels.entries.toList()) {
      if (!_send(entry.value, message)) {
        _dropClient(entry.key, notify: false);
      }
    }
  }

  void broadcastToStation(String station, dynamic message) {
    final target = station.toUpperCase();
    for (final client in _clients.toList()) {
      if (client.currentStation.toUpperCase() != target) continue;
      final channel = _clientChannels[client.id];
      if (channel == null) continue;
      if (!_send(channel, message)) {
        _dropClient(client.id, notify: false);
      }
    }
  }

  /// Writes one frame, reporting success instead of throwing. Returns false when
  /// the sink is gone, so callers can evict the dead socket and keep going.
  bool _send(WebSocketChannel channel, dynamic message) {
    try {
      channel.sink.add(message);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Removes a client from every roster it appears in. Safe to call for a
  /// client that is already gone.
  ///
  /// [channel] is the socket the caller is tearing down. It only removes the
  /// registration if that socket is still the registered one: a display that
  /// reconnects on a blip closes its old socket, and that close arrives *after*
  /// the new registration has replaced it. Evicting on id alone meant the late
  /// close threw away a healthy connection, and the display was dropped from the
  /// roster until it happened to reconnect again.
  void _dropClient(
    String? clientId, {
    required bool notify,
    WebSocketChannel? channel,
  }) {
    if (clientId == null) return;
    final registered = _clientChannels[clientId];
    if (channel != null && !identical(registered, channel)) {
      // A newer socket has taken this id over; this teardown is stale.
      return;
    }
    final before = _clients.length;
    _clients.removeWhere((c) => c.id == clientId);
    final removed = _clients.length != before;
    _clientChannels.remove(clientId)?.sink.close();
    _clientLastSeen.remove(clientId);
    if (removed && notify) {
      notifyClientsChanged();
      _notifyWebHostDebounced();
    }
  }

  /// Drops a web-host registration on teardown, subject to the same
  /// already-replaced check as [_dropClient].
  void _dropWebHost(String? webHostId, WebSocketChannel channel) {
    if (webHostId == null) return;
    if (!identical(_webHostChannels[webHostId], channel)) return;
    _webHostChannels.remove(webHostId)?.sink.close();
  }

  /// Evicts registered clients that have stopped sending anything within
  /// [limit]. A client that closes cleanly never reaches this; this only catches
  /// sockets that died without a close frame, which on a Wi-Fi link is the common
  /// case.
  @visibleForTesting
  void evictSilentClients({Duration? limit}) =>
      _evictSilentClients(limit ?? _clientSilenceLimit);

  void _evictSilentClients([Duration? limitOverride]) {
    final limit = limitOverride ?? _clientSilenceLimit;
    if (_clientChannels.isEmpty) {
      _clientLastSeen.clear();
      return;
    }

    final now = DateTime.now();
    for (final id in _clientChannels.keys.toList()) {
      final lastSeen = _clientLastSeen[id];
      if (lastSeen == null) {
        // Registered but never heard from: start the clock rather than evicting
        // on the first sweep, in case the reply is merely in flight.
        _clientLastSeen[id] = now;
        continue;
      }
      if (now.difference(lastSeen) > limit) {
        debugPrint('KDS client $id went silent; evicting');
        _dropClient(id, notify: true);
      }
    }
    _clientLastSeen.removeWhere((id, _) => !_clientChannels.containsKey(id));
  }

  /// Backdates a client's last-seen stamp so a test can reach the eviction path
  /// without waiting out the real grace period.
  @visibleForTesting
  void debugMarkClientStale(String clientId) {
    _clientLastSeen[clientId] = DateTime.now().subtract(
      _clientSilenceLimit * 2,
    );
  }

  /// Closes a client's socket server-side while leaving its roster entry in
  /// place. Writing to a closed sink throws, which is exactly what a peer that
  /// vanished mid-frame looks like to the broadcast loop, so this reproduces the
  /// condition that used to abort delivery to every other display.
  @visibleForTesting
  void debugCloseClientSocket(String clientId) {
    _clientChannels[clientId]?.sink.close();
  }

  /// Records traffic from a client so the silence sweep can tell a live socket
  /// from a dead one.
  void _noteClientActivity(String? clientId) {
    if (clientId == null) return;
    if (_clientChannels.containsKey(clientId)) {
      _clientLastSeen[clientId] = DateTime.now();
    }
  }

  List<Map<String, dynamic>> get connectedClientsList => _clients
      .map(
        (c) => {
          'id': c.id,
          'deviceName': c.deviceName,
          'currentStation': c.currentStation,
        },
      )
      .toList();

  List<String> get connectedStations {
    final stations = <String>{};
    for (final c in _clients) {
      stations.add(c.currentStation.toUpperCase());
    }
    return stations.toList()..sort();
  }

  void sendToClient(String clientId, Map<String, dynamic> message) {
    final channel = _clientChannels[clientId];
    if (channel != null) {
      channel.sink.add(jsonEncode(message));
    }
  }

  Future<Map<String, dynamic>?> _jsonBody(Request request) async {
    try {
      return jsonDecode(await request.readAsString()) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  List<String> _stringList(dynamic value) {
    if (value is List) return value.map((e) => e.toString()).toList();
    if (value is String) {
      return value
          .split(',')
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty)
          .toList();
    }
    return [];
  }

  Future<String> _fallbackStationName(String name) async {
    if (name.isNotEmpty) return name;
    final stations = await _db!.select(_db!.stations).get();
    if (stations.isNotEmpty) return stations.first.name;
    return 'Main Station';
  }

  // ── DB Watchers ─────────────────────────────────────────────

  void _startDbWatchers() {
    final db = _db!;
    void watch<T>(drift.Selectable<T> query) {
      _dbWatchers.add(query.watch().listen((_) => _notifyWebHostDebounced()));
    }

    watch(db.select(db.kDSOrders));
    watch(db.select(db.kDSItems));
    watch(db.select(db.menuItems));
    watch(db.select(db.stations));
    watch(db.select(db.globalModifiers));
  }

  void _notifyWebHostDebounced() {
    if (_webHostChannels.isEmpty) return;
    _webHostNotifyDebounce?.cancel();
    _webHostNotifyDebounce = Timer(
      const Duration(milliseconds: 150),
      () => _notifyWebHosts({'type': 'DataChanged'}),
    );
  }

  void _notifyWebHosts(Map<String, dynamic> message) {
    final text = jsonEncode(message);
    for (final ws in _webHostChannels.values) {
      try {
        ws.sink.add(text);
      } catch (_) {}
    }
  }

  // ── Host Snapshot ───────────────────────────────────────────

  Future<String> _buildHostSnapshotJson() async {
    final db = _db!;
    final orders =
        await (db.select(db.kDSOrders)
              ..orderBy([(t) => drift.OrderingTerm.desc(t.timestamp)])
              ..limit(200))
            .get();
    final allItems = await (db.select(db.kDSItems)).get();
    final itemsByOrder = <String, List<Map<String, dynamic>>>{};
    for (final i in allItems) {
      itemsByOrder.putIfAbsent(i.orderUuid, () => []).add({
        'uuid': i.uuid,
        'name': i.name,
        'modifiers': i.modifiers,
        'stationTag': i.stationTag,
        'status': i.status.index,
        'price': i.price,
      });
    }
    final menu = await db.select(db.menuItems).get();
    final stations = await db.select(db.stations).get();
    final modifiers = await db.select(db.globalModifiers).get();
    final analytics = KDSDatabase.aggregateItemSalesStats(allItems);
    final hosts = <Map<String, String>>[
      {'hostId': hostId, 'role': role, 'url': ''},
      ...?knownPeersProvider?.call(),
    ];
    return jsonEncode({
      'type': 'HostSnapshot',
      'host': {'hostId': hostId, 'role': role},
      'orders': orders
          .map(
            (o) => {
              'uuid': o.uuid,
              'customerName': o.customerName,
              'timestamp': o.timestamp.toIso8601String(),
              'status': o.status.index,
              'items': itemsByOrder[o.uuid] ?? [],
            },
          )
          .toList(),
      'menu': menu
          .map(
            (i) => {
              'id': i.id,
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
            },
          )
          .toList(),
      'stations': stations.map((s) => {'id': s.id, 'name': s.name}).toList(),
      'modifiers': modifiers.map((m) => {'id': m.id, 'name': m.name}).toList(),
      'analytics': analytics
          .map(
            (a) => {
              'name': a.name,
              'quantity': a.quantity,
              'revenue': a.revenue,
              'modifierCounts': a.modifierCounts,
            },
          )
          .toList(),
      'clients': _clients
          .map(
            (c) => {
              'id': c.id,
              'deviceName': c.deviceName,
              'currentStation': c.currentStation,
              'connectedAt': c.connectedAt.toIso8601String(),
            },
          )
          .toList(),
      'hosts': hosts,
    });
  }

  void _sendSnapshot(WebSocketChannel ws) async {
    try {
      ws.sink.add(await _buildHostSnapshotJson());
      _lastSnapshotError = null;
    } catch (e) {
      // Previously swallowed, which left every browser view on a spinner with
      // no clue why. Record it so the web host can report the failure.
      _lastSnapshotError = '$e';
      print('Host snapshot build failed: $e');
      try {
        ws.sink.add(jsonEncode({'type': 'SnapshotError', 'message': '$e'}));
      } catch (_) {}
    }
  }

  String? _lastSnapshotError;

  /// Reason the most recent snapshot push failed, if any.
  String? get lastSnapshotError => _lastSnapshotError;

  void _broadcastFinishedOrders(
    List<KDSOrderData> orders,
    List<KDSItemData> allItems,
  ) async {
    for (final order in orders) {
      final items = allItems
          .where((i) => i.orderUuid == order.uuid)
          .map(
            (i) => {
              'uuid': i.uuid,
              'name': i.name,
              'modifiers': i.modifiers,
              'stationTag': i.stationTag,
              'status': i.status.index,
              'price': i.price,
            },
          )
          .toList();
      broadcast(
        jsonEncode({
          'type': 'ReplayFinished',
          'order': {
            'uuid': order.uuid,
            'customerName': order.customerName,
            'timestamp': order.timestamp.toIso8601String(),
            'status': order.status.index,
            'items': items,
          },
        }),
      );
    }
  }
}
