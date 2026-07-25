# Trackpad Studio — build contract

A native macOS app (AppKit, Swift, SPM executable — no Xcode project, no third-party
deps) that showcases everything a Mac trackpad can do. Two tabs:

- **Capability** — live visualization of every trackpad signal we can read.
- **Board** — an Excalidraw-like canvas driven directly by raw trackpad touches.

Build: `swift build` in the repo root. Run: `swift run TrackpadStudio`.
Window appears because main.swift sets activation policy `.regular` and activates.

## Why native (recorded assumption)

Browsers cannot see per-finger trackpad data at all (trackpad = relative mouse;
pinch arrives as ctrl+wheel; force only in Safari during clicks). The MVP needs
absolute per-finger positions → AppKit `NSTouch` (public) + the private
MultitouchSupport framework (optional, for per-finger size / "weight").

## Already written — read these first, code against them, DO NOT EDIT

- `Package.swift` — targets `CMultitouchShim` (C header shim) + `TrackpadStudio`.
- `Sources/CMultitouchShim/include/CMultitouchShim.h` — private-framework struct
  layout + function-pointer typedefs (`MTShimTouch`, `MTShimContactCallback`, …).
- `Sources/TrackpadStudio/TrackpadCore.swift` — `TouchSample`, `InputEvent`,
  `TouchCaptureView` (embed as lowest bounds-filling subview; set `onEvent`),
  `TrackpadGeometry` (padRect / map helpers).

## File ownership (STRICT — write only your own files, never a sibling's)

| Agent | Files |
|---|---|
| A | `Sources/TrackpadStudio/main.swift`, `Sources/TrackpadStudio/AppShell.swift`, `Sources/TrackpadStudio/MultitouchBridge.swift` |
| B | `Sources/TrackpadStudio/CapabilityTab.swift` |
| C | `Sources/TrackpadStudio/BoardTab.swift`, `Sources/TrackpadStudio/BoardModel.swift` |

## Cross-agent public API (exact names/signatures — the seams)

Agent A implements in `MultitouchBridge.swift`:

```swift
struct MTFingerSample {
    let id: Int
    let pos: CGPoint      // normalized 0..1, origin bottom-left
    let size: Double      // capacitive contact size (a.u.); ~0.1 light graze … ~1.5+ firm pad
    let majorAxis: Double // mm
    let minorAxis: Double // mm
    let angle: Double     // radians
}

final class MultitouchReader {
    static let shared = MultitouchReader()
    private(set) var isAvailable: Bool   // false if dlopen/dlsym/device fails — NEVER crash
    private(set) var fingers: [MTFingerSample]  // latest frame, main-thread updated
    var onFrame: (([MTFingerSample]) -> Void)?  // called on main thread
    func start()   // idempotent
    func stop()
}
```

Agent A implements in `AppShell.swift` + `main.swift`: `NSApplication` bootstrap
(activation policy `.regular`, `activate`), minimal main menu (app menu with
About/Quit ⌘Q, Window menu with Close ⌘W), one `NSWindow` 1200×800 (min 900×600)
titled "Trackpad Studio", containing an `NSTabView` with two tabs:
`CapabilityTabView()` labeled "Capability" and `BoardTabView()` labeled "Board".
Call `MultitouchReader.shared.start()` at launch. Terminate after last window
closed. A references `CapabilityTabView` / `BoardTabView` only as
`final class …: NSView` with a plain `init()` — agents B and C must provide
exactly that.

Agent B implements: `final class CapabilityTabView: NSView { init() }`.
Agent C implements: `final class BoardTabView: NSView { init() }`.

## MultitouchBridge implementation notes (agent A)

`dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_NOW)`,
dlsym `MTDeviceCreateDefault`, `MTRegisterContactFrameCallback`, `MTDeviceStart`
(second arg 0), `MTDeviceStop`, `MTDeviceRelease`; cast through the typedefs in
`CMultitouchShim.h` (`import CMultitouchShim`). The C callback cannot capture
context — route through a file-private global/static, hop to the main queue,
then publish `fingers` / call `onFrame`. Any failure at any step ⇒
`isAvailable = false`, app keeps running on public APIs only. Only include
touches with state "touching" (state 4) or near (1..7 is fine — keep simple:
include all reported fingers with size > 0.05).

## Capability tab spec (agent B)

Full-bleed dark canvas look. Layout (custom `draw(_:)` is fine; a few AppKit
controls allowed):

- Left ~65%: big trackpad outline (`TrackpadGeometry.padRect`, aspect from the
  latest `TouchSample.deviceSize`, fallback aspect if none yet). Live fingers
  drawn inside: if `MultitouchReader.shared.isAvailable`, draw real ellipses
  (majorAxis/minorAxis/angle, fill alpha ∝ size) else circles from `TouchSample`s.
  Label each finger with index + normalized coords (2 decimals).
- Right column readouts, live:
  - Touch count (+ resting count).
  - Force: pressure bar 0..1 + stage indicator (hint text: "press-click to measure").
  - Pinch: accumulated scale (product of 1+delta), Rotate: accumulated degrees,
    Scroll: last dx/dy. Small "reset" affordance via key `r`.
  - Weight (only meaningful when private framework available): total size sum,
    estimated grams = totalSize × gramsPerUnit. `NSSlider` 5…120 (default 50)
    for gramsPerUnit + "Tare" `NSButton` storing a baseline subtracted from
    totalSize. If unavailable, show "per-finger size: unavailable (private
    framework blocked)".
  - Capability checklist, each row ✓ (seen this session) / — (not yet) / ✗
    (unavailable): multi-touch tracking, absolute position, per-finger
    size+ellipse (private), Force Touch pressure, pinch, rotate, scroll,
    resting-touch detection.
- Wire one `TouchCaptureView` (lowest subview, fills bounds) → update state from
  `onEvent`; also subscribe `MultitouchReader.shared.onFrame`. Chain, don't
  overwrite, if you must share the singleton's callback — you are the only
  subscriber of `onFrame`; the Board must NOT use `onFrame` (it polls
  `.fingers`), so B may own it.
- Redraw: `needsDisplay = true` on each event + a 30 Hz timer for decay/idle.

## Board tab spec (agent C)

Excalidraw-ish canvas. All geometry stored in **canvas space**; view transform =
zoom (clamped 0.2…8) about the view center + pan offset. The **pad rect**
(`TrackpadGeometry.padRect(bounds, deviceSize, 0.7)`) is drawn in fixed SCREEN
space, always visible on top (subtle rounded border + "trackpad" label) — it
represents the physical trackpad; zoom/pan changes which canvas region lies
under it (this is the user's feature 4).

Mapping: finger normalized pos → view point via `TrackpadGeometry.map(_, into: padRect)`
→ canvas point via inverse view transform. Define both transforms in
`BoardModel.swift` and use them consistently.

Interaction rules:

- **1 touch**: always show a cursor dot at the mapped point (feature 2 "light
  touch = cursor"). It DRAWS when: physical click held (mouse button down), OR
  `MultitouchReader.shared.isAvailable` and that finger's `size ≥ 0.35`
  (constant, tune). Stroke width = 2 + 6 × forceNorm where forceNorm = NSEvent
  pressure (while clicked) else `min(1, size / 1.5)`. Match MT fingers to the
  touch by nearest normalized distance.
- **≥2 touches**: never draw. Pinch (`.magnify`) zooms about view center;
  `.scroll` pans. Ongoing stroke is cancelled (removed), not committed.
- **Deep force click (stage 2)** or key `s`: quick palette overlay at the cursor
  point (feature 3): `1 pen · 2 line · 3 rect · 4 ellipse · 5 arrow · 6 text`.
  Pick by number key or normal click on an item; Esc closes.
- Tools: pen = freehand stroke; line/rect/ellipse/arrow = drag start→end with
  live preview, commit on release/lift; text = borderless `NSTextField` at the
  point, Enter commits as a text element (fixed 16 pt / zoom-scaled on draw),
  Esc cancels.
- Keys: `1…6` select tool, `s` palette, `t` text at current cursor point,
  `⌘Z` undo (pop last element), `⌘⌫` clear all, `Space` toggles trackpad
  capture, `Esc` closes overlay / releases capture until next Space.
- **Trackpad capture** (the trick that makes absolute drawing usable):
  `captureEnabled` defaults true. When a touch begins while capture is enabled
  and the window is key: `CGAssociateMouseAndMouseCursorPosition(0)` (freeze
  system cursor so finger movement doesn't wander focus); when the touch count
  returns to 0: `CGAssociateMouseAndMouseCursorPosition(1)`. ALSO re-associate
  on `NSWindow.didResignKeyNotification` (observe it), `viewDidMoveToWindow`
  with nil window, and deinit. Never leave the user's cursor frozen with zero
  fingers down — this is a hard safety rule.
- Bottom status strip (drawn): current tool, zoom %, capture on/off, key hints.
- Undo stack = element array; `⌘Z` removes last. No redo in MVP.

`BoardModel.swift`: element enum (stroke/line/rect/ellipse/arrow/text with
canvas-space geometry + width/color), transforms canvas↔view, hit/append/undo/
clear, zoom/pan mutation with clamping. Keep rendering in `BoardTab.swift`.

## Style constraints (all agents)

- Swift 5 language mode (tools 5.9), AppKit only, macOS 13+. No SwiftUI, no
  packages, no `@MainActor` annotations on shared types (everything runs on the
  main thread by construction).
- Views are non-flipped (y-up) — matches `normalizedPosition`.
- Production quality: no placeholder stubs, no TODO-driven development, no
  print-spam. Small tasteful dark UI, system colors/fonts.
- Round 1: DO NOT run `swift build` (sibling agents' files don't exist yet).
  You MAY syntax-check only your own files: `xcrun swiftc -parse <files>`.
  Integration/build/fix happens in round 2.
