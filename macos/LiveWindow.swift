import AppKit
import ImageIO

struct JPEGFrames {
    private static let start = Data([0xff, 0xd8])
    private static let end = Data([0xff, 0xd9])
    private var buffer = Data()

    mutating func append(_ data: Data) -> Data? {
        buffer.append(data)
        var latest: Data?
        while let start = buffer.range(of: Self.start) {
            if start.lowerBound > buffer.startIndex {
                buffer.removeSubrange(buffer.startIndex..<start.lowerBound)
            }
            let payloadStart = buffer.index(buffer.startIndex, offsetBy: 2)
            guard let end = buffer.range(of: Self.end, in: payloadStart..<buffer.endIndex) else {
                if buffer.count > 8 * 1024 * 1024 { buffer.removeAll() }
                return latest
            }
            latest = Data(buffer[..<end.upperBound])
            buffer.removeSubrange(buffer.startIndex..<end.upperBound)
        }
        // Keep a possible split marker across URLSession chunks.
        buffer = buffer.last == 0xff ? Data([0xff]) : Data()
        return latest
    }
}

private final class LiveFeed: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    let onFrame: (Data) -> Void
    let onFinish: (String, Bool) -> Void
    private var session: URLSession?
    private var frames = JPEGFrames()
    private var statusCode: Int?
    private var deliveredFrame = false
    private let frameLock = NSLock()
    private var pendingFrame: Data?

    init(onFrame: @escaping (Data) -> Void, onFinish: @escaping (String, Bool) -> Void) {
        self.onFrame = onFrame
        self.onFinish = onFinish
    }

    func start(_ source: URLRequest) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 65
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        self.session = session
        var request = source
        request.timeoutInterval = 65
        session.dataTask(with: request).resume()
    }

    func stop() {
        session?.invalidateAndCancel()
        session = nil
    }

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        statusCode = (response as? HTTPURLResponse)?.statusCode
        completionHandler(statusCode == 200 ? .allow : .cancel)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let frame = frames.append(data) else { return }
        deliveredFrame = true
        frameLock.lock()
        let needsDelivery = pendingFrame == nil
        pendingFrame = frame
        frameLock.unlock()
        if needsDelivery {
            DispatchQueue.main.async { [weak self] in self?.deliverFrame() }
        }
    }

    private func deliverFrame() {
        frameLock.lock()
        let frame = pendingFrame
        pendingFrame = nil
        frameLock.unlock()
        if let frame { onFrame(frame) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let text: String
        let canReconnect: Bool
        switch statusCode {
        case 401, 403:
            text = "Sign in again from Tapo Menu to refresh camera access."
            canReconnect = false
        case 404, 409, 500:
            text = "Check this camera’s configuration in Settings."
            canReconnect = false
        case 503:
            text = "The local video decoder is unavailable. Rebuild Tapo Menu with FFmpeg."
            canReconnect = false
        case 502:
            text = "The camera did not start video. Wake it and check its network connection."
            canReconnect = true
        default:
            canReconnect = true
            if !deliveredFrame {
                text = "No video frame arrived. Wake the camera and try again."
            } else {
                text = error == nil ? "Live view ended." : "Live view disconnected."
            }
        }
        DispatchQueue.main.async { [onFinish] in onFinish(text, canReconnect) }
        session.finishTasksAndInvalidate()
    }
}

final class LiveWindow: NSObject, NSWindowDelegate {
    private let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 800, height: 450),
        styleMask: [.titled, .closable, .resizable, .miniaturizable],
        backing: .buffered, defer: false
    )
    private let imageView = NSImageView()
    private let label = NSTextField(wrappingLabelWithString: "")
    private let spinner = NSProgressIndicator()
    private let retryButton = NSButton(title: "Retry", target: nil, action: nil)
    private let overlay = NSStackView()
    private var feed: LiveFeed?
    private var generation = UUID()
    private var startupMessage: DispatchWorkItem?
    private var startupTimeout: DispatchWorkItem?
    private var reconnectTask: DispatchWorkItem?
    private var stallTimer: Timer?
    private var lastFrameAt: TimeInterval?
    private var makeRequest: (() -> URLRequest?)?
    private var cameraName = ""
    private var attempts = 0

    override init() {
        super.init()
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentMinSize = NSSize(width: 420, height: 236)
        window.backgroundColor = .black
        let content = NSView()
        window.contentView = content
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.imageScaling = .scaleProportionallyUpOrDown
        label.alignment = .center
        label.textColor = .white
        label.font = .systemFont(ofSize: 14)
        spinner.style = .spinning
        spinner.controlSize = .regular
        spinner.appearance = NSAppearance(named: .darkAqua)
        retryButton.target = self
        retryButton.action = #selector(retryClicked)
        retryButton.keyEquivalent = "\r"
        overlay.orientation = .vertical
        overlay.alignment = .centerX
        overlay.spacing = 12
        overlay.translatesAutoresizingMaskIntoConstraints = false
        overlay.addArrangedSubview(spinner)
        overlay.addArrangedSubview(label)
        overlay.addArrangedSubview(retryButton)
        content.addSubview(imageView)
        content.addSubview(overlay)
        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            imageView.topAnchor.constraint(equalTo: content.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            overlay.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            overlay.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            overlay.widthAnchor.constraint(lessThanOrEqualTo: content.widthAnchor, multiplier: 0.8),
        ])
        window.center()
    }

    func show(camera: String, makeRequest: @escaping () -> URLRequest?) {
        stop()
        self.makeRequest = makeRequest
        cameraName = camera
        window.deminiaturize(nil)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        connect(reconnecting: false)
    }

    private func connect(reconnecting: Bool) {
        window.title = "\(cameraName) · \(reconnecting ? "Reconnecting" : "Connecting")"
        imageView.image = nil
        label.stringValue = "\(reconnecting ? "Reconnecting" : "Connecting") to \(cameraName)…"
        overlay.isHidden = false
        spinner.isHidden = false
        spinner.startAnimation(nil)
        retryButton.isHidden = true
        guard let request = makeRequest?() else {
            interrupted("The local camera connection could not start. Try again after checking Node.js.", retry: true)
            return
        }
        let current = generation
        let feed = LiveFeed(onFrame: { [weak self] bytes in
            guard let self, self.generation == current,
                  let source = CGImageSourceCreateWithData(bytes as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return }
            self.present(image)
        }, onFinish: { [weak self] message, canReconnect in
            guard let self, self.generation == current else { return }
            self.interrupted(message, retry: canReconnect)
        })
        self.feed = feed
        let message = DispatchWorkItem { [weak self] in
            guard let self, self.generation == current else { return }
            self.label.stringValue = "Waiting for video from \(self.cameraName)…"
        }
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, self.generation == current else { return }
            self.interrupted("No video frame arrived. Wake the camera and try again.", retry: true)
        }
        startupMessage = message
        startupTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: message)
        DispatchQueue.main.asyncAfter(deadline: .now() + 63, execute: timeout)
        feed.start(request)
    }

    private func present(_ image: CGImage) {
        imageView.alphaValue = 1
        imageView.image = NSImage(cgImage: image, size: .zero)
        lastFrameAt = ProcessInfo.processInfo.systemUptime
        guard stallTimer == nil else { return }
        clearStartup()
        spinner.stopAnimation(nil)
        overlay.isHidden = true
        window.title = "\(cameraName) · Live"
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            guard let self, let lastFrameAt = self.lastFrameAt,
                  ProcessInfo.processInfo.systemUptime - lastFrameAt >= 8 else { return }
            self.interrupted("Video stalled.", retry: true)
        }
        stallTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func connectionLost() {
        if feed != nil { interrupted("The local camera connection stopped.", retry: true) }
    }

    private func interrupted(_ message: String, retry: Bool) {
        cancelConnection()
        guard window.isVisible, !window.isMiniaturized else { return }
        if retry && attempts < 2 {
            attempts += 1
            imageView.alphaValue = 0.35
            window.title = "\(cameraName) · Reconnecting"
            label.stringValue = "\(message) Reconnecting…"
            overlay.isHidden = false
            spinner.isHidden = false
            spinner.startAnimation(nil)
            retryButton.isHidden = true
            let current = generation
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.generation == current else { return }
                self.connect(reconnecting: true)
            }
            reconnectTask = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(attempts * 2), execute: work)
            return
        }
        showFailure(message)
    }

    private func showFailure(_ message: String) {
        window.title = "\(cameraName) · Paused"
        imageView.image = nil
        label.stringValue = message
        overlay.isHidden = false
        spinner.isHidden = true
        retryButton.isHidden = makeRequest == nil
    }

    @objc private func retryClicked() {
        cancelConnection()
        attempts = 0
        connect(reconnecting: false)
    }

    private func clearStartup() {
        startupMessage?.cancel()
        startupMessage = nil
        startupTimeout?.cancel()
        startupTimeout = nil
    }

    private func cancelConnection() {
        generation = UUID()
        clearStartup()
        reconnectTask?.cancel()
        reconnectTask = nil
        stallTimer?.invalidate()
        stallTimer = nil
        lastFrameAt = nil
        spinner.stopAnimation(nil)
        feed?.stop()
        feed = nil
    }

    func stop() {
        cancelConnection()
        makeRequest = nil
        attempts = 0
    }

    func close() {
        window.close()
    }

    func windowWillClose(_ notification: Notification) {
        stop()
    }
    func windowDidMiniaturize(_ notification: Notification) {
        cancelConnection()
        showFailure("Live view paused.")
    }
}
