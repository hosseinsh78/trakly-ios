import UIKit

/// The launch cover (S1, §B15, §E3): after the colour-only launch screen, the stored tone's colour (night `#04050b` on
/// a first launch or after a night document, else the canvas) until the first page is `ready`.
final class LaunchCover: UIViewController {
    private let night: Bool

    init(night: Bool) {
        self.night = night
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("not used")
    }

    override func loadView() {
        let root = UIView()
        root.backgroundColor = night ? Theme.night : Theme.canvas
        root.isAccessibilityElement = false
        view = root
    }

    override var preferredStatusBarStyle: UIStatusBarStyle {
        night ? .lightContent : .default
    }
}
