You are agent B doing round 2 of "Trackpad Studio" (/Users/bytedance/code/trackpad).
Round 1 shipped and compiles. The user tested it and gave feedback. You own ONLY
Sources/TrackpadStudio/CapabilityTab.swift — modify nothing else.

First read: SPEC.md, Sources/TrackpadStudio/TrackpadCore.swift,
Sources/TrackpadStudio/MultitouchBridge.swift, and your current
Sources/TrackpadStudio/CapabilityTab.swift.

USER FEEDBACK (translated): "The Capability tab has no tutorial for each
capability — it just lets the user fumble around."

Your job — turn the capability checklist into a guided tutorial:

1. Each capability row becomes a tutorial card: capability name + ONE clear
   "Try:" instruction telling the user exactly what to do with their fingers,
   + the live ✓/—/✗ status that flips to ✓ the moment they perform it.
   Instructions (English, tight):
   - Multi-touch tracking — "Rest 1–5 fingers anywhere on the pad"
   - Absolute position — "Slide one finger to a corner; the dot mirrors it"
   - Per-finger size + ellipse — "Press flat with your thumb; watch the ellipse
     grow" (✗ + "grant Input Monitoring, relaunch" when unavailable)
   - Force Touch pressure — "Click and keep pressing — feel the second click"
   - Pinch — "Two fingers, spread apart / pinch together"
   - Rotate — "Two fingers, twist like turning a knob"
   - Scroll — "Two fingers, slide together in any direction"
   - Resting touch — "Rest your palm/thumb at the bottom edge without moving"
2. Highlight the first not-yet-done capability as "try this next" (subtle
   accent border), so there's a natural guided order.
3. Weight card gets numbered steps: "1 Clear the pad  2 Tare  3 Place an object
   (a spoon, not a hand)  4 Slide grams/unit until a known weight reads true".
4. Keep the live trackpad visualization and readouts; adjust layout as needed
   so tutorials fit without crowding (scrollable right column via NSScrollView
   is acceptable if needed).

Rules: Swift 5 mode, AppKit only, no SwiftUI, production quality. The full
package now compiles — verify with `swift build --scratch-path .build-b 2>&1`
(your own scratch path; another agent builds concurrently with -c). Fix any
errors you introduced in YOUR file only. When done print a 5-line summary.

ADDITIONAL USER FEEDBACK: "整体体验太糙了" — do a real polish pass on your tab:
- Clear visual hierarchy: section headers (small caps, secondary color), cards
  with consistent corner radius/padding/spacing, hairline separators.
- Readouts use monospacedDigitSystemFont so numbers don't jitter; values ease/
  decay smoothly instead of snapping.
- Touch ellipses: soft fill + hairline stroke, small id/coord labels that don't
  overlap; subtle fade-out when a finger lifts.
- The whole tab should look like a designed instrument panel, not debug output.
