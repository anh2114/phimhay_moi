import UIKit
import Flutter
import AVFoundation
import AVKit

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

    // Send debug log to Flutter UI via method channel
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

            self.pipLog("enterPiP called — url=\(url.prefix(80))... pos=\(position)")

            // 1. Setup audio session for background playback
            do {
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.playback, mode: .moviePlayback,
                    options: [.allowBluetooth, .allowBluetoothA2DP, .mixWithOthers])
                try session.setActive(true)
                self.pipLog("Audio session OK — category=\(session.category.rawValue)")
            } catch {
                self.pipLog("Audio session setup failed: \(error.localizedDescription)")
            }

            // 2. Validate URL
            guard let streamURL = URL(string: url) else {
                self.pipLog("Invalid URL")
                result(FlutterError(code: "INVALID_URL", message: "Cannot create URL", details: nil))
                return
            }
            self.pipLog("URL scheme=\(streamURL.scheme ?? "nil") host=\(streamURL.host ?? "nil")")

            // 3. Create overlay view — MUST be in window hierarchy for PiP to work
            self.removePiPOverlay()
            let overlayView = UIView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
            overlayView.backgroundColor = .clear
            overlayView.alpha = 0.01
            overlayView.isUserInteractionEnabled = false
            overlayView.tag = 8888
            self.window?.rootViewController?.view.addSubview(overlayView)
            self.pipOverlayView = overlayView

            // 4. Create AVPlayerLayer and attach to overlay view
            // URL is proxy URL (xiaofilm.online/api/hls_proxy.php?url=CDN_URL)
            // VPS is in Vietnam → proxy can access CDN
            let asset = AVURLAsset(url: streamURL)
            let playerItem = AVPlayerItem(asset: asset)
            playerItem.preferredForwardBufferDuration = 10
            let player = AVPlayer(playerItem: playerItem)
            player.allowsExternalPlayback = true
            player.volume = 1.0
            let playerLayer = AVPlayerLayer(player: player)
            playerLayer.frame = overlayView.bounds
            overlayView.layer.addSublayer(playerLayer)
            self.pipPlayerLayer = playerLayer
            self.pipPlayer = player
            self.pipRestoreURL = url

            // 5. Create PiP controller
            guard let pipController = AVPictureInPictureController(playerLayer: playerLayer) else {
                self.pipLog("Failed to create AVPictureInPictureController")
                self.removePiPOverlay()
                self.pipChannel?.invokeMethod("onPiPError", arguments: "PiP not available on this device")
                result(FlutterError(code: "NO_PIP", message: "AVPictureInPictureController not available", details: nil))
                return
            }
            pipController.delegate = self
            self.pipController = pipController

            self.pipLog("Player + controller created, starting PiP...")

            // 6. Start PiP immediately
            self.pipChannel?.invokeMethod("onPiPModeChanged", arguments: true)
            player.play()
            let started = pipController.startPictureInPicture()
            self.pipLog("startPictureInPicture returned: \(started)")
            result(true)

            // Detailed status logging for debugging
            self.pipErrorLogObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.newErrorLogEntryNotification, object: playerItem, queue: .main) { _ in
                guard let entry = playerItem.errorLog()?.events.last else { return }
                self.pipLog("HLS error — URI=\(entry.uri ?? "?") code=\(entry.errorStatusCode) \(entry.errorComment ?? "")")
            }

            let itemObservation = playerItem.observe(\.status, options: [.new]) { item, _ in
                switch item.status {
                case .unknown: self.pipLog("PlayerItem status: UNKNOWN")
                case .readyToPlay: self.pipLog("PlayerItem status: READY_TO_PLAY")
                case .failed: self.pipLog("PlayerItem status: FAILED — \(item.error?.localizedDescription ?? "nil")")
                @unknown default: self.pipLog("PlayerItem status: unknown case")
                }
            }
            self.pipPlayerObservations.append(itemObservation)

            let playerObs = player.observe(\.status, options: [.new]) { p, _ in
                switch p.status {
                case .unknown: self.pipLog("Player status: UNKNOWN")
                case .readyToPlay: self.pipLog("Player status: READY_TO_PLAY")
                case .failed: self.pipLog("Player status: FAILED — \(p.error?.localizedDescription ?? "nil")")
                @unknown default: self.pipLog("Player status: unknown case")
                }
            }
            self.pipPlayerObservations.append(playerObs)
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
    }

    // MARK: - AVPictureInPictureControllerDelegate

    func pictureInPictureControllerWillStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        self.pipLog("Will start — PiP is about to begin")
        pipChannel?.invokeMethod("onPiPModeChanged", arguments: true)
    }

    func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        self.pipLog("Did start — PiP is ACTIVE and running")
    }

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error) {
        self.pipLog("FAILED to start: \(error.localizedDescription)")
        self.pipLog("Error type: \(type(of: error))")
        pipChannel?.invokeMethod("onPiPError", arguments: error.localizedDescription)
        removePiPOverlay()
    }

    func pictureInPictureControllerWillStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        self.pipLog("Will stop — user tapped restore")
        pipChannel?.invokeMethod("onPiPModeChanged", arguments: false)
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        self.pipLog("Did stop")
        // Get position before cleanup
        let position = Int(pipPlayer?.currentTime().seconds ?? 0)
        self.pipLog("Stopping — position=\(position)")

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
