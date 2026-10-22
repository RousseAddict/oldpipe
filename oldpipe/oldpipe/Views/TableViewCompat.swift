import UIKit

// UITableView's cell-class registry arrived in iOS 6: both
// registerClass:forCellReuseIdentifier: and the index-path form of
// dequeueReusableCellWithIdentifier: are unavailable on iOS 5, where the
// one-argument dequeue is all there is and it returns nil on a miss — so the
// cell has to be built by the caller rather than by the table.
//
// On every other target these two helpers compile down to exactly the iOS 6
// calls the code used before, so the ios6/7/8 builds are behaviourally unchanged.
extension UITableView {

    func registerCell<T: UITableViewCell>(_ cellClass: T.Type, _ reuseId: String) {
        #if !IOS5_TARGET
        register(cellClass, forCellReuseIdentifier: reuseId)
        #endif
    }

    func dequeueCell<T: UITableViewCell>(_ cellClass: T.Type, _ reuseId: String,
                                         for indexPath: IndexPath) -> T {
        #if IOS5_TARGET
        if let cell = dequeueReusableCell(withIdentifier: reuseId) as? T { return cell }
        return cellClass.init(style: .default, reuseIdentifier: reuseId)
        #else
        return dequeueReusableCell(withIdentifier: reuseId, for: indexPath) as! T
        #endif
    }
}
