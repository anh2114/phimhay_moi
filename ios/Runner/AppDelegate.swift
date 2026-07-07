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
                print("PiP: startPip called from Flutter — position=\(position)")

                // Audio session đã configure trong setupPipController — không cần lại
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

            case "updatePipPosition":
                guard let args = call.arguments as? [String: Any],
                      let position = args["position"] as? Double else {
                    result(false)
                    return
                }
                self?.lastPipPosition = position
                // ★ FIX: Seek PiP player đến position mới nhất khi Flutter gọi update
                if let player = self?.pipPlayer, position > 0 {
                    player.seek(
                        to: CMTime(seconds: position, preferredTimescale: 600),
                        toleranceBefore: .zero,
                        toleranceAfter: .zero
                    )
                }
                result(true)

            case "setAutoPip":
                // iOS không cần auto-PiP (iOS PiP là manual button tap)
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

                    let tapGesture = UITapGestureRecognizer(target: self, action: #selector(self.dismissAirPlayPicker))
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

            case "configureForPlayback":
                // ★ FIX: Set audio session cho video playback — BẮT BUỘC trên iOS
                // Nếu không set → silent switch sẽ mute audio, hoặc audio không phát
                let session = AVAudioSession.sharedInstance()
                do {
                    try session.setCategory(.playback, mode: .moviePlayback,
                        options: [.allowBluetooth, .allowBluetoothA2DP])
                    try session.setActive(true)
                    result(true)
                } catch {
                    result(FlutterError(code: "PLAYBACK_ERROR", message: error.localizedDescription, details: nil))
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

        return super.application(application, didFinishLaunchingWithOptions: launchOptions)
    }

    // MARK: - PiP Setup

    private func setupPipController(url: URL, position: Double = 0, headers: [String: String] = [:]) {
        print("PiP: setupPipController called — url=\(url.absoluteString.prefix(80)), position=\(position)")

        // Dọn dẹp player cũ
        playerItemObserver?.invalidate()
        playerItemObserver = nil
        rateObservation?.invalidate()
        rateObservation = nil
        pendingStartResult = nil

        pipController?.delegate = nil
        pipController?.stopPictureInPicture()
        pipPlayer?.pause()
        pipPlayerLayer?.removeFromSuperlayer()
        pipPlayer = nil
        pipPlayerLayer = nil
        pipController = nil
        stopPositionTimer()

        // Audio session — CHỈ configure 1 lần ở đây, KHÔNG configure lại trong startPip
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback,
                options: [.allowBluetooth, .allowBluetoothA2DP])
            try AVAudioSession.sharedInstance().setActive(true)
            print("PiP: audio session configured OK")
        } catch {
            print("PiP: audio session ERROR: \(error)")
        }

        // Tạo AVPlayer với URL
        let asset: AVURLAsset
        if !headers.isEmpty {
            asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
        } else {
            asset = AVURLAsset(url: url)
        }
        let playerItem = AVPlayerItem(asset: asset)
        let player = AVPlayer(playerItem: playerItem)
        player.preventsDisplaySleepDuringVideoPlayback = true

        // PlayerLayer — PHẢI đủ lớn cho iOS PiP
        let playerLayer = AVPlayerLayer(player: player)
        playerLayer.frame = CGRect(x: 0, y: 0, width: 320, height: 180)
        playerLayer.isHidden = false
        playerLayer.opacity = 0.001
        playerLayer.videoGravity = .resizeAspect

        if let rootView = window?.rootViewController?.view {
            rootView.layer.addSublayer(playerLayer)
            print("PiP: playerLayer added to rootView")
        } else {
            print("PiP: ERROR — rootView is nil!")
        }

        let pipCtrl = AVPictureInPictureController(playerLayer: playerLayer)
        pipCtrl?.delegate = self
        print("PiP: AVPictureInPictureController created, isPictureInPicturePossible=\(pipCtrl?.isPictureInPicturePossible ?? false)")

        // Seek khi player ready
        if position > 0 {
            playerItemObserver = playerItem.observe(\.status, options: [.new]) { [weak self, weak player] item, _ in
                print("PiP: playerItem.status changed to \(item.status.rawValue)")
                guard item.status == .readyToPlay else { return }
                self?.playerItemObserver?.invalidate()
                self?.playerItemObserver = nil
                player?.seek(
                    to: CMTime(seconds: position, preferredTimescale: 600),
                    toleranceBefore: .zero,
                    toleranceAfter: .zero
                )
                print("PiP: seek to \(position)s done")
            }
        }

        pipPlayer = player
        pipPlayerLayer = playerLayer
        pipController = pipCtrl

        print("PiP: setup COMPLETE — player=\(player), pipCtrl=\(pipCtrl != nil)")
    }

    // MARK: - FIX: Start PiP chờ player + pip possible

    private func startPipWhenReady(position: Double, result: @escaping FlutterResult) {
        print("PiP: startPipWhenReady — pipPlayer=\(pipPlayer != nil), pipController=\(pipController != nil)")
        guard let player = pipPlayer, let pip = pipController else {
            print("PiP: FAIL — pipPlayer or pipController is nil!")
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
            // ★ FIX: KHÔNG nil pendingStartResult ở đây
            // → nil trong willStartPictureInPicture (khi PiP THỰC SỰ start)
            // → hoặc failedToStart delegate (khi PiP fail)
            performStartPip(player: player, pip: pip, position: position, result: result)
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
        print("PiP: performStartPip — position=\(position), isPossible=\(pip.isPictureInPicturePossible), rate=\(player.rate)")

        let seekThenPlay: () -> Void = { [weak self] in
            player.play()
            print("PiP: player.play() called, rate after play=\(player.rate)")
            self?.observePlayerRateAndStartPip(player: player, pip: pip, position: position, result: result)
        }

        if position > 0 {
            player.seek(
                to: CMTime(seconds: position, preferredTimescale: 600),
                toleranceBefore: .zero,
                toleranceAfter: .zero
            ) { finished in
                guard finished else { return }
                seekThenPlay()
            }
        } else {
            seekThenPlay()
        }
    }

    // ★ FIX: KVO player.rate → biết chính xác khi nào player bắt đầu play
    private var rateObservation: NSKeyValueObservation?
    private var pipRetryCount = 0
    private static let maxPipRetries = 8

    private func observePlayerRateAndStartPip(player: AVPlayer, pip: AVPictureInPictureController, position: Double, result: @escaping FlutterResult) {
        rateObservation?.invalidate()
        pipRetryCount = 0

        // Thử ngay lập tức nếu rate > 0
        if player.rate > 0 && pip.isPictureInPicturePossible {
            print("PiP: player already playing, starting PiP immediately")
            do {
                try pip.startPictureInPicture()
                print("PiP: started at \(position)s ✓")
                result(true)
            } catch {
                print("PiP: startPictureInPicture threw error: \(error)")
                result(false)
            }
            return
        }

        // Observe rate property — khi rate > 0 thì player đang play
        rateObservation = player.observe(\.rate, options: [.new, .old]) { [weak self, weak player, weak pip] _, change in
            guard let self = self, let player = player, let pip = pip else { return }
            let rate = player.rate
            guard rate > 0 else { return }

            // Player đang play — thử start PiP
            self.rateObservation?.invalidate()
            self.rateObservation = nil

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                self.tryStartPipWithRetry(pip: pip, position: position, result: result)
            }
        }

        // Timeout fallback 5s — nếu rate không bao giờ > 0
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
            guard let self = self, self.rateObservation != nil else { return }
            self.rateObservation?.invalidate()
            self.rateObservation = nil
            print("PiP: timeout waiting for player.rate > 0")
            result(false)
        }
    }

    private func tryStartPipWithRetry(pip: AVPictureInPictureController, position: Double, result: @escaping FlutterResult) {
        print("PiP: tryStartPipWithRetry — isPossible=\(pip.isPictureInPicturePossible), retry=\(pipRetryCount)")
        if pip.isPictureInPicturePossible {
            do {
                try pip.startPictureInPicture()
                print("PiP: startPictureInPicture() called OK at \(position)s")
                result(true)
            } catch {
                print("PiP: startPictureInPicture THREW: \(error)")
                result(false)
            }
        } else if pipRetryCount < Self.maxPipRetries {
            pipRetryCount += 1
            let delay = 0.3 + Double(pipRetryCount) * 0.15
            print("PiP: not possible yet (retry \(pipRetryCount)), waiting \(delay)s...")
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.tryStartPipWithRetry(pip: pip, position: position, result: result)
            }
        } else {
            print("PiP: not possible after \(Self.maxPipRetries) retries")
            result(false)
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
        print("PiP: willStartPictureInPicture ✓ — PiP THỰC SỰ STARTED")
        pendingStartResult = nil
        startPositionTimer()
        pipChannel?.invokeMethod("onPipStarted", arguments: nil)
    }

    func pictureInPictureControllerWillStopPictureInPicture(_ controller: AVPictureInPictureController) {
        print("PiP: willStopPictureInPicture")
        let pos = pipPlayer?.currentItem?.currentTime().seconds ?? 0
        if !pos.isNaN && pos > 0 { lastPipPosition = pos }
        stopPositionTimer()
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
        print("PiP: didStopPictureInPicture")
        pipPlayer?.pause()
        pipChannel?.invokeMethod("onPipStopped", arguments: nil)
        // ★ FIX: restore audio session về .playback (video)
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback,
                options: [.allowBluetooth, .allowBluetoothA2DP])
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {}
    }

    func pictureInPictureController(_ controller: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error) {
        print("PiP: FAILED to start — \(error.localizedDescription)")
        stopPositionTimer()
        rateObservation?.invalidate()
        rateObservation = nil
        // ★ FIX: Gọi pendingStartResult?(false) để Dart future resolve
        // Nếu không gọi → invokeMethod('startPip') treo mãi, Flutter hang
        pendingStartResult?(false)
        pendingStartResult = nil
        pipChannel?.invokeMethod("onPipStopped", arguments: nil)
    }

    func pictureInPictureControllerRestoreUserInterfaceForPictureInPictureStop(_ controller: AVPictureInPictureController, completionHandler: @escaping (Bool) -> Void) {
        completionHandler(true)
    }
}




