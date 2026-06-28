import Flutter
import UIKit
import Appodeal

class AppodealPlugin: NSObject {
    private weak var viewController: FlutterViewController?
    private var isInitialized = false

    init(viewController: FlutterViewController) {
        self.viewController = viewController
    }

    static func register(controller: FlutterViewController) {
        let channel = FlutterMethodChannel(
            name: "com.xiaofilm/appodeal",
            binaryMessenger: controller.binaryMessenger
        )
        let instance = AppodealPlugin(viewController: controller)
        channel.setMethodCallHandler { call, result in
            instance.handle(call, result: result)
        }
    }

    func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "initialize":
            guard let args = call.arguments as? [String: Any],
                  let appKey = args["appKey"] as? String else {
                result(FlutterError(code: "INVALID_ARGS", message: "Missing appKey", details: nil))
                return
            }
            guard !isInitialized else {
                print("[Appodeal] Already initialized, skipping")
                result(true)
                return
            }
            Appodeal.setLogLevel(.verbose)
            Appodeal.setAutocache(true, types: [.interstitial, .banner, .rewardedVideo])
            Appodeal.setTestingEnabled(true)
            Appodeal.initialize(
                withApiKey: appKey,
                types: [.interstitial, .banner, .rewardedVideo]
            )
            isInitialized = true
            print("[Appodeal] SDK initialized via channel")
            result(true)

        case "loadInterstitial":
            Appodeal.cacheAd(.interstitial)
            result(nil)

        case "showInterstitial":
            guard let vc = viewController else { result(false); return }
            let initialized = Appodeal.isInitialized(for: .interstitial)
            let ready = Appodeal.canShow(.interstitial, forPlacement: "")
            print("[Appodeal] showInterstitial initialized=\(initialized) canShow=\(ready)")
            if initialized && ready {
                let shown = Appodeal.showAd(.interstitial, rootViewController: vc)
                result(shown)
            } else {
                result(false)
            }

        case "loadRewarded":
            Appodeal.cacheAd(.rewardedVideo)
            result(nil)

        case "showRewarded":
            guard let vc = viewController else { result(false); return }
            let initialized = Appodeal.isInitialized(for: .rewardedVideo)
            let ready = Appodeal.canShow(.rewardedVideo, forPlacement: "")
            print("[Appodeal] showRewarded initialized=\(initialized) canShow=\(ready)")
            if initialized && ready {
                let shown = Appodeal.showAd(.rewardedVideo, rootViewController: vc)
                result(shown)
            } else {
                result(false)
            }

        case "loadBanner":
            Appodeal.cacheAd(.banner)
            result(nil)

        case "showBanner":
            guard let vc = viewController else { result(false); return }
            let initialized = Appodeal.isInitialized(for: .banner)
            let ready = Appodeal.canShow(.banner, forPlacement: "")
            print("[Appodeal] showBanner initialized=\(initialized) canShow=\(ready)")
            if initialized && ready {
                Appodeal.showAd(.bannerBottom, rootViewController: vc)
                result(true)
            } else {
                result(false)
            }

        case "hideBanner":
            Appodeal.hideBanner()
            result(true)

        case "getDebugInfo":
            let info: [String: Any] = [
                "isInitialized_interstitial": Appodeal.isInitialized(for: .interstitial),
                "isInitialized_banner": Appodeal.isInitialized(for: .banner),
                "isInitialized_rewardedVideo": Appodeal.isInitialized(for: .rewardedVideo),
                "canShow_interstitial": Appodeal.canShow(.interstitial, forPlacement: ""),
                "canShow_banner": Appodeal.canShow(.banner, forPlacement: ""),
                "canShow_rewardedVideo": Appodeal.canShow(.rewardedVideo, forPlacement: ""),
                "autocache_interstitial": Appodeal.isAutocacheEnabled(.interstitial),
                "autocache_banner": Appodeal.isAutocacheEnabled(.banner),
                "autocache_rewardedVideo": Appodeal.isAutocacheEnabled(.rewardedVideo),
                "predictedEcpm_interstitial": Appodeal.predictedEcpm(for: .interstitial),
                "predictedEcpm_banner": Appodeal.predictedEcpm(for: .banner),
                "predictedEcpm_rewardedVideo": Appodeal.predictedEcpm(for: .rewardedVideo),
                "pluginIsInitialized": isInitialized,
                "viewController": viewController != nil ? "ok" : "nil",
            ]
            print("[Appodeal] Debug info: \(info)")
            result(info)

        default:
            result(FlutterMethodNotImplemented)
        }
    }
}
