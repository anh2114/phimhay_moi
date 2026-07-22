import UIKit
import Flutter
import AVFoundation
import AVKit

@main
@objc class AppDelegate: FlutterAppDelegate, AVPictureInPictureControllerDelegate {

    // MARK: - PiP State (iOS 15+ only, like YouPiP)
    private var pipPlayer: AVPlayer?
    private var pipPlayerLayer: AVPlayerLayer?
    private var pipController: AVPictureInPictureController?
    private var pipChannel: FlutterMethodChannel?
    private var pipRestoreURL: String?
    private var pipRestorePosition: Int = 0
    private var pipPrepared = false
    private var pipIsMuted = true
    private var pipPlayerObservations: [NSKeyValueObservation] = []
    private var pipErrorLogObserver: NSObjectProtocol?
    private var pipPositionSyncTimer: Timer?

    func pipLog(_ msg: String) {
        NSLog("[PiP] \(msg)")
        pipChannel?.invokeMethod("onPiPLog", arguments: msg)
    }

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
                        options: [.allowBluetooth, .allowBluetoothA2DP, .allowAirPlay])
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
            case "preparePiP":
                guard let args = call.arguments as? [String: Any],
                      let url = args["url"] as? String else {
                    result(false)
                    return
                }
                let position = args["position"] as? Int ?? 0
                let headers = args["headers"] as? [String: String] ?? [:]
                self.preparePiP(url: url, position: position, headers: headers)
                result(true)
            case "isPiP":
                result(self.pipController?.isPictureInPictureActive ?? false)
            case "exitPiP":
                if self.pipController?.isPictureInPictureActive == true {
                    self.pipController?.stopPictureInPicture()
                    result(true)
                } else {
                    result(false)
                }
            case "syncPosition":
                guard let args = call.arguments as? [String: Any],
                      let position = args["position"] as? Int else {
                    result(false)
                    return
                }
                self.syncPosition(position)
                result(true)
            case "pauseSync":
                self.pipPlayer?.pause()
                result(true)
            default:
                result(FlutterMethodNotImplemented)
            }
        }

        GeneratedPluginRegistrant.register(with: self)
        return super.application(application, didFinishLaunchingWithOptions: launchOptions)
    }

    // MARK: - PiP Implementation (iOS 15+ style, like YouPiP)

    /// Pre-buffer: tạo AVPlayer + PiP controller sẵn, muted, đang play để buffer
    /// Khi bấm PiP → chỉ unmute + startPictureInPicture → instant PiP
    private func preparePiP(url: String, position: Int = 0, headers: [String: String] = [:]) {
        // Cleanup trước
        cleanupPiP()

        guard let streamURL = URL(string: url) else {
            pipLog("Invalid URL: \(url.prefix(60))")
            return
        }

        pipLog("preparePiP: \(url.prefix(60))... pos=\(position)")

        // 1. Audio session — phải setup trước khi AVPlayer play
        configureAudioSession()

        // 2. Create AVPlayer with headers (Cloudflare streams cần headers)
        let asset: AVURLAsset
        if headers.isEmpty {
            asset = AVURLAsset(url: streamURL)
        } else {
            asset = AVURLAsset(url: streamURL, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
        }

        let playerItem = AVPlayerItem(asset: asset)
        playerItem.preferredForwardBufferDuration = 30 // Buffer 30s ahead

        let player = AVPlayer(playerItem: playerItem)
        player.allowsExternalPlayback = true
        player.isMuted = true // Muted — pre-buffer không phát âm thanh
        pipIsMuted = true

        // 3. Create PlayerLayer (ẩn) — PiP cần layer để capture
        let playerLayer = AVPlayerLayer(player: player)
        playerLayer.frame = CGRect(x: 0, y: 0, width: 1, height: 1) // Ẩm 1px
        playerLayer.videoGravity = .resizeAspect
        // Thêm vào window nhưng ẩn
        if let window = self.window {
            window.layer.addSublayer(playerLayer)
        }
        pipPlayerLayer = playerLayer
        pipPlayer = player
        pipRestoreURL = url
        pipRestorePosition = position

        // 4. Seek đến position TRƯỚC khi play (nếu có)
        if position > 0 {
            let targetTime = CMTime(seconds: Double(position), preferredTimescale: 600)
            player.seek(to: targetTime, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                // Seek xong → play muted để bắt đầu buffer
                player.play()
                self?.pipLog("Pre-buffer: seeked to \(position)s, playing muted")
            }
        } else {
            player.play()
            pipLog("Pre-buffer: playing muted from start")
        }

        // 5. Create PiP controller
        guard let pipController = AVPictureInPictureController(playerLayer: playerLayer) else {
            pipLog("Failed to create PiP controller")
            cleanupPiP()
            return
        }

        pipController.delegate = self
        self.pipController = pipController
        pipPrepared = true

        // 6. Bắt đầu sync position từ Flutter → native player
        startPositionSync()

        pipLog("preparePiP done — ready at \(position)s")
    }

    /// Enter PiP — gọi khi user bấm nút PiP
    private func enterPiP(url: String, position: Int, headers: [String: String], result: @escaping FlutterResult) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else {
                result(FlutterError(code: "DEALLOC", message: "AppDelegate deallocated", details: nil))
                return
            }

            self.pipLog("enterPiP: pos=\(position)")

            // Nếu đã prepare sẵn → instant PiP (như YouTube)
            if self.pipPrepared, let pipController = self.pipController, let player = self.pipPlayer {
                self.pipLog("Using pre-buffered player — instant PiP")

                // Sync position trước khi start PiP
                let currentPos = Int(player.currentTime().seconds)
                if abs(currentPos - position) > 3 {
                    let targetTime = CMTime(seconds: Double(position), preferredTimescale: 600)
                    player.seek(to: targetTime, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                        guard let self = self else { return }
                        DispatchQueue.main.async {
                            self.startPiPPlayback(player: player, pipController: pipController, result: result)
                        }
                    }
                } else {
                    self.startPiPPlayback(player: player, pipController: pipController, result: result)
                }
                return
            }

            // Fallback: tạo mới (slow path)
            self.pipLog("No pre-buffer — creating new player")
            self.preparePiP(url: url, position: position, headers: headers)

            // Chờ player ready rồi start PiP
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self = self, let pipController = self.pipController, let player = self.pipPlayer else {
                    result(FlutterError(code: "PREPARE_FAILED", message: "Failed to prepare PiP", details: nil))
                    return
                }
                self.startPiPPlayback(player: player, pipController: pipController, result: result)
            }
        }
    }

    /// Start PiP playback — unmute + startPictureInPicture
    private func startPiPPlayback(player: AVPlayer, pipController: AVPictureInPictureController, result: @escaping FlutterResult) {
        // Unmute + play
        player.isMuted = false
        pipIsMuted = false
        if player.timeControlStatus != .playing {
            player.play()
        }

        // Notify Flutter PiP starting
        pipChannel?.invokeMethod("onPiPModeChanged", arguments: true)

        // Start PiP
        let started = pipController.startPictureInPicture()
        pipLog("startPictureInPicture: \(started)")

        result(started)
    }

    /// Sync Flutter player position → native AVPlayer
    private func syncPosition(_ flutterPosition: Int) {
        guard let player = pipPlayer, pipPrepared else { return }

        // Không sync khi PiP đang active — native player đang control
        if pipController?.isPictureInPictureActive == true { return }

        let avPosition = Int(player.currentTime().seconds)
        let offset = abs(avPosition - flutterPosition)

        // Chỉ sync khi offset > 3s — tránh seek liên tục
        if offset > 3 {
            let targetTime = CMTime(seconds: Double(flutterPosition), preferredTimescale: 600)
            player.seek(to: targetTime, toleranceBefore: .zero, toleranceAfter: .zero)
            pipRestorePosition = flutterPosition
            pipLog("Sync: Flutter \(flutterPosition)s → AVPlayer (was \(avPosition)s)")
        }
    }

    /// Bắt đầu timer sync position mỗi 2s
    private func startPositionSync() {
        pipPositionSyncTimer?.invalidate()
        pipPositionSyncTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            // Timer chỉ用来log, actual sync từ Flutter qua method channel
        }
    }

    private func stopPositionSync() {
        pipPositionSyncTimer?.invalidate()
        pipPositionSyncTimer = nil
    }

    /// Setup audio session cho PiP
    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .moviePlayback,
                options: [.allowBluetooth, .allowBluetoothA2DP, .allowAirPlay])
            try session.setActive(true)
        } catch {
            pipLog("Audio session error: \(error.localizedDescription)")
        }
    }

    /// Cleanup PiP resources
    private func cleanupPiP() {
        stopPositionSync()
        pipPlayerObservations.removeAll()
        if let token = pipErrorLogObserver {
            NotificationCenter.default.removeObserver(token)
            pipErrorLogObserver = nil
        }
        pipPlayerLayer?.removeFromSuperlayer()
        pipPlayerLayer = nil
        pipPlayer?.pause()
        pipPlayer = nil
        pipController = nil
        pipPrepared = false
        pipIsMuted = true
    }

    // MARK: - AVPictureInPictureControllerDelegate

    func pictureInPictureControllerWillStartPictureInPicture(_ controller: AVPictureInPictureController) {
        pipLog("Will start — PiP capturing")
        // Notify Flutter PiP đang start
        pipChannel?.invokeMethod("onPiPModeChanged", arguments: true)
    }

    func pictureInPictureControllerDidStartPictureInPicture(_ controller: AVPictureInPictureController) {
        pipLog("Did start — PiP is ACTIVE")
    }

    func pictureInPictureController(_ controller: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error) {
        pipLog("FAILED: \(error.localizedDescription)")
        pipChannel?.invokeMethod("onPiPError", arguments: error.localizedDescription)
        // Không cleanup — giữ player để retry
    }

    func pictureInPictureControllerWillStopPictureInPicture(_ controller: AVPictureInPictureController) {
        pipLog("Will stop — user tapped restore")
        pipChannel?.invokeMethod("onPiPModeChanged", arguments: false)
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
        pipLog("Did stop")
        let position = Int(pipPlayer?.currentTime().seconds ?? 0)
        pipRestorePosition = position

        // Giữ player + layer → lần PiP tiếp theo instant (như YouTube)
        // Mute + pause để tránh 2 âm thanh chạy cùng lúc
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.pipPlayer?.isMuted = true
            self.pipIsMuted = true
            self.pipPlayer?.pause()
        }

        // Notify Flutter restore tại position
        pipChannel?.invokeMethod("onPiPRestore", arguments: ["position": position])
    }

    /// Xử lý PiP restore playback (khi user tap play trong PiP window)
    func pictureInPictureController(_ controller: AVPictureInPictureController, restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        pipLog("Restore — returning to app")
        completionHandler(true)
    }

    @objc func dismissAirPlay() {
        window?.rootViewController?.view.viewWithTag(9999)?.removeFromSuperview()
    }
}
