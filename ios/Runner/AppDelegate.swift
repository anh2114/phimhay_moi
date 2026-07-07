import UIKit
import Flutter
import AVFoundation
import AVKit

@main
@objc class AppDelegate: FlutterAppDelegate {

    // iOS PiP — AVPlayer riêng cho PiP
    private var pipPlayer: AVPlayer?
    private var pipPlayerLayer: AVPlayerLayer?
    private var pipController: AVPictureInPictureController?
    private var pipChannel: FlutterMethodChannel?
    private var lastPipPosition: Double = 0
    private var playerItemObserver: NSKeyValueObservation?
    private var rateObservation: NSKeyValueObservation?
    private var pipRetryCount = 0
    private static let maxRetries = 10

    override func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        let controller = window?.rootViewController as! FlutterViewController
        let audioChannel = FlutterMethodChannel(name: "phimhay_app/audio", binaryMessenger: controller.binaryMessenger)

        // ★ PiP channel — [self] KHÔNG PHẢI [weak self]
        let pipChannel = FlutterMethodChannel(name: "phimhay/pip", binaryMessenger: controller.binaryMessenger)
        self.pipChannel = pipChannel
        pipChannel.setMethodCallHandler { [self] (call, result) in
            switch call.method {
            case "isPipAvailable":
                result(AVPictureInPictureController.isPictureInPictureSupported())

            case "setupPip":
                result(true)

            case "startPip":
                guard let args = call.arguments as? [String: Any],
                      let urlString = args["url"] as? String,
                      let url = URL(string: urlString),
                      let position = args["position"] as? Double else {
                    result(false)
                    return
                }
                self.startIosPip(url: url, position: position, result: result)

            case "stopPip":
                self.pipController?.stopPictureInPicture()
                result(true)

            case "getPipPosition":
                result(self.lastPipPosition)

            case "isPipActive":
                result(self.pipController?.isPictureInPictureActive ?? false)

            default:
                result(FlutterMethodNotImplemented)
            }
        }

        // AirPlay
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
                } catch { result(FlutterError(code: "ERR", message: error.localizedDescription, details: nil)) }
            case "configAVSession":
                let session = AVAudioSession.sharedInstance()
                do {
                    try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetooth])
                    try session.setActive(true)
                    result(true)
                } catch { result(FlutterError(code: "ERR", message: error.localizedDescription, details: nil)) }
            case "activateAudioSession":
                let session = AVAudioSession.sharedInstance()
                do { try session.setCategory(.playAndRecord, mode: .default, options: [.allowBluetooth]); try session.setActive(true); result(true) }
                catch { result(FlutterError(code: "ERR", message: error.localizedDescription, details: nil)) }
            case "checkMicPermission":
                result(AVAudioSession.sharedInstance().recordPermission == .granted)
            default:
                result(FlutterMethodNotImplemented)
            }
        }

        GeneratedPluginRegistrant.register(with: self)
        return super.application(application, didFinishLaunchingWithOptions: launchOptions)
    }

    // MARK: - iOS PiP Flow

    private func startIosPip(url: URL, position: Double, result: @escaping FlutterResult) {
        print("PiP: startIosPip — url=\(url.absoluteString.prefix(60)), pos=\(position)")

        // Cleanup player cũ
        cleanupPipPlayer()

        // Audio session
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback,
                options: [.allowBluetooth, .allowBluetoothA2DP])
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("PiP: audio session error: \(error)")
        }

        // Tạo AVPlayer
        let asset = AVURLAsset(url: url)
        let playerItem = AVPlayerItem(asset: asset)
        let player = AVPlayer(playerItem: playerItem)
        player.preventsDisplaySleepDuringVideoPlayback = true

        // PlayerLayer — cần visible cho PiP
        let playerLayer = AVPlayerLayer(player: player)
        playerLayer.frame = CGRect(x: 0, y: 0, width: 320, height: 180)
        playerLayer.isHidden = false
        playerLayer.opacity = 0.001
        playerLayer.videoGravity = .resizeAspect
        if let rootView = window?.rootViewController?.view {
            rootView.layer.addSublayer(playerLayer)
        }

        let pipCtrl = AVPictureInPictureController(playerLayer: playerLayer)
        pipCtrl?.delegate = self

        pipPlayer = player
        pipPlayerLayer = playerLayer
        pipController = pipCtrl

        guard let pipCtrl = pipCtrl else {
            print("PiP: pipCtrl is nil after creation")
            result(false)
            return
        }

        // Chờ player ready rồi mới seek + start PiP
        if playerItem.status == .readyToPlay {
            seekAndStartPip(player: player, pip: pipCtrl, position: position, result: result)
        } else {
            print("PiP: waiting for readyToPlay...")
            playerItemObserver = playerItem.observe(\.status, options: [.new]) { [weak self] item, _ in
                guard item.status == .readyToPlay else { return }
                self?.playerItemObserver?.invalidate()
                self?.playerItemObserver = nil
                DispatchQueue.main.async {
                    self?.seekAndStartPip(player: player, pip: pipCtrl, position: position, result: result)
                }
            }
            // Timeout 8s
            DispatchQueue.main.asyncAfter(deadline: .now() + 8.0) { [weak self] in
                guard self?.playerItemObserver != nil else { return }
                self?.playerItemObserver?.invalidate()
                self?.playerItemObserver = nil
                print("PiP: timeout waiting for readyToPlay")
                result(false)
            }
        }
    }

    private func seekAndStartPip(player: AVPlayer, pip: AVPictureInPictureController, position: Double, result: @escaping FlutterResult) {
        // Seek tới position
        let seekThenStart: () -> Void = { [weak self] in
            player.play()
            self?.waitForRateAndStartPip(player: player, pip: pip, result: result)
        }

        if position > 0 {
            player.seek(
                to: CMTime(seconds: position, preferredTimescale: 600),
                toleranceBefore: .zero, toleranceAfter: .zero
            ) { finished in guard finished else { return }; seekThenStart() }
        } else {
            seekThenStart()
        }
    }

    private func waitForRateAndStartPip(player: AVPlayer, pip: AVPictureInPictureController, result: @escaping FlutterResult) {
        pipRetryCount = 0

        // Thử ngay
        if player.rate > 0 && pip.isPictureInPicturePossible {
            do {
                try pip.startPictureInPicture()
                print("PiP: started ✓")
                result(true)
            } catch {
                print("PiP: start error: \(error)")
                result(false)
            }
            return
        }

        // KVO player.rate
        rateObservation?.invalidate()
        rateObservation = player.observe(\.rate, options: [.new]) { [weak self, weak player, weak pip] _, _ in
            guard let self = self, let player = player, let pip = pip else { return }
            guard player.rate > 0 else { return }
            self.rateObservation?.invalidate()
            self.rateObservation = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                self.retryStartPip(pip: pip, result: result)
            }
        }

        // Timeout 8s
        DispatchQueue.main.asyncAfter(deadline: .now() + 8.0) { [weak self] in
            guard self?.rateObservation != nil else { return }
            self?.rateObservation?.invalidate()
            self?.rateObservation = nil
            print("PiP: timeout rate")
            result(false)
        }
    }

    private func retryStartPip(pip: AVPictureInPictureController, result: @escaping FlutterResult) {
        if pip.isPictureInPicturePossible {
            do {
                try pip.startPictureInPicture()
                print("PiP: started ✓")
                result(true)
            } catch {
                print("PiP: error: \(error)")
                result(false)
            }
        } else if pipRetryCount < Self.maxRetries {
            pipRetryCount += 1
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3 + Double(pipRetryCount) * 0.2) { [weak self] in
                self?.retryStartPip(pip: pip, result: result)
            }
        } else {
            result(false)
        }
    }

    private func cleanupPipPlayer() {
        playerItemObserver?.invalidate()
        playerItemObserver = nil
        rateObservation?.invalidate()
        rateObservation = nil
        pipController?.delegate = nil
        pipController?.stopPictureInPicture()
        pipPlayer?.pause()
        pipPlayerLayer?.removeFromSuperlayer()
        pipPlayer = nil
        pipPlayerLayer = nil
        pipController = nil
    }

    @objc func dismissAirPlay() {
        window?.rootViewController?.view.viewWithTag(9999)?.removeFromSuperview()
    }
}

// MARK: - AVPictureInPictureControllerDelegate
extension AppDelegate: AVPictureInPictureControllerDelegate {
    func pictureInPictureControllerWillStartPictureInPicture(_ controller: AVPictureInPictureController) {
        print("PiP: willStart ✓")
        pipChannel?.invokeMethod("onPipStarted", arguments: nil)
    }

    func pictureInPictureControllerWillStopPictureInPicture(_ controller: AVPictureInPictureController) {
        print("PiP: willStop")
        // Lưu position trước khi stop
        if let pos = pipPlayer?.currentItem?.currentTime().seconds, !pos.isNaN, pos > 0 {
            lastPipPosition = pos
        }
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
        print("PiP: didStop — position=\(lastPipPosition)")
        // Gửi position về Flutter + dispose AVPlayer
        pipChannel?.invokeMethod("onPipStopped", arguments: ["position": lastPipPosition])
        cleanupPipPlayer()
    }

    func pictureInPictureController(_ controller: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error) {
        print("PiP: FAILED — \(error.localizedDescription)")
        rateObservation?.invalidate()
        rateObservation = nil
        pipChannel?.invokeMethod("onPipStopped", arguments: ["position": 0])
        cleanupPipPlayer()
    }

    func pictureInPictureControllerRestoreUserInterfaceForPictureInPictureStop(
        _ controller: AVPictureInPictureController,
        completionHandler: @escaping (Bool) -> Void
    ) {
        completionHandler(true)
    }
}
