# NOTES — decisions, hardware findings, what worked / didn't

## 2026-11-10 — M0 toolchain and scaffolding

### Machine
- MacBook Pro 14" 2021 (MacBookPro18,3), Apple M1 Pro, 16 GB, macOS 26.6.2 (25G83).
- Tablet: not yet seen over adb — model, Android version and resolution still to be detected.

### Toolchain
- Present: Homebrew, Xcode **Command Line Tools** 26.5 (Swift 6.3.2). Full Xcode is NOT installed.
- Installed via Homebrew: `openjdk@17`, `gradle` (only used to generate the wrapper),
  casks `android-commandlinetools` and `android-platform-tools`.
- Installed via sdkmanager into `/opt/homebrew/share/android-commandlinetools`:
  `platforms;android-35`, `build-tools;35.0.0`, `platform-tools`.
- `source env.sh` sets JAVA_HOME / ANDROID_HOME / PATH for builds.

### Decisions
- **No Xcode needed.** The Mac app is a SwiftPM package built with `swift build`; `mac/scripts/bundle.sh`
  assembles and signs `TabletPen.app` by hand. Saves a ~15 GB Xcode install and works with free signing.
  Trade-off: no SwiftUI previews / Interface Builder, and tests use Swift Testing (XCTest ships only
  with Xcode). `mac/scripts/test.sh` adds the CLT framework paths Swift Testing needs.
- **Stable signing = self-signed certificate** "TabletPen Dev" in the login keychain
  (`mac/scripts/make-identity.sh`). TCC keys the Accessibility grant to the signing certificate, so
  rebuilds keep the permission. Ad-hoc signing would reset it on every build. Not created yet — it
  triggers a keychain prompt, so it is done at the start of M1 together with the Accessibility grant.
- **adb path:** the Homebrew cask `adb` (`/opt/homebrew/bin/adb`) is killed on launch (exit 137) because
  the cask binary carries the quarantine attribute. I did not strip quarantine; the sdkmanager copy at
  `/opt/homebrew/share/android-commandlinetools/platform-tools/adb` works and is what `env.sh` and the
  Mac app use. The cask can be removed: `brew uninstall --cask android-platform-tools`.
- **Android build:** Gradle 8.11.1 wrapper, AGP 8.9.1, Kotlin 2.1.20, Compose BOM 2025.04.00,
  minSdk 29, target/compileSdk 35. App id `dev.tabletpen.app`.
- **Protocol:** see `protocol/SPEC.md`. Length-prefixed little-endian frames on TCP 27183, 17-byte
  samples, historical samples included, curves applied on the Mac. Shared hex vectors in
  `protocol/vectors/frames.txt` are checked by both test suites (Kotlin 6 tests, Swift 6 tests, all pass).
- **Inspector** uses a plain `View` inside Compose (`AndroidView`) rather than Compose pointer input,
  so MotionEvents are seen raw (history, hover, generic motion, unbuffered dispatch). Everything is
  also written to logcat tag `TPInspect` (lines: SYS, DEV, EV, KEY, STAT) so results can be read
  over adb instead of by eye.

### Status
- Android inspector APK builds; not yet installed (no device attached).
- Mac menu-bar skeleton builds, bundles (ad-hoc signed for now) and launches.
- Git repo initialised, nothing committed yet.

### Open hardware questions (answered once the tablet is connected)
- Exact model / Android version / resolution / refresh modes.
- Pen sample rate and history depth; real pressure range and number of distinct levels.
- Whether AXIS_TILT and AXIS_ORIENTATION are reported, and how noisy tilt is.
- Hover distance reporting; side button as BUTTON_STYLUS_PRIMARY vs Bluetooth KeyEvent.

## 2026-11-10 — M0 hardware findings (inspector run on the real tablet)

Raw log: `protocol/recordings/m0-inspector-logcat.txt`.

### Devices
- Tablet: **Lenovo Idea Tab Pro 12.7" (TB373FU)**, MediaTek MT8792, Android 16 (SDK 36, ZUI 17.5),
  1840×2944 native (2944×1840 landscape), ~273 dpi → 10.8 × 6.7 in. Display modes 144/120/60/30 Hz.
- Touch digitizer: `NVTCapacitiveTouchScreen`. Pen digitizer: `touch-pen` (source 0x5002 = TOUCHSCREEN|STYLUS).
- Pen over Bluetooth LE shows up as two HID devices: `Lenovo Tab Pen Plus Mouse` and
  `Lenovo Tab Pen Plus Consumer Control`.

### Fingers
- ~120 Hz (8.3 ms between samples), mostly one sample per event, occasionally 1–2 historical.
- Pressure is always 1.0 (no finger pressure); size is reported.
- **Three fingers are taken by the system.** As soon as a third finger lands, ZUI sends the app
  ACTION_CANCEL (its three-finger screenshot / split-screen gestures are enabled:
  `three_finger_slide_down_enabled=1` etc.). The app never sees 3 pointers. So three-finger drag only
  works if those ZUI gestures are turned off (Settings → General settings → gestures); the fallback
  that always works is tap-and-drag (double-tap, hold, drag).

### Pen
- **~240 Hz** (4 ms between samples), up to 235 samples/s observed, usually delivered unbatched
  (history 0), sometimes 1–4 historical, once 9. Well above the 144 Hz display, so the pipeline must
  forward every sample rather than one per frame.
- Pressure: 0.009–0.96 observed, 1204 distinct values in a 30 s test. Lightest strokes 0.02–0.09,
  normal writing 0.45–0.70, hard 0.85–0.96. Default curve is built from these.
- Tilt (AXIS_TILT) is reported, 9°–70°, also while hovering. **A normal writing grip already reads
  ~45°**, upright ~10°, "shading" lean 60–70°. That is why tilt "triggers too easily": apps treating
  any tilt as intentional see a big value all the time. Default tilt dead zone is therefore set
  around the natural grip (below ~50° counts as no tilt), not near 0°.
- AXIS_ORIENTATION is reported over the full −π..π range.
- Hover works (HOVER_ENTER/MOVE/EXIT) but AXIS_DISTANCE is a constant 1.0 — no hover height.
- **Side button: never in MotionEvent.buttonState.** It arrives only as KeyEvents from the Bluetooth
  `Consumer Control` device, with vendor key codes: single click = keycode **601** (DOWN then UP a
  few ms apart), double click = **602** (UP only), long press = **603** (UP only). They arrive
  whether or not the pen is near the screen, and the app can capture them while it is in the
  foreground. Consequences: the button is a *click*, not a held state (no "hold button while
  dragging"), and there is a delay inherent in Lenovo's click/double/long classification.
  Mapping: 601 → right-click; 602 and 603 are free for shortcuts.
- Palm: the system's own palm rejection (`pen_dynamic_palm_rejection=1`) already suppressed palm
  touches during the pen-writing test; the app adds its own guard anyway.

## 2026-11-10 — M1 built; Scratchpad added (user request)

### M1 (USB + trackpad) — built, awaiting hands-on confirmation
- Link verified on hardware: Mac app finds adb, runs `adb reverse tcp:27183`, tablet connects, HELLO
  reports a 2944×1730 capture surface at 273 dpi. Cursor injection needs the Accessibility grant.
- The Mac listener is bound to loopback only until Wi-Fi pairing/encryption exists (M4), so nothing on
  the network can inject input.
- Signing: self-signed "TabletPen Dev" certificate in its **own keychain**
  (`~/Library/Keychains/tabletpen-dev.keychain-db`, fixed password) rather than the login keychain —
  no keychain prompts, and the login keychain is untouched. Designated requirement is
  `identifier "dev.tabletpen.mac" and certificate leaf = H"f5be…"`, stable across rebuilds.
- Pinch zoom uses the undocumented gesture CGEvent (type 29, subtype 8). No public API exists.
  `TabletPen --selftest` checks that macOS really delivers it (and moves, clicks, scroll phases).
- Defaults: fingers relative, pen absolute, letterbox. Finger tap = left, two-finger tap = right,
  three-finger tap = middle. Pen button click = right-click.
- The tablet reported 120 Hz at connect although the app requests the 144 Hz mode; ZUI seems to
  pick the mode itself. Input rate is independent of this (pen 240 Hz); revisit for ink rendering in M2.
- Tests: 37 Swift tests (protocol, gestures, pen, palm rejection, mapping, curves, clock sync),
  6 Kotlin protocol tests. Replay test with a real recorded session is still to do (menu →
  "Record input session" writes the raw stream to ~/Library/Application Support/TabletPen/recordings).

### Scratchpad (tablet only)
- Third tab next to Trackpad and Inspector. One unbounded canvas: pen writes, one finger pans, two
  fingers pan + pinch-zoom (5 %–1600 %), dot grid thins out when zoomed out.
- Tools: pen (pressure → width), highlighter, stroke eraser, "Move image" (drag to move, drag the
  corner dot to resize, delete). 6 colours, 3 widths, undo/redo (300 steps, not kept across restarts).
- Images: "Paste image" reads an image from the Android clipboard; "Add image" opens the system
  photo picker. Images are downscaled to max 2560 px and copied into app storage; they draw under
  the ink so you can write on them.
- Pen side button here: click = toggle eraser, double click = undo, long press = redo.
- Storage: `files/scratchpad/doc.bin` + `img-*` files, format documented in `ScratchDoc.kt`.
  Autosaves 0.8 s after each change (atomic temp-file rename) and when leaving the tab/app.
- Rendering is a normal hardware-accelerated View with unbuffered input, not yet the AndroidX
  front-buffered low-latency path; that comes with the M2 ink engine and will be shared.
- Verified over adb: stylus strokes render, finger pan works, content and view position survive a
  force-stop. NOT verified by me: image paste/pick (needs a real clipboard/photo) and feel with the
  real pen — injected stylus events have no pressure or hover.
- Self-test (`open -n -W --stdout out.txt mac/dist/TabletPen.app --args --selftest`) passes on this
  Mac: absolute + relative moves, click/double-click counts, drag, right-click, scroll deltas with
  began/changed/ended and momentum phases, and the private pinch event (apps receive `magnify`).
  It caught a real bug: at 240 Hz the system-reported cursor position lags what was just posted, and
  re-reading it each move discarded movement. The injector now only resyncs after a 150 ms pause.
- The Accessibility grant survived a rebuild → the self-signed identity works as intended.
- Measured latency in real use (tablet event timestamp → CGEvent posted, over USB, ~10 min of use):
  typically 4–6 ms average per half-second window, occasional spikes up to ~55 ms. Target was < 20 ms.

## 2026-11-10 — Trackpad click/drag fixes; scope closed

User feedback: drag felt "sticky", and a single click sometimes registered as a double. No event
recording existed for that session, so the causes below are inferred from the code, not observed.

- **Sticky start:** every touch had a 0.04 in (1 mm) dead zone before the cursor followed, which also
  delayed the start of a tap-and-drag. Now the cursor follows after 0.02 in; a touch only stops
  counting as a tap after 0.05 in of travel.
- **Unwanted drags / second click:** tapping and then touching again within 0.30 s to move the cursor
  was treated as tap-and-drag (button down → up = a second click at the same spot). The window is now
  0.25 s and the second touch must land within 0.6 in of the tap.
- **Double from one tap:** a touch landing < 40 ms after a lift is treated as contact bounce and
  ignored; taps only chain into a double-click within 0.35 s *and* 0.6 in of each other. Same bounce
  rule for the pen tip.
- Every click decision is now written to `~/Library/Logs/TabletPen.log` (`button left down clicks=…`)
  so remaining mis-clicks can be diagnosed from real timings.
- 42 Swift tests pass (5 new for the cases above). Not yet confirmed by the user on hardware.

**Scope:** the user decided this is enough — M2–M6 (notes app, live sync, Wi-Fi, drawing-tablet mode,
shortcut panel, annotate) are not being built. The project is: USB trackpad/mouse mode, the
tablet-only Scratchpad, and the Inspector. The recorded-session replay test was not done.
