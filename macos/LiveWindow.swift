import AppKit

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
    let onFinish: (String) -> Void
    private var session: URLSession?
    private var frames = JPEGFrames()
    private var statusCode: Int?
    private var deliveredFrame = false

    init(onFrame: @escaping (Data) -> Void, onFinish: @escaping (String) -> Void) {
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
        DispatchQueue.main.async { [onFrame] in onFrame(frame) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let text: String
        switch statusCode {
        case 401, 403: text = "Sign in again from the Tapo Menu icon to refresh camera access."
        case 409: text = "Set up your cameras from the Tapo Menu icon."
        case 503: text = "The local video decoder is unavailable."
        case 502: text = "The camera did not start video. Wake it and try again."
        default:
            if !deliveredFrame {
                text = "No video frame arrived. Wake the camera and try again."
            } else {
                text = error == nil ? "Live view ended." : "Live view disconnected."
            }
        }
        DispatchQueue.main.async { [onFinish] in onFinish(text) }
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
    private var retry: (() -> Void)?

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

    func show(camera: String, request: URLRequest, onRetry: @escaping () -> Void) {
        stop()
        retry = onRetry
        window.title = "Cam \(camera) · Live"
        imageView.image = nil
        label.stringValue = "Connecting to Cam \(camera)…"
        overlay.isHidden = false
        spinner.isHidden = false
        spinner.startAnimation(nil)
        retryButton.isHidden = true
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        let current = generation
        let feed = LiveFeed(onFrame: { [weak self] bytes in
            guard let self, self.generation == current, let frame = NSImage(data: bytes) else { return }
            self.imageView.image = frame
            self.clearStartup()
            self.spinner.stopAnimation(nil)
            self.overlay.isHidden = true
        }, onFinish: { [weak self] message in
            guard let self, self.generation == current else { return }
            self.showFailure(message)
        })
        self.feed = feed
        let message = DispatchWorkItem { [weak self] in
            guard let self, self.generation == current else { return }
            self.label.stringValue = "Waiting for video from Cam \(camera)…"
        }
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, self.generation == current else { return }
            self.showFailure("No video frame arrived. Wake the camera and try again.")
        }
        startupMessage = message
        startupTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: message)
        DispatchQueue.main.asyncAfter(deadline: .now() + 63, execute: timeout)
        feed.start(request)
    }

    func showFailure(_ message: String) {
        stop()
        imageView.image = nil
        label.stringValue = message
        overlay.isHidden = false
        spinner.isHidden = true
        retryButton.isHidden = retry == nil
    }

    @objc private func retryClicked() { retry?() }

    private func clearStartup() {
        startupMessage?.cancel()
        startupMessage = nil
        startupTimeout?.cancel()
        startupTimeout = nil
    }

    func stop() {
        generation = UUID()
        clearStartup()
        spinner.stopAnimation(nil)
        feed?.stop()
        feed = nil
    }

    func windowWillClose(_ notification: Notification) {
        stop()
        retry = nil
    }
    func windowDidMiniaturize(_ notification: Notification) {
        showFailure("Live view paused.")
    }
}
