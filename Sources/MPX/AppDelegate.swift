import AppKit
import UniformTypeIdentifiers

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSMenuItemValidation {
    private var players: [PlayerWindowController] = []
    private var recentMenu: NSMenu!
    private var audioMenu: NSMenu!
    private var subtitlesMenu: NSMenu!
    private var current: PlayerWindowController? { NSApp.keyWindow?.windowController as? PlayerWindowController }

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false
        buildMenus()
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handleURL(_:reply:)),
                                                     forEventClass: AEEventClass(kInternetEventClass),
                                                     andEventID: AEEventID(kAEGetURL))
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.players.isEmpty { self.newWindow(nil) }
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        for filename in filenames { open(URL(fileURLWithPath: filename)) }
        sender.reply(toOpenOrPrint: .success)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { newWindow(nil) }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) { players.forEach { $0.shutdown() } }

    @objc private func handleURL(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        if event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue == "mpx://new-window" { newWindow(nil) }
    }

    private func makeWindow() -> PlayerWindowController? {
        do {
            let player = try PlayerWindowController()
            player.applySavedVolume()
            player.onClose = { [weak self] closed in self?.players.removeAll { $0 === closed } }
            players.append(player)
            player.showWindow(nil)
            player.window?.makeKeyAndOrderFront(nil)
            return player
        } catch {
            let alert = NSAlert()
            alert.messageText = "mpx could not open a window"
            alert.informativeText = error.localizedDescription
            alert.runModal()
            return nil
        }
    }

    private func open(_ url: URL) {
        let player = players.first { $0.fileURL == nil } ?? makeWindow()
        player?.open(url)
        player?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func newWindow(_ sender: Any?) { _ = makeWindow() }
    @objc func openFile(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.title = "Open Video"
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        // Unknown extensions should remain selectable: the engine, rather than
        // an extension allowlist, decides what it can decode.
        panel.begin { [weak self] response in
            guard response == .OK else { return }
            panel.urls.forEach { self?.open($0) }
        }
    }
    @objc private func openRecent(_ sender: NSMenuItem) { if let url = sender.representedObject as? URL { open(url) } }
    @objc private func clearRecent(_ sender: Any?) { NSDocumentController.shared.clearRecentDocuments(sender) }
    @objc private func playPause(_ sender: Any?) { current?.togglePlayback() }
    @objc private func back(_ sender: Any?) { current?.skip(-10) }
    @objc private func forward(_ sender: Any?) { current?.skip(10) }
    @objc private func beginning(_ sender: Any?) { current?.goToStart() }
    @objc private func end(_ sender: Any?) { current?.goToEnd() }
    @objc private func goToTime(_ sender: Any?) { current?.goToTime() }
    @objc private func fullScreen(_ sender: Any?) { current?.toggleFullscreen() }
    @objc private func fit(_ sender: Any?) { current?.resetZoom() }
    @objc private func zoomIn(_ sender: Any?) { current?.zoomFromCenter(by: 1.25) }
    @objc private func zoomOut(_ sender: Any?) { current?.zoomFromCenter(by: 0.8) }
    @objc private func track(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? [String] else { return }
        current?.engine.set(value[0], value[1])
        current?.showControls()
    }
    @objc private func openSubtitle(_ sender: Any?) {
        guard let player = current, player.fileURL != nil else { return }
        let panel = NSOpenPanel()
        panel.title = "Open Subtitle File"
        panel.canChooseDirectories = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            player.engine.command(["sub-add", url.path, "select"])
            player.showControls()
        }
    }

    private func menu(_ title: String, parent: NSMenu) -> NSMenu {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let child = NSMenu(title: title)
        item.submenu = child
        parent.addItem(item)
        return child
    }
    @discardableResult private func item(_ title: String, _ action: Selector, _ key: String = "",
                                       _ modifiers: NSEvent.ModifierFlags = .command, into menu: NSMenu,
                                       target: AnyObject? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.target = target ?? self
        menu.addItem(item)
        return item
    }

    private func buildMenus() {
        let main = NSMenu()
        let app = menu("mpx", parent: main)
        item("About mpx", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), into: app, target: NSApp)
        app.addItem(.separator())
        let services = menu("Services", parent: app)
        NSApp.servicesMenu = services
        app.addItem(.separator())
        item("Hide mpx", #selector(NSApplication.hide(_:)), "h", into: app, target: NSApp)
        item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option], into: app, target: NSApp)
        item("Show All", #selector(NSApplication.unhideAllApplications(_:)), into: app, target: NSApp)
        app.addItem(.separator())
        item("Quit mpx", #selector(NSApplication.terminate(_:)), "q", into: app, target: NSApp)

        let file = menu("File", parent: main)
        item("New Window", #selector(newWindow(_:)), "n", into: file)
        item("Open…", #selector(openFile(_:)), "o", into: file)
        recentMenu = menu("Open Recent", parent: file); recentMenu.delegate = self
        file.addItem(.separator())
        let close = NSMenuItem(title: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        file.addItem(close)

        let edit = menu("Edit", parent: main)
        for (title, action, key) in [("Cut", "cut:", "x"), ("Copy", "copy:", "c"), ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a")] {
            edit.addItem(NSMenuItem(title: title, action: Selector(action), keyEquivalent: key))
        }

        let playback = menu("Playback", parent: main)
        item("Play / Pause", #selector(playPause(_:)), " ", [], into: playback)
        playback.addItem(.separator())
        item("Back 10 Seconds", #selector(back(_:)), String(UnicodeScalar(NSLeftArrowFunctionKey)!), [], into: playback)
        item("Forward 10 Seconds", #selector(forward(_:)), String(UnicodeScalar(NSRightArrowFunctionKey)!), [], into: playback)
        item("Go to Start", #selector(beginning(_:)), String(UnicodeScalar(NSLeftArrowFunctionKey)!), .option, into: playback)
        item("Go to End", #selector(end(_:)), String(UnicodeScalar(NSRightArrowFunctionKey)!), .option, into: playback)
        item("Go to Time…", #selector(goToTime(_:)), "g", [.command, .shift], into: playback)

        audioMenu = menu("Audio", parent: main); audioMenu.delegate = self
        subtitlesMenu = menu("Subtitles", parent: main); subtitlesMenu.delegate = self

        let view = menu("View", parent: main)
        item("Enter Full Screen", #selector(fullScreen(_:)), "f", [.command, .control], into: view)
        view.addItem(.separator())
        item("Zoom In", #selector(zoomIn(_:)), "+", into: view)
        item("Zoom Out", #selector(zoomOut(_:)), "-", into: view)
        item("Reset Zoom to Fit", #selector(fit(_:)), "0", into: view)

        let window = menu("Window", parent: main)
        window.addItem(NSMenuItem(title: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"))
        window.addItem(NSMenuItem(title: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: ""))
        window.addItem(.separator())
        item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:)), into: window, target: NSApp)
        NSApp.windowsMenu = window
        NSApp.mainMenu = main
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === recentMenu {
            menu.removeAllItems()
            for url in NSDocumentController.shared.recentDocumentURLs.prefix(15) {
                let recent = item(url.lastPathComponent, #selector(openRecent(_:)), into: menu)
                recent.representedObject = url
                recent.toolTip = url.path
            }
            if menu.items.isEmpty { let empty = NSMenuItem(title: "No Recent Files", action: nil, keyEquivalent: ""); empty.isEnabled = false; menu.addItem(empty) }
            menu.addItem(.separator())
            item("Clear Menu", #selector(clearRecent(_:)), into: menu)
        } else if menu === audioMenu {
            menu.removeAllItems()
            addTracks(type: "audio", property: "aid", to: menu)
        } else if menu === subtitlesMenu {
            menu.removeAllItems()
            let off = item("Off", #selector(track(_:)), into: menu)
            off.representedObject = ["sid", "no"]
            off.state = current?.tracks.contains(where: { $0.type == "sub" && $0.selected }) == true ? .off : .on
            addTracks(type: "sub", property: "sid", to: menu)
            menu.addItem(.separator())
            item("Open Subtitle File…", #selector(openSubtitle(_:)), into: menu)
        }
    }

    private func addTracks(type: String, property: String, to menu: NSMenu) {
        for media in current?.tracks.filter({ $0.type == type }) ?? [] {
            let item = item(media.label, #selector(track(_:)), into: menu)
            item.representedObject = [property, String(media.id)]
            item.state = media.selected ? .on : .off
        }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(playPause(_:)), #selector(back(_:)), #selector(forward(_:)), #selector(beginning(_:)),
             #selector(end(_:)), #selector(goToTime(_:)), #selector(track(_:)), #selector(openSubtitle(_:)), #selector(fit(_:)),
             #selector(zoomIn(_:)), #selector(zoomOut(_:)):
            return current?.fileURL != nil
        case #selector(fullScreen(_:)):
            menuItem.title = current?.window?.styleMask.contains(.fullScreen) == true ? "Exit Full Screen" : "Enter Full Screen"
            return current != nil
        default: return true
        }
    }
}
