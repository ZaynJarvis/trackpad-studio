You are agent A on a 3-agent parallel build of "Trackpad Studio", a native macOS
AppKit app in /Users/bytedance/code/trackpad.

First read, in full:
- /Users/bytedance/code/trackpad/SPEC.md  (the contract — follow it exactly)
- /Users/bytedance/code/trackpad/Sources/TrackpadStudio/TrackpadCore.swift
- /Users/bytedance/code/trackpad/Sources/CMultitouchShim/include/CMultitouchShim.h
- /Users/bytedance/code/trackpad/Package.swift

Your job — create ONLY these files (never create/modify anything else; agents B
and C are concurrently writing CapabilityTab.swift and BoardTab.swift/BoardModel.swift):

1. Sources/TrackpadStudio/main.swift — NSApplication bootstrap per SPEC.
2. Sources/TrackpadStudio/AppShell.swift — AppDelegate, main menu, 1200×800 window
   (min 900×600, title "Trackpad Studio"), NSTabView with CapabilityTabView()
   ("Capability") and BoardTabView() ("Board"). Start MultitouchReader.shared at
   launch. Terminate after last window closed.
3. Sources/TrackpadStudio/MultitouchBridge.swift — MTFingerSample + MultitouchReader
   exactly as SPEC's public API, implemented via dlopen/dlsym of the private
   MultitouchSupport framework using the typedefs from `import CMultitouchShim`.
   The C callback cannot capture Swift context: use a file-private global, hop to
   DispatchQueue.main, publish `fingers` and call `onFrame`. Any failure ⇒
   isAvailable = false and the app runs fine without it. Never crash.

Rules: Swift 5 mode, AppKit only, macOS 13+, no third-party deps, no SwiftUI,
production quality, no stubs. Do NOT run `swift build` (siblings' files are
missing); you may `xcrun swiftc -parse` your own files to syntax-check.

When done, print a 5-line summary: files written, public API surface, any
deviation from SPEC (should be none).
