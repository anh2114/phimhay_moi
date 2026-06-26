import Flutter
import UIKit
import Appodeal

class AppodealPlugin: NSObject, FlutterPlugin {
    static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(
            name: "com.xiaofilm/appodeal",
            binaryMessenger: registrar.messenger()
        )
        let instance = AppodealPlugin()
        registrar.addMethodCallDelegate(instance, channel: channel)
    }
    
    func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "initialize":
            guard let args = call.arguments as? [String: Any],
                  let appKey = args["appKey"] as? String else {
                result(FlutterError(code: "INVALID_ARGS", message: "Missing appKey", details: nil))
                return
            }
            initializeAppodeal(appKey: appKey, result: result)
            
        case "loadInterstitial":
            Appodeal.loadAd(withType: .interstitial)
            result(nil)
            
        case "showInterstitial":
            let shown = Appodeal.showAd(withType: .interstitial)
            result(shown)
            
        case "loadRewarded":
            Appodeal.loadAd(withType: .rewardedVideo)
            result(nil)
            
        case "showRewarded":
            let shown = Appodeal.showAd(withType: .rewardedVideo)
            result(shown)
            
        case "loadBanner":
            result(nil)
            
        default:
            result(FlutterMethodNotImplemented)
        }
    }
    
    private func initializeAppodeal(appKey: String, result: @escaping FlutterResult) {
        let types: AppodealAdType = [.interstitial, .banner, .rewardedVideo]
        
        Appodeal.setSdkVersion("3.0.0")
        Appodeal.initialize(
            withApiKey: appKey,
            types: types,
            completion: { initialized in
                print("[Appodeal] SDK initialized: \(initialized)")
                result(initialized)
            }
        )
    }
}
