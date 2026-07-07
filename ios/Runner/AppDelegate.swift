import UIKit
import Flutter
import AVFoundation
import AVKit
import fl_pip

@main
@objc class AppDelegate: FlFlutterAppDelegate {

    override func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        let controller = window?.rootViewController as! FlutterViewController
        let audioChannel = FlutterMethodChannel(name: "phimhay_app/audio", binaryMessenger: controller.binaryMessenger)

        // Audio channel
        audioChannel.setMethodCallHandler { (call, result) in
            switch call.method {
            case "setSpeaker":
                let args = call.arguments as? [String: Any]
                let speakerOn = args?["on"] as? Bool ?? true
                let session = AVAudioSession.sharedInstance()
                do {
                    if speakerOn {
                        try session.setCategory(.playAndRecord, mode: .default,
                            options: [.defaultToSpeaker, .allowBluetooth, .allowBluetoothA2DP])
                        try session.setActive(true, options: [])
                        try session.overrideOutputAudioPort(.speaker)
                    } else {
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

    override func registerPlugin(_ registry: FlutterPluginRegistry) {
        GeneratedPluginRegistrant.register(with: registry)
    }
}
