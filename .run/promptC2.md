You are agent C doing round 2 of "Trackpad Studio" (/Users/bytedance/code/trackpad).
Round 1 shipped and compiles. The user tested it and gave feedback. You own ONLY
Sources/TrackpadStudio/BoardTab.swift and Sources/TrackpadStudio/BoardModel.swift —
modify nothing else.

First read: SPEC.md, Sources/TrackpadStudio/TrackpadCore.swift, and your current
BoardTab.swift + BoardModel.swift in full.

USER FEEDBACK (translated):
- "On the Board the system mouse cursor should be hidden — the app already draws
  its own cursor dot, so the OS arrow floating there is confusing."
- "The state after a long press is wrong."
- "Pressing Esc should exit the app's draw mode and show the mouse again — that
  feels better."

ROOT CAUSE already diagnosed for the long-press bug — fix exactly this: when the
palette opens during a force press, item selection uses the MOUSE location
(`paletteTool(at: location)` in mouseDown, and hover highlight likewise), but at
that moment the cursor is frozen by CGAssociateMouseAndMouseCursorPosition(0) —
so the palette can never be reached with the pointer and the UI looks stuck.

Redesign the Board interaction to a two-mode machine:

1. **Draw mode** (default when the Board tab is active): trackpad touches drive
   the app cursor/drawing as today; the SYSTEM cursor is hidden while over the
   board — implement with a transparent NSCursor (1×1 clear NSImage) applied
   via a .cursorUpdate NSTrackingArea, so AppKit restores the arrow automatically
   outside the view. Keep the existing freeze-while-touching capture logic and
   all its safety restores.
2. **Pointer mode** (entered with Esc): capture off, cursor association
   restored, system arrow visible (invalidate cursor rects / re-set arrow),
   touches do NOT draw — normal macOS pointing for using tabs/UI. `Space`
   returns to draw mode. Entering the tab starts in draw mode; resign-key /
   view-removal forces pointer-mode behavior (already-existing safety paths).
3. **Palette, finger-driven**: while the palette is open, the FINGER-mapped view
   point (the app cursor) drives item hover highlight; selection happens on
   finger lift over an item, on physical click, or via keys 1–6. Esc closes the
   palette (first Esc closes palette, staying in draw mode; Esc with no palette
   open switches to pointer mode). Opening anchor: center the palette near the
   app-cursor point but clamp fully inside the view.
4. **Long-press opens the palette too**: holding a physical click ≥0.5 s without
   moving more than a few points opens the palette (same path as deep force
   click, latched once per press) — more discoverable than deep-force only.
5. **Pressure state hygiene**: on mouseUp reset current pressure/stage readouts
   to 0 so nothing looks stuck after release; cancel any stroke draft when the
   palette opens (exists — keep).
6. Status strip must show the current mode prominently, e.g.
   "DRAW · pen · 100% · Esc pointer" / "POINTER · Space to draw".

Rules: Swift 5 mode, AppKit only, no SwiftUI, production quality. Hard safety
rule unchanged: never leave the cursor frozen or hidden when it shouldn't be —
restore association AND visible cursor on pointer mode, resign-key, view
removal, deinit. The full package now compiles — verify with
`swift build --scratch-path .build-c 2>&1` (your own scratch path; another agent
builds concurrently with -b). Fix any errors you introduced in YOUR files only.
When done print a 5-line summary.

ADDITIONAL USER FEEDBACK: "整体体验太糙了" — do a real polish pass on the Board:
- Stroke quality: smooth input polylines (quadratic midpoint / Catmull-Rom),
  interpolate width along the stroke; no jaggy segments.
- App cursor: a refined ring + dot with a soft shadow; ring radius/opacity
  responds to current force. Distinct look when hovering vs drawing.
- Pad-rect overlay: hairline rounded border, very subtle fill, small "TRACKPAD"
  label; must never fight visually with content.
- Empty-state hint centered on first launch: "Touch the trackpad to draw · hold
  a click for shapes · Esc frees the mouse" — disappears once anything is drawn.
- Palette: rounded floating card with drawn tool glyphs (not just text), hover
  highlight, subtle shadow.
- Status strip: clean typography, mode shown as a small badge, monospaced digits
  for zoom %.
- Everything must still be verified to compile before you finish.
