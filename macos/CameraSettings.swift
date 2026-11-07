import AppKit
import Darwin

struct ConfiguredCamera: Codable, Equatable {
    let id: String
    var host: String
    var name: String?

    var displayName: String {
        if let name, !name.isEmpty { return name }
        return "Cam \(id)"
    }
}

struct MenuConfiguration: Codable, Equatable {
    var cameras: [ConfiguredCamera] = []
    var recordingsURL: String?

    var hasValidCameras: Bool {
        cameras.count <= 16
            && Set(cameras.map(\.id)).count == cameras.count
            && Set(cameras.map(\.host)).count == cameras.count
            && cameras.allSatisfy {
                $0.id.range(of: "\\A[A-Za-z0-9][A-Za-z0-9-]{0,23}\\z", options: .regularExpression) != nil
                    && CameraSettings.isPrivateIPv4($0.host)
                    && ($0.name?.utf8.count ?? 0) <= 160
            }
    }

    var recordingsLink: URL? {
        guard let recordingsURL,
              let address = URLComponents(string: recordingsURL),
              address.scheme?.lowercased() == "https",
              address.host?.isEmpty == false,
              address.user == nil, address.password == nil else { return nil }
        return address.url
    }
}

enum PrivateFiles {
    static func directory(_ url: URL) throws {
        try FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        var attributes = stat()
        guard lstat(url.path, &attributes) == 0,
              attributes.st_mode & S_IFMT == S_IFDIR,
              attributes.st_uid == geteuid(), attributes.st_mode & 0o077 == 0 else {
            throw CocoaError(.fileWriteNoPermission)
        }
    }

    static func read(_ url: URL) throws -> Data? {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        if fd < 0 && errno == ENOENT { return nil }
        guard fd >= 0 else { throw CocoaError(.fileReadNoPermission) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var attributes = stat()
        guard fstat(fd, &attributes) == 0,
              attributes.st_mode & S_IFMT == S_IFREG,
              attributes.st_uid == geteuid(), attributes.st_mode & 0o077 == 0,
              attributes.st_size <= 65_536 else { throw CocoaError(.fileReadNoPermission) }
        return try handle.read(upToCount: 65_537) ?? Data()
    }

    static func write(_ data: Data, to url: URL, mode: mode_t = 0o600) throws {
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".tmp-" + UUID().uuidString)
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode)
        guard fd >= 0 else { throw CocoaError(.fileWriteNoPermission) }
        defer { try? FileManager.default.removeItem(at: temporary) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        try handle.write(contentsOf: data)
        try handle.close()
        guard rename(temporary.path, url.path) == 0 else { throw CocoaError(.fileWriteNoPermission) }
    }
}

private final class SettingsDocumentView: NSView {
    override var isFlipped: Bool { true }
}

final class CameraSettings: NSObject {
    private struct Row {
        let id: String
        let name: NSTextField
        let host: NSTextField
        let remove: NSButton
        let stack: NSStackView
    }

    private let cameras = NSStackView()
    private let add = NSButton(title: "Add Camera", target: nil, action: nil)
    private let link = NSTextField()
    private let validation = NSTextField(wrappingLabelWithString: "")
    private var rows: [Row] = []

    func run(configuration: MenuConfiguration) -> MenuConfiguration? {
        let alert = NSAlert()
        alert.messageText = "Tapo Menu Settings"
        alert.informativeText = "Add up to 16 cameras using their private IPv4 addresses."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.accessoryView = makeForm()
        for camera in configuration.cameras { addRow(camera) }
        if rows.isEmpty { addClicked() }
        link.stringValue = configuration.recordingsURL ?? ""
        NSApp.activate(ignoringOtherApps: true)
        while alert.runModal() == .alertFirstButtonReturn {
            if let settings = validated() { return settings }
        }
        return nil
    }

    private func makeForm() -> NSView {
        let scroll = NSScrollView()
        scroll.borderType = .bezelBorder
        scroll.hasVerticalScroller = true
        let document = SettingsDocumentView()
        document.translatesAutoresizingMaskIntoConstraints = false
        cameras.orientation = .vertical
        cameras.alignment = .leading
        cameras.spacing = 6
        cameras.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(cameras)
        scroll.documentView = document
        NSLayoutConstraint.activate([
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            cameras.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 8),
            cameras.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -8),
            cameras.topAnchor.constraint(equalTo: document.topAnchor, constant: 8),
            cameras.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -8),
        ])

        add.target = self
        add.action = #selector(addClicked)
        link.placeholderString = "https://… (optional)"
        link.setAccessibilityLabel("Recordings URL")
        validation.textColor = .systemRed
        let form = NSStackView(views: [
            NSTextField(labelWithString: "Camera names and addresses"), scroll, add,
            NSTextField(labelWithString: "Private recordings URL"), link, validation,
        ])
        form.frame = NSRect(x: 0, y: 0, width: 500, height: 272)
        form.orientation = .vertical
        form.alignment = .leading
        form.spacing = 6
        NSLayoutConstraint.activate([
            scroll.widthAnchor.constraint(equalTo: form.widthAnchor),
            scroll.heightAnchor.constraint(equalToConstant: 144),
            link.widthAnchor.constraint(equalTo: form.widthAnchor),
            validation.widthAnchor.constraint(equalTo: form.widthAnchor),
        ])
        return form
    }

    @objc private func addClicked() {
        guard rows.count < 16 else { return }
        let ids = Set(rows.map(\.id))
        guard let number = (1...16).first(where: { !ids.contains(String($0)) }) else { return }
        addRow(ConfiguredCamera(id: String(number), host: "", name: nil))
    }

    private func addRow(_ camera: ConfiguredCamera) {
        let name = NSTextField(string: camera.name ?? "")
        name.placeholderString = camera.displayName
        name.setAccessibilityLabel("Name for \(camera.displayName)")
        let host = NSTextField(string: camera.host)
        host.placeholderString = "192.168.1.20"
        host.setAccessibilityLabel("Address for \(camera.displayName)")
        let remove = NSButton(title: "Remove", target: self, action: #selector(removeClicked(_:)))
        remove.setAccessibilityLabel("Remove \(camera.displayName)")
        let stack = NSStackView(views: [name, host, remove])
        stack.spacing = 8
        cameras.addArrangedSubview(stack)
        NSLayoutConstraint.activate([
            stack.widthAnchor.constraint(equalTo: cameras.widthAnchor),
            host.widthAnchor.constraint(equalToConstant: 128),
        ])
        rows.append(Row(id: camera.id, name: name, host: host, remove: remove, stack: stack))
        updateButtons()
        if rows.count > 1 { stack.scrollToVisible(stack.bounds) }
    }

    @objc private func removeClicked(_ sender: NSButton) {
        guard let index = rows.firstIndex(where: { $0.remove === sender }) else { return }
        let row = rows.remove(at: index)
        cameras.removeArrangedSubview(row.stack)
        row.stack.removeFromSuperview()
        updateButtons()
    }

    private func updateButtons() {
        add.isEnabled = rows.count < 16
        for row in rows { row.remove.isEnabled = rows.count > 1 }
    }

    private func validated() -> MenuConfiguration? {
        let trim = CharacterSet.whitespacesAndNewlines
        let configured = rows.map { row in
            let name = row.name.stringValue.trimmingCharacters(in: trim)
            return ConfiguredCamera(
                id: row.id, host: row.host.stringValue.trimmingCharacters(in: trim),
                name: name.isEmpty ? nil : name
            )
        }
        guard configured.allSatisfy({ Self.isPrivateIPv4($0.host) }),
              Set(configured.map(\.host)).count == configured.count else {
            validation.stringValue = "Enter a different private IPv4 address for each camera."
            return nil
        }
        guard configured.allSatisfy({ ($0.name?.utf8.count ?? 0) <= 160 }) else {
            validation.stringValue = "Use shorter camera names."
            return nil
        }
        let url = link.stringValue.trimmingCharacters(in: trim)
        let settings = MenuConfiguration(cameras: configured, recordingsURL: url.isEmpty ? nil : url)
        guard url.isEmpty || settings.recordingsLink != nil else {
            validation.stringValue = "Use an HTTPS recordings URL without embedded credentials."
            return nil
        }
        return settings
    }

    static func isPrivateIPv4(_ host: String) -> Bool {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        let octets = parts.compactMap { part -> UInt8? in
            guard let value = UInt8(part), String(value) == part else { return nil }
            return value
        }
        guard parts.count == 4, octets.count == 4 else { return false }
        return octets[0] == 10
            || (octets[0] == 172 && (16...31).contains(octets[1]))
            || (octets[0] == 192 && octets[1] == 168)
    }
}
