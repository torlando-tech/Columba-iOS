//
//  MessageTimelineView.swift
//  Columba-iOS
//
//  UIKit-backed conversation timeline. UIKit owns scrolling, cell reuse,
//  pagination triggers, and viewport continuity. SwiftUI continues to render
//  the existing message bubble content inside reusable collection cells.
//

import SwiftUI
#if os(iOS)
import UIKit
#endif

struct MessageTimelinePaginationPolicy {
    static func shouldLoadOlder(
        contentOffsetY: CGFloat,
        viewportHeight: CGFloat,
        isLoading: Bool,
        allHistoryLoaded: Bool
    ) -> Bool {
        guard viewportHeight > 0, !isLoading, !allHistoryLoaded else { return false }
        return contentOffsetY < viewportHeight * 3
    }
}

struct MessageTimelineViewportAnchor {
    static func adjustedContentOffset(
        previousContentOffset: CGFloat,
        previousAnchorMinY: CGFloat,
        updatedAnchorMinY: CGFloat
    ) -> CGFloat {
        previousContentOffset + updatedAnchorMinY - previousAnchorMinY
    }
}

struct MessagePageCursor {
    private(set) var nextOffset = 0

    mutating func reset(recordCount: Int) {
        nextOffset = recordCount
    }

    mutating func recordFetchedPage(recordCount: Int) {
        nextOffset += recordCount
    }

    mutating func recordInsertedAtNewest() {
        nextOffset += 1
    }
}

#if os(iOS)
@available(iOS 17.0, *)
struct MessageTimelineView: UIViewControllerRepresentable {
    let messages: [Message]
    let isLoadingMore: Bool
    let allMessagesLoaded: Bool
    let onLoadOlder: @MainActor () async -> Void
    let onReply: (Message) -> Void
    let onToggleReaction: (Message, String) -> Void
    let onLongPress: (Message) -> Void

    func makeUIViewController(context: Context) -> MessageTimelineViewController {
        let controller = MessageTimelineViewController()
        controller.onLoadOlder = onLoadOlder
        controller.onReply = onReply
        controller.onToggleReaction = onToggleReaction
        controller.onLongPress = onLongPress
        return controller
    }

    func updateUIViewController(_ controller: MessageTimelineViewController, context: Context) {
        controller.onLoadOlder = onLoadOlder
        controller.onReply = onReply
        controller.onToggleReaction = onToggleReaction
        controller.onLongPress = onLongPress
        controller.update(
            messages: messages,
            isLoadingMore: isLoadingMore,
            allMessagesLoaded: allMessagesLoaded
        )
    }
}

@available(iOS 17.0, *)
final class MessageTimelineViewController: UIViewController, UICollectionViewDataSource, UICollectionViewDelegate {
    var onLoadOlder: (@MainActor () async -> Void)?
    var onReply: ((Message) -> Void)?
    var onToggleReaction: ((Message, String) -> Void)?
    var onLongPress: ((Message) -> Void)?

    private var messages: [Message] = []
    private var isLoadingMore = false
    private var allMessagesLoaded = false
    private var loadTask: Task<Void, Never>?
    private var needsInitialBottomScroll = false
    private var hasCompletedInitialPositioning = false
    private var previousViewportSize = CGSize.zero
    private var shouldFollowBottomAcrossResize = false

    private lazy var collectionView: UICollectionView = {
        let layout = UICollectionViewCompositionalLayout { _, _ in
            let itemSize = NSCollectionLayoutSize(
                widthDimension: .fractionalWidth(1),
                heightDimension: .estimated(80)
            )
            let item = NSCollectionLayoutItem(layoutSize: itemSize)
            let groupSize = NSCollectionLayoutSize(
                widthDimension: .fractionalWidth(1),
                heightDimension: .estimated(80)
            )
            let group = NSCollectionLayoutGroup.vertical(layoutSize: groupSize, subitems: [item])
            let section = NSCollectionLayoutSection(group: group)
            section.interGroupSpacing = 12
            section.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16)
            return section
        }

        let view = UICollectionView(frame: .zero, collectionViewLayout: layout)
        view.translatesAutoresizingMaskIntoConstraints = false
        view.backgroundColor = .clear
        view.alwaysBounceVertical = true
        view.keyboardDismissMode = .interactive
        view.dataSource = self
        view.delegate = self
        view.register(UICollectionViewCell.self, forCellWithReuseIdentifier: "MessageCell")
        return view
    }()

    private let loadingIndicator: UIActivityIndicatorView = {
        let indicator = UIActivityIndicatorView(style: .medium)
        indicator.translatesAutoresizingMaskIntoConstraints = false
        indicator.hidesWhenStopped = true
        return indicator
    }()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        view.addSubview(collectionView)
        view.addSubview(loadingIndicator)
        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            loadingIndicator.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            loadingIndicator.centerXAnchor.constraint(equalTo: view.centerXAnchor)
        ])

        let dismissKeyboard = UITapGestureRecognizer(target: self, action: #selector(didTapTimeline))
        dismissKeyboard.cancelsTouchesInView = false
        collectionView.addGestureRecognizer(dismissKeyboard)

        collectionView.reloadData()
        needsInitialBottomScroll = !messages.isEmpty
        updateLoadingIndicator()
    }

    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        if previousViewportSize != .zero, previousViewportSize != view.bounds.size {
            shouldFollowBottomAcrossResize = isNearBottom
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()

        let viewportChanged = previousViewportSize != .zero && previousViewportSize != view.bounds.size
        previousViewportSize = view.bounds.size

        if needsInitialBottomScroll, !messages.isEmpty, collectionView.bounds.height > 0 {
            needsInitialBottomScroll = false
            hasCompletedInitialPositioning = true
            scrollToBottom(animated: false)
            requestOlderMessagesIfNecessary()
        } else if viewportChanged, shouldFollowBottomAcrossResize {
            shouldFollowBottomAcrossResize = false
            scrollToBottom(animated: false)
        }
    }

    deinit {
        loadTask?.cancel()
    }

    func update(messages newMessages: [Message], isLoadingMore: Bool, allMessagesLoaded: Bool) {
        let oldMessages = messages
        let anchor = visibleAnchor()
        let wasNearBottom = self.isNearBottom
        let oldLastID = oldMessages.last?.id

        messages = deduplicated(newMessages)
        self.isLoadingMore = isLoadingMore || loadTask != nil
        self.allMessagesLoaded = allMessagesLoaded
        updateLoadingIndicator()

        guard isViewLoaded else { return }

        collectionView.reloadData()
        collectionView.collectionViewLayout.invalidateLayout()
        collectionView.layoutIfNeeded()

        if oldMessages.isEmpty, !messages.isEmpty {
            needsInitialBottomScroll = true
            hasCompletedInitialPositioning = false
            view.setNeedsLayout()
        } else if wasNearBottom, oldLastID != messages.last?.id {
            scrollToBottom(animated: false)
        } else if let anchor {
            restore(anchor: anchor)
        }

        requestOlderMessagesIfNecessary()
    }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        messages.count
    }

    func collectionView(
        _ collectionView: UICollectionView,
        cellForItemAt indexPath: IndexPath
    ) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "MessageCell", for: indexPath)
        guard messages.indices.contains(indexPath.item) else { return cell }
        let message = messages[indexPath.item]

        cell.backgroundConfiguration = UIBackgroundConfiguration.clear()
        cell.contentConfiguration = UIHostingConfiguration {
            SwipeToReplyContainer(onReply: { [weak self] in
                guard message.messageHash != nil else { return }
                self?.onReply?(message)
            }) {
                MessageBubble(
                    message: message,
                    onToggleReaction: { [weak self] emoji in
                        self?.onToggleReaction?(message, emoji)
                    },
                    onTapReplyPreview: { [weak self] replyID in
                        self?.scrollToMessage(id: replyID)
                    },
                    onLongPress: { [weak self] in
                        self?.onLongPress?(message)
                    }
                )
            }
        }
        .margins(.all, 0)

        return cell
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        requestOlderMessagesIfNecessary()
    }

    private var isNearBottom: Bool {
        guard collectionView.bounds.height > 0 else { return true }
        let bottomOffset = max(
            -collectionView.adjustedContentInset.top,
            collectionView.contentSize.height
                - collectionView.bounds.height
                + collectionView.adjustedContentInset.bottom
        )
        return bottomOffset - collectionView.contentOffset.y <= 120
    }

    private func requestOlderMessagesIfNecessary() {
        guard isViewLoaded,
              hasCompletedInitialPositioning,
              MessageTimelinePaginationPolicy.shouldLoadOlder(
                contentOffsetY: collectionView.contentOffset.y,
                viewportHeight: collectionView.bounds.height,
                isLoading: isLoadingMore || loadTask != nil,
                allHistoryLoaded: allMessagesLoaded
              ),
              let onLoadOlder else { return }

        isLoadingMore = true
        updateLoadingIndicator()
        loadTask = Task { @MainActor [weak self] in
            await onLoadOlder()
            guard let self, !Task.isCancelled else { return }
            self.loadTask = nil
            self.isLoadingMore = false
            self.updateLoadingIndicator()
            // SwiftUI applies the new message page and exhaustion state on the
            // next main-loop turn. Re-check after that update so telemetry-only
            // pages cannot strand the user inside the preload threshold.
            DispatchQueue.main.async { [weak self] in
                self?.requestOlderMessagesIfNecessary()
            }
        }
    }

    private func updateLoadingIndicator() {
        if isLoadingMore {
            loadingIndicator.startAnimating()
        } else {
            loadingIndicator.stopAnimating()
        }
    }

    private struct VisibleAnchor {
        let messageID: String
        let minY: CGFloat
        let contentOffsetY: CGFloat
    }

    private func visibleAnchor() -> VisibleAnchor? {
        let visible = collectionView.indexPathsForVisibleItems.compactMap { indexPath -> (IndexPath, UICollectionViewLayoutAttributes)? in
            guard let attributes = collectionView.layoutAttributesForItem(at: indexPath) else { return nil }
            return (indexPath, attributes)
        }
        guard let top = visible.min(by: { $0.1.frame.minY < $1.1.frame.minY }),
              messages.indices.contains(top.0.item) else { return nil }
        let message = messages[top.0.item]
        return VisibleAnchor(
            messageID: message.id,
            minY: top.1.frame.minY,
            contentOffsetY: collectionView.contentOffset.y
        )
    }

    private func restore(anchor: VisibleAnchor) {
        guard let index = messages.firstIndex(where: { $0.id == anchor.messageID }) else { return }
        let indexPath = IndexPath(item: index, section: 0)
        guard let attributes = collectionView.layoutAttributesForItem(at: indexPath) else { return }
        let targetY = MessageTimelineViewportAnchor.adjustedContentOffset(
            previousContentOffset: anchor.contentOffsetY,
            previousAnchorMinY: anchor.minY,
            updatedAnchorMinY: attributes.frame.minY
        )
        collectionView.setContentOffset(
            CGPoint(x: collectionView.contentOffset.x, y: clampedContentOffsetY(targetY)),
            animated: false
        )
    }

    private func scrollToBottom(animated: Bool) {
        guard !messages.isEmpty else { return }
        collectionView.layoutIfNeeded()
        collectionView.scrollToItem(
            at: IndexPath(item: messages.count - 1, section: 0),
            at: .bottom,
            animated: animated
        )
    }

    private func scrollToMessage(id: String) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        collectionView.scrollToItem(
            at: IndexPath(item: index, section: 0),
            at: .centeredVertically,
            animated: true
        )
    }

    private func clampedContentOffsetY(_ proposed: CGFloat) -> CGFloat {
        let minimum = -collectionView.adjustedContentInset.top
        let maximum = max(
            minimum,
            collectionView.contentSize.height
                - collectionView.bounds.height
                + collectionView.adjustedContentInset.bottom
        )
        return min(maximum, max(minimum, proposed))
    }

    private func deduplicated(_ input: [Message]) -> [Message] {
        var seen = Set<String>()
        return input.filter { seen.insert($0.id).inserted }
    }

    var renderedMessageCount: Int {
        collectionView.numberOfItems(inSection: 0)
    }

    var visibleMessageCellCount: Int {
        collectionView.indexPathsForVisibleItems.count
    }

    func setViewportForTesting(_ size: CGSize) {
        view.frame = CGRect(origin: .zero, size: size)
        view.setNeedsLayout()
        view.layoutIfNeeded()
    }

    func setContentOffsetForTesting(y: CGFloat) {
        view.setNeedsLayout()
        view.layoutIfNeeded()
        collectionView.setContentOffset(CGPoint(x: 0, y: y), animated: false)
        scrollViewDidScroll(collectionView)
    }

    @objc
    private func didTapTimeline() {
        view.window?.endEditing(true)
    }
}
#endif
