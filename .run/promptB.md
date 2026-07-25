You are agent B on a 3-agent parallel build of "Trackpad Studio", a native macOS
AppKit app in /Users/bytedance/code/trackpad.

First read, in full:
- /Users/bytedance/code/trackpad/SPEC.md  (the contract — follow it exactly,
  especially the "Capability tab spec" section and the cross-agent API of
  MultitouchReader/MTFingerSample which agent A is writing right now)
- /Users/bytedance/code/trackpad/Sources/TrackpadStudio/TrackpadCore.swift

Your job — create ONLY this file (never create/modify anything else):

1. Sources/TrackpadStudio/CapabilityTab.swift — `final class CapabilityTabView:
   NSView` with a plain `init()`, implementing the Capability tab exactly per
   SPEC: big live trackpad visualization (ellipses via MultitouchReader when
   available, else circles from TouchSamples), right-column live readouts
   (touch count, pressure bar + stage, pinch/rotate/scroll accumulators with
   `r` reset, weight estimate with grams-per-unit NSSlider + Tare button), and
   the capability checklist with ✓/—/✗ states. Wire one TouchCaptureView as the
   lowest bounds-filling subview; you own MultitouchReader.shared.onFrame.
   Redraw on events + 30 Hz timer.

Code against the exact API in SPEC.md (MultitouchReader.shared.isAvailable /
.fingers / .onFrame, MTFingerSample fields). It will exist at integration time.

Rules: Swift 5 mode, AppKit only, macOS 13+, no third-party deps, no SwiftUI,
production quality, tasteful dark UI, no stubs. Do NOT run `swift build`
(siblings' files are missing); you may `xcrun swiftc -parse` your own file to
syntax-check.

When done, print a 5-line summary: file written, sections implemented, any
deviation from SPEC (should be none).
