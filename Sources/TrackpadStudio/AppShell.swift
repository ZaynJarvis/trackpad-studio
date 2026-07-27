import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private var tutorialPanel: NSPanel?
    private var boardView: BoardTabView?

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMainMenu()
        MultitouchReader.shared.start()

        let window = makeMainWindow()
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        if let idx = CommandLine.arguments.firstIndex(of: "--snapshot"),
           CommandLine.arguments.count > idx + 1 {
            runSnapshotMode(directory: CommandLine.arguments[idx + 1])
        }

        if let idx = CommandLine.arguments.firstIndex(of: "--ai-test"),
           CommandLine.arguments.count > idx + 1 {
            runAITestMode(directory: CommandLine.arguments[idx + 1])
        }

        // Smoke test for the black-background keying: --keytest in.png out.png
        if let idx = CommandLine.arguments.firstIndex(of: "--keytest"),
           CommandLine.arguments.count > idx + 2 {
            if let image = NSImage(contentsOfFile: CommandLine.arguments[idx + 1]),
               let tiff = BoardTabView.transparentized(image).tiffRepresentation,
               let rep = NSBitmapImageRep(data: tiff),
               let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(
                    to: URL(fileURLWithPath: CommandLine.arguments[idx + 2])
                )
            }
            NSApp.terminate(nil)
        }
    }

    /// End-to-end smoke test for the ⌘G AI redraw: seed demo content, run the
    /// real codex+imagegen pipeline, write before/after PNGs, quit.
    private func runAITestMode(directory: String) {
        let dir = URL(fileURLWithPath: directory, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        boardView?.seedDemoContent()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in
            if let board = window?.contentView {
                writePNG(of: board, to: dir.appendingPathComponent("ai-before.png"))
            }
            boardView?.runAIRedraw { [self] in
                if let board = window?.contentView {
                    writePNG(of: board, to: dir.appendingPathComponent("ai-after.png"))
                }
                NSApp.terminate(nil)
            }
        }
    }

    /// Self-screenshot mode: renders the board (with demo content) and the
    /// tutorial panel to PNGs, then quits. Needs no screen-recording permission
    /// because an app may always rasterize its own views.
    private func runSnapshotMode(directory: String) {
        let dir = URL(fileURLWithPath: directory, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        boardView?.seedDemoContent()
        showTutorial(nil)

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [self] in
            if let board = window?.contentView {
                writePNG(of: board, to: dir.appendingPathComponent("board.png"))
            }
            if let tutorial = tutorialPanel?.contentView {
                writePNG(of: tutorial, to: dir.appendingPathComponent("tutorial.png"))
            }
            NSApp.terminate(nil)
        }
    }

    private func writePNG(of view: NSView, to url: URL) {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: url)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MultitouchReader.shared.stop()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    @objc func showTutorial(_ sender: Any?) {
        let panel: NSPanel
        if let existing = tutorialPanel {
            panel = existing
        } else {
            panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 900, height: 640),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            panel.title = "Trackpad Tutorial"
            panel.minSize = NSSize(width: 800, height: 560)
            panel.isReleasedWhenClosed = false
            panel.contentView = CapabilityTabView()
            panel.center()
            tutorialPanel = panel
        }
        panel.makeKeyAndOrderFront(nil)
    }

    private func installMainMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu(title: "Trackpad Studio")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let aboutItem = NSMenuItem(
            title: "About Trackpad Studio",
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: ""
        )
        aboutItem.target = NSApp
        appMenu.addItem(aboutItem)
        appMenu.addItem(.separator())

        let tutorialItem = NSMenuItem(
            title: "Trackpad Tutorial",
            action: #selector(showTutorial(_:)),
            keyEquivalent: "t"
        )
        tutorialItem.keyEquivalentModifierMask = .command
        tutorialItem.target = self
        appMenu.addItem(tutorialItem)
        appMenu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: "Quit Trackpad Studio",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        quitItem.keyEquivalentModifierMask = .command
        quitItem.target = NSApp
        appMenu.addItem(quitItem)

        let windowMenuItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)

        let closeItem = NSMenuItem(
            title: "Close",
            action: #selector(NSWindow.performClose(_:)),
            keyEquivalent: "w"
        )
        closeItem.keyEquivalentModifierMask = .command
        windowMenu.addItem(closeItem)

        NSApp.mainMenu = mainMenu
        NSApp.windowsMenu = windowMenu
    }

    private func makeMainWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_200, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Trackpad Studio"
        window.minSize = NSSize(width: 900, height: 600)
        window.center()

        let container = NSView(frame: window.contentView?.bounds ?? .zero)
        container.autoresizingMask = [.width, .height]

        let board = BoardTabView()
        board.frame = container.bounds
        board.autoresizingMask = [.width, .height]
        container.addSubview(board)
        boardView = board

        let help = NSButton(title: "?", target: self, action: #selector(showTutorial(_:)))
        help.bezelStyle = .circular
        help.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        help.toolTip = "Trackpad Tutorial (⌘T)"
        help.sizeToFit()
        help.frame.origin = CGPoint(
            x: container.bounds.maxX - help.frame.width - 12,
            y: container.bounds.maxY - help.frame.height - 12
        )
        help.autoresizingMask = [.minXMargin, .minYMargin]
        container.addSubview(help)

        window.contentView = container
        return window
    }
}
