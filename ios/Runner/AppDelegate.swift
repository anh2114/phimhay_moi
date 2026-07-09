import UIKit
import Flutter
import AVFoundation
import AVKit
import Network

// MARK: - Local HLS Proxy Server
// Runs on localhost, proxies HLS requests to CDN
// Solves AVPlayer inability to load geo-restricted CDN URLs
class HLSProxyServer {
    static let shared = HLSProxyServer()
    private var listener: NWListener?
    private var connections: [NWConnection] = []
    private let queue = DispatchQueue(label: "hls-proxy", qos: .userInitiated)
    private(set) var port: UInt16 = 0
    private var baseURL: String = ""
    private static let proxyPort: UInt16 = 18963

    func start(baseURL: String) throws {
        self.baseURL = baseURL
        self.port = HLSProxyServer.proxyPort
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        let nwPort = NWEndpoint.Port(rawValue: HLSProxyServer.proxyPort)!
        listener = try NWListener(using: params, on: nwPort)
        listener?.stateUpdateHandler = { state in
            if case .ready = state {
                NSLog("[HLSProxy] Server started on port \(HLSProxyServer.proxyPort)")
            }
            if case .failed(let err) = state {
                NSLog("[HLSProxy] Listener failed: \(err)")
            }
        }
        listener?.newConnectionHandler = { [weak self] conn in
            self?.handleConnection(conn)
        }
        listener?.start(queue: queue)
    }

    func stop() {
        listener?.cancel()
        listener = nil
        connections.forEach { $0.cancel() }
        connections.removeAll()
        port = 0
    }

    private func handleConnection(_ conn: NWConnection) {
        connections.append(conn)
        conn.start(queue: queue)
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
            guard let data = data, !data.isEmpty else {
                conn.cancel()
                return
            }
            let request = String(data: data, encoding: .utf8) ?? ""
            guard let firstLine = request.components(separatedBy: "\r\n").first,
                  let path = firstLine.components(separatedBy: " ").dropFirst().first else {
                conn.cancel()
                return
            }
            // URL decode the path
            let decodedPath = path.removingPercentEncoding ?? path
            NSLog("[HLSProxy] Request: \(decodedPath.prefix(100))")

            // Fetch from CDN and respond
            let targetURL = self.baseURL.hasSuffix("/") ? String(self.baseURL.dropLast()) + decodedPath : decodedPath
            self.proxyRequest(targetURL, to: conn)
        }
    }

    private func proxyRequest(_ urlString: String, to conn: NWConnection) {
        guard let url = URL(string: urlString) else {
            let response = "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\n\r\n"
            conn.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in conn.cancel() })
            return
        }
        let task = URLSession.shared.dataTask(with: url) { data, response, error in
            if let error = error {
                NSLog("[HLSProxy] Fetch error: \(error.localizedDescription)")
                let resp = "HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\n\r\n"
                conn.send(content: resp.data(using: .utf8), completion: .contentProcessed { _ in conn.cancel() })
                return
            }
            let httpResponse = response as? HTTPURLResponse
            let statusCode = httpResponse?.statusCode ?? 200
            var headerStr = "HTTP/1.1 \(statusCode) OK\r\n"
            headerStr += "Content-Type: \(httpResponse?.mimeType ?? "application/octet-stream")\r\n"
            headerStr += "Access-Control-Allow-Origin: *\r\n"
            headerStr += "Connection: close\r\n"
            headerStr += "Cache-Control: no-cache\r\n"
            if let data = data {
                headerStr += "Content-Length: \(data.count)\r\n\r\n"
                var responseData = headerStr.data(using: .utf8)! + data
                conn.send(content: responseData, completion: .contentProcessed { _ in conn.cancel() })
            } else {
                headerStr += "Content-Length: 0\r\n\r\n"
                conn.send(content: headerStr.data(using: .utf8), completion: .contentProcessed { _ in conn.cancel() })
            }
        }
        task.resume()
    }
}

@main
@objc class AppDelegate: FlutterAppDelegate, AVPictureInPictureControllerDelegate {

    private var pipPlayer: AVPlayer?
    private var pipPlayerLayer: AVPlayerLayer?
    private var pipController: AVPictureInPictureController?
    private var pipChannel: FlutterMethodChannel?
    private var pipRestoreURL: String?
    private var pipOverlayView: UIView?
    private var pipPlayerObservations: [NSKeyValueObservation] = []
    private var pipErrorLogObserver: NSObjectProtocol?

    override func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        let controller = window?.rootViewController as! FlutterViewController
        let audioChannel = FlutterMethodChannel(name: "phimhay_app/audio", binaryMessenger: controller.binaryMessenger)

        // Audio channel
        audioChannel.setMethodCallHandler { (call, result) in
            switch call.method {
            case "configureForPlayback":
                let session = AVAudioSession.sharedInstance()
                do {
                    try session.setCategory(.playback, mode: .moviePlayback,
                        options: [.allowBluetooth, .allowBluetoothA2DP])
                    try session.setActive(true)
                    result(true)
                } catch {
                    result(FlutterError(code: "ERROR", message: error.localizedDescription, details: nil))
                }
            case "setSpeaker":
                let args = call.arguments as? [String: Any]
                let on = args?["on"] as? Bool ?? true
                let session = AVAudioSession.sharedInstance()
                do {
                    if on {
                        try session.setCategory(.playAndRecord, mode: .default,
                            options: [.defaultToSpeaker, .allowBluetooth])
                        try session.setActive(true)
                        try session.overrideOutputAudioPort(.speaker)
                    } else {
                        try session.setCategory(.playAndRecord, mode: .voiceChat,
                            options: [.allowBluetooth])
                        try session.setActive(true)
                        try session.overrideOutputAudioPort(.none)
                    }
                    result(true)
                } catch {
                    result(FlutterError(code: "ERROR", message: error.localizedDescription, details: nil))
                }
            case "configAVSession":
                let session = AVAudioSession.sharedInstance()
                do {
                    try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetooth])
                    try session.setActive(true)
                    result(true)
                } catch {
                    result(FlutterError(code: "ERROR", message: error.localizedDescription, details: nil))
                }
            case "activateAudioSession":
                let session = AVAudioSession.sharedInstance()
                do {
                    try session.setCategory(.playAndRecord, mode: .default, options: [.allowBluetooth])
                    try session.setActive(true)
                    result(true)
                } catch {
                    result(FlutterError(code: "ERROR", message: error.localizedDescription, details: nil))
                }
            case "checkMicPermission":
                result(AVAudioSession.sharedInstance().recordPermission == .granted)
            default:
                result(FlutterMethodNotImplemented)
            }
        }

        // AirPlay channel
        let airplayChannel = FlutterMethodChannel(name: "phimhay/airplay", binaryMessenger: controller.binaryMessenger)
        airplayChannel.setMethodCallHandler { (call, result) in
            switch call.method {
            case "showRoutePicker":
                DispatchQueue.main.async {
                    let session = AVAudioSession.sharedInstance()
                    do {
                        try session.setCategory(.playback, mode: .moviePlayback,
                            options: [.allowAirPlay, .allowBluetooth, .allowBluetoothA2DP])
                        try session.setActive(true)
                    } catch {}

                    let overlay = UIView(frame: UIScreen.main.bounds)
                    overlay.backgroundColor = UIColor.black.withAlphaComponent(0.6)
                    overlay.tag = 9999

                    let cardWidth: CGFloat = 280
                    let cardHeight: CGFloat = 200
                    let card = UIView(frame: CGRect(
                        x: (UIScreen.main.bounds.width - cardWidth) / 2,
                        y: (UIScreen.main.bounds.height - cardHeight) / 2,
                        width: cardWidth, height: cardHeight
                    ))
                    card.backgroundColor = UIColor(white: 0.15, alpha: 1)
                    card.layer.cornerRadius = 16

                    let pickerView = AVRoutePickerView(frame: CGRect(x: 0, y: 20, width: cardWidth, height: 120))
                    pickerView.tintColor = .white
                    pickerView.activeTintColor = .systemBlue
                    pickerView.backgroundColor = .clear
                    card.addSubview(pickerView)

                    let label = UILabel(frame: CGRect(x: 0, y: 145, width: cardWidth, height: 30))
                    label.text = "Chạm để chọn thiết bị AirPlay"
                    label.textColor = .white
                    label.textAlignment = .center
                    label.font = .systemFont(ofSize: 13, weight: .medium)
                    card.addSubview(label)

                    overlay.addSubview(card)
                    let tap = UITapGestureRecognizer(target: self, action: #selector(self.dismissAirPlay))
                    overlay.addGestureRecognizer(tap)
                    self.window?.rootViewController?.view.addSubview(overlay)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 30) { overlay.removeFromSuperview() }
                    result(true)
                }
            default:
                result(FlutterMethodNotImplemented)
            }
        }

        // PiP channel
        pipChannel = FlutterMethodChannel(name: "phimhay/pip", binaryMessenger: controller.binaryMessenger)
        pipChannel?.setMethodCallHandler { [weak self] (call, result) in
            guard let self = self else { return }
            switch call.method {
            case "enterPiP":
                guard let args = call.arguments as? [String: Any],
                      let url = args["url"] as? String,
                      let position = args["position"] as? Int else {
                    result(FlutterError(code: "INVALID_ARGS", message: "Missing url or position", details: nil))
                    return
                }
                let headers = args["headers"] as? [String: String] ?? [:]
                self.enterPiP(url: url, position: position, headers: headers, result: result)
            case "isPiP":
                result(self.pipController?.isPictureInPictureActive ?? false)
            case "exitPiP":
                if self.pipController?.isPictureInPictureActive == true {
                    self.pipController?.stopPictureInPicture()
                    result(true)
                } else {
                    result(false)
                }
            default:
                result(FlutterMethodNotImplemented)
            }
        }

        GeneratedPluginRegistrant.register(with: self)
        return super.application(application, didFinishLaunchingWithOptions: launchOptions)
    }

    // MARK: - PiP

    private func enterPiP(url: String, position: Int, headers: [String: String], result: @escaping FlutterResult) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else {
                result(FlutterError(code: "DEALLOC", message: "AppDelegate deallocated", details: nil))
                return
            }

            NSLog("[PiP] enterPiP called — url=\(url.prefix(80))... pos=\(position)")

            // 1. Setup audio session for background playback
            do {
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.playback, mode: .moviePlayback,
                    options: [.allowBluetooth, .allowBluetoothA2DP, .mixWithOthers])
                try session.setActive(true)
                NSLog("[PiP] Audio session OK — category=\(session.category.rawValue)")
            } catch {
                NSLog("[PiP] Audio session setup failed: \(error.localizedDescription)")
            }

            // 2. Validate URL
            guard let streamURL = URL(string: url) else {
                NSLog("[PiP] Invalid URL")
                result(FlutterError(code: "INVALID_URL", message: "Cannot create URL", details: nil))
                return
            }
            NSLog("[PiP] URL scheme=\(streamURL.scheme ?? "nil") host=\(streamURL.host ?? "nil")")

            // 3. Start local HLS proxy (AVPlayer loads from localhost, proxy fetches from CDN)
            let proxy = HLSProxyServer.shared
            proxy.stop() // Stop any previous instance
            do {
                // baseURL = everything before the m3u8 filename
                let fullURL = streamURL.absoluteString
                let baseURL: String
                if let lastSlash = fullURL.lastIndex(of: "/") {
                    baseURL = String(fullURL[fullURL.startIndex...lastSlash])
                } else {
                    baseURL = fullURL
                }
                try proxy.start(baseURL: baseURL)
                NSLog("[PiP] Proxy started on port \(proxy.port), baseURL=\(baseURL.prefix(80))")
            } catch {
                NSLog("[PiP] Proxy start failed: \(error.localizedDescription)")
                // Fallback: use original URL directly
            }

            // 4. Rewrite URL to localhost proxy (if proxy started)
            let finalURL: URL
            if proxy.port > 0 {
                // Extract path from original URL (everything after host)
                let path = streamURL.path // e.g. "/20260602/NfKAemIC/index.m3u8"
                let localURL = URL(string: "http://127.0.0.1:\(proxy.port)\(path)")!
                finalURL = localURL
                NSLog("[PiP] Using local proxy: \(localURL.absoluteString)")
            } else {
                finalURL = streamURL
                NSLog("[PiP] Using direct URL (proxy failed)")
            }

            // 5. Create overlay view — MUST be in window hierarchy for PiP to work
            self.removePiPOverlay()
            let overlayView = UIView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
            overlayView.backgroundColor = .clear
            overlayView.alpha = 0.01   // must stay visible (not isHidden) for PiP to capture the layer
            overlayView.isUserInteractionEnabled = false
            overlayView.tag = 8888
            self.window?.rootViewController?.view.addSubview(overlayView)
            self.pipOverlayView = overlayView

            // 6. Create AVPlayerLayer and attach to overlay view
            let asset = AVURLAsset(url: finalURL)
            let playerItem = AVPlayerItem(asset: asset)
            playerItem.preferredForwardBufferDuration = 10
            let player = AVPlayer(playerItem: playerItem)
            player.allowsExternalPlayback = true
            let playerLayer = AVPlayerLayer(player: player)
            playerLayer.frame = overlayView.bounds
            overlayView.layer.addSublayer(playerLayer)
            self.pipPlayerLayer = playerLayer
            self.pipPlayer = player
            self.pipRestoreURL = url

            // 6. Create PiP controller
            guard let pipController = AVPictureInPictureController(playerLayer: playerLayer) else {
                NSLog("[PiP] Failed to create AVPictureInPictureController")
                self.removePiPOverlay()
                self.pipChannel?.invokeMethod("onPiPError", arguments: "PiP not available on this device")
                result(FlutterError(code: "NO_PIP", message: "AVPictureInPictureController not available", details: nil))
                return
            }
            pipController.delegate = self
            self.pipController = pipController

            NSLog("[PiP] Player + controller created, waiting for player ready...")

            // 7. Wait for player to be ready (status = .readyToPlay)
            // Use timeout: if not ready in 20s, fail (đủ thời gian cho DNS+TLS+tải segment đầu trên mobile)
            var observed = false
            let timeoutWork = DispatchWorkItem { [weak self] in
                guard !observed, let self = self else { return }
                observed = true
                NSLog("[PiP] TIMEOUT — player not ready in 20s. itemStatus=\(playerItem.status.rawValue) itemError=\(playerItem.error?.localizedDescription ?? "nil")")
                self.removePiPOverlay()
                self.pipChannel?.invokeMethod("onPiPError", arguments: "Player timeout")
                result(FlutterError(code: "TIMEOUT", message: "Player did not become ready in 20s: \(playerItem.error?.localizedDescription ?? "unknown reason")", details: nil))
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: timeoutWork)

            // Log lỗi HTTP thật của từng request (manifest/segment) — rất hữu ích để biết
            // chính xác lý do treo: 403, 404, timeout mạng, DNS, v.v.
            pipErrorLogObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.newErrorLogEntryNotification, object: playerItem, queue: .main) { _ in
                guard let entry = playerItem.errorLog()?.events.last else { return }
                NSLog("[PiP] HLS error log — URI=\(entry.uri ?? "?") statusCode=\(entry.errorStatusCode) domain=\(entry.errorDomain) comment=\(entry.errorComment ?? "nil")")
            }

            // Observe cả playerItem.status (đáng tin hơn player.status, có kèm error cụ thể)
            let itemObservation = playerItem.observe(\.status, options: [.new]) { item, _ in
                if item.status == .failed {
                    NSLog("[PiP] PlayerItem FAILED: \(item.error?.localizedDescription ?? "unknown")")
                }
            }
            self.pipPlayerObservations.append(itemObservation)

            let observation = player.observe(\.status, options: [.new]) { [weak self] player, change in
                guard let self = self, !observed else { return }
                guard change.newValue == .readyToPlay else {
                    if change.newValue == .failed {
                        observed = true
                        timeoutWork.cancel()
                        NSLog("[PiP] Player FAILED: \(player.error?.localizedDescription ?? "unknown")")
                        self.removePiPOverlay()
                        DispatchQueue.main.async {
                            self.pipChannel?.invokeMethod("onPiPError", arguments: player.error?.localizedDescription ?? "Player failed")
                            result(FlutterError(code: "PLAYER_FAILED", message: player.error?.localizedDescription ?? "Player failed", details: nil))
                        }
                    }
                    return
                }

                // Player is ready
                observed = true
                timeoutWork.cancel()
                NSLog("[PiP] Player ready — seeking to \(position)s")

                // Seek to position
                let targetTime = CMTime(seconds: Double(position), preferredTimescale: 600)
                player.seek(to: targetTime, toleranceBefore: .zero, toleranceAfter: .zero) { _ in
                    DispatchQueue.main.async {
                        NSLog("[PiP] Seek complete — starting PiP")
                        player.play()
                        pipController.startPictureInPicture()
                        // Result will be returned in delegate callback
                        // But return true here to indicate PiP was initiated
                        result(true)
                    }
                }
            }
            self.pipPlayerObservations.append(observation)
        }
    }

    private func removePiPOverlay() {
        pipPlayerObservations.removeAll()
        if let token = pipErrorLogObserver {
            NotificationCenter.default.removeObserver(token)
            pipErrorLogObserver = nil
        }
        pipPlayerLayer?.removeFromSuperlayer()
        pipPlayerLayer = nil
        pipPlayer?.pause()
        pipPlayer = nil
        pipOverlayView?.removeFromSuperview()
        pipOverlayView = nil
        // Stop local proxy server
        HLSProxyServer.shared.stop()
    }

    // MARK: - AVPictureInPictureControllerDelegate

    func pictureInPictureControllerWillStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        NSLog("[PiP] Will start")
        pipChannel?.invokeMethod("onPiPModeChanged", arguments: true)
    }

    func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        NSLog("[PiP] Did start — PiP is active")
    }

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error) {
        NSLog("[PiP] FAILED to start: \(error.localizedDescription)")
        pipChannel?.invokeMethod("onPiPError", arguments: error.localizedDescription)
        removePiPOverlay()
    }

    func pictureInPictureControllerWillStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        NSLog("[PiP] Will stop — user tapped restore")
        pipChannel?.invokeMethod("onPiPModeChanged", arguments: false)
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        NSLog("[PiP] Did stop")
        // Get position before cleanup
        let position = Int(pipPlayer?.currentTime().seconds ?? 0)
        NSLog("[PiP] Stopping — position=\(position)")

        // Cleanup native player
        removePiPOverlay()

        // Notify Flutter to resume at position
        DispatchQueue.main.async { [weak self] in
            self?.pipChannel?.invokeMethod("onPiPRestore", arguments: ["position": position])
        }
    }

    @objc func dismissAirPlay() {
        window?.rootViewController?.view.viewWithTag(9999)?.removeFromSuperview()
    }
}