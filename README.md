# DartKDS
### The Open Source, Offline Kitchen Display System

![DartKDS Logo](Icon.png)

DartKDS is a lightweight, self-hosted **Kitchen Display System (KDS)** designed for restaurants, food trucks, and pop-up kitchens. It replaces messy paper tickets with real-time digital screens that work entirely over your local network.

**No cloud. No subscriptions. No internet required.**

<a href="https://apps.obtainium.imranr.dev/redirect?r=obtainium%3A%2F%2Fapp%2F%257B%2522id%2522%253A%2522com.hoid.kds.dartkds%2522%252C%2522url%2522%253A%2522https%253A%252F%252Fgithub.com%252FCephandriusMaxtori%252FdartKDS%2522%252C%2522author%2522%253A%2522CephandriusMaxtori%2522%252C%2522name%2522%253A%2522DartKDS%2522%257D"><img src="assets/obtainium-badge.png" height="48" alt="Get it on Obtainium"></a>

---

## 📸 Screenshots

| Order Intake (Host) |        Kitchen Display (Client)        |
| :---: |:--------------------------------------:|
| ![Intake](OrderIntakeScreenshot.jpg) |            ![KDS](Icon.png)            |
| *Modern, intuitive order entry* | *High-contrast, actionable prep lists* |

---

## ✨ Key Features

- 📱 **Flexible Roles** — Turn any tablet or phone into a Primary Host (Intake) or a Kitchen Display (Client).
- 🔌 **Instant Pairing** — Connect new screens in seconds via **QR Code Scanning**.
- 🔍 **Smart Routing** — Orders automatically route to specific stations (Grill, Fryer, Bar, etc.) based on your menu configuration.
- 🍔 **Combo/Meal Deals** — Bundle menu items into combos with special pricing. Combos expand into individual kitchen tickets per component, each routed to its station.
- 📊 **Insightful Analytics** — Track item popularity and modifier frequency (e.g., "Which burger toppings are trending?").
- 🌐 **Browser Support** — Access the kitchen view from any device with a web browser.
- 💾 **Local Resilience** — Orders are stored on-device using a high-performance SQLite database.
- 🌓 **Adaptive UI** — Light mode for Front-of-House and a high-contrast Dark Mode for the Kitchen.
- 🔋 **Keep Screen On** — Prevent the host display from sleeping during service (optional).
- 🔔 **Kitchen Broadcasts** — Push alerts (86s, rush notices, etc.) straight to station screens.

---

## 📲 Install on Android

DartKDS ships as release APKs on GitHub, so you can install and auto-update it straight from source with [Obtainium](https://obtainium.imranr.dev) — no Play Store, no sideloading.

- **With Obtainium:** tap the badge above, or open Obtainium, tap **Add**, and paste `https://github.com/CephandriusMaxtori/dartKDS`.
- **Without it:** download an APK from [Releases](https://github.com/CephandriusMaxtori/dartKDS/releases/latest) and install it manually.

Obtainium picks the CPU-ABI build matching your device automatically and notifies you when a new version is published. Allow installs from Obtainium when prompted.

> Each release ships three APKs (`arm64-v8a`, `armeabi-v7a`, `x86_64`). Roughly every current phone is `arm64-v8a`; older 32-bit devices and emulators want the other two.

---

## 🚀 Getting Started

### 1. The Host (Front-of-House)
Launch DartKDS on your main tablet and select **Primary Host**. This device becomes the "brain" of your kitchen, hosting the database and the server.

### 2. The Clients (Kitchen Stations)
Launch the app on other devices and select **Client**. 
- **Easy Pairing:** Tap "Scan QR Code" on the client and point it at the Host's pairing code in Settings.
- **Auto-Discovery:** Clients will automatically find the Host if they are on the same Wi-Fi network.
- **TV Mode** A special mode for when connected to a TV. (**In Progress**)

---

## 🛠 Developer Setup

If you want to build or customize DartKDS:

### Prerequisites
- [Flutter SDK](https://docs.flutter.dev/get-started/install)
- Python 3 (optional, for automation)

### Installation
```bash
git clone https://github.com/CephandriusMaxtori/dartKDS.git
cd dartKDS
flutter pub get
dart run build_runner build --delete-conflicting-outputs
```

### Building for Android
We've included a helper script that builds the Web UI bundle and produces per-ABI release APKs:
```bash
python build.py            # full release build (web UI + all ABI APKs)
python build.py --apk-only # APK-only if the Web UI is already bundled
# or run the steps manually:
#   flutter build web --no-web-resources-cdn
#   dart run scripts/bundle_webui.dart
#   flutter build apk --release --split-per-abi
```

---

## 🧩 Project Architecture

- **State Management:** Riverpod
- **Database:** Drift (SQLite)
- **Networking:** Shelf (Embedded Server) + WebSockets (Real-time Sync)
- **Discovery:** mDNS + UDP Broadcast

---

## 🤝 Contributing
Found a bug or want to add a feature? 
1. Open an issue to discuss your ideas.
2. Submit a PR with your changes.

**DartKDS** — *Built for speed, built for reliability, built for the kitchen.*
