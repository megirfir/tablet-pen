# TabletPen

Turns a Lenovo Idea Tab Pro + Tab Pen Plus into a pen/touch input device for a Mac.

- `android/` — Kotlin + Compose tablet app (captures pen and touch, note-taking).
- `mac/` — Swift menu-bar app (receives input, posts pointer/scroll/keyboard events).
- `protocol/` — wire protocol spec and shared test vectors.
- `NOTES.md` — decision log and hardware findings.

**What it does:** USB trackpad/mouse mode (fingers and pen), a Mirror tab (the Mac's screen on the
tablet, with touch/pen control and tablet-only doodles on top), a tablet-only Scratchpad (infinite
canvas with ink and images), and an input Inspector. The originally planned notes app, Wi-Fi
connection, drawing-tablet mode, shortcut panel and annotate mode were dropped and are not built.

## Setup (once)

```sh
brew install openjdk@17
brew install --cask android-commandlinetools
source env.sh
yes | sdkmanager --licenses
sdkmanager "platforms;android-35" "build-tools;35.0.0" "platform-tools"
```

Xcode is not required; the Command Line Tools are enough (`xcode-select --install`).

On the tablet: Settings → About tablet → tap **Build number** 7 times, then
Settings → System → Developer options → enable **USB debugging**. Connect with a USB-C **data**
cable (charge-only cables won't show the device) and accept the "Allow USB debugging?" prompt.

## Build and run

```sh
source env.sh

# Android
cd android && ./gradlew installDebug          # build + install on the connected tablet
./gradlew testDebugUnitTest                    # protocol tests
adb logcat -s TPInspect                        # inspector output

# Mac
cd mac && scripts/test.sh                      # unit tests
scripts/bundle.sh && open dist/TabletPen.app   # menu-bar app
```

## Usage

1. Plug the tablet in over USB and start the Mac app (`open mac/dist/TabletPen.app`). The first time,
   run `mac/scripts/make-identity.sh` once before `bundle.sh`, then allow TabletPen under
   System Settings → Privacy & Security → Accessibility.
2. Open TabletPen on the tablet. The top bar shows the connection and live latency.

**Trackpad tab** — one finger moves, tap clicks, two-finger tap right-clicks, two fingers scroll
(with momentum) or pinch to zoom, double-tap-and-drag drags. Pen: hover moves, touch clicks/drags,
side button right-clicks. Relative/absolute, sensitivity, acceleration, target screen and gesture
options are in the Mac menu-bar icon → Settings.

**Mirror tab** — shows the Mac's screen (the display chosen under Settings → Screen, default main).
The first time, macOS asks for **Screen Recording** permission for TabletPen (System Settings →
Privacy & Security → Screen Recording); the picture appears once it is allowed.
- Fingers always control the Mac where they touch: tap = click there, two-finger tap = right-click,
  two fingers = scroll / pinch, double-tap + drag = drag, one finger moving = move the cursor.
- Pen, chosen in the toolbar: **Doodle** (ink over the picture), **Erase** (removes whole strokes),
  or **Control Mac** (hover moves the cursor, touch clicks/drags, side button right-clicks).
- Doodles exist only on the tablet — nothing is drawn on the Mac — and are not saved. They stay
  where you drew them on the glass, so they do not follow the page when the Mac scrolls; use
  Clear doodles when you move on.
- Pen side button while doodling: click switches draw/erase, double click undoes, long press redoes.

**Scratchpad tab** (works without the Mac) — endless canvas. Pen writes; one finger pans, two fingers
zoom. Paste an image from the clipboard or add one from Photos, move/resize it with "Move image",
and write on top. Pen button: click toggles the eraser, double click undoes, long press redoes.

**Inspector tab** — live dump of every pen/touch event, also in `adb logcat -s TPInspect`.

Three-finger drag needs Lenovo's own three-finger gestures switched off on the tablet (they
intercept the touches before any app sees them).
