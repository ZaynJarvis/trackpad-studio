You are agent C doing round 3 of "Trackpad Studio" (/Users/bytedance/code/trackpad).
You own ONLY Sources/TrackpadStudio/BoardTab.swift and
Sources/TrackpadStudio/BoardModel.swift — modify nothing else.

First read your current BoardTab.swift + BoardModel.swift in full (they were
just reworked in round 2 — two-mode draw/pointer machine, finger-driven palette).

USER FEEDBACK (translated): "Zoom and two-finger pan can't happen at the same
time — please make simultaneous pinch+pan work."

Root cause: the board relies on system gestures (.magnify and .scroll events),
which macOS recognizes as mutually exclusive — once a pinch is detected, scroll
stops streaming. But we already receive raw two-finger touch positions.

Fix — unified two-finger navigation from raw touches (draw mode only):

1. When exactly 2 touches are active in draw mode, each frame compute from the
   two normalized positions (mapped through the pad rect into view space):
   - centroid movement → pan delta (view points, applied directly)
   - inter-finger distance ratio (current / previous) → zoom factor,
     **anchored at the current centroid's view point** (not the view center),
     so content under the fingers stays under the fingers. Clamp zoom 0.2…8;
     when clamped, don't accumulate drift.
2. Reset the gesture baseline whenever the touch count changes (1→2, 3→2, etc.);
   never jump on entry. End cleanly when a finger lifts.
3. While this raw two-finger navigation is active, IGNORE .magnify and .scroll
   events in draw mode (they'd double-apply). Pointer mode keeps system
   gestures behavior as-is.
4. Keep all round-2 rules intact: 2 touches never draw, ongoing stroke draft is
   cancelled, palette/finger-selection unaffected, capture + cursor safety
   rules unchanged.
5. Status strip: while two-finger navigation is active show live zoom % (it
   should visibly change while panning simultaneously).

Rules: Swift 5 mode, AppKit only, production quality. Verify with
`swift build --scratch-path .build-c 2>&1` and fix errors in YOUR files only.
When done print a 5-line summary.
