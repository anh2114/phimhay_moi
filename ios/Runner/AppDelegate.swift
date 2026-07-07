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
                self.startPiP(result: result)
            case "prewarmPiP":
                guard let args = call.arguments as? [String: Any],
                      let url = args["url"] as? String,
                      let position = args["position"] as? Int else {
                    result(false)
                    return
                }
                self.prewarmPiP(url: url, position: position)
                result(true)
            case "isPiP":
                result(self.pipWebView != nil)
            case "exitPiP":
                result(false)
            case "updatePiPPosition":
                guard let args = call.arguments as? [String: Any],
                      let position = args["position"] as? Int else {
                    result(false)
                    return
                }
                self.updatePiPPosition(position: position)
                result(true)
            default:
                result(FlutterMethodNotImplemented)
            }
        }

        GeneratedPluginRegistrant.register(with: self)
        return super.application(application, didFinishLaunchingWithOptions: launchOptions)
    }

    // MARK: - PiP via WebKit

    private func prewarmPiP(url: String, position: Int) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            NSLog("[PiP] prewarm — url=\(url.prefix(100))... pos=\(position)")

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

            // Load HTML with video element — autoPiP when going to background
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
            <video id="pipVideo" playsinline webkit-playsinline x-webkit-airplay="allows-airplay" autoplay autoPictureInPicture></video>
            <script>
                var video = document.getElementById('pipVideo');
                video.src = '\(url.replacingOccurrences(of: "'", with: "\\'"))';
                video.currentTime = \(position);
                video.load();
                video.play().catch(function(e) { console.log('prewarm play error:', e); });
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
            let pipStartedHandler = PiPStartedHandler { [weak self] in
                NSLog("[PiP] PiP started!")
                self?.pipChannel?.invokeMethod("onPiPModeChanged", arguments: true)
            }

            let pipEndedHandler = PiPEndedHandler { [weak self] in
                NSLog("[PiP] PiP ended — keeping WebView alive for reuse")
                let webView = self?.pipWebView
                webView?.evaluateJavaScript("document.getElementById('pipVideo').currentTime") { pos, _ in
                    let position = (pos as? NSNumber)?.intValue ?? 0
                    NSLog("[PiP] Position at end: \(position)")
                    // Pause video but KEEP WebView alive for next PiP
                    webView?.evaluateJavaScript("document.getElementById('pipVideo').pause()")
                    self?.pipChannel?.invokeMethod("onPiPModeChanged", arguments: false)
                    DispatchQueue.main.async {
                        self?.pipChannel?.invokeMethod("onPiPRestore", arguments: ["position": position])
                    }
                }
            }

            let pipErrorHandler = PiPErrorHandler { [weak self] error in
                NSLog("[PiP] Error: \(error)")
            }

            let contentController = webView.configuration.userContentController
            contentController.add(pipStartedHandler, name: "pipStarted")
            contentController.add(pipEndedHandler, name: "pipEnded")
            contentController.add(pipErrorHandler, name: "pipError")

            // Load HTML
            webView.loadHTMLString(html, baseURL: URL(string: "https://xiaofilm.site"))
        }
    }

    private func startPiP(result: @escaping FlutterResult) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, let webView = self.pipWebView else {
                result(FlutterError(code: "NO_WEBVIEW", message: "No prewarmed WebView. Call prewarmPiP first.", details: nil))
                return
            }

            NSLog("[PiP] startPiP — calling requestPictureInPicture()")

            // This MUST be called in user gesture context (same tick as the tap)
            let js = """
            (function() {
                var video = document.getElementById('pipVideo');
                if (!video) { return 'no video element'; }
                if (!video.src) { return 'no video src'; }
                if (video.readyState < 2) { return 'video not ready: readyState=' + video.readyState; }
                video.requestPictureInPicture().then(function() {
                    console.log('PiP started OK');
                }).catch(function(e) {
                    console.log('PiP request failed:', e.message);
                    window.webkit.messageHandlers.pipError.postMessage({error: e.message});
                });
                return 'requesting...';
            })()
            """

            webView.evaluateJavaScript(js) { resultStr, error in
                if let error = error {
                    NSLog("[PiP] JS error: \(error)")
                    result(FlutterError(code: "JS_ERROR", message: error.localizedDescription, details: nil))
                } else {
                    NSLog("[PiP] JS result: \(resultStr ?? "nil")")
                    // Don't return true yet — wait for enterpictureinpicture event
                    result(true)
                }
            }
        }
    }

    private func updatePiPPosition(position: Int) {
        DispatchQueue.main.async { [weak self] in
            guard let webView = self?.pipWebView else { return }
            let js = """
            (function() {
                var video = document.getElementById('pipVideo');
                if (!video) return;
                // Only update if position differs significantly (>3s)
                if (Math.abs(video.currentTime - \(position)) > 3) {
                    video.currentTime = \(position);
                }
                video.play().catch(function(){});
            })()
            """
            webView.evaluateJavaScript(js)
        }
    }

    private func cleanupPiPWebView() {
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
