import Combine
import Foundation

@MainActor
public final class StudioModel: ObservableObject {
    @Published public private(set) var envelope: EngineEnvelope?
    @Published public private(set) var progress: EngineProgress?
    @Published public private(set) var isBusy = false
    @Published public private(set) var clientError: EngineClientError?

    private let engine: any EngineRunning
    private var nextGeneration: UInt64 = 0
    private var activeGeneration: UInt64?

    public init(engine: any EngineRunning) {
        self.engine = engine
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

        guard mutation.ok, operation != .preflight, operation != .status else { return }
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
}

private extension EngineClientError {
    var isInterruption: Bool {
        self == .cancelled || self == .timedOut
    }
}
