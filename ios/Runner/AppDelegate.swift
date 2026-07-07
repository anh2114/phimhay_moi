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
    private var pipOverlayView: UIView?
    private var pipObservations: [NSKeyValueObservation] = []

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
                self.enterPiP(url: url, position: position, result: result)
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

    // MARK: - PiP via Native AVPlayer + Proxy

    private func enterPiP(url: String, position: Int, result: @escaping FlutterResult) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else {
                result(FlutterError(code: "DEALLOC", message: "AppDelegate deallocated", details: nil))
                return
            }

            NSLog("[PiP] enterPiP — url=\(url.prefix(120))... pos=\(position)")

            // 1. Setup audio session
            do {
                try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback,
                    options: [.allowBluetooth, .allowBluetoothA2DP])
                try AVAudioSession.sharedInstance().setActive(true)
            } catch {
                NSLog("[PiP] Audio session failed: \(error)")
            }

            // 2. Validate URL
            guard let streamURL = URL(string: url) else {
                result(FlutterError(code: "INVALID_URL", message: "Cannot create URL", details: nil))
                return
            }

            // 3. Cleanup previous PiP if any
            self.cleanupPiP()

            // 4. Create overlay view in window (required for PiP)
            let overlayView = UIView(frame: CGRect(x: -1, y: -1, width: 1, height: 1))
            overlayView.backgroundColor = .clear
            overlayView.tag = 8888
            self.window?.rootViewController?.view.addSubview(overlayView)
            self.pipOverlayView = overlayView

            // 5. Create AVPlayer with proxy URL (proxy handles CORS + headers)
            let playerItem = AVPlayerItem(url: streamURL)
            let player = AVPlayer(playerItem: playerItem)
            self.pipPlayer = player

            // 6. Create player layer and add to overlay
            let playerLayer = AVPlayerLayer(player: player)
            playerLayer.frame = overlayView.bounds
            overlayView.layer.addSublayer(playerLayer)
            self.pipPlayerLayer = playerLayer

            // 7. Create PiP controller
            let pipController = AVPictureInPictureController(playerLayer: playerLayer)
            pipController.delegate = self
            self.pipController = pipController

            NSLog("[PiP] Player created, waiting for ready...")

            // 8. Wait for player ready, then seek + start PiP
            var handled = false
            let timeout = DispatchWorkItem { [weak self] in
                guard !handled else { return }
                handled = true
                NSLog("[PiP] TIMEOUT")
                self?.cleanupPiP()
                result(FlutterError(code: "TIMEOUT", message: "Player not ready in 15s", details: nil))
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: timeout)

            let obs = player.observe(\.status, options: [.new]) { [weak self] player, change in
                guard let self = self, !handled else { return }
                guard change.newValue == .readyToPlay else {
                    if change.newValue == .failed {
                        handled = true
                        timeout.cancel()
                        let errMsg = player.error?.localizedDescription ?? "unknown"
                        NSLog("[PiP] Player FAILED: \(errMsg)")
                        self.cleanupPiP()
                        DispatchQueue.main.async {
                            result(FlutterError(code: "PLAYER_FAILED", message: errMsg, details: nil))
                        }
                    }
                    return
                }

                handled = true
                timeout.cancel()
                NSLog("[PiP] Player ready — seeking to \(position)s")

                let target = CMTime(seconds: Double(position), preferredTimescale: 600)
                player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { _ in
                    DispatchQueue.main.async {
                        player.play()
                        NSLog("[PiP] Starting PiP...")
                        pipController.startPictureInPicture()
                        result(true)
                    }
                }
            }
            self.pipObservations.append(obs)
        }
    }

    private func cleanupPiP() {
        pipObservations.removeAll()
        pipPlayerLayer?.removeFromSuperlayer()
        pipPlayerLayer = nil
        pipPlayer?.pause()
        pipPlayer = nil
        pipController?.stopPictureInPicture()
        pipController = nil
        pipOverlayView?.removeFromSuperview()
        pipOverlayView = nil
    }

    // MARK: - AVPictureInPictureControllerDelegate

    func pictureInPictureControllerWillStartPictureInPicture(_ controller: AVPictureInPictureController) {
        NSLog("[PiP] Will start")
        pipChannel?.invokeMethod("onPiPModeChanged", arguments: true)
    }

    func pictureInPictureControllerDidStartPictureInPicture(_ controller: AVPictureInPictureController) {
        NSLog("[PiP] Did start")
    }

    func pictureInPictureController(_ controller: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error) {
        NSLog("[PiP] FAILED: \(error.localizedDescription)")
        pipChannel?.invokeMethod("onPiPError", arguments: error.localizedDescription)
        cleanupPiP()
    }

    func pictureInPictureControllerWillStopPictureInPicture(_ controller: AVPictureInPictureController) {
        NSLog("[PiP] Will stop")
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
        let position = Int(pipPlayer?.currentTime().seconds ?? 0)
        NSLog("[PiP] Did stop — pos=\(position)")
        cleanupPiP()
        DispatchQueue.main.async { [weak self] in
            self?.pipChannel?.invokeMethod("onPiPRestore", arguments: ["position": position])
        }
    }

    @objc func dismissAirPlay() {
        window?.rootViewController?.view.viewWithTag(9999)?.removeFromSuperview()
    }
}
