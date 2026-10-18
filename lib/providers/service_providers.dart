import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../services/discovery_service.dart';
import '../services/host_server.dart';
import '../services/client_service.dart';
import '../services/sync_service.dart';
import '../models/database.dart';
import '../models/connected_client.dart';
import 'app_state_providers.dart';

final databaseProvider = Provider((ref) => KDSDatabase());

final discoveryServiceProvider = Provider((ref) => DiscoveryService());

final hostServerProvider = Provider((ref) => HostServer());

final syncServiceProvider = Provider<SyncService>((ref) {
  final db = ref.watch(databaseProvider);
  return SyncService(db);
});

// Starts (or no-ops if already running) the host server, discovery
// advertisement, and sync loop. Called both from the role-selection screen
// and on app restart, where the persisted host role routes straight to
// HostHome without going through role selection.
Future<void> startHostServices(WidgetRef ref) async {
  final server = ref.read(hostServerProvider);
  if (server.isRunning) return;

  final db = ref.read(databaseProvider);
  await server.start(db);

  final identity = ref.read(hostIdentityProvider);
  await ref
      .read(discoveryServiceProvider)
      .register(
        8080,
        hostId: identity.hostId,
        role: identity.role.name,
      );

  ref.read(syncServiceProvider).start(
        identity.hostId,
        ref.read(discoveryServiceProvider).discover(),
      );

  server.setIdentity(identity.hostId, identity.role.name);
  server.knownPeersProvider = () => ref
      .read(syncServiceProvider)
      .peers
      .map(
        (p) => {
          'hostId': p.hostId,
          'role': p.role,
          'url': 'http://${p.address}:${p.port}',
        },
      )
      .toList();
}

final connectedClientsProvider = StreamProvider<List<ConnectedClient>>((ref) {
  final server = ref.watch(hostServerProvider);
  final controller = StreamController<List<ConnectedClient>>();
  
  // Registered as its own listener rather than assigned to a shared callback
  // field, so this and `DriftHostStore.watchClients` can both subscribe without
  // one clobbering the other on teardown.
  void listener() {
    if (!controller.isClosed) controller.add(server.connectedClients);
  }

  server.addClientListener(listener);

  // Initial value
  controller.add(server.connectedClients);

  ref.onDispose(() {
    server.removeClientListener(listener);
    controller.close();
  });
  
  return controller.stream;
});

final clientServiceProvider = Provider((ref) {
  final service = ClientService();
  // Without this the service's reconnect timer and liveness watchdog outlive the
  // container and keep dialling a host nobody is listening to.
  ref.onDispose(service.dispose);
  return service;
});
