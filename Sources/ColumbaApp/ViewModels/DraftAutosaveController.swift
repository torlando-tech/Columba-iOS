import Foundation
import OSLog

protocol DraftPersistence: Sendable {
    func fetchDraftText(for conversationHash: Data) async throws -> String?
    func saveDraft(_ content: String, for conversationHash: Data) async throws
    func clearDraft(for conversationHash: Data) async throws
}

extension MessageRepository: DraftPersistence {
    func fetchDraftText(for conversationHash: Data) async throws -> String? {
        try await fetchDraft(for: conversationHash)?.content
    }
}

@MainActor
private final class DraftMutationPipeline {
    private enum SaveSource {
        case autosave
        case flush
    }

    private enum Mutation {
        case save(String, SaveSource, CheckedContinuation<Void, Never>?)
        case clear
    }

    private static let logger = Logger(
        subsystem: "network.columba.Columba",
        category: "DraftAutosaveController"
    )

    private let persistence: any DraftPersistence
    private let conversationHash: Data
    private var mutations: [Mutation?] = []
    private var nextMutationIndex = 0
    private var worker: Task<Void, Never>?

    init(persistence: any DraftPersistence, conversationHash: Data) {
        self.persistence = persistence
        self.conversationHash = conversationHash
    }

    func enqueueSave(_ text: String) {
        enqueue(.save(text, .autosave, nil))
    }

    func enqueueClear() {
        enqueue(.clear)
    }

    func enqueueSaveAndWait(_ text: String) async {
        await withCheckedContinuation { continuation in
            enqueue(.save(text, .flush, continuation))
        }
    }

    private func enqueue(_ mutation: Mutation) {
        mutations.append(mutation)
        guard worker == nil else { return }

        // The worker retains this pipeline, but not its owning controller, until
        // every already-enqueued durable intent has completed.
        worker = Task {
            await drain()
        }
    }

    private func drain() async {
        while nextMutationIndex < mutations.count {
            guard let mutation = mutations[nextMutationIndex] else {
                nextMutationIndex += 1
                continue
            }
            mutations[nextMutationIndex] = nil
            nextMutationIndex += 1

            switch mutation {
            case let .save(text, source, completion):
                do {
                    try await persistence.saveDraft(text, for: conversationHash)
                } catch {
                    switch source {
                    case .autosave:
                        Self.logger.error("Draft autosave repository mutation failed")
                    case .flush:
                        Self.logger.error("Draft flush repository mutation failed")
                    }
                }
                completion?.resume()
            case .clear:
                do {
                    try await persistence.clearDraft(for: conversationHash)
                } catch {
                    Self.logger.error("Draft clear repository mutation failed")
                }
            }
        }

        mutations.removeAll(keepingCapacity: true)
        nextMutationIndex = 0
        worker = nil
    }
}

@MainActor
final class DraftAutosaveController {
    typealias Sleeper = @Sendable (Duration) async throws -> Void

    private static let logger = Logger(
        subsystem: "network.columba.Columba",
        category: "DraftAutosaveController"
    )

    private let persistence: any DraftPersistence
    private let mutationPipeline: DraftMutationPipeline
    private let conversationHash: Data
    private let debounceDuration: Duration
    private let sleeper: Sleeper

    private var latestText = ""
    private var generation: UInt64 = 0
    private var pendingTask: Task<Void, Never>?

    init(
        repository: MessageRepository,
        conversationHash: Data,
        debounceDuration: Duration = .milliseconds(500),
        sleeper: @escaping Sleeper = { duration in
            try await Task.sleep(for: duration)
        }
    ) {
        self.persistence = repository
        self.conversationHash = conversationHash
        self.mutationPipeline = DraftMutationPipeline(
            persistence: repository,
            conversationHash: conversationHash
        )
        self.debounceDuration = debounceDuration
        self.sleeper = sleeper
    }

    init(
        persistence: any DraftPersistence,
        conversationHash: Data,
        debounceDuration: Duration,
        sleeper: @escaping Sleeper
    ) {
        self.persistence = persistence
        self.conversationHash = conversationHash
        self.mutationPipeline = DraftMutationPipeline(
            persistence: persistence,
            conversationHash: conversationHash
        )
        self.debounceDuration = debounceDuration
        self.sleeper = sleeper
    }

    func restore() async throws -> String? {
        try await persistence.fetchDraftText(for: conversationHash)
    }

    func textChanged(_ text: String) {
        latestText = text
        generation += 1
        let scheduledGeneration = generation

        pendingTask?.cancel()
        let sleeper = sleeper
        let debounceDuration = debounceDuration
        pendingTask = Task { [weak self] in
            do {
                try await sleeper(debounceDuration)
                try Task.checkCancellation()
            } catch is CancellationError {
                return
            } catch {
                Self.logger.error("Draft debounce failed")
                return
            }

            guard let self else { return }
            guard generation == scheduledGeneration else { return }
            pendingTask = nil
            mutationPipeline.enqueueSave(latestText)
        }
    }

    func flush(_ text: String) async {
        latestText = text
        generation += 1
        pendingTask?.cancel()
        pendingTask = nil

        await mutationPipeline.enqueueSaveAndWait(text)
    }

    func clearImmediately() {
        latestText = ""
        generation += 1
        pendingTask?.cancel()
        pendingTask = nil
        mutationPipeline.enqueueClear()
    }

    func cancel() {
        pendingTask?.cancel()
        pendingTask = nil
    }

    deinit {
        pendingTask?.cancel()
    }
}
