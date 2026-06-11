import SwiftUI
import UIKit

// MARK: - Efficient Pager (UIPageViewController)

struct PagingPhotoView: UIViewControllerRepresentable {
    let photos: [PhotoFile]
    let store: GalleryStore
    /// Source of truth is the photo's id, not its index. A foreground rescan
    /// can insert/remove photos and shift indices — the index would silently
    /// land on a different photo, so we keep the id stable and re-resolve
    /// the index against the current `photos` array on every update.
    @Binding var currentPhotoID: UUID
    @Binding var isChromeVisible: Bool
    @Binding var isInfoOpen: Bool

    func makeUIViewController(context: Context) -> UIPageViewController {
        let pvc = UIPageViewController(
            transitionStyle: .scroll,
            navigationOrientation: .horizontal,
            options: [.interPageSpacing: 12]
        )
        pvc.dataSource = context.coordinator
        pvc.delegate = context.coordinator
        pvc.view.backgroundColor = .clear
        // Fall back to the first photo's id when the bound id is no longer in
        // `photos` — defensive against being constructed mid-rescan.
        let initialID = photos.contains(where: { $0.id == currentPhotoID })
            ? currentPhotoID
            : photos.first?.id
        if let id = initialID {
            let initial = context.coordinator.makeHostingController(for: id)
            pvc.setViewControllers([initial], direction: .forward, animated: false)
        }
        return pvc
    }

    func updateUIViewController(_ pvc: UIPageViewController, context: Context) {
        context.coordinator.parent = self
        guard let current = pvc.viewControllers?.first as? IndexedHostingController,
              current.photoID != currentPhotoID,
              photos.contains(where: { $0.id == currentPhotoID }) else { return }
        // Programmatic `setViewControllers` mid-swipe trips UIPageViewController's
        // "No view controller managing visible view" assertion — its in-flight
        // transition gets interrupted while the queuing scroll view still
        // points at a view it no longer manages. Stash the request and apply
        // it from `didFinishAnimating` instead.
        if context.coordinator.isTransitioning {
            context.coordinator.pendingPhotoID = currentPhotoID
            return
        }
        context.coordinator.applyPhotoID(currentPhotoID, to: pvc)
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    class IndexedHostingController: UIHostingController<AnyView> {
        let photoID: UUID
        init(photoID: UUID, rootView: AnyView) {
            self.photoID = photoID
            super.init(rootView: rootView)
            view.backgroundColor = .clear
        }
        @MainActor required init?(coder: NSCoder) { fatalError() }
    }

    class Coordinator: NSObject, UIPageViewControllerDataSource, UIPageViewControllerDelegate {
        var parent: PagingPhotoView
        /// True between `willTransitionTo` and `didFinishAnimating` for a
        /// gesture-driven swipe. While set, programmatic photoID updates are
        /// queued via `pendingPhotoID` and data-source neighbor lookups read
        /// from `photosSnapshot` so an enrichment tick that rebuilds
        /// `parent.photos` can't shift the answers UIKit gets mid-transition.
        var isTransitioning = false
        /// Photo id requested by `updateUIViewController` while a transition
        /// was in flight. Applied from `didFinishAnimating`.
        var pendingPhotoID: UUID?
        /// Photos array frozen for the duration of a manual swipe.
        private var photosSnapshot: [PhotoFile]?
        /// Weak cache so a given photoID always resolves to the same hosting
        /// controller while UIPageViewController still holds it. Returning a
        /// fresh instance on every data-source call confused the page
        /// controller's bookkeeping when the user reversed direction mid-swipe.
        private final class WeakVC { weak var vc: IndexedHostingController? }
        private var vcCache: [UUID: WeakVC] = [:]

        init(_ parent: PagingPhotoView) { self.parent = parent }

        private var activePhotos: [PhotoFile] {
            photosSnapshot ?? parent.photos
        }

        func makeHostingController(for photoID: UUID) -> IndexedHostingController {
            if let cached = vcCache[photoID]?.vc { return cached }
            // Caller guarantees `photoID` is in `activePhotos`; the firstIndex
            // lookup is the canonical resolution path post-rescan.
            let photos = activePhotos
            let idx = photos.firstIndex(where: { $0.id == photoID }) ?? 0
            let photo = photos[idx]
            let view = PhotoPageView(
                photo: photo,
                initialThumbnail: parent.store.cachedThumbnail(for: photo.url),
                isChromeVisible: parent.$isChromeVisible,
                isInfoOpen: parent.$isInfoOpen
            )
            .environment(parent.store)
            let controller = IndexedHostingController(photoID: photoID, rootView: AnyView(view))
            let box = WeakVC()
            box.vc = controller
            vcCache[photoID] = box
            return controller
        }

        func applyPhotoID(_ photoID: UUID, to pvc: UIPageViewController) {
            guard let current = pvc.viewControllers?.first as? IndexedHostingController,
                  current.photoID != photoID,
                  parent.photos.contains(where: { $0.id == photoID }) else { return }
            let curIdx = parent.photos.firstIndex(where: { $0.id == current.photoID }) ?? 0
            let tarIdx = parent.photos.firstIndex(where: { $0.id == photoID }) ?? 0
            let direction: UIPageViewController.NavigationDirection = tarIdx > curIdx ? .forward : .reverse
            let vc = makeHostingController(for: photoID)
            pvc.setViewControllers([vc], direction: direction, animated: false)
            // didFinishAnimating (the usual prune point) doesn't fire for
            // programmatic transitions — drop dead boxes here too.
            vcCache = vcCache.filter { $0.value.vc != nil }
        }

        func pageViewController(_ pvc: UIPageViewController, viewControllerBefore vc: UIViewController) -> UIViewController? {
            let photos = activePhotos
            guard let indexed = vc as? IndexedHostingController,
                  let curIdx = photos.firstIndex(where: { $0.id == indexed.photoID }),
                  curIdx > 0 else { return nil }
            return makeHostingController(for: photos[curIdx - 1].id)
        }

        func pageViewController(_ pvc: UIPageViewController, viewControllerAfter vc: UIViewController) -> UIViewController? {
            let photos = activePhotos
            guard let indexed = vc as? IndexedHostingController,
                  let curIdx = photos.firstIndex(where: { $0.id == indexed.photoID }),
                  curIdx < photos.count - 1 else { return nil }
            return makeHostingController(for: photos[curIdx + 1].id)
        }

        func pageViewController(_ pvc: UIPageViewController, willTransitionTo pendingViewControllers: [UIViewController]) {
            isTransitioning = true
            photosSnapshot = parent.photos
        }

        func pageViewController(_ pvc: UIPageViewController, didFinishAnimating finished: Bool, previousViewControllers: [UIViewController], transitionCompleted completed: Bool) {
            isTransitioning = false
            photosSnapshot = nil
            if completed, let indexed = pvc.viewControllers?.first as? IndexedHostingController {
                parent.currentPhotoID = indexed.photoID
            }
            vcCache = vcCache.filter { $0.value.vc != nil }
            if let pending = pendingPhotoID {
                pendingPhotoID = nil
                applyPhotoID(pending, to: pvc)
            }
        }
    }
}

