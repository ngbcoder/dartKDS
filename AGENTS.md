# AGENTS.md

## Project

DartKDS — Flutter/Dart offline Kitchen Display System. Single host + multiple clients on LAN.

## Build & Run

```bash
flutter pub get              # install dependencies
flutter run                  # run app (device/emulator)
flutter build apk            # build Android APK
flutter build ios            # build iOS
```

### Web UI (bundled into host APK)

The host serves a Flutter web client over LAN at `http://<host-ip>:8080`. Features are
written once in Dart — no hand-written JS/HTML. To rebuild and bundle into the APK:

```bash
flutter build web --no-web-resources-cdn   # local canvaskit (air-gapped)
dart run scripts/bundle_webui.dart         # copy build/web → assets/webui
flutter build apk                          # APK now includes the web UI
```

During desktop development the host serves `build/web` directly from disk (no bundle step needed).
On mobile hosts the bundled `assets/webui/` assets are served via `rootBundle` fallback.

`python build.py` runs all three steps (web build, bundle, APK). Run `python build.py --help`
for flags (`--debug`, `--web-only`, `--skip-web`, `--apk-only`). It wraps `flutter`/`dart` via
`cmd /c` on Windows because the toolchain shims are `.bat` files.

## Code Generation (Drift)

```bash
dart run build_runner build --delete-conflicting-outputs
```

Run this after any change to `lib/models/database.dart` (table definitions, migrations).
Generated output: `lib/models/database.g.dart`.

## Lint & Analyze

```bash
flutter analyze
```

## Test

```bash
flutter test
```

## Project Structure

Docs: [`docs/UI.md`](docs/UI.md) documents every screen, layout, and state.
[`docs/UI_Known_Issues.md`](docs/UI_Known_Issues.md) lists UI bugs/inconsistencies not yet fixed.

```
lib/
├── main.dart                          # Entry point, theme, role routing
├── models/
│   ├── database.dart                  # Drift schema (5 tables, migrations)
│   ├── database.g.dart                # Generated — DO NOT EDIT
│   ├── connected_client.dart          # In-memory client model
│   ├── menu_item.dart                 # Legacy hardcoded catalog (unused)
│   ├── order_status.dart              # OrderStatus enum
│   └── item_status.dart               # ItemStatus enum
├── providers/
│   ├── app_state_providers.dart       # DeviceRole, station tag, tab index
│   ├── client_state_provider.dart     # Client-side order/bump state
│   ├── intake_provider.dart           # Order builder state
│   ├── service_providers.dart         # Riverpod wiring (db, server, discovery, client)
│   └── settings_provider.dart         # Persisted settings via SharedPreferences
├── services/
│   ├── host_server.dart               # Shelf HTTP server + WS hub (port 8080), serves web UI
│   ├── discovery_service.dart         # mDNS + UDP broadcast discovery
│   ├── client_service.dart            # WebSocket client connector
│   ├── sync_service.dart              # Multi-host sync (pulls/pushes changes over HTTP)
│   └── sync_engine.dart               # Change-set snapshot/apply logic for sync
└── ui/
    ├── client/
    │   └── client_home.dart           # Kitchen display UI
    ├── host/
    │   ├── host_home.dart             # Host bottom nav (4 tabs)
    │   ├── intake_screen.dart         # Legacy intake UI
    │   └── views/
    │       ├── order_intake_view.dart # Primary order intake (search, stock, edit)
    │       ├── inventory_view.dart    # Stock management
    │       ├── library_view.dart      # Menu/station/modifier CRUD + backup
    │       ├── sent_queue_view.dart   # Order history, recall, edit
    │       ├── more_view.dart         # Navigation hub
    │       └── settings_view.dart     # Client list, network, theme
    └── shared/
        └── role_selection_screen.dart # Host/Client role picker
```

### Web stubs (`lib/web_*.dart`)

Stub files that replace native-only packages (`dart:io`, `shelf_io`, `nsd`, `path_provider`,
`drift/native`, `drift/isolate`) when compiling to Flutter Web. The web build is client-only;
host mode is blocked at the role selection screen. Conditionals use
`if (dart.library.js_interop)` with `as` prefix **after** the `if` clause.

## Key Conventions

- **State management:** Riverpod (`flutter_riverpod`).
- **Database:** Drift (SQLite ORM). Schema in `lib/models/database.dart`. All generated code in `database.g.dart`.
- **Server:** Shelf framework (`shelf`, `shelf_router`, `shelf_web_socket`). Runs on port 8080.
- **Analytics:** Supports per-item modifier frequency tracking, allowing the kitchen to see the most popular customizations in the Sales Charts.
- **Discovery:** mDNS via `nsd` package + UDP broadcast on port 41234.
- **UUIDs:** `uuid` package (v4). Used for orders, items, client identity.
- **No auth** — air-gapped LAN-only system.
