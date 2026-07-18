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
    private var pendingDeleteUserThemes = false

    public init(engine: any EngineRunning) {
        self.engine = engine
    }

    public var isVerified: Bool {
        envelope?.state.verified == true
    }

    public var primaryOperation: EngineOperation? {
        guard let state = envelope?.state else { return nil }
        if state.install == .notInstalled { return canRequest(.install) ? .install : nil }
        if state.session == .paused { return canRequest(.resume) ? .resume : nil }
        return canRequest(.apply) ? .apply : nil
    }

    public var pauseResumeOperation: EngineOperation? {
        guard let state = envelope?.state else { return nil }
        let operation: EngineOperation = state.session == .paused ? .resume : .pause
        return canRequest(operation) ? operation : nil
    }

    public func canRequest(_ operation: EngineOperation) -> Bool {
        guard !isBusy, presentation == nil, let envelope else { return false }
        if operation == .restore, envelope.error?.recoveryActions.contains(.restore) == true {
            return true
        }
        guard let action = operation.stateAction else { return false }
        return envelope.state.availableActions.contains(action)
    }

    public func launch() async {
        guard !hasLaunched else { return }
        hasLaunched = true
        await refresh(.preflight)
    }

    public func request(_ operation: EngineOperation) async {
        guard canRequest(operation) else { return }
        switch operation {
        case .restore:
            presentation = .restoreConfirmation
        case .uninstall:
            pendingDeleteUserThemes = false
            presentation = .uninstallConfirmation
        default:
            await perform(operation)
        }
    }

    public func cancelPresentation() {
        presentation = nil
        pendingDeleteUserThemes = false
    }

    public func confirmPresentation(deleteUserThemes: Bool = false) async {
        guard !isBusy, let presentation else { return }
        self.presentation = nil

        switch presentation {
        case let .restartConfirmation(operation):
            await perform(operation, restartAuthorized: true, deleteUserThemes: deletionIntent(for: operation))
        case let .forceStopConfirmation(operation):
            await perform(
                operation,
                restartAuthorized: true,
                forceAuthorized: true,
                deleteUserThemes: deletionIntent(for: operation)
            )
        case .restoreConfirmation:
            await perform(.restore)
        case .uninstallConfirmation:
            pendingDeleteUserThemes = deleteUserThemes
            await perform(.uninstall, deleteUserThemes: deleteUserThemes)
        }
    }

    public func refresh(_ operation: EngineOperation = .preflight) async {
        guard beginOperation() else { return }
        defer { endOperation() }

        do {
            envelope = try await invoke(operation)
        } catch {
            if operation == .uninstall { pendingDeleteUserThemes = false }
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
            presentRecovery(for: mutation, operation: operation, deleteUserThemes: deleteUserThemes)
            return
        }
        if operation == .uninstall { pendingDeleteUserThemes = false }
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

    private func deletionIntent(for operation: EngineOperation) -> Bool {
        operation == .uninstall && pendingDeleteUserThemes
    }

    private func presentRecovery(
        for envelope: EngineEnvelope,
        operation: EngineOperation,
        deleteUserThemes: Bool
    ) {
        switch envelope.error?.code {
        case .restartRequired, .codexCloseRequired:
            pendingDeleteUserThemes = operation == .uninstall && deleteUserThemes
            presentation = .restartConfirmation(operation)
        case .forceStopRequired:
            pendingDeleteUserThemes = operation == .uninstall && deleteUserThemes
            presentation = .forceStopConfirmation(operation)
        default:
            pendingDeleteUserThemes = false
            break
        }
    }
}

private extension EngineOperation {
    var stateAction: EngineState.Action? {
        switch self {
        case .install: .install
        case .apply: .apply
        case .pause: .pause
        case .resume: .resume
        case .restore: .restore
        case .verify: .verify
        case .uninstall: .uninstall
        case .preflight, .status: nil
        }
    }
}

private extension EngineClientError {
    var isInterruption: Bool {
        self == .cancelled || self == .timedOut
    }
}
