import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/host_store_provider.dart';
import '../../services/web_host_client.dart';
import '../host/host_home.dart';

/// Connection gate for the browser build.
///
/// Everything below this widget is the same `HostHome` the native host device
/// runs; the only browser-specific part is establishing and supervising the
/// WebSocket link to the host that served this page.
class WebHostHome extends ConsumerStatefulWidget {
  const WebHostHome({super.key});

  @override
  ConsumerState<WebHostHome> createState() => _WebHostHomeState();
}

class _WebHostHomeState extends ConsumerState<WebHostHome> {
  WebHostStatus _status = WebHostStatus.disconnected;
  String? _error;
  bool _connectScheduled = false;
  StreamSubscription<WebHostStatus>? _statusSub;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _connect());
  }

  @override
  void dispose() {
    _statusSub?.cancel();
    super.dispose();
  }

  Future<void> _connect() async {
    final client = ref.read(webHostClientProvider);
    if (client == null) return;

    // Cancel first: every RETRY used to add another listener to the same
    // stream, so the widget rebuilt N times per status change.
    await _statusSub?.cancel();
    _statusSub = client.statusStream.listen((status) {
      if (mounted) setState(() => _status = status);
    });

    if (!mounted) return;
    setState(() {
      _error = null;
      _status = client.status;
    });

    try {
      // The page was served by the host itself, so the origin it was loaded
      // from is the host address.
      await client.connect(host: Uri.base.host);
      if (mounted) {
        setState(() {
          _status = client.status;
          _error = client.lastFrameError;
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        // Report the port the page was actually served from. This used to hardcode
        // 8080, so on any host running on a different port the error pointed at
        // an address that was never in use — `WebHostClient._defaultPort`
        // already derives it correctly.
        final port = Uri.base.hasPort ? Uri.base.port : 8080;
        _error = 'Could not reach the host at ${Uri.base.host}:$port';
        _status = WebHostStatus.error;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final ready = _status == WebHostStatus.connected;

    if (!ready) {
      final theme = Theme.of(context);
      return Scaffold(
        backgroundColor: theme.scaffoldBackgroundColor,
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.soup_kitchen_rounded,
                    size: 48,
                    color: theme.colorScheme.primary,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'DartKDS',
                    style: theme.textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.w900,
                      letterSpacing: 1.5,
                    ),
                  ),
                  const SizedBox(height: 24),
                  if (_error != null)
                    Text(
                      _error!,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: Color(0xFFDC2626),
                        fontWeight: FontWeight.w700,
                      ),
                    )
                  else
                    const CircularProgressIndicator(),
                  const SizedBox(height: 20),
                  if (_error != null)
                    ElevatedButton.icon(
                      onPressed: _connectScheduled
                          ? null
                          : () {
                              setState(() {
                                _connectScheduled = true;
                                _error = null;
                              });
                              _connect().whenComplete(() {
                                if (mounted) {
                                  setState(() => _connectScheduled = false);
                                }
                              });
                            },
                      icon: const Icon(Icons.refresh_rounded, size: 18),
                      label: const Text('RETRY'),
                    )
                  else
                    Text(
                      _status == WebHostStatus.connecting
                          ? 'Connecting to host...'
                          : 'Waiting for host...',
                      style: TextStyle(color: theme.hintColor, fontSize: 13),
                    ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    return const HostHome();
  }
}
