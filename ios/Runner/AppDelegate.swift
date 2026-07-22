import UIKit
import Flutter
import AVFoundation
import AVKit

@main
@objc class AppDelegate: FlutterAppDelegate, AVPictureInPictureControllerDelegate {

    // MARK: - PiP State
    private var pipPlayer: AVPlayer?
    private var pipPlayerLayer: AVPlayerLayer?
    private var pipController: AVPictureInPictureController?
    private var pipChannel: FlutterMethodChannel?
    private var pipRestoreURL: String?
    private var pipRestorePosition: Int = 0

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
        airplayChannel.setMethodCallHandler { [weak self] (call, result) in
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
                    let tap = UITapGestureRecognizer(target: self, action: #selector(self?.dismissAirPlay))
                    overlay.addGestureRecognizer(tap)
                    self?.window?.rootViewController?.view.addSubview(overlay)
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
                // No-op — we don't pre-buffer anymore (caused crashes)
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
                // No-op — position is managed by native AVPlayer
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

    // MARK: - PiP (Simple, no pre-buffer)

    private func enterPiP(url: String, position: Int, headers: [String: String], result: @escaping FlutterResult) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else {
                result(FlutterError(code: "DEALLOC", message: "AppDelegate deallocated", details: nil))
                return
            }

            self.pipLog("enterPiP: pos=\(position)")

            // Cleanup trước
            self.cleanupPiP()

            // 1. Setup audio session
            self.configureAudioSession()

            // 2. Validate URL
            guard let streamURL = URL(string: url) else {
                result(FlutterError(code: "INVALID_URL", message: "Cannot create URL", details: nil))
                return
            }

            // 3. Create AVPlayer
            let asset: AVURLAsset
            if headers.isEmpty {
                asset = AVURLAsset(url: streamURL)
            } else {
                asset = AVURLAsset(url: streamURL, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
            }

            let playerItem = AVPlayerItem(asset: asset)
            playerItem.preferredForwardBufferDuration = 10

            let player = AVPlayer(playerItem: playerItem)
            player.allowsExternalPlayback = true

            // 4. Create PlayerLayer (hidden, 1px)
            let playerLayer = AVPlayerLayer(player: player)
            playerLayer.frame = CGRect(x: 0, y: 0, width: 1, height: 1)
            playerLayer.videoGravity = .resizeAspect
            if let window = self.window {
                window.layer.addSublayer(playerLayer)
            }
            self.pipPlayerLayer = playerLayer
            self.pipPlayer = player
            self.pipRestoreURL = url
            self.pipRestorePosition = position

            // 5. Seek to position
            if position > 0 {
                let targetTime = CMTime(seconds: Double(position), preferredTimescale: 600)
                player.seek(to: targetTime, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                    guard let self = self else { return }
                    DispatchQueue.main.async {
                        self.startPiP(player: player, result: result)
                    }
                }
            } else {
                self.startPiP(player: player, result: result)
            }
        }
    }

    private func startPiP(player: AVPlayer, result: @escaping FlutterResult) {
        // Create PiP controller
        guard let playerLayer = self.pipPlayerLayer else {
            result(FlutterError(code: "NO_LAYER", message: "No player layer", details: nil))
            return
        }

        guard let pipController = AVPictureInPictureController(playerLayer: playerLayer) else {
            result(FlutterError(code: "NO_PIP", message: "PiP not available", details: nil))
            return
        }

        pipController.delegate = self
        self.pipController = pipController

        // Play + start PiP
        player.play()

        // Notify Flutter
        pipChannel?.invokeMethod("onPiPModeChanged", arguments: true)

        let started = pipController.startPictureInPicture()
        pipLog("startPictureInPicture: \(started)")

        result(started)
    }

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

    private func cleanupPiP() {
        pipPlayerLayer?.removeFromSuperlayer()
        pipPlayerLayer = nil
        pipPlayer?.pause()
        pipPlayer = nil
        pipController?.delegate = nil
        pipController = nil
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
        pipChannel?.invokeMethod("onPiPModeChanged", arguments: false)
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
        pipLog("Did stop")
        let position = Int(pipPlayer?.currentTime().seconds ?? 0)

        // Cleanup sau khi PiP stop
        cleanupPiP()

        // Notify Flutter restore
        pipChannel?.invokeMethod("onPiPRestore", arguments: ["position": position])
    }

    func pictureInPictureController(_ controller: AVPictureInPictureController, restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        completionHandler(true)
    }

    @objc func dismissAirPlay() {
        window?.rootViewController?.view.viewWithTag(9999)?.removeFromSuperview()
    }
}
