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
                result(true)
            case "isPiP":
                result(self.pipController?.isPictureInPictureActive ?? false)
            case "exitPiP":
                do {
                    if self.pipController?.isPictureInPictureActive == true {
                        self.pipController?.stopPictureInPicture()
                        result(true)
                    } else {
                        result(false)
                    }
                } catch {
                    result(false)
                }
            case "syncPosition":
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

    // MARK: - PiP

    private func enterPiP(url: String, position: Int, headers: [String: String], result: @escaping FlutterResult) {
        do {
            pipLog("enterPiP start: pos=\(position)")

            // Cleanup
            cleanupPiP()

            // 1. Audio session — set category mà KHÔNG deactivate (tránh conflict với Flutter)
            let session = AVAudioSession.sharedInstance()
            do {
                try session.setCategory(.playback, mode: .moviePlayback,
                    options: [.allowBluetooth, .allowBluetoothA2DP, .allowAirPlay])
                try session.setActive(true, options: .notifyOthersOnDeactivation)
            } catch {
                pipLog("Audio session warning: \(error.localizedDescription)")
                // Tiếp tục dù audio session fail — PiP vẫn có thể hoạt động
            }
            pipLog("Audio session OK")

            // 2. Validate URL
            guard let streamURL = URL(string: url) else {
                pipLog("Invalid URL")
                result(FlutterError(code: "INVALID_URL", message: "Invalid URL", details: nil))
                return
            }
            pipLog("URL OK: \(url.prefix(50))")

            // 3. Create AVPlayerItem
            let asset: AVURLAsset
            if headers.isEmpty {
                asset = AVURLAsset(url: streamURL)
            } else {
                asset = AVURLAsset(url: streamURL, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
            }
            let playerItem = AVPlayerItem(asset: asset)
            playerItem.preferredForwardBufferDuration = 10
            pipLog("PlayerItem created")

            // 4. Create AVPlayer
            let player = AVPlayer(playerItem: playerItem)
            player.allowsExternalPlayback = true
            pipLog("AVPlayer created")

            // 5. Create PlayerLayer — PHẢI visible và trong view hierarchy để PiP hoạt động
            let playerLayer = AVPlayerLayer(player: player)
            // Frame nhỏ, ở góc màn hình — PiP cần layer visible
            playerLayer.frame = CGRect(x: 0, y: 0, width: 1, height: 1)
            playerLayer.videoGravity = .resizeAspect
            playerLayer.opacity = 0.01 // Gần như invisible nhưng VISIBLE (không hidden)
            if let rootVC = self.window?.rootViewController {
                rootVC.view.layer.addSublayer(playerLayer)
            }
            self.pipPlayerLayer = playerLayer
            self.pipPlayer = player
            self.pipRestorePosition = position
            pipLog("PlayerLayer added (hidden, full screen size)")

            // 6. Seek to position if needed
            if position > 0 {
                let targetTime = CMTime(seconds: Double(position), preferredTimescale: 600)
                player.seek(to: targetTime, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                    guard let self = self else { return }
                    DispatchQueue.main.async {
                        self.doStartPiP(player: player, result: result)
                    }
                }
            } else {
                doStartPiP(player: player, result: result)
            }
        } catch {
            pipLog("ERROR in enterPiP: \(error.localizedDescription)")
            result(FlutterError(code: "ERROR", message: error.localizedDescription, details: nil))
        }
    }

    private func doStartPiP(player: AVPlayer, result: @escaping FlutterResult) {
        guard let playerLayer = self.pipPlayerLayer else {
            pipLog("No playerLayer")
            result(FlutterError(code: "NO_LAYER", message: "No player layer", details: nil))
            return
        }

        // Create PiP controller
        guard let pipController = AVPictureInPictureController(playerLayer: playerLayer) else {
            pipLog("Cannot create PiP controller — PiP may not be available")
            result(FlutterError(code: "NO_PIP", message: "PiP not available", details: nil))
            return
        }
        pipController.delegate = self
        self.pipController = pipController
        pipLog("PiP controller created")

        // Play — phải play TRƯỚC khi start PiP
        player.play()
        pipLog("Player playing, status: \(player.timeControlStatus.rawValue)")

        // Notify Flutter
        pipChannel?.invokeMethod("onPiPModeChanged", arguments: true)

        // Start PiP
        pipController.startPictureInPicture()
        pipLog("startPictureInPicture called")

        // Notify Flutter PiP starting
        pipChannel?.invokeMethod("onPiPModeChanged", arguments: true)

        result(true)
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
        cleanupPiP()
        pipChannel?.invokeMethod("onPiPRestore", arguments: ["position": position])
    }

    func pictureInPictureController(_ controller: AVPictureInPictureController, restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        completionHandler(true)
    }

    @objc func dismissAirPlay() {
        window?.rootViewController?.view.viewWithTag(9999)?.removeFromSuperview()
    }
}
