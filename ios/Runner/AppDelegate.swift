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
            let playerLayer = AVPlayerLayer(player: player)
            playerLayer.frame = overlayView.bounds
            overlayView.layer.addSublayer(playerLayer)
            self.pipPlayerLayer = playerLayer
            self.pipPlayer = player
            self.pipRestoreURL = url

            // 5. Create PiP controller
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

            // 6. Wait for player to be ready
            var observed = false
            let timeoutWork = DispatchWorkItem { [weak self] in
                guard !observed, let self = self else { return }
                observed = true
                NSLog("[PiP] TIMEOUT — player not ready in 20s")
                self.removePiPOverlay()
                self.pipChannel?.invokeMethod("onPiPError", arguments: "Player timeout")
                result(FlutterError(code: "TIMEOUT", message: "Player timeout", details: nil))
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: timeoutWork)

            self.pipErrorLogObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.newErrorLogEntryNotification, object: playerItem, queue: .main) { _ in
                guard let entry = playerItem.errorLog()?.events.last else { return }
                NSLog("[PiP] HLS error — URI=\(entry.uri ?? "?") code=\(entry.errorStatusCode) \(entry.errorComment ?? "")")
            }

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

                        observed = true
                        timeoutWork.cancel()
                        NSLog("[PiP] Player ready — seeking to \(position)s")

                        let targetTime = CMTime(seconds: Double(position), preferredTimescale: 600)
                        player.seek(to: targetTime, toleranceBefore: .zero, toleranceAfter: .zero) { _ in
                            DispatchQueue.main.async {
                                NSLog("[PiP] Seek done — starting PiP")
                                player.play()
                                pipController.startPictureInPicture()
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