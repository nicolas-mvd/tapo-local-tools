import Foundation

struct CameraStatus: Decodable {
    let id: String
    let batteryPercent: Int?
    let charging: Bool?
    let online: Bool
}

struct MenuStatus: Decodable {
    let cameras: [CameraStatus]
    let hasCredentials: Bool
}

final class TapoBridge {
    private struct Startup: Decodable { let port: Int }

    let supportDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Tapo Menu", isDirectory: true)
    var configFile: URL { supportDirectory.appendingPathComponent("config.json") }
    var tokenFile: URL { supportDirectory.appendingPathComponent("camera-tokens.json") }
    var onStateChange: (() -> Void)?
    private(set) var port: Int?
    private(set) var failed = false

    private let token = UUID().uuidString + UUID().uuidString
    private var process: Process?
    private var output: Pipe?
    private var startup = Data()
    private var startupTimeout: DispatchWorkItem?
    private let session = URLSession(configuration: .ephemeral)

    func start() {
        guard process == nil else { return }
        guard let resources = Bundle.main.resourceURL,
              let node = Bundle.main.object(forInfoDictionaryKey: "TapoNodeExecutable") as? String else {
            failed = true
            onStateChange?()
            return
        }

        let child = Process()
        let pipe = Pipe()
        child.executableURL = URL(fileURLWithPath: node)
        child.arguments = [resources.appendingPathComponent("macos/bridge.cjs").path]
        child.standardOutput = pipe
        child.standardError = FileHandle.nullDevice
        child.standardInput = FileHandle.nullDevice
        var environment = ProcessInfo.processInfo.environment
        for key in ["NODE_OPTIONS", "NODE_PATH", "PYTHONHOME", "PYTHONPATH"] {
            environment.removeValue(forKey: key)
        }
        environment["TAPO_BRIDGE_TOKEN"] = token
        environment["TAPO_CONFIG"] = configFile.path
        environment["TAPO_TOKEN_FILE"] = tokenFile.path
        environment["TAPO_FFMPEG"] = resources.appendingPathComponent("ffmpeg").path
        environment["TAPO_PYTHON"] = "/usr/bin/python3"
        child.environment = environment

        failed = false
        startup = Data()
        process = child
        output = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self, weak child] handle in
            let bytes = handle.availableData
            DispatchQueue.main.async {
                guard let self, let child, self.process === child, self.port == nil else { return }
                self.receiveStartup(bytes)
            }
        }
        child.terminationHandler = { [weak self] finished in
            DispatchQueue.main.async {
                guard let self, self.process === finished else { return }
                self.stop()
                self.failed = true
                self.onStateChange?()
            }
        }

        do {
            try child.run()
            let timeout = DispatchWorkItem { [weak self] in
                guard let self, self.port == nil else { return }
                self.stop()
                self.failed = true
                self.onStateChange?()
            }
            startupTimeout = timeout
            DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: timeout)
        } catch {
            stop()
            failed = true
            onStateChange?()
        }
    }

    private func receiveStartup(_ bytes: Data) {
        guard !bytes.isEmpty else { return }
        startup.append(bytes)
        guard startup.count <= 512 else {
            stop()
            failed = true
            onStateChange?()
            return
        }
        guard let newline = startup.firstIndex(of: 10) else { return }
        guard let reply = try? JSONDecoder().decode(Startup.self, from: startup.prefix(upTo: newline)),
              (1...65535).contains(reply.port) else {
            stop()
            failed = true
            onStateChange?()
            return
        }
        startupTimeout?.cancel()
        output?.fileHandleForReading.readabilityHandler = nil
        port = reply.port
        onStateChange?()
    }

    func stop() {
        startupTimeout?.cancel()
        startupTimeout = nil
        output?.fileHandleForReading.readabilityHandler = nil
        output = nil
        let child = process
        process = nil
        port = nil
        if child?.isRunning == true { child?.terminate() }
    }

    func request(_ endpoint: String) -> URLRequest? {
        guard let port, let url = URL(string: "http://127.0.0.1:\(port)\(endpoint)") else { return nil }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    func status(completion: @escaping (MenuStatus?) -> Void) {
        guard var request = request("/status") else { completion(nil); return }
        request.timeoutInterval = 8
        session.dataTask(with: request) { data, response, _ in
            var status: MenuStatus?
            if (response as? HTTPURLResponse)?.statusCode == 200, let data {
                status = try? JSONDecoder().decode(MenuStatus.self, from: data)
            }
            let result = status
            RunLoop.main.perform(inModes: [.common, .eventTracking]) {
                completion(result)
            }
        }.resume()
    }
}
