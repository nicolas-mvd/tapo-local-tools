import AppKit

final class MenuApp: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private struct TokenFile: Codable {
        struct Entry: Codable {
            let host: String
            let lat: String

            var isValid: Bool {
                !lat.isEmpty && lat.utf8.count <= 4096 && lat.utf8.allSatisfy { (33...126).contains($0) }
            }
        }
        var type = "tapo-lat/v1"
        var cameras: [String: Entry]
    }

    private struct SignInAttempt {
        let directory: URL
        let cameras: [ConfiguredCamera]
        let preview: ConfiguredCamera?
        let launcher: Process
    }

    private struct BatteryReading {
        let percent: Int
        let charging: Bool?
        let checkedAt: Date
    }

    private let bridge = TapoBridge()
    private let menu = NSMenu()
    private let signInItem = NSMenuItem(title: "Sign In…", action: nil, keyEquivalent: "")
    private let recordingsItem = NSMenuItem(title: "Open Recordings", action: nil, keyEquivalent: "")
    private let emptyItem = NSMenuItem(title: "No cameras configured", action: nil, keyEquivalent: "")
    private var statusItem: NSStatusItem?
    private var items: [String: NSMenuItem] = [:]
    private var configuration = MenuConfiguration()
    private var status: [String: CameraStatus] = [:]
    private var batteries: [String: BatteryReading] = [:]
    private var probeFailed = false
    private var liveWindow: LiveWindow?
    private var refreshing = false
    private var signInTimer: Timer?
    private var attempt: SignInAttempt?

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
        emptyItem.isEnabled = false
        menu.addItem(emptyItem)
        menu.addItem(.separator())
        recordingsItem.target = self
        recordingsItem.action = #selector(openRecordings)
        menu.addItem(recordingsItem)
        let settings = NSMenuItem(title: "Settings…", action: #selector(settingsClicked), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        signInItem.target = self
        signInItem.action = #selector(signInClicked)
        menu.addItem(signInItem)
        let quit = NSMenuItem(title: "Quit Tapo Menu", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        menu.addItem(quit)
        item.menu = menu

        reloadConfiguration()
        bridge.onStateChange = { [weak self] in
            guard let self else { return }
            if self.bridge.failed {
                self.probeFailed = true
                self.updateRows()
                self.liveWindow?.connectionLost()
            } else {
                self.refresh()
            }
        }
        bridge.start()
    }

    func menuWillOpen(_ menu: NSMenu) {
        reloadConfiguration()
        if bridge.failed { bridge.start() }
        updateRows()
        refresh()
    }

    private func reloadConfiguration() {
        do {
            let saved = try PrivateFiles.read(bridge.configFile)
            let updated = try saved.map { try JSONDecoder().decode(MenuConfiguration.self, from: $0) }
            let newConfiguration = updated ?? MenuConfiguration()
            guard newConfiguration.hasValidCameras else { throw CocoaError(.fileReadCorruptFile) }
            emptyItem.title = "No cameras configured"
            guard newConfiguration != configuration else { updateRows(); return }
            let unchanged = Set(newConfiguration.cameras.filter { camera in
                configuration.cameras.contains { $0.id == camera.id && $0.host == camera.host }
            }.map(\.id))
            batteries = batteries.filter { unchanged.contains($0.key) }
            status = status.filter { unchanged.contains($0.key) }
            configuration = newConfiguration
            for row in items.values { menu.removeItem(row) }
            items.removeAll()
            for (index, camera) in configuration.cameras.enumerated() {
                let row = NSMenuItem(title: camera.displayName, action: #selector(cameraClicked(_:)), keyEquivalent: "")
                row.representedObject = camera.id
                row.target = self
                menu.insertItem(row, at: index)
                items[camera.id] = row
            }
            updateRows()
        } catch {
            emptyItem.title = "Check camera settings"
            probeFailed = true
            updateRows()
        }
    }

    private func refresh() {
        guard bridge.port != nil, !refreshing, !configuration.cameras.isEmpty else { return }
        refreshing = true
        let cameras = configuration.cameras
        bridge.status { [weak self] response in
            guard let self else { return }
            self.refreshing = false
            guard self.configuration.cameras == cameras else { self.refresh(); return }
            self.probeFailed = response?.probeFailed ?? true
            if let response {
                for reading in response.cameras where cameras.contains(where: {
                    $0.id == reading.id && $0.host == reading.host
                }) {
                    self.status[reading.id] = reading
                    if reading.online, let percent = reading.batteryPercent, let timestamp = reading.checkedAt {
                        self.batteries[reading.id] = BatteryReading(
                            percent: percent, charging: reading.charging,
                            checkedAt: Date(timeIntervalSince1970: timestamp)
                        )
                    }
                }
            }
            self.updateRows()
        }
    }

    private func updateRows() {
        emptyItem.isHidden = !configuration.cameras.isEmpty
        recordingsItem.isEnabled = configuration.recordingsLink != nil
        if attempt != nil {
            signInItem.title = "Cancel Sign-In"
        } else if configuration.cameras.isEmpty {
            signInItem.title = "Set Up and Sign In…"
        } else {
            signInItem.title = configuration.cameras.allSatisfy { status[$0.id]?.hasCredentials == true }
                ? "Sign In Again…" : "Sign In…"
        }
        var hasLowBattery = false
        for camera in configuration.cameras {
            guard let row = items[camera.id] else { continue }
            let reading = status[camera.id]
            let battery = batteries[camera.id]
            var details = [String]()
            if let battery {
                let age = max(0, Date().timeIntervalSince(battery.checkedAt))
                details.append("\(battery.percent)%")
                if age < 60 && reading?.online == true && reading?.batteryPercent != nil && !probeFailed {
                    details.append("just now")
                    if battery.charging == true {
                        details.append("Charging")
                    } else if battery.percent <= 20 {
                        details.append("Low battery")
                        hasLowBattery = true
                    }
                } else {
                    let formatter = RelativeDateTimeFormatter()
                    formatter.unitsStyle = .abbreviated
                    details.append(formatter.localizedString(for: battery.checkedAt, relativeTo: Date()))
                }
            } else if reading?.online == true {
                details.append("Battery unavailable")
            }
            if probeFailed {
                details.append("Status unavailable")
            } else if reading?.online == false {
                details.append("No reply")
            } else if reading == nil {
                details.append("Checking…")
            }
            row.title = ([camera.displayName] + details).joined(separator: " · ")
        }
        statusItem?.button?.contentTintColor = hasLowBattery ? .systemOrange : nil
        statusItem?.button?.toolTip = hasLowBattery ? "A Tapo camera has low battery" : "Tapo cameras"
    }

    @objc private func settingsClicked() {
        _ = editSettings()
    }

    private func editSettings() -> Bool {
        guard let settings = CameraSettings().run(configuration: configuration) else { return false }
        do {
            try PrivateFiles.directory(bridge.supportDirectory)
            try PrivateFiles.write(JSONEncoder().encode(settings), to: bridge.configFile)
            if settings.cameras != configuration.cameras {
                endSignIn()
                liveWindow?.close()
            }
            reloadConfiguration()
            refresh()
            return true
        } catch {
            showAlert("Could not save settings.", detail: "Check the permissions of Tapo Menu’s Application Support folder.")
            return false
        }
    }

    @objc private func openRecordings() {
        guard let url = configuration.recordingsLink else { return }
        if !NSWorkspace.shared.open(url) {
            showAlert("Could not open recordings.", detail: "Check the recordings URL in Settings.")
        }
    }

    @objc private func cameraClicked(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let camera = configuration.cameras.first(where: { $0.id == id }) else { return }
        guard status[id]?.hasCredentials != false,
              FileManager.default.fileExists(atPath: bridge.tokenFile.path) else {
            beginSignIn(preview: camera)
            return
        }
        openLive(camera)
    }

    @objc private func signInClicked() {
        if attempt != nil {
            endSignIn()
            return
        }
        if configuration.cameras.isEmpty && !editSettings() { return }
        beginSignIn(preview: nil)
    }

    private func openLive(_ camera: ConfiguredCamera) {
        if liveWindow == nil { liveWindow = LiveWindow() }
        liveWindow?.show(camera: camera.displayName) { [weak self] in
            guard let self else { return nil }
            if self.bridge.port == nil { self.bridge.start() }
            return self.bridge.request("/live/\(camera.id)")
        }
    }

    private func beginSignIn(preview: ConfiguredCamera?) {
        guard attempt == nil else {
            showAlert("Sign-in is already open.", detail: "Continue in Terminal or choose Cancel Sign-In from the menu.")
            return
        }
        guard let helper = Bundle.main.resourceURL?.appendingPathComponent("macos/Sign in to Tapo.command"),
              FileManager.default.isExecutableFile(atPath: helper.path) else {
            showAlert("The sign-in helper is unavailable.", detail: "Rebuild Tapo Menu to restore it.")
            return
        }
        let id = UUID().uuidString
        let directory = bridge.supportDirectory.appendingPathComponent("sign-in-" + id, isDirectory: true)
        let cameras = preview.map { [$0] } ?? configuration.cameras
        let launcher = Process()
        do {
            try PrivateFiles.directory(bridge.supportDirectory)
            try PrivateFiles.directory(directory)
            let config = try JSONEncoder().encode(MenuConfiguration(cameras: cameras))
            try PrivateFiles.write(config, to: directory.appendingPathComponent("config.json"))
            let command = directory.appendingPathComponent("Sign in to Tapo.command")
            let escapedHelper = helper.path.replacingOccurrences(of: "'", with: "'\"'\"'")
            try PrivateFiles.write(Data("#!/bin/sh\nexec '\(escapedHelper)' '\(id)'\n".utf8), to: command, mode: 0o700)
            launcher.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            launcher.arguments = ["-a", "Terminal", command.path]
            try launcher.run()
        } catch {
            try? FileManager.default.removeItem(at: directory)
            showAlert("Could not open the sign-in helper.", detail: "Check Terminal and your Tapo Menu settings, then try again.")
            return
        }

        attempt = SignInAttempt(directory: directory, cameras: cameras, preview: preview, launcher: launcher)
        let deadline = Date().addingTimeInterval(300)
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            self.pollSignIn(deadline: deadline)
        }
        signInTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        updateRows()
    }

    private func pollSignIn(deadline: Date) {
        guard let attempt else { return }
        do {
            if let result = try PrivateFiles.read(attempt.directory.appendingPathComponent("camera-tokens.json")) {
                try installTokens(result, for: attempt.cameras)
                endSignIn()
                refresh()
                if let camera = attempt.preview,
                   configuration.cameras.contains(where: { $0.id == camera.id && $0.host == camera.host }) {
                    openLive(camera)
                }
            } else if FileManager.default.fileExists(atPath: attempt.directory.appendingPathComponent("failed").path)
                        || (!attempt.launcher.isRunning && attempt.launcher.terminationStatus != 0)
                        || Date() >= deadline {
                endSignIn()
                showAlert("Sign-in did not finish.", detail: "Check the result in Terminal or choose Sign In to try again.")
            }
        } catch {
            endSignIn()
            showAlert("Could not save camera access.", detail: "Check your Tapo Menu settings and try signing in again.")
        }
    }

    private func installTokens(_ data: Data, for cameras: [ConfiguredCamera]) throws {
        let decoder = JSONDecoder()
        let received = try decoder.decode(TokenFile.self, from: data)
        guard received.type == "tapo-lat/v1", received.cameras.count == cameras.count,
              cameras.allSatisfy({ camera in
                  let token = received.cameras["camera" + camera.id]
                  return token?.host == camera.host && token?.isValid == true
              }) else { throw CocoaError(.fileReadCorruptFile) }

        let existing = try? PrivateFiles.read(bridge.tokenFile)
        let previous = existing.flatMap { try? decoder.decode(TokenFile.self, from: $0) }
        var combined = TokenFile(cameras: [:])
        let previousTokens = previous?.type == combined.type ? previous?.cameras : nil
        for camera in configuration.cameras {
            let key = "camera" + camera.id
            let token = received.cameras[key] ?? previousTokens?[key]
            if let token, token.host == camera.host, token.isValid { combined.cameras[key] = token }
        }
        try PrivateFiles.write(JSONEncoder().encode(combined), to: bridge.tokenFile)
        for camera in cameras {
            status.removeValue(forKey: camera.id)
        }
    }

    private func endSignIn() {
        signInTimer?.invalidate()
        signInTimer = nil
        if let attempt { try? FileManager.default.removeItem(at: attempt.directory) }
        attempt = nil
        updateRows()
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
