import UIKit
import Flutter
import AVFoundation
import AVKit
import WebKit

@main
@objc class AppDelegate: FlutterAppDelegate, AVPictureInPictureControllerDelegate {

    private var pipChannel: FlutterMethodChannel?
    private var pipWebView: WKWebView?
    private var pipRestorePosition: Int = 0

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
                result(self.pipWebView != nil)
            case "exitPiP":
                result(false)
            default:
                result(FlutterMethodNotImplemented)
            }
        }

        GeneratedPluginRegistrant.register(with: self)
        return super.application(application, didFinishLaunchingWithOptions: launchOptions)
    }

    // MARK: - PiP via WebKit

    private func enterPiP(url: String, position: Int, result: @escaping FlutterResult) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else {
                result(FlutterError(code: "DEALLOC", message: "AppDelegate deallocated", details: nil))
                return
            }

            NSLog("[PiP] enterPiP via WebKit — url=\(url.prefix(100))... pos=\(position)")
            self.pipRestorePosition = position

            // Setup audio session
            do {
                try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback,
                    options: [.allowBluetooth, .allowBluetoothA2DP])
                try AVAudioSession.sharedInstance().setActive(true)
            } catch {
                NSLog("[PiP] Audio session failed: \(error)")
            }

            // Cleanup old WebView
            self.cleanupPiPWebView()

            // Create hidden WKWebView for PiP
            let config = WKWebViewConfiguration()
            config.allowsInlineMediaPlayback = true
            config.mediaTypesRequiringUserActionForPlayback = []

            let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 320, height: 180), configuration: config)
            webView.isHidden = true
            webView.tag = 8888
            self.window?.rootViewController?.view.addSubview(webView)
            self.pipWebView = webView

            // Load HTML with video element pointing to the m3u8 URL
            let html = """
            <!DOCTYPE html>
            <html>
            <head>
            <style>
                body { margin: 0; background: black; }
                video { width: 100%; height: 100%; object-fit: contain; }
            </style>
            </head>
            <body>
            <video id="pipVideo" playsinline webkit-playsinline x-webkit-airplay="allows-airplay" autoplay></video>
            <script>
                var video = document.getElementById('pipVideo');
                video.src = '\(url.replacingOccurrences(of: "'", with: "\\'"))';
                video.load();
                video.addEventListener('loadeddata', function() {
                    video.currentTime = \(position);
                    video.play().catch(function(e) { console.log('play error:', e); });
                    // Notify native that video is ready
                    window.webkit.messageHandlers.pipReady.postMessage({ready: true});
                });
                video.addEventListener('enterpictureinpicture', function() {
                    window.webkit.messageHandlers.pipStarted.postMessage({started: true});
                });
                video.addEventListener('leavepictureinpicture', function() {
                    window.webkit.messageHandlers.pipEnded.postMessage({ended: true});
                });
                video.addEventListener('error', function(e) {
                    window.webkit.messageHandlers.pipError.postMessage({error: e.target.error?.message || 'Unknown error'});
                });
            </script>
            </body>
            </html>
            """

            // Add message handlers
            let pipReadyHandler = PipReadyHandler { [weak self] in
                NSLog("[PiP] Video ready — requesting PiP")
                let js = "document.getElementById('pipVideo').requestPictureInPicture().catch(function(e){window.webkit.messageHandlers.pipError.postMessage({error:e.message})});"
                webView.evaluateJavaScript(js) { _, error in
                    if let error = error {
                        NSLog("[PiP] requestPictureInPicture failed: \(error)")
                        result(FlutterError(code: "PIP_FAILED", message: error.localizedDescription, details: nil))
                        self?.cleanupPiPWebView()
                    }
                }
            }

            let pipStartedHandler = PiPStartedHandler { [weak self] in
                NSLog("[PiP] PiP started!")
                self?.pipChannel?.invokeMethod("onPiPModeChanged", arguments: true)
                result(true)
            }

            let pipEndedHandler = PiPEndedHandler { [weak self] in
                NSLog("[PiP] PiP ended — getting position")
                let webView = self?.pipWebView
                webView?.evaluateJavaScript("document.getElementById('pipVideo').currentTime") { pos, _ in
                    let position = (pos as? NSNumber)?.intValue ?? 0
                    NSLog("[PiP] Position at end: \(position)")
                    self?.cleanupPiPWebView()
                    DispatchQueue.main.async {
                        self?.pipChannel?.invokeMethod("onPiPRestore", arguments: ["position": position])
                    }
                }
            }

            let pipErrorHandler = PiPErrorHandler { [weak self] error in
                NSLog("[PiP] Error: \(error)")
                result(FlutterError(code: "PIP_ERROR", message: error, details: nil))
                self?.cleanupPiPWebView()
            }

            let contentController = webView.configuration.userContentController
            contentController.add(pipReadyHandler, name: "pipReady")
            contentController.add(pipStartedHandler, name: "pipStarted")
            contentController.add(pipEndedHandler, name: "pipEnded")
            contentController.add(pipErrorHandler, name: "pipError")

            // Timeout after 15s
            DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
                guard self?.pipWebView != nil else { return }
                NSLog("[PiP] TIMEOUT — video not ready in 15s")
                self?.cleanupPiPWebView()
                result(FlutterError(code: "TIMEOUT", message: "Video did not load in 15s", details: nil))
            }

            // Load HTML
            webView.loadHTMLString(html, baseURL: URL(string: "https://xiaofilm.site"))
        }
    }

    private func cleanupPiPWebView() {
        pipWebView?.configuration.userContentController.removeScriptMessageHandler(forName: "pipReady")
        pipWebView?.configuration.userContentController.removeScriptMessageHandler(forName: "pipStarted")
        pipWebView?.configuration.userContentController.removeScriptMessageHandler(forName: "pipEnded")
        pipWebView?.configuration.userContentController.removeScriptMessageHandler(forName: "pipError")
        pipWebView?.removeFromSuperview()
        pipWebView = nil
    }

    @objc func dismissAirPlay() {
        window?.rootViewController?.view.viewWithTag(9999)?.removeFromSuperview()
    }
}

// MARK: - WKScriptMessageHandler wrappers

class PipReadyHandler: NSObject, WKScriptMessageHandler {
    let callback: () -> Void
    init(callback: @escaping () -> Void) { self.callback = callback }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        callback()
    }
}

class PiPStartedHandler: NSObject, WKScriptMessageHandler {
    let callback: () -> Void
    init(callback: @escaping () -> Void) { self.callback = callback }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        callback()
    }
}

class PiPEndedHandler: NSObject, WKScriptMessageHandler {
    let callback: () -> Void
    init(callback: @escaping () -> Void) { self.callback = callback }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        callback()
    }
}

class PiPErrorHandler: NSObject, WKScriptMessageHandler {
    let callback: (String) -> Void
    init(callback: @escaping (String) -> Void) { self.callback = callback }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        let error = (message.body as? [String: Any])?["error"] as? String ?? "Unknown error"
        callback(error)
    }
}
