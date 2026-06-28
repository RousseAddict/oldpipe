import UIKit

@UIApplicationMain
class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        let nav = UINavigationController(rootViewController: HomeVC())
        nav.navigationBar.barStyle = .black
        nav.navigationBar.tintColor = UIColor(red: 0.98, green: 0.27, blue: 0.27, alpha: 1) // YouTube red
        window = UIWindow(frame: UIScreen.main.bounds)
        window?.backgroundColor = UIColor(red: 0.07, green: 0.07, blue: 0.07, alpha: 1)
        window?.rootViewController = nav
        window?.makeKeyAndVisible()
        return true
    }
}
