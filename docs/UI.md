# DartKDS — UI Reference

Documentation of every screen, its layout, states, and interactions. Source of truth is the
Flutter code under `lib/ui/` plus the theme in `lib/main.dart`.

Known rough edges and bugs found while writing this are tracked separately in
[`UI_Known_Issues.md`](UI_Known_Issues.md).

---

## 1. Design System

### 1.1 Themes

Two independent themes, selected by device role (`lib/main.dart:225`):

| | Host (terminal / POS) | Client (kitchen display) |
|---|---|---|
| Theme | `buildTheme(brightness)` light + dark | `kitchenTheme`, dark only |
| Applies when | role is `host` or `unset` | role is `client` |
| `themeMode` | `settings.themeMode` (light / dark / system) | forced `ThemeMode.dark` |
| Font | `Lexend` | `Lexend` |

Host color tokens:

| Token | Value |
|---|---|
| Primary / seed | `#2AA31F` |
| Focused input border | `#16A34A`, 2px |
| Scaffold (dark / light) | `#020617` / `#F8FAFC` |
| Card (dark / light) | `#0F172A` / `#FFFFFF` |
| Divider (dark / light) | `#1E293B` / `#E2E8F0` |
| Body text (dark / light) | `#F1F5F9` / `#0F172A` |
| Hint text (dark / light) | `#475569` / `#94A3B8` |
| Nav selected (dark / light) | `#F8FAFC` / `#2AA31F` |
| Nav unselected (dark / light) | `#94A3B8` / `#64748B` |
| Snackbar bg (dark / light) | `#F8FAFC` (text `#0F172A`) / `#0F172A` (white text) |

Client (kitchen) theme: dark only, scaffold `#020617`, card `#0F172A`, primary `#10B981`.

Shared component styling: card radius **16** with 1px outline; input radius **12** with
16/16 padding; elevated button radius **12**; floating snackbar radius **12**; card elevation 0.

### 1.2 Typography

- `Lexend` throughout; clock/ID figures use `monospace`.
- Section labels are uppercase, `w900`, `letterSpacing` 1.0–1.2, size 10–12, grey
  (`#6B7280` / `#666666`).
- Screen titles are `w800`/`w900`, size 18–28, `letterSpacing` −0.4 to −1.
- Most action labels are `w900` uppercase with `letterSpacing` 0.5–2.

### 1.3 Enums

```dart
DeviceRole   { unset, host, client }
HostRole     { primary, backup }
OrderStatus  { pending, partial, ready, complete }
ItemStatus   { pending, cooking, ready, bumped }
ThemeMode    { light, dark, system }
```

### 1.4 Responsive rules (`lib/ui/shared/responsive_utils.dart`)

| Helper | Behavior |
|---|---|
| `Responsive.isMobile` | width < 600 |
| `Responsive.isTablet` | 600 ≤ width < 1200 |
| `Responsive.isDesktop` | width ≥ 1200 |
| `ContentWidth({maxWidth})` | `Align(topCenter)` + `ConstrainedBox`; host shell uses 1400, pushed screens use 1000, default 1200 |
| `gridColumnsFor(width)` | ≥1000 → 3 columns, ≥620 → 2, else 2 |

### 1.5 Settings bound to the UI (`lib/providers/settings_provider.dart`)

Persisted in `SharedPreferences` via `AppSettings`:

| Field | Default | Effect |
|---|---|---|
| `themeMode` | `light` | Host theme only |
| `use24HourFormat` | `false` | `HH:mm` vs `h:mm a` in every clock and history timestamp |
| `stationName` | `'Host'` | Default client station label |
| `clientTextScale` | `1.0` | Wraps the client tree in `MediaQuery(textScaler:)` |
| `clientVolume` | `1.0` | `notification.mp3` playback volume |
| `clientHighContrast` | `false` | Client bg → black, borders → white, 4px |
| `enableConfetti` | `true` | Confetti on send / finish |
| `keepScreenOn` | `false` | `WakelockPlus` while role is host (`_WakelockSync`, `main.dart:257`) |

---

## 2. Navigation Map

```
RoleSelectionScreen                        (role unset, first launch)
├── ClientHome                              → client role
└── WebHostHome (kIsWeb only)               → connection gate
    └── HostHome                            → host role
        ├── ORDER    OrderIntakeView
        ├── HISTORY  SentQueueView
        ├── STOCK    InventoryView
        └── SYSTEM   MoreView
                     ├── MENU LIBRARY   ─┐
                     ├── STATIONS        ├─ push LibraryView (tabIndex set first)
                     ├── MODIFIERS       │
                     ├── BACKUP         ─┘
                     ├── SYSTEM SETTINGS → push SettingsView
                     ├── SALES CHARTS    → push AnalyticsView
                     └── KITCHEN ALERTS  → KITCHEN BROADCAST dialog (no push)
```

Bottom nav items (`lib/ui/host/host_home.dart:298`) — `ORDER` (apps), `HISTORY` (history),
`STOCK` (inventory_2), `SYSTEM` (settings), all 22px. App bar title switches per tab:
`TERMINAL`, `HISTORY`, `STOCK`, `SYSTEM`.

---

## 3. Role Selection — `lib/ui/shared/role_selection_screen.dart`

Gradient background (`#020617`→`#0F172A` dark, `#F8FAFC`→`#E2E8F0` light), max width 1000.

- **Header:** 60px primary rounded square with `restaurant_menu` icon (glow shadow), title
  `DARTKDS` (28, w900), tagline `Go Warriors` in primary.
- **Section label:** `ASSIGN DEVICE ROLE` (primary, size 12, w900, letterSpacing 2).
- **Three role cards** — side-by-side row on tablet/desktop, vertical list on phone:

| Card | Accent | Subtitle | Effect |
|---|---|---|---|
| `PRIMARY HOST` | `#2AA31F` | Order Intake | Starts server, registers `primary` mDNS, starts sync, role → host |
| `BACKUP HOST` | `#8B5CF6` | Sync Peer | Same, registered as `backup` |
| `DISPLAY CLIENT` | `#10B981` | Kitchen Screen | Role → client, no services started |

Each card: icon tile at 10% accent alpha, uppercase accent title (12, w900, letterSpacing 1.2),
20px subtitle, 2-line description. `HapticFeedback.lightImpact()` on tap.

- Footer: `DARTKDS v1.2.0 • BUILT FOR WARRIORS`.
- On host cards a modal `CircularProgressIndicator` (green) shows while the server boots; on
  failure a red snackbar `INIT FAILED: <error>`.

---

## 4. Browser Host Gate — `lib/ui/webhost/web_host_shell.dart`

Shown only when `kIsWeb` and role is host. Centered card, max width 420:

- `soup_kitchen` icon 48 in primary, `DartKDS` headline with letterSpacing 1.5.
- While connecting: `CircularProgressIndicator` plus `Connecting to host...` /
  `Waiting for host...`.
- On failure: red text (e.g. `Could not reach the host at 192.168.1.5:8080`) and a
  `RETRY` button.
- On `WebHostStatus.connected` it renders the same `HostHome` — only the socket is
  browser-specific (connects to `Uri.base.host:8080`).

---

## 5. Host Shell — `lib/ui/host/host_home.dart`

- **App bar** (`toolbarHeight: 70`): green status dot `#22C55E` + tab title
  (13, letterSpacing 1.5). Actions: `swap_horiz` role switch (hidden in browser) → confirm
  dialog `SWITCH DEVICE ROLE?`; a `RUSH` label + scaled (0.7) `Switch` with red thumb
  (`#DC2626`) that turns the label red and calls `setRushMode`; a monospace clock ticking
  every second, separated by a left divider.
- **Body:** `ContentWidth(maxWidth: 1400)` around the active view.
- **Bottom nav:** 4 items, 1.5px top border.
- **New client connected:** when a client appears in `hostClientsProvider`, an alert dialog
  `NEW CLIENT CONNECTED` with a green dot, the device name, and a `STATION: <TAG>` badge
  (`#22C55E` at 12% alpha). `OK` button in primary.

---

## 6. Order Intake — `lib/ui/host/views/order_intake_view.dart`

App bar title `TERMINAL`. Three-column composition:

```
Row
├── Expanded(flex 3)  menu section
│     ├── Search + filters
│     └── Menu grid
└── 360px cart panel   (width ≥ 600 and cart non-empty, 2px left divider)
Positioned bottom cart bar (width < 600 and cart non-empty, height = 40% of screen clamped 200–340, top shadow)
```

On phones the cart renders as a bottom panel with a 2px top border and a soft shadow.

### 6.1 Search and filters

- Search field, hint `Search menu...`, prefix `search` icon, dark fill `#1A1A1A`, dense, with a
  **300ms debounce**.
- Filter toggle row: `tune` icon + `FILTERS` / `HIDE FILTERS` + a chevron. When collapsed and
  a filter is active, a primary pill shows the active category and tag.
- Expanded shows two chip rows (32px): category (from `item.category`, excluding `ALL` /
  `ALL ITEMS`) and tag (from `item.tags`). Chips prefixed with `ALL`; selected = `#111111`
  background with white `w900` text, unselected = transparent with divider border.

### 6.2 Menu grid

`GridView.builder`, padding 10, spacing 8, `childAspectRatio: 1.0`. Columns from width:

| Width | Columns |
|---|---|
| < 400 | 3 |
| < 700 | 4 |
| < 1000 | 5 |
| < 1300 | 6 |
| ≥ 1300 | 7 |

Tile (radius 16, 1.5px border, padding 16):
- Name uppercased (13, w800, 2 lines max).
- `⚡ QUICK` and/or the first tag on a size-8 primary line.
- Bottom row: price in primary (12, w900) and a stock chip when `trackStock` — raw count, or
  `OUT` in red.
- **Out of stock** (`trackStock && stockQuantity <= 0`): surface greyed, border transparent,
  `onTap: null`, name and price in hint color.

Tap behavior: items with no modifiers, or with `oneTouch`, are added straight to the cart
(light haptic, `Added: <name>` snackbar). Everything else opens the modifier dialog.

### 6.3 Cart / order summary panel

1. **Header** (primary at 10% alpha when editing an existing order, else divider at 10%):
   `GUEST / ORDER NAME` field (`InputBorder.none`, dense, 14 w900) + `EDITING` badge when editing.
2. `ITEMS (n)` row with a red `CLEAR` text button → `CLEAR TICKET?` confirmation.
3. Cart lines (`ListView.separated`): `2×` quantity, item name, modifier string
   (`A • B`, size 11, `#666666`), line total, and a close icon to remove. Tapping a line
   reopens the modifier dialog in edit mode.
4. **Action button** — one full-width button, disabled and greyed when the cart is empty:

| Button | Icon | Background |
|---|---|---|
| `COMPLETE ORDER` + total (new order) | `bolt_rounded` | `#10B981` |
| `UPDATE ORDER` (when editing) | `sync_rounded` | `#10B981` |

The new-order label carries the total beneath it. `UPDATE ORDER` carries none — a recalled
order is re-sent, not re-charged.

Total = `Σ (menu price + Σ modifier deltas) × qty`. Modifier deltas are parsed from strings
like `Add Bacon +$2.00` via `RegExp(r'\+\s*\$?([0-9]+(\.[0-9]+)?)')`. `_cartTotal` uses the
same per-line arithmetic as `submitOrder`, so the figure quoted in the calculator is the
figure billed.

**Payment calculator** — a new order with a total above zero opens `PAYMENT CALCULATOR`
instead of sending straight away. Editing a recalled order, or a zero-total cart, skips it
and sends directly.

| Element | Detail |
|---|---|
| Title | `PAYMENT CALCULATOR` (18, w900) |
| `TOTAL DUE` panel | divider-tinted, amount at 22 w900 |
| `CASH RECEIVED` | centred, 24 w900, `\$ ` prefix, numeric-decimal keyboard |
| Result panel | `CHANGE DUE:` green `#22C55E`, or `REMAINING:` orange while short |
| Quick chips | `$5` `$10` `$20` `$50` `$100` — write the field and set the result |
| `EXACT CHANGE` | fills the field with the total, i.e. zero change |
| Actions | `CANCEL`, `COMPLETE ORDER` (`#111111`) |

Nothing is focused or pre-filled on open: `autofocus` is off, the field starts empty and the
result panel stays hidden until an amount is entered, so no value is selected on the cashier's
behalf and the keyboard never covers the change figure. Only a deliberate tap on the field, a
chip or `EXACT CHANGE` fills it. `COMPLETE ORDER` dismisses the dialog and sends the order;
`CANCEL` sends nothing and leaves the cart intact.

**Send feedback** — snackbars: `Sent to Kitchen: <name>!` or `Order "<name>" Updated!`
(`#111111`). Heavy haptic + optional confetti on send.

An unnamed order is stored as `Guest`. Sending always leaves the order `pending`; only the
kitchen closes one out (`TicketFinished`), or a recall from History reopens it.

### 6.4 Modifier dialog

`StatefulBuilder` + `watchGlobalModifiers`. Modifier set = required + item modifiers +
global modifiers. Order is kept as the union of the first two plus any extras.

- Title: item name uppercased (20, w900).
- `REQUIREMENT: SELECT ONE (…)` line — green `#22C55E` when satisfied, red otherwise.
- **QUANTITY** stepper: 60px row, `−` / count / `+` with dividers; `−` disabled at 1, `+`
  disabled when the item tracks stock and the count has reached stock.
- **MODIFIERS** `Wrap` of `FilterChip`s (no checkmark, selected = `#111111` with white text).
  Unselected required modifiers carry a 1.5px red border and `red.shade700` label. A red
  `SELECTION REQUIRED` pill appears when the item has required modifiers.
- Actions: `CANCEL`, and `ADD ITEM` (or `SAVE CHANGES` when editing) — enabled only when
  requirements are met, otherwise disabled and greyed.

---

## 7. History — `lib/ui/host/views/sent_queue_view.dart`

App bar title `HISTORY`. `TabBar` with 3px indicator, labels
`ACTIVE (n)` / `CLOSED (n)` / `ALL (n)`.

Order card (radius 10, 1px border, padding 16):
- **Header:** person icon, `<NAME>`, `#ABCD` (first 4 of uuid), status badge, timestamp
  (respects 24h setting), then the action pill.
- **Action pill:** active → `ADD ITEMS`; closed → `EDIT`. Both load the order into the intake
  and jump to the ORDER tab (`hostTabIndexProvider = 0`).
- **Items:** green `check_circle` per line, name, and modifiers on a `#FACC15` at 10% alpha
  background; price right-aligned.
- **Total row:** `TOTAL` with the amount in primary, 16 w900.

Status badge = pill at 12% alpha with a 0.3 alpha border, 10 w900, letterSpacing 0.5:

| OrderStatus | Label | Color |
|---|---|---|
| `pending` | `ACTIVE` | `#F59E0B` |
| `partial` | `IN PROGRESS` | `#2AA31F` |
| `ready` | `SERVED` | `#22C55E` |
| `complete` | `CLOSED` | `#6B7280` |

Empty states (faded receipt icon + title + subtitle): `No Active Orders` /
`No Closed Orders` / `No Orders`.

Recall matches items back to menu entries **by name**; unmatched items are synthesized as
placeholders, and recalled quantity always resets to 1.

---

## 8. Stock — `lib/ui/host/views/inventory_view.dart`

App bar title `STOCK`. Header `STOCK MANAGEMENT` / `Sync and monitor live inventory levels.`
with an `EXPORT LIST` button (compact: `LIST`) that shares a generated shopping list of low
or out-of-stock items; when nothing is low it shows `All items are in stock.`

Rows are driven by `watchTrackedStockItems()` and bordered by severity:
`stock <= 0` red 2px, `0 < stock <= 5` orange 2px, otherwise divider 1px.

- **Wide (≥600):** name + station, `-1` / `+1` quick buttons (50×44), a fixed 80px column
  with the count (28 w900, red when out of stock), `Zero` in red, and `SET`.
- **Compact:** name + station and count on one row, then `-1`, `+1`, `Zero`, and an expanded
  `SET` button on the next.
- `SET` opens `SET STOCK: <NAME>` with a numeric field and `CANCEL` / `SAVE`.

All adjustments fire `HapticFeedback.lightImpact()`.

---

## 9. System — `lib/ui/host/views/more_view.dart`

Header `MANAGEMENT HUB` / `System configuration and reporting.`, then a
`SliverGrid` (columns from `gridColumnsFor`, aspect 1.4) of icon cards (radius 8, icon at 8%
accent alpha):

| Card | Subtitle | Icon | Accent |
|---|---|---|---|
| `MENU LIBRARY` | Items & Catalog | `menu_book_rounded` | `#111111` |
| `STATIONS` | Routing lines | `router_rounded` | `#D97706` |
| `MODIFIERS` | Global choices | `tune_rounded` | `#7C3AED` |
| `SYSTEM SETTINGS` | Devices & Network | `important_devices_rounded` | `#2AA31F` |
| `BACKUP` | Data sync | `backup_table_rounded` | `#059669` |
| `SALES CHARTS` | Revenue & Trends | `bar_chart_rounded` | `#22C55E` |
| `KITCHEN ALERTS` | Send Broadcasts | `campaign_rounded` | `#DC2626` |

Library cards set `libraryTabIndexProvider` then push a `MaterialPageRoute` with an app bar
and `ContentWidth(maxWidth: 1000)`. `KITCHEN ALERTS` opens a dialog instead:
`KITCHEN BROADCAST` — message field (hint `e.g. 86 Smash Burgers, Rush coming in...`) plus a
`TARGET STATION` dropdown (`ALL SCREENS` or a connected station), with the send button
labelled `SEND TO ALL SCREENS` or `SEND TO <STATION>` in `#DC2626`.

---

## 10. Library — `lib/ui/host/views/library_view.dart`

Four tabs in a `TabBar` (`ITEMS`, `STATIONS`, `MODIFIERS`, `BACKUP`), 3px indicator, the
selected index persisted to `libraryTabIndexProvider` so the MoreView cards can deep-link.
The whole screen is gated behind `watchStations()`.

### 10.1 ITEMS

Sliver 1 — `NEW MENU ITEM` card (radius 8, padding 20, label 11 w900 `#666666`) with:
`Item Name` (`e.g. Smash Burger`), `Price` (`0.00`, `$` prefix), `Available Modifiers`
(`Bacon, Cheese, Egg`), `Required Modifiers` (`Rare, Medium, Well`),
`Tags (for menu filters)` (`Gluten Free, Spicy, Chef Special`),
`Category` (`e.g. Burgers, Sides, Drinks`, default `All Items`),
`Routing Station` dropdown. Then two dense switches:

- `TRACK INVENTORY` — reveals a `Current Stock` field when on. Thumb `#111111`.
- `ONE TOUCH ADD` — subtitle `Adds to ticket instantly on tap (skips modifier screen).`
  Thumb `#2AA31F`.

Then `SAVE TO LIBRARY` (`#111111`, vertical padding 16) — requires a name and a station.

Sliver 2 — item rows (radius 8) with name, price in `#2AA31F`, and tag chips:

| Chip | Background | Text |
|---|---|---|
| Station (uppercased) | `#F3F4F6` | `#666666` |
| `STOCK: n` (tracked only) | `#FFF7ED` | `#C2410C` |
| `ONE TOUCH` | `#EFF6FF` | `#2AA31F` |
| Each tag | `#EFF6FF` | `#2AA31F` |
| `REQUIRED: a, b` (red text) | — | `Colors.red` |

Overflow menu (`more_vert`): `EDIT ITEM` and `DELETE` (red). Delete has no confirmation.

### 10.2 STATIONS

`NEW STATION` card with a single `Station Name` field (`e.g. Grill`) and `CREATE STATION`
(`#111111`). Rows show the uppercased name with `edit_outlined` and `delete_outline` (red)
icon buttons; edits open an `EDIT STATION` dialog.

### 10.3 MODIFIERS

Full-width `ADD MODIFIER` button (`#2AA31F`, `add_rounded` 22) opens `NEW GLOBAL MODIFIER`
with a `Modifier Name` field. Rows list uppercased modifier names with a red delete icon
button. Empty state: `No modifiers yet. Tap "+ ADD MODIFIER" above.`

### 10.4 BACKUP

- `SYSTEM BACKUP` — `EXPORT LIBRARY` (green download icon) and `IMPORT LIBRARY` (upload icon).
  Export writes `dartkds_backup_<yyyy-MM-dd>.json` via the file picker, falling back to the
  documents directory plus the share sheet; success snackbar is green. Import requires a
  `menuItems` key in the JSON and shows an `IMPORT LIBRARY` confirmation
  (`PROCEED` merges and updates by name).
- `DANGER ZONE` — `CLEAR ALL LIBRARY DATA` in `#DC2626`; confirmation
  `CLEAR ALL LIBRARY DATA?` notes that order history is preserved.

Dialogs: `NEW GLOBAL MODIFIER`, `EDIT STATION`, `EDIT MENU ITEM` (same field set as the
create card, with `SAVE CHANGES`).

---

## 11. Host Settings — `lib/ui/host/views/settings_view.dart`

Pushed from MoreView. A `ListView` of `_buildSectionHeader` (grey `#6B7280`, 12 w900,
letterSpacing 1.2) + `_buildCard` (radius 10, card fill, 1px border) pairs.

| Section | Content |
|---|---|
| `CONNECTED CLIENTS` | Green circular `tablet_android` avatar per client, device name, `Station: <tag>`, `REASSIGN` button (station picker list). Empty: `No kitchen displays connected`. Footer tile `Pair New Device` opens the QR dialog. |
| `NETWORK & BLUETOOTH` | One monospace IP per non-loopback IPv4, `bluetooth_audio` icon for `192.168.44.*` (label `Network Interface: Bluetooth PAN`) else `wifi` (`Local Network`). Then `Wi-Fi Hotspot` and `Bluetooth Tethering (PAN)` deep links to Android settings. |
| `DISPLAY` | `Keep Screen On` — subtitle `Prevent the host screen from sleeping`, `wb_sunny` icon in primary. |
| `FORMAT` | `Use 24-Hour Format` (`schedule` icon) and `Enable Confetti` (`celebration` icon). |
| `THEME` | `Appearance` row whose subtitle shows the current mode uppercase; opens a bottom sheet with `Light Mode`, `Dark Mode`, `System Default` (selected tiles show a primary `check_circle`, others a grey empty radio). |
| `MORE` | `About KDS` (version 1.0.0) and `Reset Application` in red → `Reset Everything?` warning dialog. |

**Pairing QR dialog** — `PAIR NEW DEVICE`, 200×200 `QrImageView` on a white rounded card, and
either a `Select Host IP:` dropdown (when several IPv4 addresses exist) or a monospace
`HOST IP: <ip>` line. Payload: `dartkds://connect?ip=<ip>&port=8080`. IP preference order is
`192.168.*` → `10.*` → `172.*` → other → `169.254.*`.

---

## 12. Sales Charts — `lib/ui/host/views/analytics_view.dart`

Full scaffold pushed from MoreView. `CustomScrollView` over `watchItemSalesStats()` (sorted
by revenue in SQL, capped at 25 rows).

1. `SALES PERFORMANCE` header with an `EXPORT CSV` button.
2. Two summary cards: `TOTAL REVENUE` (payments icon, `#22C55E`) and `ITEMS SOLD`
   (shopping basket icon, `#2AA31F`).
3. `PERFORMANCE BY ITEM` card with the top 5 bar rows — name, revenue in `#22C55E`,
   `Top Modifiers: …` line, and an 8px bar with a `#22C55E`→`#4ADE80` gradient scaled to the
   highest revenue.
4. Ranked list of every item: circular rank number, name uppercased, `n units sold`, the top
   3 modifiers in italic hint text, and revenue in `#22C55E`.

Empty state: faded `bar_chart_rounded` 64 with `NO SALES DATA YET`.

---

## 13. Kitchen Display Client — `lib/ui/client/client_home.dart`

Landscape-preferred, immersive sticky system UI. The whole tree is wrapped in
`MediaQuery(textScaler: TextScaler.linear(settings.clientTextScale))`.

```
Stack
├── Scaffold
│   └── Column
│       ├── Header (fixed 60px)
│       └── Expanded → empty state | LayoutBuilder grid/list
└── Confetti overlay (IgnorePointer)
```

**Background:** black in high contrast, white in light mode, `#030712` otherwise.
**Header background:** black + 2px white bottom border in high contrast, `grey.shade200` in
light, `#1F2937` in dark.

### 13.1 Header

| Element | Detail |
|---|---|
| Station chip | `#22C55E`, radius 4, black 16 w900 uppercase text; tap → `SET STATION NAME` dialog |
| Connection dot | 8px: `#22C55E` (with glow) or `red`; label `KDS • <ip>` with `(OFFLINE)` appended when down; tap while offline opens manual connect |
| Clock | `Stream.periodic(1s)` in a `RepaintBoundary`; `HH:mm:ss` or `h:mm:ss a`, monospace 22 bold |
| Actions | `history` (recent bumps), `swap_horiz` (switch role), `settings` (KDS settings) — all 20px |

### 13.2 Ticket grid / list

- **Tablet and desktop:** `GridView`, padding 8, `crossAxisCount = (maxWidth / 240).floor().clamp(1, 14)`,
  spacing 8. Tile height comes from the board, not the width: `mainAxisExtent = (maxHeight - 24).clamp(120, ∞)`,
  where 24 is the 8px grid padding (16) plus the 8px main-axis spacing under the single full-height row.
  This replaced `childAspectRatio: 1.05`, which capped a ticket at roughly two visible item rows regardless
  of how much board was left below it. Built by the top-level `ticketGridDelegate(maxWidth:, maxHeight:)`
  in `client_home.dart` so the geometry is testable without booting the client.
- **Phone:** horizontal `ListView`; ticket width 240 in rush mode, 290 otherwise. A horizontal `ListView`
  already gives each child the full cross-axis extent, so phone tickets were always full height.
- New tickets animate in over 600ms with `Curves.elasticOut` (scale 0.8 → 1.0 plus fade) keyed
  by order uuid.

**Aging colors** drive the whole card:

| Elapsed | Color | Meaning |
|---|---|---|
| < 5 min | `#22C55E` | fresh |
| 5–10 min | `#FACC15` | warning |
| ≥ 10 min | `#DC2626` | late |

`elapsedMinutes ≥ 15` counts as late, and late tickets pulse: the border opacity is driven by
`globalPulseProvider`, a 50ms triangular wave (20Hz).

**Card chrome:** surface black (high contrast) / white (light) / `#0F172A` (dark), radius 16,
`AnimatedScale` 150ms, shadow black 10% blur 10 offset (0,4). Border is 4px white in high
contrast (red once ≥ 10 min), otherwise 2px in the aging color at the pulse opacity.

**Card body:**
1. 6px urgency bar in the aging color.
2. Header row at 5% aging-color alpha: `#ABCD • CUSTOMER` (16 in rush mode / 20 normal) — the
   customer name is omitted entirely in rush mode — and the elapsed `NNm` in the aging color,
   monospace 16 w900.
3. Item list. Tapping an item bumps it: `HapticFeedback.lightImpact()`, sends `ItemBumped` over
   the socket, and drops the row to 30% opacity (`AnimatedOpacity` 200ms) with a green
   `check_circle` and strikethrough name. Modifiers render as a `#FACC15` flag with black
   14 w900 uppercase text.
4. Footer, 50px: `BUMP ALL` normally, `FINISH` once every item is bumped (footer turns
   `#22C55E`, text black). Bump-all sends an `ItemBumped` per unbumped item; `FINISH` sends
   `TicketFinished`, removes the ticket locally, pushes it to `recentBumpsProvider`, plays
   `heavyImpact`, and triggers confetti when enabled.

**Station filtering:** `GENERAL` and `EXPO` see every item; any other station shows only items
whose `stationTag` matches, and hides the card when nothing matches.

**Empty state:** `check_circle_outline` 100 and `QUEUE EMPTY` (24, w900, letterSpacing 4) at
10% opacity.

### 13.3 Client dialogs

| Dialog | Contents |
|---|---|
| `SCAN PAIRING CODE` | Full-screen `MobileScanner` with a 250×250 reticle; parses `dartkds://connect?ip=…&port=…` (default 8080); green `Pairing with <ip>...` snackbar |
| `RECENT BUMPS` | `#UUID4 - NAME` rows with `HH:mm:ss` times and a green `RECALL` button; empty → `No recent bumps` |
| `NOTIFICATION` (broadcast) | `campaign_rounded` 80, optional `TO STATION: <tag>`, uppercase message (4 lines max), `ACKNOWLEDGE`. Background `#DC2626`, radius 12, **4px white border**, non-dismissible, `heavyImpact` on open |
| `SET STATION NAME` | Single field, hint `e.g. GRILL, FRYER, EXPO`; `CANCEL` / `SAVE` (green) |
| `MANUAL CONNECT` | `HOST IP ADDRESS` + `PORT (8080)` numeric fields; `CANCEL` / `CONNECT` (green) |
| `SWITCH DEVICE ROLE?` | `CANCEL` / `SWITCH ROLE` |
| `KDS SETTINGS` | See below |

**`KDS SETTINGS`** (background `#1F2937`, or white in light mode):
- `APPEARANCE` — `SegmentedButton` with `Light` / `Dark` (`light_mode` / `dark_mode`, 16px).
  Cannot select `ThemeMode.system` from here.
- `TEXT SIZE` slider, 0.8 → 2.0, 6 divisions, green active.
- `ALERT VOLUME` slider, 0.0 → 1.0, green active.
- Switches: `HIGH CONTRAST`, `ENABLE CONFETTI` (green thumbs).
- `CURRENT STATION` row with the station in green w900 and a `CHANGE` button.
- `EXIT KITCHEN MODE` in red — sets the role back to `unset`.
- `CLOSE` action.

### 13.4 Connection behavior

- On web, skips mDNS/UDP and connects straight to `Uri.base.host:8080`.
- Otherwise mDNS + UDP discovery, with cached `last_host` / `last_port` from
  `SharedPreferences` and a `client_uuid` identity.
- On connect sends `RegisterClient` with `id`, `deviceName` (`Platform.localHostname`) and
  `station`.
- Watchdog: a 15s timer force-reconnects when the last heartbeat is older than 75s.
- Discovery backoff: after 30s unconnected, retries increment; past 2 it waits 60s before
  trying again.
- `paused` cancels discovery and the watchdog; `resumed` restarts discovery if disconnected.
- Alert sound: `audioplayers` playing `assets/notification.mp3` at `settings.clientVolume`.

### 13.5 Incoming socket messages

| `type` | UI reaction |
|---|---|
| `ping` | ignored (refreshes the heartbeat) |
| `KitchenBroadcast` | non-dismissible red `NOTIFICATION` overlay |
| `RushModeChanged` | updates local rush state (hides customer names, narrows tickets) |
| `OrderCreated` / `OrderUpdated` | if the station matches, plays the sound and vibrates |
| `SetStation` | overwrites `stationTagProvider` |
| `ReplayFinished` | recreates the order as complete with all items bumped and records it in recent bumps |
| `OrderDeleted` | removes the order from `clientStateProvider` |

---

## 14. Visual Semantics Summary

| Meaning | Color |
|---|---|
| Connected / success / fresh ticket | `#22C55E` |
| Primary action / brand | `#2AA31F` |
| Paid / settled | `#16A34A` |
| Confirmed action (quick send) | `#10B981` |
| Station chip | `#22C55E` |
| Warning / aging 5–10 min | `#FACC15`, `#F59E0B` |
| Late (≥ 10 min) / rush / broadcast / danger | `#DC2626` |
| Muted / closed tab | `#6B7280`, `#64748B` |
| Neutral dark surface | `#111111`, `#0F172A`, `#1E2937`, `#1F2937` |

---

## 15. Widget & Function Index

Every widget, build helper, and dialog in the UI layer, with its location.

### 15.1 `lib/main.dart`

| Symbol | Line | Role |
|---|---|---|
| `main()` | 15 | Bootstraps `SharedPreferences`, overrides `webHostClientProvider` on web |
| `MyApp.build` | 38 | Watches `deviceRoleProvider` + `settingsProvider`, builds both themes, picks `home` |
| `buildTheme(brightness)` | 42 | Host light/dark theme factory |
| `kitchenTheme` | 205 | Client (dark-only) theme |
| `MyApp._getHome` | 239 | `host` → `WebHostHome`/`HostHome`, `client` → `ClientHome`, `unset` → `RoleSelectionScreen` |
| `_WakelockSync` | 257 | Keeps the host screen awake while `keepScreenOn` is set |
| `_WakelockSyncState._sync` | 268 | Enables/disables `WakelockPlus` |

### 15.2 `lib/ui/shared/responsive_utils.dart`

| Symbol | Line | Role |
|---|---|---|
| `Responsive` | 3 | Picks `mobile` / `tablet` / `desktop` by width |
| `Responsive.isMobile` | 15 | `< 600` |
| `Responsive.isTablet` | 18 | `600–1199` |
| `Responsive.isDesktop` | 20 | `≥ 1200` |
| `ContentWidth` | 43 | Centres and clamps page content |
| `gridColumnsFor()` | 63 | Grid column count from available width |

### 15.3 `lib/ui/shared/role_selection_screen.dart`

| Symbol | Line | Role |
|---|---|---|
| `RoleSelectionScreen` | 9 | First-launch role picker |
| `build` | 19 | Gradient layout, 3-across or stacked role cards |
| `_buildHeader` | 170 | Logo, `DARTKDS`, `Go Warriors` |
| `_buildRoleOption` | 221 | One role card (icon tile, accent title, subtitle, description) |
| `_handleTap` | 313 | Boots the server/discovery/sync for hosts, switches role for clients |

### 15.4 `lib/ui/webhost/web_host_shell.dart`

| Symbol | Line | Role |
|---|---|---|
| `WebHostHome` | 15 | Browser-only connection gate in front of `HostHome` |
| `_connect` | 40 | Opens the WebSocket to `Uri.base.host` and subscribes to status |
| `build` | 77 | Loading / error / retry card, then delegates to `HostHome` |

### 15.5 `lib/ui/host/host_home.dart`

| Symbol | Line | Role |
|---|---|---|
| `HostHome` | 15 | Host shell — app bar, 4-tab bottom nav |
| `_views` | 23 | `[OrderIntakeView, SentQueueView, InventoryView, MoreView]` |
| `_startHostServices` | 46 | Restarts server/discovery/sync after a cold start; no-op in browser |
| `_onClientsChanged` | 64 | Diffs the client list to detect new joiners |
| `_confirmSwitchRole` | 80 | `SWITCH DEVICE ROLE?` dialog → shuts down services, role → `unset` |
| `_showClientConnectedDialog` | 107 | `NEW CLIENT CONNECTED` dialog with station badge |
| `build` | 195 | Scaffold, app bar, `ContentWidth(maxWidth: 1400)`, bottom nav |

### 15.6 `lib/ui/host/views/order_intake_view.dart`

| Symbol | Line | Role |
|---|---|---|
| `parseModifierPrice()` | 15 | Extracts `+$X.XX` from a modifier string |
| `OrderIntakeView` | 24 | Intake screen |
| `_calcColumns` | 54 | Menu grid column count (3/4/5/6/7 by width) |
| `build` | 63 | Row: menu section (flex 3) + 360px cart, or bottom cart on phones; confetti overlay |
| `_buildMenuSection` | 122 | Search/filter bar + menu grid |
| `_buildOrderSummarySection` | 422 | Cart panel: guest field, line items, `COMPLETE ORDER` / `UPDATE ORDER` |
| `_cartTotal` | — | Order total, same arithmetic as `submitOrder` |
| `_showPaymentDialog` | — | Change calculator: cash received, change due / remaining, quick chips |
| `_buildFilterChipRow` | 696 | One horizontal chip row (category or tag) |
| `_handleItemTap` | 754 | Adds directly, or opens the modifier dialog |
| `_showModifierDialog` | 773 | Quantity stepper, required-modifier enforcement, `ADD ITEM` / `SAVE CHANGES` |
| `_sendToKitchen` | 1039 | Submits the order, clears the intake, confetti + snackbar |

### 15.7 `lib/ui/host/views/sent_queue_view.dart`

| Symbol | Line | Role |
|---|---|---|
| `SentQueueView` | 12 | History screen (active / closed / all orders) |
| `build` | 16 | `TabBar` with live counts + `TabBarView` |
| `_buildOrderList` | 108 | Order cards with items, totals, `ADD ITEMS` / `EDIT` |
| `_buildStatusBadge` | 364 | Maps `OrderStatus` → label + color pill |
| `_editOrder` | 404 | Recalls an order into the intake and switches to the ORDER tab |

### 15.8 `lib/ui/host/views/inventory_view.dart`

| Symbol | Line | Role |
|---|---|---|
| `InventoryView` | 9 | Stock list with severity borders |
| `_quickAdjust` | 154 | `-1` / `+1` / `Zero` button |
| `_setButton` | 177 | `SET` button that opens manual entry |
| `_showSetStockDialog` | 195 | `SET STOCK: <NAME>` numeric dialog |
| `_updateStock` | 219 | Writes the new quantity to the store |
| `_exportShoppingList` | 223 | Builds and shares the low-stock shopping list |

### 15.9 `lib/ui/host/views/more_view.dart`

| Symbol | Line | Role |
|---|---|---|
| `MoreView` | 10 | Management hub grid |
| `build` | 14 | `MANAGEMENT HUB` header + 7-card `SliverGrid` |
| `_showBroadcastDialog` | 145 | `KITCHEN BROADCAST` — message + target station |
| `_buildCard` | 237 | One hub card; pushes a route or opens a dialog |

### 15.10 `lib/ui/host/views/library_view.dart`

| Symbol | Line | Role |
|---|---|---|
| `LibraryView` | 15 | 4-tab CRUD screen (`ITEMS`, `STATIONS`, `MODIFIERS`, `BACKUP`) |
| `build` | 52 | Gates on `watchStations()`, `DefaultTabController` seeded from `libraryTabIndexProvider` |
| `_buildItemsTab` | 131 | New-item card + item list with tag chips and overflow menu |
| `_buildTag` | 505 | Small uppercase chip |
| `_buildTextField` | 556 | Shared decorated field (label 13 w700, radius 6, dense) |
| `_buildStationsTab` | 571 | New-station card + station rows |
| `_buildGlobalModifiersTab` | 689 | `ADD MODIFIER` + modifier list |
| `_buildBackupTab` | 780 | Export/import + danger zone |
| `_exportLibrary` | 885 | JSON backup via file picker, with share-sheet fallback |
| `_importLibrary` | 935 | Picks a JSON, confirms, merges by name |
| `_showResetLibraryConfirmation` | 1010 | `CLEAR ALL LIBRARY DATA?` |
| `_showAddModifierDialog` | 1047 | `NEW GLOBAL MODIFIER` |
| `_showEditStationDialog` | 1099 | `EDIT STATION` |
| `_showEditItemDialog` | 1157 | `EDIT MENU ITEM` — same fields as the create card |

### 15.11 `lib/ui/host/views/settings_view.dart`

| Symbol | Line | Role |
|---|---|---|
| `SettingsView` | 11 | Sectioned settings list |
| `build` | 15 | Client roster, network, display, format, theme, more |
| `score()` | 111, 317 | IPv4 preference ranking (duplicated per use site) |
| `_buildCard` | 267 | Rounded card container |
| `_buildSectionHeader` | 284 | Grey uppercase section label |
| `_showPairingQRCode` | 299 | `PAIR NEW DEVICE` QR dialog with IP dropdown |
| `_showReassignDialog` | 410 | Station picker for a connected client |
| `_openHotspotSettings` | 448 | Android Wi-Fi tethering deep link |
| `_openBluetoothSettings` | 458 | Android Bluetooth tethering deep link |
| `_showThemePicker` | 468 | Bottom sheet: Light / Dark / System |
| `_themeTile` | 526 | One theme option row |
| `_showResetConfirmation` | 554 | `Reset Everything?` warning dialog |

### 15.12 `lib/ui/host/views/analytics_view.dart`

| Symbol | Line | Role |
|---|---|---|
| `AnalyticsView` | 14 | Sales charts |
| `build` | 18 | Header + `EXPORT CSV`, summary cards, top-5 bars, ranked list |
| `_buildSummaryCard` | 245 | `TOTAL REVENUE` / `ITEMS SOLD` card |
| `_buildChartRow` | 285 | Gradient bar row with top modifiers |
| `_exportSalesReport` | 362 | CSV export of item stats |

### 15.13 `lib/ui/client/client_home.dart`

| Symbol | Line | Role |
|---|---|---|
| `ClientHome` | 22 | Kitchen display screen |
| `initState` | 45 | Landscape lock, immersive mode, loads cached host, starts discovery |
| `_loadLastHostAndStart` | 65 | Reconnects to the last known host |
| `didChangeAppLifecycleState` | 73 | Stops discovery on pause, restarts on resume |
| `_playSound` | 83 | Plays `notification.mp3` at the configured volume |
| `_handleIncomingMessage` | 93 | Socket message dispatch (see §13.5) |
| `_fetchIp` | 169 | Reads non-loopback IPv4 for the header label |
| `dispose` | 184 | Restores orientation/system UI, cancels timers |
| `_startDiscovery` | 201 | mDNS + UDP discovery with backoff |
| `_listenForHosts` | 226 | Watches the discovery stream |
| `_connectToHost` | 251 | Opens the socket, registers the client, starts the watchdog |
| `_handleDisconnect` | 319 | Retry the last host, else restart discovery |
| `build` | 340 | Scaffold, background color, header + grid/list, confetti |
| `_buildAnimatedTicket` | 423 | 600ms elastic scale+fade entrance |
| `_buildConnectionScreen` | 455 | Unused first-run connect/search screen (see known issues) |
| `_showScannerDialog` | 526 | `SCAN PAIRING CODE` — `MobileScanner` + `dartkds://connect` parsing |
| `_buildConfetti` | 592 | Two side blasters on finish |
| `_buildHeader` | 637 | Station chip, connection dot, clock, action icons |
| `_showRecentBumpsDialog` | 768 | `RECENT BUMPS` with `RECALL` |
| `_showBroadcastOverlay` | 844 | Non-dismissible red `NOTIFICATION` |
| `_confirmSwitchRole` | 920 | Role switch confirmation |
| `_showClientSettings` | 949 | `KDS SETTINGS` dialog |
| `_buildSlider` | 1111 | Shared labeled slider (text size, volume) |
| `_buildEmptyState` | 1145 | `QUEUE EMPTY` |
| `_showStationSelectionDialog` | 1169 | `SET STATION NAME` |
| `_showManualConnectDialog` | 1210 | `MANUAL CONNECT` (IP + port) |
| `_TicketCard` | 1266 | One ticket |
| `_TicketCardState.build` | 1288 | Aging colors, border pulse, urgency bar, item list |
| `_buildFooter` | 1537 | `BUMP ALL` / `FINISH` |

