import UIKit
import Flutter
import AVFoundation
import AVKit

@main
@objc class AppDelegate: FlutterAppDelegate, AVPictureInPictureControllerDelegate {

    // MARK: - PiP Pre-buffer State (like YouPiP)
    private var pipPlayer: AVPlayer?
    private var pipPlayerLayer: AVPlayerLayer?
    private var pipController: AVPictureInPictureController?
    private var pipChannel: FlutterMethodChannel?
    private var pipRestorePosition: Int = 0
    private var pipPrepared = false
    private var pipUrl: String = ""
    private var pipWasDismissed = false // true = user tapped X to dismiss PiP

    func pipLog(_ msg: String) {
        NSLog("[PiP] \(msg)")
        DispatchQueue.main.async { [weak self] in
            self?.pipChannel?.invokeMethod("onPiPLog", arguments: msg)
        }
    }

    override func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        let controller = window?.rootViewController as! FlutterViewController

        // Audio channel
        let audioChannel = FlutterMethodChannel(name: "phimhay_app/audio", binaryMessenger: controller.binaryMessenger)
        audioChannel.setMethodCallHandler { (call, result) in
            switch call.method {
            case "configureForPlayback":
                do {
                    let session = AVAudioSession.sharedInstance()
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
                do {
                    let session = AVAudioSession.sharedInstance()
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
                do {
                    let session = AVAudioSession.sharedInstance()
                    try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetooth])
                    try session.setActive(true)
                    result(true)
                } catch {
                    result(FlutterError(code: "ERROR", message: error.localizedDescription, details: nil))
                }
            case "activateAudioSession":
                do {
                    let session = AVAudioSession.sharedInstance()
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
        airplayChannel.setMethodCallHandler { [weak self] (call, result) in
            switch call.method {
            case "showRoutePicker":
                DispatchQueue.main.async {
                    // ★ FIX: Nếu picker đang mở → dismiss trước, không mở lại
                    if self?.window?.rootViewController?.view.viewWithTag(9999) != nil {
                        self?.dismissAirPlay()
                        result(true)
                        return
                    }

                    do {
                        let session = AVAudioSession.sharedInstance()
                        try session.setCategory(.playback, mode: .moviePlayback,
                            options: [.allowAirPlay, .allowBluetooth, .allowBluetoothA2DP])
                        try session.setActive(true)
                    } catch {}

                    let overlay = UIView(frame: UIScreen.main.bounds)
                    overlay.backgroundColor = UIColor.black.withAlphaComponent(0.6)
                    overlay.tag = 9999

                    let cardWidth: CGFloat = 280
                    let cardHeight: CGFloat = 240
                    let card = UIView(frame: CGRect(
                        x: (UIScreen.main.bounds.width - cardWidth) / 2,
                        y: (UIScreen.main.bounds.height - cardHeight) / 2,
                        width: cardWidth, height: cardHeight
                    ))
                    card.backgroundColor = UIColor(white: 0.15, alpha: 1)
                    card.layer.cornerRadius = 16

                    // ★ FIX: Close button — dismiss ngay khi bấm
                    let closeButton = UIButton(type: .system)
                    closeButton.frame = CGRect(x: cardWidth - 36, y: 8, width: 28, height: 28)
                    closeButton.setTitle("✕", for: .normal)
                    closeButton.titleLabel?.font = .systemFont(ofSize: 16, weight: .bold)
                    closeButton.setTitleColor(.white, for: .normal)
                    closeButton.addTarget(self, action: #selector(self?.dismissAirPlay), for: .touchUpInside)
                    card.addSubview(closeButton)

                    let pickerView = AVRoutePickerView(frame: CGRect(x: 0, y: 20, width: cardWidth, height: 140))
                    pickerView.tintColor = .white
                    pickerView.activeTintColor = .systemBlue
                    pickerView.backgroundColor = .clear
                    card.addSubview(pickerView)

                    let label = UILabel(frame: CGRect(x: 0, y: 170, width: cardWidth, height: 30))
                    label.text = "Chạm để chọn thiết bị AirPlay"
                    label.textColor = .white
                    label.textAlignment = .center
                    label.font = .systemFont(ofSize: 13, weight: .medium)
                    card.addSubview(label)

                    overlay.addSubview(card)

                    // ★ FIX: Tap trên overlay → dismiss (không phải trên card)
                    let tap = UITapGestureRecognizer(target: self, action: #selector(self?.dismissAirPlay))
                    overlay.addGestureRecognizer(tap)

                    // ★ FIX: Tap trên card → KHÔNG dismiss (cho phép chọn route)
                    card.isUserInteractionEnabled = true

                    self?.window?.rootViewController?.view.addSubview(overlay)
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
            case "enterPiP":
                self.enterPiP(result: result)
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
            default:
                result(FlutterMethodNotImplemented)
            }
        }

        GeneratedPluginRegistrant.register(with: self)
        return super.application(application, didFinishLaunchingWithOptions: launchOptions)
    }

    // MARK: - PiP Pre-buffer (như YouPiP)

    /// Tạo AVPlayer ẩn + PiP controller SẴN, muted, đang play để buffer
    /// Khi cần PiP → chỉ startPictureInPicture() → instant
    private func preparePiP(url: String, position: Int, headers: [String: String]) {
        // Nếu URL giống và đã prepare → skip
        if pipPrepared && pipUrl == url {
            pipLog("preparePiP: already prepared for this URL")
            return
        }

        // Cleanup cũ
        cleanupPiP()

        guard let streamURL = URL(string: url) else {
            pipLog("preparePiP: invalid URL")
            return
        }

        pipLog("preparePiP: \(url.prefix(50))... pos=\(position)")

        // 1. Audio session
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .moviePlayback,
                options: [.allowBluetooth, .allowBluetoothA2DP, .allowAirPlay])
            try session.setActive(true)
        } catch {
            pipLog("Audio session warning: \(error.localizedDescription)")
        }

        // 2. Create AVPlayer (muted, pre-buffer)
        let asset: AVURLAsset
        if headers.isEmpty {
            asset = AVURLAsset(url: streamURL)
        } else {
            asset = AVURLAsset(url: streamURL, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
        }

        let playerItem = AVPlayerItem(asset: asset)
        playerItem.preferredForwardBufferDuration = 30

        let player = AVPlayer(playerItem: playerItem)
        player.allowsExternalPlayback = true
        player.isMuted = true // Muted — pre-buffer không phát âm thanh

        // 3. Create PlayerLayer (hidden, off-screen)
        let playerLayer = AVPlayerLayer(player: player)
        playerLayer.frame = CGRect(x: -1000, y: -1000, width: 1, height: 1)
        playerLayer.videoGravity = .resizeAspect
        if let rootVC = self.window?.rootViewController {
            rootVC.view.layer.addSublayer(playerLayer)
        }

        self.pipPlayer = player
        self.pipPlayerLayer = playerLayer
        self.pipUrl = url

        // 4. Seek + play muted để buffer
        if position > 0 {
            let targetTime = CMTime(seconds: Double(position), preferredTimescale: 600)
            player.seek(to: targetTime, toleranceBefore: .zero, toleranceAfter: .zero) { _ in
                player.play()
            }
        } else {
            player.play()
        }

        // 5. Create PiP controller
        guard let pipController = AVPictureInPictureController(playerLayer: playerLayer) else {
            pipLog("preparePiP: cannot create PiP controller")
            cleanupPiP()
            return
        }
        pipController.delegate = self
        self.pipController = pipController
        self.pipPrepared = true
        self.pipRestorePosition = position

        pipLog("preparePiP done — ready at \(position)s")
    }

    /// Sync Flutter player position → native AVPlayer
    private func syncPosition(_ position: Int) {
        guard let player = pipPlayer, pipPrepared else { return }

        // ★ FIX: Luôn update pipRestorePosition — kể cả khi PiP đang active
        // Để khi PiP stop, position mới nhất được gửi về Flutter
        pipRestorePosition = position

        // Nếu PiP đang active → KHÔNG seek (native player đang play tự nhiên)
        if pipController?.isPictureInPictureActive == true { return }

        let current = Int(player.currentTime().seconds)
        let offset = abs(current - position)
        if offset > 3 {
            let targetTime = CMTime(seconds: Double(position), preferredTimescale: 600)
            player.seek(to: targetTime, toleranceBefore: .zero, toleranceAfter: .zero)
            pipLog("Sync: \(position)s (was \(current)s)")
        }
    }

    /// Enter PiP — seek to latest position trước khi unmute + play
    private func enterPiP(result: @escaping FlutterResult) {
        guard pipPrepared, let pipController = self.pipController, let player = self.pipPlayer else {
            pipLog("enterPiP: not prepared")
            result(FlutterError(code: "NOT_PREPARED", message: "PiP not prepared", details: nil))
            return
        }

        pipLog("enterPiP: starting... pos=\(pipRestorePosition)")

        // ★ FIX: Seek đến pipRestorePosition TRƯỚC khi unmute — đảm bảo position chính xác
        let targetTime = CMTime(seconds: Double(pipRestorePosition), preferredTimescale: 600)
        player.seek(to: targetTime, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            guard let self = self else { return }
            // Unmute + play SAU khi seek xong
            player.isMuted = false
            if player.timeControlStatus != .playing {
                player.play()
            }

            // Notify Flutter
            self.pipChannel?.invokeMethod("onPiPModeChanged", arguments: true)

            // Start PiP — instant because player is already buffered!
            pipController.startPictureInPicture()
            self.pipLog("enterPiP: startPictureInPicture called (pos=\(self.pipRestorePosition))")
        }

        result(true)
    }

    /// Cleanup
    private func cleanupPiP() {
        pipPlayerLayer?.removeFromSuperlayer()
        pipPlayerLayer = nil
        pipPlayer?.pause()
        pipPlayer = nil
        pipController?.delegate = nil
        pipController = nil
        pipPrepared = false
        pipUrl = ""
    }

    // MARK: - AVPictureInPictureControllerDelegate

    func pictureInPictureControllerWillStartPictureInPicture(_ controller: AVPictureInPictureController) {
        pipLog("Will start")
        pipChannel?.invokeMethod("onPiPModeChanged", arguments: true)
    }

    func pictureInPictureControllerDidStartPictureInPicture(_ controller: AVPictureInPictureController) {
        pipLog("Did start — ACTIVE")
    }

    func pictureInPictureController(_ controller: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error) {
        pipLog("FAILED: \(error.localizedDescription)")
        pipChannel?.invokeMethod("onPiPError", arguments: error.localizedDescription)
    }

    func pictureInPictureControllerWillStopPictureInPicture(_ controller: AVPictureInPictureController) {
        pipLog("Will stop")
        pipWasDismissed = true

        // ★ FIX: Capture position TRƯỚC khi PiP stop
        // Vì khi DidStop fire, player có thể đã bị reset → currentTime() trả 0
        if let player = pipPlayer {
            let raw = player.currentTime().seconds
            if !raw.isNaN && !raw.isInfinite && raw > 0 {
                pipRestorePosition = Int(raw)
                pipLog("WillStop: captured position \(pipRestorePosition)s")
            }
        }

        pipChannel?.invokeMethod("onPiPModeChanged", arguments: false)
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
        pipLog("Did stop — dismissed=\(pipWasDismissed)")

        // ★ FIX: Capture position — ưu tiên native position, fallback pipRestorePosition
        var rawSeconds = pipPlayer?.currentTime().seconds ?? 0
        if rawSeconds.isNaN || rawSeconds.isInfinite || rawSeconds < 0 {
            rawSeconds = 0
        }
        var position = Int(rawSeconds)

        // Fallback: nếu native position = 0 hoặc invalid → dùng pipRestorePosition
        // pipRestorePosition đã được update trong WillStop với position mới nhất
        if position <= 0 {
            position = pipRestorePosition
            pipLog("Using pipRestorePosition: \(position)s (raw=\(Int(rawSeconds))s)")
        } else {
            pipLog("Position at stop: \(position)s")
        }

        // ★ FIX: KHÔNG pause native player ngay — để Flutter handle
        // Chỉ mute + pause SAU khi gửi message cho Flutter
        // Để Flutter có thể đọc position từ native player nếu cần

        // Notify Flutter: PiP ended + whether it was dismissed or restored
        pipChannel?.invokeMethod("onPiPRestore", arguments: [
            "position": position,
            "dismissed": pipWasDismissed
        ])

        // Pause native player SAU khi gửi message
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.pipPlayer?.isMuted = true
            self?.pipPlayer?.pause()
        }
    }

    func pictureInPictureController(_ controller: AVPictureInPictureController, restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        pipLog("Restore — returning to app")
        pipWasDismissed = false // PiP restored, NOT dismissed

        // ★ FIX: Đợi 500ms để Flutter view restore xong rồi mới complete
        // Tránh race condition: Flutter view chưa restore mà PiP đã stop
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            completionHandler(true)
        }
    }

    @objc func dismissAirPlay() {
        window?.rootViewController?.view.viewWithTag(9999)?.removeFromSuperview()
    }
}
