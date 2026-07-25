import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private var tutorialPanel: NSPanel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMainMenu()
        MultitouchReader.shared.start()

        let window = makeMainWindow()
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
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
