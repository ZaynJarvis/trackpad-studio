You are agent C on a 3-agent parallel build of "Trackpad Studio", a native macOS
AppKit app in /Users/bytedance/code/trackpad.

First read, in full:
- /Users/bytedance/code/trackpad/SPEC.md  (the contract — follow it exactly,
  especially the "Board tab spec" section and the cross-agent API of
  MultitouchReader/MTFingerSample which agent A is writing right now)
- /Users/bytedance/code/trackpad/Sources/TrackpadStudio/TrackpadCore.swift

Your job — create ONLY these files (never create/modify anything else):

1. Sources/TrackpadStudio/BoardModel.swift — element types (stroke/line/rect/
   ellipse/arrow/text in canvas space), canvas↔view transforms (zoom 0.2…8 about
   view center + pan), append/undo/clear, zoom/pan mutation with clamping.
2. Sources/TrackpadStudio/BoardTab.swift — `final class BoardTabView: NSView`
   with a plain `init()`: the Excalidraw-like board exactly per SPEC —
   fixed screen-space trackpad pad-rect overlay (always visible), absolute
   finger→canvas mapping, 1-touch cursor/draw rules (click-force or MT size ≥
   0.35 threshold, force-modulated stroke width), ≥2-touch pinch-zoom/pan with
   stroke cancel, deep-force-click/`s` quick palette (1 pen · 2 line · 3 rect ·
   4 ellipse · 5 arrow · 6 text), text via borderless NSTextField, key map
   (1…6, s, t, ⌘Z, ⌘⌫, Space, Esc), trackpad capture via
   CGAssociateMouseAndMouseCursorPosition with the hard safety rule (never
   leave cursor frozen at 0 touches; re-associate on resign-key / view removal /
   deinit), bottom status strip.

Code against the exact API in SPEC.md (MultitouchReader.shared.isAvailable /
.fingers — poll it, do NOT touch .onFrame, that belongs to agent B). It will
exist at integration time.

Rules: Swift 5 mode, AppKit only, macOS 13+, no third-party deps, no SwiftUI,
production quality, tasteful dark UI, no stubs. Do NOT run `swift build`
(siblings' files are missing); you may `xcrun swiftc -parse` your own files to
syntax-check.

When done, print a 5-line summary: files written, interaction rules implemented,
any deviation from SPEC (should be none).
