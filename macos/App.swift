import AppKit

final class MenuApp: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let bridge = TapoBridge()
    private let menu = NSMenu()
    private let signInItem = NSMenuItem(title: "Sign In…", action: nil, keyEquivalent: "")
    private var statusItem: NSStatusItem?
    private var items: [String: NSMenuItem] = [:]
    private var liveWindow: LiveWindow?
    private var refreshing = false
    private var signInTimer: Timer?
    private var pendingCamera: String?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem = item
        let icon = NSImage(systemSymbolName: "video", accessibilityDescription: "Tapo cameras")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 16, weight: .medium))
        icon?.isTemplate = true
        item.button?.image = icon
        item.button?.toolTip = "Tapo cameras"
        item.button?.setAccessibilityLabel("Tapo cameras")

        menu.autoenablesItems = false
        menu.delegate = self
        for id in ["1", "2"] {
            let camera = NSMenuItem(title: "Cam \(id) · Checking…", action: #selector(cameraClicked(_:)), keyEquivalent: "")
            camera.representedObject = id
            camera.target = self
            menu.addItem(camera)
            items[id] = camera
        }
        menu.addItem(.separator())
        signInItem.target = self
        signInItem.action = #selector(signInClicked)
        menu.addItem(signInItem)
        let quit = NSMenuItem(title: "Quit Tapo Menu", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        menu.addItem(quit)
        item.menu = menu

        bridge.onStateChange = { [weak self] in
            guard let self else { return }
            if self.bridge.failed {
                for (id, row) in self.items { row.title = "Cam \(id) · Unavailable" }
                self.liveWindow?.showFailure("The local camera connection stopped.")
            } else {
                self.refresh()
            }
        }
        bridge.start()
    }

    func menuWillOpen(_ menu: NSMenu) {
        if bridge.failed { bridge.start() }
        refresh()
    }

    private func refresh() {
        guard bridge.port != nil, !refreshing else { return }
        refreshing = true
        bridge.status { [weak self] status in
            guard let self else { return }
            self.refreshing = false
            guard let status else {
                for (id, row) in self.items { row.title = "Cam \(id) · Unavailable" }
                return
            }
            if status.cameras.isEmpty {
                self.signInItem.title = "Set Up and Sign In…"
                for (id, row) in self.items { row.title = "Cam \(id) · Set Up…" }
                return
            }
            self.signInItem.title = status.hasCredentials ? "Sign In Again…" : "Sign In…"
            for (id, row) in self.items {
                let camera = status.cameras.first { $0.id == id }
                if let camera, camera.online {
                    let battery = camera.batteryPercent.map { "\($0)%" } ?? "Battery unknown"
                    row.title = "Cam \(id) · \(battery)" + (camera.charging == true ? " (Charging)" : "")
                } else {
                    row.title = "Cam \(id) · Offline"
                }
            }
        }
    }

    @objc private func cameraClicked(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        guard FileManager.default.fileExists(atPath: bridge.configFile.path),
              FileManager.default.fileExists(atPath: bridge.tokenFile.path) else {
            beginSignIn(camera: id)
            return
        }
        openLive(camera: id)
    }

    @objc private func signInClicked() { beginSignIn(camera: nil) }

    private func openLive(camera id: String) {
        guard let request = bridge.request("/live/\(id)") else {
            bridge.start()
            if let liveWindow {
                liveWindow.showFailure("The local connection is restarting. Try again in a moment.")
            } else {
                showAlert("Tapo Menu is starting its local connection.", detail: "Open the camera again in a moment.")
            }
            return
        }
        if liveWindow == nil { liveWindow = LiveWindow() }
        liveWindow?.show(camera: id, request: request, onRetry: { [weak self] in
            self?.openLive(camera: id)
        })
    }

    private func beginSignIn(camera: String?) {
        if let camera { pendingCamera = camera }
        guard signInTimer == nil else { return }
        guard let helper = Bundle.main.resourceURL?.appendingPathComponent("macos/Sign in to Tapo.command"),
              FileManager.default.isExecutableFile(atPath: helper.path) else {
            pendingCamera = nil
            showAlert("The sign-in helper is unavailable.", detail: "Rebuild Tapo Menu to restore it.")
            return
        }
        let stamp = tokenModificationTime()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", "Terminal", helper.path]
        do {
            try process.run()
        } catch {
            pendingCamera = nil
            showAlert("Could not open Terminal.", detail: "Try Sign In from the menu again.")
            return
        }

        let deadline = Date().addingTimeInterval(300)
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            if let latest = self.tokenModificationTime(), latest != stamp {
                let id = self.pendingCamera
                self.endSignIn()
                self.refresh()
                if let id { self.openLive(camera: id) }
            } else if Date() >= deadline {
                self.endSignIn()
            }
        }
        signInTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func tokenModificationTime() -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: bridge.tokenFile.path))?[.modificationDate] as? Date
    }

    private func endSignIn() {
        signInTimer?.invalidate()
        signInTimer = nil
        pendingCamera = nil
    }

    private func showAlert(_ message: String, detail: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    func applicationWillTerminate(_ notification: Notification) {
        endSignIn()
        liveWindow?.stop()
        bridge.stop()
    }
}

@main
struct TapoMenuMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = MenuApp()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}
