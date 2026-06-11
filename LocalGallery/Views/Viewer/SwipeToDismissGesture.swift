import SwiftUI
import UIKit

// MARK: - Swipe-down dismiss (UIKit gesture — doesn't conflict with TabView paging)

/// Vertical-pan installer with state-aware actions:
/// - Info drawer closed: down past 150pt dismisses the viewer; up past 150pt
///   opens the info drawer. Downward pans drive `offset` for the rubber-band
///   dim. Upward pans don't slide the photo — the drawer animates open.
/// - Info drawer open: down past 150pt closes the drawer. Touches starting
///   below `photoHeight` are ignored so the info panel's scroll view handles
///   them natively.
struct SwipeToDismissGestureInstaller: UIViewRepresentable {
    @Binding var offset: CGFloat
    @Binding var isInfoOpen: Bool
    var photoHeight: CGFloat
    var onDismiss: () -> Void
    var onOpenInfo: () -> Void
    var onCloseInfo: () -> Void

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        DispatchQueue.main.async {
            guard let host = view.parentViewController?.view else { return }
            let pan = UIPanGestureRecognizer(
                target: context.coordinator,
                action: #selector(Coordinator.handlePan(_:))
            )
            pan.delegate = context.coordinator
            pan.cancelsTouchesInView = false
            pan.delaysTouchesBegan = false
            host.addGestureRecognizer(pan)
            context.coordinator.panGesture = pan
            context.coordinator.hostView = host
        }
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.offsetBinding = $offset
        context.coordinator.isInfoOpenBinding = $isInfoOpen
        context.coordinator.photoHeight = photoHeight
        context.coordinator.onDismiss = onDismiss
        context.coordinator.onOpenInfo = onOpenInfo
        context.coordinator.onCloseInfo = onCloseInfo
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        if let pan = coordinator.panGesture, let host = coordinator.hostView {
            host.removeGestureRecognizer(pan)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            offset: $offset,
            isInfoOpen: $isInfoOpen,
            photoHeight: photoHeight,
            onDismiss: onDismiss,
            onOpenInfo: onOpenInfo,
            onCloseInfo: onCloseInfo
        )
    }

    class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var offsetBinding: Binding<CGFloat>
        var isInfoOpenBinding: Binding<Bool>
        var photoHeight: CGFloat
        var onDismiss: () -> Void
        var onOpenInfo: () -> Void
        var onCloseInfo: () -> Void
        var panGesture: UIPanGestureRecognizer?
        weak var hostView: UIView?

        init(
            offset: Binding<CGFloat>,
            isInfoOpen: Binding<Bool>,
            photoHeight: CGFloat,
            onDismiss: @escaping () -> Void,
            onOpenInfo: @escaping () -> Void,
            onCloseInfo: @escaping () -> Void
        ) {
            self.offsetBinding = offset
            self.isInfoOpenBinding = isInfoOpen
            self.photoHeight = photoHeight
            self.onDismiss = onDismiss
            self.onOpenInfo = onOpenInfo
            self.onCloseInfo = onCloseInfo
        }

        @objc func handlePan(_ gesture: UIPanGestureRecognizer) {
            let dy = gesture.translation(in: gesture.view).y
            let infoOpen = isInfoOpenBinding.wrappedValue
            switch gesture.state {
            case .changed:
                // Rubber-band only when info is closed and user is pulling down
                // to dismiss. All other states are threshold-based — no live
                // preview while dragging.
                if !infoOpen, dy > 0 {
                    offsetBinding.wrappedValue = dy
                }
            case .ended, .cancelled:
                if infoOpen {
                    if dy > 150 { onCloseInfo() }
                } else {
                    if dy > 150 {
                        onDismiss()
                    } else if dy < -150 {
                        onOpenInfo()
                    }
                    withAnimation(.easeOut(duration: 0.2)) {
                        offsetBinding.wrappedValue = 0
                    }
                }
            default:
                break
            }
        }

        // Begin for vertical pans. When info is open, only begin in the photo
        // area — touches in the info panel area belong to its scroll view.
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return false }
            let v = pan.velocity(in: pan.view)
            guard abs(v.y) > abs(v.x) * 2.0 else { return false }
            if isInfoOpenBinding.wrappedValue {
                let location = pan.location(in: pan.view)
                return location.y < photoHeight
            }
            return true
        }

        // Allow TabView's scroll gesture to work simultaneously
        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool { true }
    }
}

private extension UIView {
    var parentViewController: UIViewController? {
        var responder: UIResponder? = self
        while let r = responder {
            if let vc = r as? UIViewController { return vc }
            responder = r.next
        }
        return nil
    }
}

