# FalcoFold — build plan

> **Working title.** FalcoFold is a free, open-source macOS app inspired by [Bendy](https://trybendy.app). Don't use Bendy's name, logo, website copy or sound files. Write our own.

## What it does

As the MacBook lid comes down, the desktop tilts, blurs and darkens. When the lid opens past a set angle, the desktop snaps back to normal and a soft click plays.

- Reads the hinge angle from the Mac's built-in lid angle sensor.
- Captures the built-in display live and draws the effect with Metal in a click-through overlay, so windows and wallpaper move together.
- Three styles: **Silk**, **Shade** and **Frost**. Each has sliders for perspective, blur and shadow, plus a setting for the angle where the effect clears.
- Follows the lid automatically, or lets you drag the angle by hand.
- If the lid stops partway while opening, the desktop snaps back right away instead of waiting for the clear angle. It comes back once the lid closes a few degrees again.
- Lives in the menu bar. Click to pause, or press Esc while the effect is showing.
- No sound when the desktop clears

## Project decisions

| Topic | Decision |
|---|---|
| License | MIT (freeware, open source) |
| Money | None: no payments, license keys, accounts or promo codes |
| Network | None: no telemetry, no update checks. Frames never leave the Mac. |
| Distribution | **Private** GitHub repo (owner `pietrouk`), shared with invited collaborators. Zipped `.app` in that repo's Releases, plus build-from-source instructions. Never make anything public without asking. |
| Signing | No notarization and no Developer ID. See "Signing and permissions" below. |
| Min OS | macOS 14 Sonoma |
| Hardware | Apple silicon MacBook with a lid angle sensor |
| Language / UI | Swift, SwiftUI (MenuBarExtra and Settings), AppKit for the overlay window, Metal |
| Project format | [XcodeGen](https://github.com/yonaskolb/XcodeGen) `project.yml` checked into git, with the generated `.xcodeproj` gitignored. If XcodeGen isn't available, use a hand-made Xcode project. |

## Dev machine facts (checked 2026-09-17)

- MacBook Pro M3 Pro (`Mac15,7`), running macOS 27 (Darwin 27).
- The lid sensor is present: HID vendor `0x05AC`, product `0x8104`, usage page `0x20`, usage `0x8A` (`las` in `hidutil list`).
- Only the Command Line Tools were installed, not Xcode. **Install Xcode before starting**, then run `sudo xcode-select -s /Applications/Xcode.app` and confirm with `xcodebuild -version`.

## Architecture

```
LidSensor ──angle──▶ LidState (smoothing, hysteresis, mapping to 0…1 progress)
                          │
                          ├─▶ CaptureController (ScreenCaptureKit, runs only while armed)
                          │         │ CVPixelBuffer → CVMetalTextureCache → MTLTexture
                          │         ▼
                          └─▶ OverlayWindow + MetalRenderer (tilt, blur, shade)
AppSettings (UserDefaults) ─▶ style presets, sliders, clear angle, sound, launch at login
MenuBar / Settings UI (SwiftUI)
```

### LidSensor
- Use `IOHIDManager` to find the device by the vendor, product and usage values above.
- Known approach (from the open-source LidAngleSensor project; **verify in M1**): read feature report ID 1 with `IOHIDDeviceGetReport`. The angle in degrees is a 16-bit little-endian value in bytes 1–2.
- Bendy says it doesn't poll. Try an input-value callback first. If the device only answers feature-report requests, poll at ~60 Hz but only while the app is active.
- Reopen the device after sleep/wake. If the device is missing, show "unsupported hardware" in the menu instead of crashing.

### LidState
- Low-pass or spring smoothing on the raw angle, with hysteresis around the arm and clear thresholds.
- Mapping: `progress = clamp((clearAngle − angle) / (clearAngle − closedAngle), 0, 1)`.
- **Armed** when the angle drops below the clear angle, which starts capture and shows the overlay. **Cleared** when the angle goes back above the clear angle plus hysteresis, which snaps back, plays the click, hides the overlay and stops capture.
- Manual mode uses a slider value instead of the sensor. **This is also how Claude can test visuals without anyone moving the lid.**

### CaptureController
- `SCStream` on the built-in display only (`CGDisplayIsBuiltin`), BGRA, cursor shown.
- Frame rate matches the display (120 Hz on ProMotion).
- Use `SCContentFilter(display:excludingApplications:[self])` so the overlay never captures itself. Don't rely on `NSWindow.sharingType = .none`.
- Measure how long the stream takes to start. If there's a visible lag when arming, keep a low-fps stream warm while the angle is in a "near clear" band.
- Check access with `CGPreflightScreenCaptureAccess()` and request it with `CGRequestScreenCaptureAccess()`. Newer macOS versions re-ask periodically, so handle revoked access gracefully.

### OverlayWindow + MetalRenderer
- Borderless `NSWindow` covering the built-in display, with `ignoresMouseEvents = true`, level above normal windows (e.g. `.screenSaver`), and `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]`.
- `MTKView` draws a textured quad that rotates about the hinge (bottom edge) with a perspective projection driven by `progress × perspective`.
- "Holds its place from where you sit": add an option to counter-rotate so the image stays visually stable relative to the viewer, then snap back on clear.
- Blur uses `MPSImageGaussianBlur`, with sigma set by `progress × blur`.
- Shade uses a gradient darkening in the fragment shader, set by `progress × shadow`.
- Presets:
  - **Silk**: perspective-led
  - **Shade**: shadow-led
  - **Frost**: blur-led
  - Every slider stays editable.
- Keep shaders in a `.metal` file, which works once Xcode is installed. Fallback: compile from a source string with `device.makeLibrary(source:)`.

### App shell
- `MenuBarExtra` menu: Pause/Resume, style picker, manual-angle toggle and slider, Settings…, Quit.
- Settings tabs:
  - **General**: launch at login via `SMAppService`, sound on/off, pause
  - **Style**: preset, sliders, clear angle
  - **About**: version, GitHub link, license
- **Esc** without Accessibility permission: register a Carbon `RegisterEventHotKey` for Esc only while the effect is armed, and unregister it on clear. Never grab Esc globally.
- Click sound: our own short CC0 or self-made `.caf`, played with `NSSound`.
- First launch walks the user through granting Screen Recording and checking the sensor.

## Signing and permissions

- **During development**, sign with a stable identity: a free Apple ID "Personal Team" Apple Development certificate in Xcode, or a self-signed code-signing certificate from Keychain Access. Screen Recording permission is tied to the code signature. With plain ad-hoc signing, macOS asks for permission again after every rebuild.
- **Release builds** are unsigned or ad-hoc. The README must explain:
  - how to open an app from an unidentified developer (System Settings → Privacy & Security → Open Anyway)
  - that Screen Recording may need to be granted again after each update

## Milestones

Check the usage meter (`get_usage`) at the start of the session and after every milestone. Report how much each milestone used and project the rest.

| # | Milestone | Done when | Model |
|---|---|---|---|
| M0 | Setup | Xcode active, `git init`, `project.yml`, `LICENSE` (MIT), `README` stub, `.gitignore`. An empty menu bar app builds and runs. | Sonnet |
| M1 | **Risky core** | Live lid angle shown in the menu. The overlay shows the live desktop tilting as the angle changes (manual slider and real lid). **Stop and report usage here.** | Opus |
| M2 | Effects | Perspective, blur and shade; three presets; smoothing, hysteresis, clear angle, snap-back; counter-rotate option | Opus |
| M3 | App shell | Settings UI, pause, Esc hotkey, click sound, launch at login, permission onboarding | Sonnet |
| M4 | Hardening | Built-in display only; clamshell mode (lid closed with external monitor → disabled); sleep/wake; display changes; full-screen Spaces; no capture when fully open; CPU/GPU check in Instruments | Opus |
| M5 | Open-source release | README with GIF, build instructions, Gatekeeper and permission notes, a GitHub Release with a zipped `.app` | Sonnet |

## Test checklist
- [ ] Lid from fully open to ~10° and back: smooth, no flicker, snaps back cleanly
- [ ] Overlay never appears in its own capture (no infinite tunnel)
- [ ] Clicks and typing pass through the overlay
- [ ] Esc pauses while armed and doesn't steal Esc otherwise
- [ ] External monitor attached, lid closed (clamshell): nothing happens
- [ ] Sleep/wake and display changes: sensor and capture recover
- [ ] Full-screen app, Mission Control, Stage Manager
- [ ] Screen Recording denied or revoked: clear message, no crash
- [ ] Idle with lid fully open: ~0% CPU, no active capture
- [ ] Mac without the sensor: "unsupported" message

## Out of scope
License keys, payments, Developer ID signing, notarization, auto-update (Sparkle), App Store, telemetry, the marketing website.
