#if COLUMBA_NOMADNET_ENABLED
import SwiftUI
import RNSAPI
#if os(iOS)
import UIKit

/// A SwiftUI wrapper around `UIScrollView` that provides native two-finger
/// pinch-to-zoom plus horizontal + vertical scrolling. SwiftUI's `ScrollView`
/// combined with `MagnifyGesture` can't coordinate pan and pinch cleanly —
/// `UIScrollView` handles both natively via its built-in gesture recognizers.
///
/// Used by the NomadNet browser's `Monospace (scroll)` rendering mode.
@available(iOS 17.0, *)
struct ZoomableScrollView<Content: View>: UIViewRepresentable {
    let content: Content
    var minimumZoom: CGFloat = 0.5
    var maximumZoom: CGFloat = 4.0

    init(
        minimumZoom: CGFloat = 0.5,
        maximumZoom: CGFloat = 4.0,
        @ViewBuilder content: () -> Content
    ) {
        self.minimumZoom = minimumZoom
        self.maximumZoom = maximumZoom
        self.content = content()
    }

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = UIScrollView()
        scrollView.minimumZoomScale = minimumZoom
        scrollView.maximumZoomScale = maximumZoom
        scrollView.delegate = context.coordinator
        scrollView.showsHorizontalScrollIndicator = true
        scrollView.showsVerticalScrollIndicator = true
        scrollView.bouncesZoom = true
        scrollView.alwaysBounceHorizontal = false
        scrollView.alwaysBounceVertical = false
        scrollView.backgroundColor = .clear
        scrollView.contentInsetAdjustmentBehavior = .automatic

        // Host the SwiftUI content in a UIHostingController; attach its view
        // to the scroll view at its intrinsic content size so the scroll
        // view's contentSize tracks the document's natural width/height.
        let host = UIHostingController(rootView: content)
        host.view.translatesAutoresizingMaskIntoConstraints = true
        host.view.backgroundColor = .clear
        host.view.frame = CGRect(origin: .zero, size: host.view.intrinsicContentSize)
        scrollView.addSubview(host.view)
        scrollView.contentSize = host.view.frame.size

        context.coordinator.hostingController = host
        context.coordinator.scrollView = scrollView
        return scrollView
    }

    func updateUIView(_ scrollView: UIScrollView, context: Context) {
        // Update the hosted SwiftUI content and resize to match new intrinsic size.
        guard let host = context.coordinator.hostingController else { return }
        host.rootView = content

        // Measure the natural size of the new content.
        let target = host.view.systemLayoutSizeFitting(
            UIView.layoutFittingCompressedSize,
            withHorizontalFittingPriority: .fittingSizeLevel,
            verticalFittingPriority: .fittingSizeLevel
        )
        let size = CGSize(
            width: max(target.width, host.view.intrinsicContentSize.width),
            height: max(target.height, host.view.intrinsicContentSize.height)
        )
        if host.view.frame.size != size {
            host.view.frame = CGRect(origin: .zero, size: size)
            // contentSize must account for zoom — UIScrollView scales contentSize by zoomScale
            scrollView.contentSize = size
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator: NSObject, UIScrollViewDelegate {
        weak var scrollView: UIScrollView?
        var hostingController: UIHostingController<Content>?

        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            hostingController?.view
        }
    }
}
#endif
#endif
