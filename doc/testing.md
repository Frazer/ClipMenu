# Testing

ClipMenu’s interactive UI (NSMenu popups, previews, `/` filter) is hard to cover with plain XCTest. Most coverage lives in **Accessibility / on-screen smoke scripts** under `Resources/scripts/`, plus one **in-process self-test** flag on the app.

Grant **Accessibility** (and sometimes Input Monitoring) to Terminal / your IDE when a script posts HID keys or reads AX trees.

## Quick reference

| What | How to run | Needs Accessibility |
|------|------------|---------------------|
| Preview AX smoke (primary) | `bash Resources/scripts/run_preview_ax_smoke.sh` | Yes |
| Real preview smoke (no UI-test mocks) | `swift Resources/scripts/test_real_preview.swift /path/to/ClipMenu.app` | Yes (keyboard post) |
| External `/` filter smoke | `swift Resources/scripts/test_filter_slash.swift /path/to/ClipMenu.app` | Yes |
| In-process `/` filter self-test | `ClipMenu --seed-clips --self-test-filter-slash` | No |
| XCUITest targets | Xcode `ClipMenuUITests` | N/A (currently skipped) |

Typical Debug app path after `xcodebuild`:

```sh
APP="$HOME/Library/Developer/Xcode/DerivedData/ClipMenu-*/Build/Products/Debug/ClipMenu.app"
# Prefer the newest match if several DerivedData folders exist.
```

Build first if needed:

```sh
xcodebuild -project ClipMenu.xcodeproj -scheme ClipMenu -configuration Debug build \
  CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO
```

---

## Preview tests

### `run_preview_ax_smoke.sh` / `preview_ax_smoke.swift` (primary)

Builds the `ClipMenuTest` scheme, launches with `CLIPMENU_UI_TEST_MODE=1`, and runs AX scenarios:

- status-bar preview
- keyboard popup preview
- submenu preview
- status submenu preview
- scrollable preview

This is the suite UITests defer to. Prefer it for preview geometry regressions.

```sh
bash Resources/scripts/run_preview_ax_smoke.sh
```

### `test_real_preview.swift` (developer smoke)

Launches the **real** `ClipMenu` app **without** `CLIPMENU_UI_TEST_MODE`, opens the hotkey menu via `--seed-clips --open-hotkey-menu`, sends ↑, and checks `CGWindowList` for an on-screen preview window.

Use this when you need confidence that previews work outside the test harness/mocks. It is thinner and more heuristic than the AX smoke runner (window layer/size), so treat it as a manual/CI-adjacent smoke, not a replacement for `preview_ax_smoke`.

```sh
swift Resources/scripts/test_real_preview.swift "$APP"
```

---

## Filter (`/`) tests

### In-process: `--self-test-filter-slash`

Opens the main menu, posts `/` then `a` through the same event-tracking path the menu uses, and asserts filter mode activates without jumping to the first clip row.

```sh
"$APP/Contents/MacOS/ClipMenu" --seed-clips --self-test-filter-slash
# exit 0 = PASS (look for "[FILTER SELFTEST] PASS" on stderr)
```

Related launch flags (also used by scripts):

- `--seed-clips` — insert sample clips when history is empty; bump inline history count for tests
- `--open-hotkey-menu` — open the main hotkey menu shortly after launch (no self-test exit)

### External: `test_filter_slash.swift`

Hosts the built app and drives `/` via HID + Accessibility. Useful as a second opinion; the in-process self-test is usually enough for day-to-day filter work.

```sh
swift Resources/scripts/test_filter_slash.swift "$APP"
```

---

## XCUITests

`UITests/ClipMenuUITests.swift` cases are intentionally `XCTSkip`’d and point at `run_preview_ax_smoke.sh`. Native NSMenu tracking does not automate reliably through XCUITest alone.

---

## Environment notes

- `CLIPMENU_UI_TEST_MODE=1` — enables paste/preview harness behavior used by AX smoke and some UI test helpers. **Omit** it for `test_real_preview.swift`.
- Scripts under `Resources/scripts/` that talk to the live UI may force-quit existing ClipMenu instances for the target bundle ID before launching.
