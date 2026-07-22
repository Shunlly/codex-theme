import Combine
import Foundation

public enum StudioPresentation: Equatable, Sendable {
    case restartConfirmation(EngineOperation, deleteUserThemes: Bool)
    case forceStopConfirmation(EngineOperation, deleteUserThemes: Bool)
    case restoreConfirmation
    case uninstallConfirmation
}

public struct StudioMenuState: Equatable, Sendable {
    public let primaryOperation: EngineOperation?
    public let primaryEnabled: Bool
    public let pauseResumeOperation: EngineOperation?
    public let pauseResumeEnabled: Bool
    public let restoreEnabled: Bool
    public let statusEnabled: Bool
    public let allowsTermination: Bool
    private let enabledOperations: [EngineOperation]

    public init(envelope: EngineEnvelope?, isBusy: Bool, presentation: StudioPresentation?) {
        let state = envelope?.state
        let primaryOperation: EngineOperation?
        if state?.install == .notInstalled {
            primaryOperation = .install
        } else if state?.session == .paused {
            primaryOperation = .resume
        } else if state != nil {
            primaryOperation = .apply
        } else {
            primaryOperation = nil
        }
        let pauseResumeOperation: EngineOperation? = state.map { $0.session == .paused ? .resume : .pause }

        let enabledOperations = EngineOperation.allCases.filter {
            Self.isEnabled($0, envelope: envelope, isBusy: isBusy, presentation: presentation)
        }
        self.enabledOperations = enabledOperations
        self.primaryOperation = primaryOperation
        self.pauseResumeOperation = pauseResumeOperation
        if let primaryOperation {
            primaryEnabled = enabledOperations.contains(primaryOperation)
        } else {
            primaryEnabled = false
        }
        if let pauseResumeOperation {
            pauseResumeEnabled = enabledOperations.contains(pauseResumeOperation)
        } else {
            pauseResumeEnabled = false
        }
        restoreEnabled = enabledOperations.contains(.restore)
        statusEnabled = !isBusy && presentation == nil
        allowsTermination = !isBusy
    }

    public func isEnabled(_ operation: EngineOperation) -> Bool {
        enabledOperations.contains(operation)
    }

    private static func isEnabled(
        _ operation: EngineOperation?,
        envelope: EngineEnvelope?,
        isBusy: Bool,
        presentation: StudioPresentation?
    ) -> Bool {
        guard let operation, !isBusy, presentation == nil, let envelope else { return false }
        guard let action = operation.stateAction else { return false }
        return envelope.state.availableActions.contains(action)
    }
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

    public var primaryOperation: EngineOperation? {
        menuState.primaryOperation
    }

    public var pauseResumeOperation: EngineOperation? {
        menuState.pauseResumeOperation
    }

    public func canRequest(_ operation: EngineOperation) -> Bool {
        menuState.isEnabled(operation)
    }

    public var menuState: StudioMenuState {
        StudioMenuState(envelope: envelope, isBusy: isBusy, presentation: presentation)
    }

    public func launch() async {
        guard !hasLaunched else { return }
        hasLaunched = true
        await refresh(.preflight)
        guard envelope?.ok == true, envelope?.state.session == .official else { return }
        if canRequest(.install), !canRequest(.restore) {
            await perform(.install)
        } else if canRequest(.apply) {
            await perform(.apply)
        }
    }

    public func request(_ operation: EngineOperation) async {
        guard canRequest(operation) else { return }
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
        case let .restartConfirmation(operation, deleteUserThemes):
            await perform(operation, restartAuthorized: true, deleteUserThemes: deleteUserThemes)
        case let .forceStopConfirmation(operation, deleteUserThemes):
            await perform(
                operation,
                restartAuthorized: true,
                forceAuthorized: true,
                deleteUserThemes: deleteUserThemes
            )
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
        let preInstallSession = envelope?.state.session
        guard beginOperation() else { return }
        let succeeded = await performActive(
            operation,
            restartAuthorized: restartAuthorized,
            forceAuthorized: forceAuthorized,
            deleteUserThemes: deleteUserThemes
        )
        endOperation()
        if succeeded, operation == .install, preInstallSession == .official, canRequest(.apply) {
            await perform(.apply)
        }
    }

    private func performActive(
        _ operation: EngineOperation,
        restartAuthorized: Bool,
        forceAuthorized: Bool,
        deleteUserThemes: Bool
    ) async -> Bool {
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
            return false
        }

        guard mutation.ok else {
            presentRecovery(for: mutation, operation: operation, deleteUserThemes: deleteUserThemes)
            return false
        }
        guard operation != .preflight, operation != .status else { return true }
        do {
            let status = try await invoke(.status)
            envelope = status
            return status.ok
        } catch {
            let clientError = normalized(error)
            self.clientError = clientError
            if clientError.isInterruption {
                await reconcileStatus(preserving: clientError)
            }
            return false
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

    private func presentRecovery(
        for envelope: EngineEnvelope,
        operation: EngineOperation,
        deleteUserThemes: Bool
    ) {
        switch envelope.error?.code {
        case .restartRequired, .codexCloseRequired:
            presentation = .restartConfirmation(operation, deleteUserThemes: operation == .uninstall && deleteUserThemes)
        case .forceStopRequired:
            presentation = .forceStopConfirmation(operation, deleteUserThemes: operation == .uninstall && deleteUserThemes)
        default:
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
