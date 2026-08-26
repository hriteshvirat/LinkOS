import Foundation

/// ConnectionWatchdog monitors the health of the WebSocket server and Bonjour service,
/// applying targeted restarts when failures are detected.
///
/// Uses a cooldown safeguard: after `maxFailures` consecutive failures within `failureTimeWindow`
/// seconds, the watchdog backs off for `cooldownPeriod` seconds to prevent restart loops.
///
/// This class is `@MainActor` because `WebSocketServer` and `BonjourService` are both
/// `@MainActor`-isolated, so all health checks and restarts run safely on the main actor.
@MainActor
final class ConnectionWatchdog {

    // MARK: - Configuration

    private let checkInterval: TimeInterval = 5.0
    private let maxFailures = 3
    private let failureTimeWindow: TimeInterval = 60   // 1 minute
    private let cooldownPeriod: TimeInterval   = 300   // 5 minutes

    // MARK: - Injected Dependencies

    private weak var webSocketServer: WebSocketServer?
    private weak var bonjourService: BonjourService?

    // MARK: - State

    private struct FailureRecord {
        var count: Int
        var firstFailureAt: Date
        var cooldownUntil: Date?
    }

    private var failureHistory: [String: FailureRecord] = [:]
    private var checkTask: Task<Void, Never>?

    // MARK: - Init

    init(webSocketServer: WebSocketServer, bonjourService: BonjourService) {
        self.webSocketServer = webSocketServer
        self.bonjourService  = bonjourService
    }

    // MARK: - Lifecycle

    func startMonitoring() {
        stopMonitoring() // Cancel any previous task first
        checkTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.performChecks()
                try? await Task.sleep(nanoseconds: UInt64((self?.checkInterval ?? 5.0) * 1_000_000_000))
            }
        }
        LinkOSLogger.shared.info("ConnectionWatchdog started (interval: \(checkInterval)s)", category: .network)
    }

    func stopMonitoring() {
        checkTask?.cancel()
        checkTask = nil
        failureHistory.removeAll()
        LinkOSLogger.shared.info("ConnectionWatchdog stopped", category: .network)
    }

    // MARK: - Checks

    private func performChecks() {
        if PhoneSessionManager.shared.activeSession.isStreaming {
            return // Do not restart network components if we have an active stream
        }

        checkComponent(name: "WebSocketServer", isHealthy: webSocketServer?.isListening() ?? false) {
            Task { @MainActor [weak self] in
                guard let self, let server = self.webSocketServer else { return }
                await server.stop()
                try? await Task.sleep(nanoseconds: 500_000_000)
                try? await server.start()
            }
        }

        checkComponent(name: "BonjourService", isHealthy: bonjourService?.isPublished() ?? false) {
            Task { @MainActor [weak self] in
                guard let self, let bonjour = self.bonjourService else { return }
                bonjour.stopAdvertising()
                try? await Task.sleep(nanoseconds: 500_000_000)
                await bonjour.startAdvertising()
            }
        }
    }

    private func checkComponent(name: String, isHealthy: Bool, restart: @escaping () -> Void) {
        let now = Date()

        if isHealthy {
            // Success — clear failure record (but not if still in cooldown)
            if let record = failureHistory[name], record.cooldownUntil == nil {
                failureHistory.removeValue(forKey: name)
            }
            return
        }

        // Check cooldown
        if let cooldownUntil = failureHistory[name]?.cooldownUntil {
            if now < cooldownUntil {
                return // Still backing off — do not attempt restart
            } else {
                // Cooldown expired — clear history and try again fresh
                failureHistory.removeValue(forKey: name)
            }
        }

        var record = failureHistory[name] ?? FailureRecord(count: 0, firstFailureAt: now, cooldownUntil: nil)

        // Reset window if the first failure was too long ago
        if now.timeIntervalSince(record.firstFailureAt) > failureTimeWindow {
            record = FailureRecord(count: 1, firstFailureAt: now, cooldownUntil: nil)
        } else {
            record.count += 1
        }

        if record.count >= maxFailures {
            // Too many failures — enter cooldown
            let cooldownEnd = now.addingTimeInterval(cooldownPeriod)
            record.cooldownUntil = cooldownEnd
            failureHistory[name] = record
            LinkOSLogger.shared.error(
                "Watchdog: \(name) failed \(record.count) times in \(Int(failureTimeWindow))s. " +
                "Entering \(Int(cooldownPeriod))s cooldown until \(cooldownEnd).",
                category: .network
            )
        } else {
            failureHistory[name] = record
            LinkOSLogger.shared.warning(
                "Watchdog: \(name) appears unhealthy (attempt \(record.count)/\(maxFailures)). Restarting...",
                category: .network
            )
            restart()
        }
    }
}
