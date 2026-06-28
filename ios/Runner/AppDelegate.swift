import UIKit
import Flutter
import AVFoundation
import AVKit

@main
@objc class AppDelegate: FlutterAppDelegate {

    // PiP support
    private var pipController: AVPictureInPictureController?
    private var pipPlayerLayer: AVPlayerLayer?
    private var pipPlayer: AVPlayer?
    private var pipChannel: FlutterMethodChannel?

    // Poll position
    private var lastPipPosition: Double = 0
    private var pipPositionTimer: Timer?

    // FIX: chờ player ready
    private var playerItemObserver: NSKeyValueObservation?
    private var pendingStartResult: FlutterResult?
    private var pendingStartPosition: Double = 0

    override func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        let controller = window?.rootViewController as! FlutterViewController
        let audioChannel = FlutterMethodChannel(name: "phimhay_app/audio", binaryMessenger: controller.binaryMessenger)

        // PiP channel
        let pipChannel = FlutterMethodChannel(name: "phimhay/pip", binaryMessenger: controller.binaryMessenger)
        self.pipChannel = pipChannel
        pipChannel.setMethodCallHandler { [weak self] (call, result) in
            switch call.method {
            case "isPipAvailable":
                result(AVPictureInPictureController.isPictureInPictureSupported())

            case "setupPip":
                guard let args = call.arguments as? [String: Any],
                      let urlString = args["url"] as? String,
                      let url = URL(string: urlString) else {
                    result(false)
                    return
                }
                let position = args["position"] as? Double ?? 0
                let headers = args["headers"] as? [String: String] ?? [:]
                self?.setupPipController(url: url, position: position, headers: headers)
                result(true)

            case "startPip":
                guard let self = self else { result(false); return }
                let args = call.arguments as? [String: Any]
                let position = args?["position"] as? Double ?? 0

                // Config audio session cho PiP
                do {
                    try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
                    try AVAudioSession.sharedInstance().setActive(true)
                } catch {
                    print("PiP: audio session error: \(error)")
                }

                // FIX: dùng hàm mới chờ player ready rồi mới start
                self.startPipWhenReady(position: position, result: result)

            case "stopPip":
                self?.pipController?.stopPictureInPicture()
                self?.stopPositionTimer()
                result(true)

            case "getPipPosition":
                result(self?.lastPipPosition ?? 0)

            case "isPipActive":
                result(self?.pipController?.isPictureInPictureActive ?? false)

            case "updatePipUrl":
                guard let args = call.arguments as? [String: Any],
                      let urlString = args["url"] as? String,
                      let url = URL(string: urlString) else {
                    result(false)
                    return
                }
                self?.pipPlayer?.replaceCurrentItem(with: AVPlayerItem(url: url))
                result(true)

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

                    // Background overlay
                    let overlay = UIView(frame: UIScreen.main.bounds)
                    overlay.backgroundColor = UIColor.black.withAlphaComponent(0.6)
                    overlay.tag = 9999

                    // AirPlay picker card
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

                    let tapGesture = UITapGestureRecognizer(target: self, selector: #selector(self.dismissAirPlayPicker))
                    overlay.addGestureRecognizer(tapGesture)

                    if let rootView = self.window?.rootViewController?.view {
                        rootView.addSubview(overlay)
                    }

                    DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
                        overlay.removeFromSuperview()
                    }
                    result(true)
                }
            default:
                result(FlutterMethodNotImplemented)
            }
        }

        // Audio channel
        audioChannel.setMethodCallHandler { (call, result) in
            switch call.method {
            case "setSpeaker":
                let args = call.arguments as? [String: Any]
                let speakerOn = args?["on"] as? Bool ?? true
                let session = AVAudioSession.sharedInstance()
                do {
                    if speakerOn {
                        // Speaker: dùng .default mode — không áp signal processing (tránh reverb/vang)
                        try session.setCategory(.playAndRecord, mode: .default,
                            options: [.defaultToSpeaker, .allowBluetooth, .allowBluetoothA2DP])
                        try session.setActive(true, options: [])
                        try session.overrideOutputAudioPort(.speaker)
                    } else {
                        // Earpiece: dùng .voiceChat mode — có AEC, AGC cho voice
                        try session.setCategory(.playAndRecord, mode: .voiceChat,
                            options: [.allowBluetooth, .allowBluetoothA2DP])
                        try session.setActive(true, options: [])
                        try session.overrideOutputAudioPort(.none)
                    }
                    result(true)
                } catch {
                    result(FlutterError(code: "SPEAKER_ERROR", message: error.localizedDescription, details: nil))
                }

            case "configAVSession":
                // Mặc định earpiece — dùng .voiceChat mode (có AEC cho voice)
                let session = AVAudioSession.sharedInstance()
                do {
                    try session.setCategory(.playAndRecord, mode: .voiceChat,
                        options: [.allowBluetooth, .allowBluetoothA2DP])
                    try session.setActive(true, options: [])
                    result(true)
                } catch {
                    result(FlutterError(code: "SESSION_ERROR", message: error.localizedDescription, details: nil))
                }

            case "activateAudioSession":
                // Restore normal audio mode — video volume không bị giảm
                let session = AVAudioSession.sharedInstance()
                do {
                    try session.setCategory(.playAndRecord, mode: .default,
                        options: [.allowBluetooth, .allowBluetoothA2DP])
                    try session.setActive(true, options: [])
                    result(true)
                } catch {
                    result(FlutterError(code: "SESSION_ERROR", message: error.localizedDescription, details: nil))
                }

            case "checkMicPermission":
                let session = AVAudioSession.sharedInstance()
                switch session.recordPermission {
                case .granted: result(true)
                default: result(false)
                }

            default:
                result(FlutterMethodNotImplemented)
            }
        }

        GeneratedPluginRegistrant.register(with: self)
        
        // Register Appodeal plugin
        AppodealPlugin.register(controller: controller)
        
        return super.application(application, didFinishLaunchingWithOptions: launchOptions)
    }

    // MARK: - PiP Setup

    private func setupPipController(url: URL, position: Double = 0, headers: [String: String] = [:]) {
        // Huỷ observer cũ trước
        playerItemObserver?.invalidate()
        playerItemObserver = nil
        pendingStartResult = nil

        pipController?.delegate = nil
        pipPlayerLayer?.removeFromSuperlayer()
        stopPositionTimer()

        // Dùng AVURLAsset với custom headers nếu có
        let asset: AVURLAsset
        if !headers.isEmpty {
            asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
        } else {
            asset = AVURLAsset(url: url)
        }
        let playerItem = AVPlayerItem(asset: asset)
        let player = AVPlayer(playerItem: playerItem)
        player.preventsDisplaySleepDuringVideoPlayback = true

        // AVPlayerLayer phải visible + có size để PiP render
        let playerLayer = AVPlayerLayer(player: player)
        playerLayer.frame = CGRect(x: 0, y: 0, width: 100, height: 100)
        playerLayer.isHidden = false
        playerLayer.opacity = 0

        if let rootView = window?.rootViewController?.view {
            rootView.layer.addSublayer(playerLayer)
        }

        let pipCtrl = AVPictureInPictureController(playerLayer: playerLayer)
        pipCtrl?.delegate = self

        // FIX: seek NGAY SAU KHI player item ready, không seek lúc chưa load
        if position > 0 {
            playerItemObserver = playerItem.observe(\.status, options: [.new]) { [weak self, weak player] item, _ in
                guard item.status == .readyToPlay else { return }
                self?.playerItemObserver?.invalidate()
                self?.playerItemObserver = nil
                player?.seek(
                    to: CMTime(seconds: position, preferredTimescale: 600),
                    toleranceBefore: .zero,
                    toleranceAfter: .zero
                )
                print("PiP: setup seek to \(position)s after readyToPlay")
            }
        }

        pipPlayer = player
        pipPlayerLayer = playerLayer
        pipController = pipCtrl

        print("PiP: setup — url=\(url.lastPathComponent), position=\(position), headers=\(headers.count)")
    }

    // MARK: - FIX: Start PiP chờ player + pip possible

    private func startPipWhenReady(position: Double, result: @escaping FlutterResult) {
        guard let player = pipPlayer, let pip = pipController else {
            print("PiP: startPipWhenReady — no player/controller")
            result(false)
            return
        }

        // Lưu lại để dùng trong observer
        pendingStartResult = result
        pendingStartPosition = position

        let item = player.currentItem
        let status = item?.status ?? .unknown

        if status == .readyToPlay {
            // Player đã sẵn sàng, thực hiện luôn
            performStartPip(player: player, pip: pip, position: position, result: result)
            pendingStartResult = nil
        } else {
            // Chưa ready → observe, timeout 5s
            print("PiP: waiting for player readyToPlay before startPip...")

            // Timeout guard
            DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
                guard let self = self, self.pendingStartResult != nil else { return }
                print("PiP: timeout waiting for readyToPlay")
                self.playerItemObserver?.invalidate()
                self.playerItemObserver = nil
                self.pendingStartResult?(false)
                self.pendingStartResult = nil
            }

            playerItemObserver?.invalidate()
            playerItemObserver = item?.observe(\.status, options: [.new]) { [weak self, weak player, weak pip] observedItem, _ in
                guard observedItem.status == .readyToPlay else { return }
                self?.playerItemObserver?.invalidate()
                self?.playerItemObserver = nil

                guard let self = self,
                      let player = player,
                      let pip = pip,
                      let pendingResult = self.pendingStartResult else { return }

                self.pendingStartResult = nil
                DispatchQueue.main.async {
                    self.performStartPip(player: player, pip: pip, position: self.pendingStartPosition, result: pendingResult)
                }
            }
        }
    }

    /// Thực sự seek + play + startPictureInPicture sau khi biết player đã ready
    private func performStartPip(player: AVPlayer, pip: AVPictureInPictureController, position: Double, result: @escaping FlutterResult) {
        if position > 0 {
            player.seek(
                to: CMTime(seconds: position, preferredTimescale: 600),
                toleranceBefore: .zero,
                toleranceAfter: .zero
            ) { [weak self, weak pip] finished in
                guard finished else { return }
                player.play()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    self?.tryStartPip(pip: pip, position: position, result: result)
                }
            }
        } else {
            player.play()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.tryStartPip(pip: pip, position: position, result: result)
            }
        }
    }

    private func tryStartPip(pip: AVPictureInPictureController?, position: Double, result: @escaping FlutterResult) {
        guard let pip = pip else { result(false); return }

        if pip.isPictureInPicturePossible {
            pip.startPictureInPicture()
            print("PiP: started at \(position)s ✓")
            result(true)
        } else {
            // Thử lại sau 0.5s thêm
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                if pip.isPictureInPicturePossible {
                    pip.startPictureInPicture()
                    print("PiP: started at \(position)s (retry) ✓")
                    result(true)
                } else {
                    print("PiP: not possible even after retry")
                    result(false)
                }
            }
        }
    }

    // MARK: - AirPlay

    @objc func dismissAirPlayPicker() {
        window?.rootViewController?.view.viewWithTag(9999)?.removeFromSuperview()
    }

    // MARK: - Position Timer

    private func startPositionTimer() {
        stopPositionTimer()
        pipPositionTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self = self, let player = self.pipPlayer else { return }
            let pos = player.currentItem?.currentTime().seconds ?? 0
            if !pos.isNaN && pos > 0 {
                self.lastPipPosition = pos
            }
        }
    }

    private func stopPositionTimer() {
        pipPositionTimer?.invalidate()
        pipPositionTimer = nil
    }
}

// MARK: - AVPictureInPictureControllerDelegate
extension AppDelegate: AVPictureInPictureControllerDelegate {
    func pictureInPictureControllerWillStartPictureInPicture(_ controller: AVPictureInPictureController) {
        pipPlayer?.play()
        startPositionTimer()
        pipChannel?.invokeMethod("onPipStarted", arguments: nil)
    }

    func pictureInPictureControllerWillStopPictureInPicture(_ controller: AVPictureInPictureController) {
        let pos = pipPlayer?.currentItem?.currentTime().seconds ?? 0
        if !pos.isNaN && pos > 0 { lastPipPosition = pos }
        stopPositionTimer()
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
        pipPlayer?.pause()
        // ★ FIX: restore audio session về .playback (video) thay vì .voiceChat
        // .voiceChat có AGC tự giảm volume → âm thanh bị nhỏ
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {}
    }

    func pictureInPictureController(_ controller: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error) {
        print("PiP: failed — \(error.localizedDescription)")
        stopPositionTimer()
    }

    func pictureInPictureControllerRestoreUserInterfaceForPictureInPictureStop(_ controller: AVPictureInPictureController, completionHandler: @escaping (Bool) -> Void) {
        completionHandler(true)
    }
}




