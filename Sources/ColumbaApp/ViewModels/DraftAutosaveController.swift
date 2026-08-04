import Foundation
import OSLog

@MainActor
final class DraftAutosaveController {
    typealias Sleeper = @Sendable (Duration) async throws -> Void

    private static let logger = Logger(
        subsystem: "network.columba.Columba",
        category: "DraftAutosaveController"
    )

    private let repository: MessageRepository
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
        self.repository = repository
        self.conversationHash = conversationHash
        self.debounceDuration = debounceDuration
        self.sleeper = sleeper
    }

    func restore() async throws -> String? {
        try await repository.fetchDraft(for: conversationHash)?.content
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

            do {
                try await repository.saveDraft(latestText, for: conversationHash)
            } catch {
                Self.logger.error("Draft autosave repository mutation failed")
            }
        }
    }

    func flush(_ text: String) async {
        latestText = text
        generation += 1
        pendingTask?.cancel()
        pendingTask = nil

        do {
            try await repository.saveDraft(text, for: conversationHash)
        } catch {
            Self.logger.error("Draft flush repository mutation failed")
        }
    }

    func clearImmediately() {
        latestText = ""
        generation += 1
        pendingTask?.cancel()
        pendingTask = nil

        let repository = repository
        let conversationHash = conversationHash
        Task {
            do {
                try await repository.clearDraft(for: conversationHash)
            } catch {
                Self.logger.error("Draft clear repository mutation failed")
            }
        }
    }

    func cancel() {
        pendingTask?.cancel()
        pendingTask = nil
    }

    deinit {
        pendingTask?.cancel()
    }
}
