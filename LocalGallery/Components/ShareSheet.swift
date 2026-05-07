import SwiftUI
import UIKit

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

extension ShareSheet {
    /// Walk the presentation chain and present a `UIActivityViewController`
    /// from the topmost view controller. Used by the Logs view and the
    /// Settings crash banner — both need to share files from a context where
    /// embedding a SwiftUI `.sheet` modifier on the call site would be
    /// awkward (nested in a `Menu`, or fired from a `Button` action that
    /// already lives inside a presented sheet).
    @MainActor
    static func present(items: [Any]) {
        let vc = UIActivityViewController(activityItems: items, applicationActivities: nil)
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let window = scene.keyWindow else { return }
        var topVC = window.rootViewController
        while let presented = topVC?.presentedViewController { topVC = presented }
        vc.popoverPresentationController?.sourceView = window
        vc.popoverPresentationController?.sourceRect = CGRect(
            x: window.bounds.midX, y: window.safeAreaInsets.top, width: 0, height: 0
        )
        topVC?.present(vc, animated: true)
    }
}
