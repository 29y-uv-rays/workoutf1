import UIKit
import HealthKit

class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        HealthKitService.shared.enableBackgroundDeliveryIfPossible()
        return true
    }
}
