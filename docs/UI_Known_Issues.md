# DartKDS — Known UI Issues

Rough edges and outright bugs found while documenting the UI in [`UI.md`](UI.md).

## Open

_Nothing currently open._

Everything previously listed here has been fixed. The entries below are kept
so the next person does not re-investigate them. **Line references were
re-checked on 17 Oct 2026** — several had drifted, and the corrections are called
out where they matter.

## Fixed

### The app did not compile — fixed

`lib/ui/host/views/order_intake_view.dart` had a syntax error that made the
whole project unbuildable: the item list's `trailing` row carried a duplicated
close (`],` then `),` a second time), left over from moving the quantity stepper
into the row. The parser lost sync from there and reported 63 errors, nearly all
of them bogus follow-ons (`Padding` "2 positional arguments expected", `Undefined
name theme`) that obscured the single real cause.

Worth remembering: because this file would not compile, the layout tests that
import it could not load either. Several layout bugs below were already present
and simply invisible. A file that does not parse is not just a broken feature —
it silences its own regression tests.

### 4. A ticket taller than the board scrolls with no indication — fixed

`lib/ui/client/client_home.dart` — the item list inside `_TicketCard` is bounded
by the card, so an order with more items than fit, or `clientTextScale` at its
2.0 maximum (which grows the rows without growing the card), still truncates.
Issue #6 gave every tile the full board height instead of a share of it, which
fixed the common case but left the list bounded.

The list is now wrapped in a `Scrollbar` with `thumbVisibility: true`, so the
control is always on screen. A full-length thumb means everything fits; a short
one means there is more below. It uses an explicit `ScrollController` rather
than the primary one, because the board is a horizontal strip of cards and a
shared controller would put two scrollables on one position.

### History card layout and action button — fixed

`lib/ui/host/views/sent_queue_view.dart`

- The card header `Row` gave neither child a flex, so a long guest name overflowed
  the card and painted over the timestamp and the action chip. The label side is
  now `Expanded` with the name ellipsising; the same applied to the per-item rows
  so a long item name no longer runs into the price.
- `ADD ITEMS` / `EDIT` was an `InkWell` wrapped around a bare `Container` — about
  a 22px tap target, no button semantics, no border and no press feedback, so it
  read as a static label. It is now a real Material button: 40px minimum target,
  visible ripple, a tinted border, and a `Semantics` label naming the order and
  the action rather than just the raw button text. The timestamp moved inside it.

### Intake fields recreated on every rebuild — fixed

`lib/ui/host/views/order_intake_view.dart` — the guest-name and order-note
`TextField`s built a fresh `TextEditingController` inline in `build`. Because every
keystroke writes through `onChanged` and rebuilds, the caret was thrown back to the
end of the field after each character, so typing into the middle of a name was
impossible; one controller also leaked per rebuild. Both are now view-scoped,
disposed in `dispose`, and synced from state only when the text actually differs.

### Menu header overflows on a 360px phone — fixed

`lib/ui/host/views/order_intake_view.dart` — the FILTERS row overflowed the
header by ~23px on a 360px phone, clipping the sort caret off the right edge.
The row is `[icon, label, active-filter badge, Spacer, sort dropdown, caret]`;
the label and the badge are the only children that can grow, so they are the
ones now wrapped in `Flexible` with an ellipsis. The `Spacer` and dropdown keep
their natural size.

Note for anyone re-investigating: the first attempt wrapped the **search field**
in `Expanded`, on the theory that the field and the FILTERS button were
competing for width. They are not — they are stacked vertically. That change
was also invalid on its own terms: the header `Column` sits inside a `Container`
with no fixed height, so it is laid out with unbounded height and a flex child
there cannot lay out at all. Reverted.

### Order summary overflows its sheet on a short screen — fixed

`lib/ui/host/views/order_intake_view.dart` — on a 360×560 screen the summary
sheet's fixed chrome (header, ITEMS count row, order-note field, divider, send
button) exceeded the sheet's own height, so the `Expanded` item list was
squeezed to zero and the `Column` overflowed by ~20px. The auto-commit that
added the order-note field did not revisit `_bottomSheetHeight`, which still
hands out `screenHeight * 0.4` — 224px here, less than the chrome needs.

Raising the sheet's minimum height would only have moved the cliff to a
slightly smaller screen, so instead everything above the send button now scrolls
as a single unit (`Expanded` + `SingleChildScrollView`) with the item list
switched to `shrinkWrap`, and the send button stays pinned below it. That drops
the assumption that the chrome always fits, which is the actual invariant that
was violated. The button is the one thing that must never scroll away, so it
stays outside the scroll view.

### 1. `Reset Application` does nothing — fixed

`lib/ui/host/views/settings_view.dart` — `RESET` used to only
`Navigator.pop(context)`. It now calls `_resetEverything`, which clears the
library and the sales/history stores and reports failure in a snackbar instead
of swallowing it.

An earlier version of this file also recorded a follow-up: that the reset was
confirmed **twice** (`Reset Everything?` followed by a second `Delete for good?`
dialog), and that the two disagreed on scope. **That is no longer true.**
There is now a single `Reset Application?` dialog, and its body states the full
scope up front — "Menu items, stations and order history will be deleted, and
every connected display will clear its board."

### 2. Grid helper has a dead branch — fixed

`lib/ui/shared/responsive_utils.dart` — the mid-width case is now
`2.clamp(min, max)` and the fallback `min.clamp(1, max)`, so `min: 1` actually
collapses to a single column.

### 3. Client settings cannot select System theme — fixed

`lib/ui/client/client_home.dart` — `APPEARANCE` offers `Auto` / `Light` /
`Dark`, and `selected: {settings.themeMode}` reports the real setting rather
than always showing `Dark`.

### 5. `TabBar` indicator color differs between the two tabbed screens — fixed

`lib/ui/host/views/library_view.dart` now uses
`indicatorColor: colorScheme.primary`, matching `sent_queue_view.dart`.

### 7. Duplicated IP ranking function — fixed

Both call sites now go through `HostServer.rankLanAddress`, so the address shown
in settings and in the pairing QR code is the one the host would have picked for
itself.

### 8. Deletions in the library have no confirmation — fixed

`lib/ui/host/views/library_view.dart` — the item overflow menu, the station
trash icon and the global-modifier trash icon all route through a new
`_confirmDelete` helper, which names the row being destroyed and matches the
`CLEAR ALL LIBRARY DATA?` dialog styling already in the file.

### 9. `_buildConnectionScreen` is never called — fixed

`lib/ui/client/client_home.dart` — `build` now returns it on first run
(`!_isConnected && !_hasConnectedBefore`), so QR scan, manual connect and
re-scan are reachable again.

### 10. Client alarm volume may be write-only — not a bug

`settings.clientVolume` is applied correctly. `_audioPlayer` is a single
long-lived `AudioPlayer` instance held by the client state, and `_playSound` sets
the volume on that same instance immediately before `play`. There is no
per-play recreation, so the value takes effect.

## 6. Hardcoded greys bypass the theme — closed, no code change needed

`#666666`, `#111111`, `#6B7280` and `#1F2937` are spread across `library_view`,
`order_intake_view`, `settings_view`, `analytics_view`, `client_home`,
`inventory_view`, `more_view` and `sent_queue_view`.

**Were fixed** — the secondary-text cases, which are the ones that actually
vanish in `high contrast` mode:

- `analytics_view` — `PERFORMANCE BY ITEM` heading and the summary-card labels
  now use `theme.hintColor`
- `settings_view` — `_buildSectionHeader` and the empty-state row now use
  `theme.hintColor`

**The rest were left alone deliberately.** The remaining greys are not hint
colours, so a blanket "replace with `hintColor` / `cardColor` / `dividerColor`"
would have made things worse:

- `#111111` and `#1F2937` are mostly *deliberate brand near-blacks* — primary
  button fills paired with `foregroundColor: Colors.white`, selection fills,
  snackbar surfaces, slider active thumbs. Recolouring these to a grey token
  would drop them straight out of contrast. `client_home.dart:600` (the
  `RE-SCAN FOR HOST` button) is one of these, not a theming fault.
- `sent_queue_view.dart:435` (was `:381`) is a *semantic status colour* for the
  `CLOSED` order state, not a hint.
- `library_view.dart:466` (was `:413`) and `more_view.dart:72` pass a dark grey
  in as the text/icon colour of a light chip; `hintColor` there would be too pale.
- `client_home.dart:814` looks like a hardcoded surface but is already correct
  — it is the `else` fallback of a chain that branches on `highContrast` and
  `light` first.

**A claim in an older version of this file was simply wrong.** It stated that
`client_home.dart:933`, `:1339` and `:1379` each hardcoded
`AlertDialog(backgroundColor: Color(0xFF1F2937))` and ignored the light board.
Re-checked: all four dialogs — recent bumps (`:952`), KDS settings (`:1141`),
station name (`:1378`) and manual connect (`:1424`) — already branch on
`isLight ? Colors.white : const Color(0xFF1F2937)` and pair the background with a
matching title/content colour. The old line numbers had simply drifted onto
dialogs that were already right, which made the group look broken when it was
not. No shared helper is needed.