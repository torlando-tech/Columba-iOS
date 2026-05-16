//
//  AutoAnnounceManager.swift
//  ColumbaApp
//
//  Manages periodic LXMF announces based on user settings.
//  Ports Android's AutoAnnounceManager behavior to iOS.
//

import Foundation
import RNSAPI
import os.log

/// Manages automatic periodic announces based on user settings.
///
/// Observes the auto-announce settings (enabled state and interval)
/// and triggers announces at the configured interval when enabled.
/// The interval is randomized by +/- 1 hour to prevent network congestion.
@available(iOS 17.0, macOS 14.0, *)
@MainActor
public final class AutoAnnounceManager {
    // MARK: - Constants

    /// Randomization range in minutes (±1 hour).
    private static let randomizationRangeMinutes = 60

    /// Minimum interval in minutes (1 hour).
    private static let minIntervalMinutes = 60

    /// Maximum interval in minutes (12 hours).
    private static let maxIntervalMinutes = 720

    // MARK: - Properties

    private weak var appServices: AppServices?
    private var announceTask: Task<Void, Never>?
    private let logger = Logger(subsystem: "network.columba.Columba", category: "AutoAnnounceManager")

    // MARK: - Initialization

    public init(appServices: AppServices) {
        self.appServices = appServices
    }

    // MARK: - Public Methods

    /// Start the periodic announce loop.
    ///
    /// Reads settings from UserDefaults and begins the announce cycle.
    /// If already running, restarts with current settings.
    public func start() {
        stop()

        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: "auto_announce_enabled") else {
            logger.info("Auto-announce disabled, not starting")
            return
        }

        let intervalHours = defaults.integer(forKey: "announce_interval_hours")
        let effectiveInterval = intervalHours > 0 ? intervalHours : 3

        logger.info("Starting auto-announce loop: \(effectiveInterval)h interval")

        announceTask = Task { [weak self] in
            await self?.announceLoop(intervalHours: effectiveInterval)
        }
    }

    /// Stop the periodic announce loop.
    public func stop() {
        announceTask?.cancel()
        announceTask = nil
        logger.info("Auto-announce stopped")
    }

    /// Reset the timer (e.g., after a network topology change triggers an immediate announce).
    ///
    /// Restarts the loop so the next periodic announce is a full interval away.
    public func resetTimer() {
        logger.info("Timer reset requested")
        start()
    }

    // MARK: - Private Methods

    /// Main announce loop that runs until cancelled.
    private func announceLoop(intervalHours: Int) async {
        let baseIntervalMinutes = intervalHours * 60

        while !Task.isCancelled {
            // Calculate randomized delay: base ± 1 hour, with minute precision
            let randomOffset = Int.random(
                in: -Self.randomizationRangeMinutes...Self.randomizationRangeMinutes
            )
            let actualMinutes = min(
                max(baseIntervalMinutes + randomOffset, Self.minIntervalMinutes),
                Self.maxIntervalMinutes
            )
            let delaySeconds = UInt64(actualMinutes) * 60

            let hours = actualMinutes / 60
            let mins = actualMinutes % 60
            logger.info("Next auto-announce in \(hours)h \(mins)m (base: \(intervalHours)h, offset: \(randomOffset)m)")

            // Sleep for the interval
            do {
                try await Task.sleep(for: .seconds(delaySeconds))
            } catch {
                // Task was cancelled
                return
            }

            // Re-check settings in case they changed during sleep
            let defaults = UserDefaults.standard
            guard defaults.bool(forKey: "auto_announce_enabled") else {
                logger.info("Auto-announce disabled during sleep, stopping")
                return
            }

            // Perform the announce
            guard let services = appServices else { return }

            let displayName = await SettingsRepository().getDisplayName()
            do {
                try await services.sendAllAnnounces(displayName: displayName)
                logger.info("Auto-announce sent successfully")

                // Record the announce time
                let now = Date()
                defaults.set(now.timeIntervalSince1970, forKey: "last_announce_time")
            } catch {
                logger.warning("Auto-announce failed: \(error.localizedDescription)")
            }
        }
    }
}
