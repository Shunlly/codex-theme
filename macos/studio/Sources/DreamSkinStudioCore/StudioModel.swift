import Combine
import Foundation

public enum StudioPresentation: Equatable, Sendable {
    case restartConfirmation(EngineOperation)
    case forceStopConfirmation(EngineOperation)
    case restoreConfirmation
    case uninstallConfirmation
}

@MainActor
public final class StudioModel: ObservableObject {
    @Published public private(set) var envelope: EngineEnvelope?
    @Published public private(set) var progress: EngineProgress?
    @Published public private(set) var isBusy = false
    @Published public private(set) var clientError: EngineClientError?
    @Published public private(set) var presentation: StudioPresentation?

    private let engine: any EngineRunning
    private var nextGeneration: UInt64 = 0
    private var activeGeneration: UInt64?
    private var hasLaunched = false

    public init(engine: any EngineRunning) {
        self.engine = engine
    }

    public var isVerified: Bool {
        envelope?.state.verified == true
    }

    public func launch() async {
        guard !hasLaunched else { return }
        hasLaunched = true
        await refresh(.preflight)
    }

    public func request(_ operation: EngineOperation) async {
        guard !isBusy, presentation == nil else { return }
        switch operation {
        case .restore:
            presentation = .restoreConfirmation
        case .uninstall:
            presentation = .uninstallConfirmation
        default:
            await perform(operation)
        }
    }

    public func cancelPresentation() {
        presentation = nil
    }

    public func confirmPresentation(deleteUserThemes: Bool = false) async {
        guard !isBusy, let presentation else { return }
        self.presentation = nil

        switch presentation {
        case let .restartConfirmation(operation):
            await perform(operation, restartAuthorized: true)
        case let .forceStopConfirmation(operation):
            await perform(operation, restartAuthorized: true, forceAuthorized: true)
        case .restoreConfirmation:
            await perform(.restore)
        case .uninstallConfirmation:
            await perform(.uninstall, deleteUserThemes: deleteUserThemes)
        }
    }

    public func refresh(_ operation: EngineOperation = .preflight) async {
        guard beginOperation() else { return }
        defer { endOperation() }

        do {
            envelope = try await invoke(operation)
        } catch {
            let clientError = normalized(error)
            self.clientError = clientError
            if clientError.isInterruption {
                await reconcileStatus(preserving: clientError)
            }
        }
    }

    public func perform(
        _ operation: EngineOperation,
        restartAuthorized: Bool = false,
        forceAuthorized: Bool = false,
        deleteUserThemes: Bool = false
    ) async {
        guard beginOperation() else { return }
        defer { endOperation() }

        let mutation: EngineEnvelope
        do {
            mutation = try await invoke(
                operation,
                restartAuthorized: restartAuthorized,
                forceAuthorized: forceAuthorized,
                deleteUserThemes: deleteUserThemes
            )
            envelope = mutation
        } catch {
            let clientError = normalized(error)
            self.clientError = clientError
            if clientError.isInterruption {
                await reconcileStatus(preserving: clientError)
            }
            return
        }

        guard mutation.ok else {
            presentRecovery(for: mutation, operation: operation)
            return
        }
        guard operation != .preflight, operation != .status else { return }
        do {
            envelope = try await invoke(.status)
        } catch {
            let clientError = normalized(error)
            self.clientError = clientError
            if clientError.isInterruption {
                await reconcileStatus(preserving: clientError)
            }
        }
    }

    private func beginOperation() -> Bool {
        guard !isBusy else { return false }
        isBusy = true
        progress = nil
        clientError = nil
        return true
    }

    private func endOperation() {
        activeGeneration = nil
        progress = nil
        isBusy = false
    }

    private func invoke(
        _ operation: EngineOperation,
        restartAuthorized: Bool = false,
        forceAuthorized: Bool = false,
        deleteUserThemes: Bool = false
    ) async throws -> EngineEnvelope {
        let generation = activateGeneration()
        let envelope = try await engine.run(
            operation,
            restartAuthorized: restartAuthorized,
            forceAuthorized: forceAuthorized,
            deleteUserThemes: deleteUserThemes,
            onProgress: progressHandler(for: generation)
        )
        guard !Task.isCancelled else { throw EngineClientError.cancelled }
        return envelope
    }

    private func reconcileStatus(preserving originalError: EngineClientError) async {
        let generation = activateGeneration()
        let engine = self.engine
        let progressHandler = progressHandler(for: generation)
        let reconciliation = Task.detached {
            try await engine.run(
                .status,
                restartAuthorized: false,
                forceAuthorized: false,
                deleteUserThemes: false,
                onProgress: progressHandler
            )
        }

        if let reconciled = try? await reconciliation.value {
            envelope = reconciled
        }
        clientError = originalError
    }

    private func activateGeneration() -> UInt64 {
        nextGeneration &+= 1
        activeGeneration = nextGeneration
        progress = nil
        return nextGeneration
    }

    private func progressHandler(for generation: UInt64) -> @Sendable (EngineProgress) -> Void {
        { [weak self] progress in
            Task { @MainActor [weak self] in
                guard self?.activeGeneration == generation, self?.isBusy == true else { return }
                self?.progress = progress
            }
        }
    }

    private func normalized(_ error: any Error) -> EngineClientError {
        if Task.isCancelled { return .cancelled }
        if error is CancellationError { return .cancelled }
        return error as? EngineClientError ?? .transportFailed
    }

    private func presentRecovery(for envelope: EngineEnvelope, operation: EngineOperation) {
        switch envelope.error?.code {
        case .restartRequired, .codexCloseRequired:
            presentation = .restartConfirmation(operation)
        case .forceStopRequired:
            presentation = .forceStopConfirmation(operation)
        default:
            break
        }
    }
}

private extension EngineClientError {
    var isInterruption: Bool {
        self == .cancelled || self == .timedOut
    }
}
