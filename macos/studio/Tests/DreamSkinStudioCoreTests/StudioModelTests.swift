import Foundation
#if canImport(XCTest)
import XCTest
#else
import Testing
#endif
@testable import DreamSkinStudioCore

private struct ForeignTransportError: Error, Sendable {}

private actor ScriptedEngine: EngineRunning {
    struct Call: Equatable, Sendable {
        let operation: EngineOperation
        let restartAuthorized: Bool
        let forceAuthorized: Bool
        let deleteUserThemes: Bool
    }

    enum Reply: Sendable {
        case envelope(EngineEnvelope, progress: [EngineProgress] = [])
        case failure(EngineClientError)
        case foreignFailure
        case suspendedRequiresUncancelled(EngineEnvelope)
        case suspended(EngineEnvelope, progress: [EngineProgress] = [])
    }

    private var replies: [Reply]
    private var calls: [Call] = []
    private var callbacks: [@Sendable (EngineProgress) -> Void] = []
    private var continuations: [CheckedContinuation<Void, Never>] = []

    init(_ replies: [Reply]) {
        self.replies = replies
    }

    func run(
        _ operation: EngineOperation,
        restartAuthorized: Bool,
        forceAuthorized: Bool,
        deleteUserThemes: Bool,
        onProgress: @escaping @Sendable (EngineProgress) -> Void
    ) async throws -> EngineEnvelope {
        calls.append(Call(
            operation: operation,
            restartAuthorized: restartAuthorized,
            forceAuthorized: forceAuthorized,
            deleteUserThemes: deleteUserThemes
        ))
        callbacks.append(onProgress)
        guard !replies.isEmpty else { throw EngineClientError.transportFailed }
        let reply = replies.removeFirst()

        switch reply {
        case let .envelope(envelope, progress):
            progress.forEach(onProgress)
            return envelope
        case let .failure(error):
            throw error
        case .foreignFailure:
            throw ForeignTransportError()
        case let .suspendedRequiresUncancelled(envelope):
            guard !Task.isCancelled else { throw EngineClientError.transportFailed }
            await withCheckedContinuation { continuations.append($0) }
            return envelope
        case let .suspended(envelope, progress):
            progress.forEach(onProgress)
            await withCheckedContinuation { continuations.append($0) }
            return envelope
        }
    }

    func recordedCalls() -> [Call] {
        calls
    }

    func resumeNext() {
        guard !continuations.isEmpty else { return }
        continuations.removeFirst().resume()
    }

    func emitProgress(forCall index: Int, _ progress: EngineProgress) {
        callbacks[index](progress)
    }
}

#if !canImport(XCTest)
@Suite("StudioModelTests", .serialized)
#endif
final class StudioModelTests: CoreTestCase {
    private let fileManager = FileManager.default

#if !canImport(XCTest)
    @Test
#endif
    @MainActor
    func testDefaultRefreshRunsPreflightAndPublishesEnvelope() async {
        let preflight = makeEnvelope(operation: .preflight)
        let engine = ScriptedEngine([.envelope(preflight, progress: [.checking])])
        let model = StudioModel(engine: engine)

        await model.refresh()

        let calls = await engine.recordedCalls()
        XCTAssertEqual(calls, [call(.preflight)])
        XCTAssertEqual(model.envelope, preflight)
        XCTAssertNil(model.progress)
        XCTAssertNil(model.clientError)
        XCTAssertFalse(model.isBusy)
    }

#if !canImport(XCTest)
    @Test
#endif
    @MainActor
    func testRejectsBusyReentryAndKeepsMutationStatusInOneBusyLifecycle() async throws {
        let mutation = makeEnvelope(operation: .apply)
        let status = makeEnvelope(operation: .status, session: "active")
        let engine = ScriptedEngine([
            .suspended(mutation),
            .suspended(status),
        ])
        let model = StudioModel(engine: engine)
        let operation = Task {
            await model.perform(
                .apply,
                restartAuthorized: true,
                forceAuthorized: true,
                deleteUserThemes: false
            )
        }

        try await waitUntil { await engine.recordedCalls().count == 1 }
        XCTAssertTrue(model.isBusy)
        XCTAssertFalse(model.menuState.allowsTermination)
        await model.refresh(.status)
        let callsDuringMutation = await engine.recordedCalls()
        XCTAssertEqual(callsDuringMutation.count, 1)

        await engine.resumeNext()
        try await waitUntil { await engine.recordedCalls().count == 2 }
        XCTAssertTrue(model.isBusy)
        XCTAssertFalse(model.menuState.allowsTermination)
        let callsDuringStatus = await engine.recordedCalls()
        XCTAssertEqual(callsDuringStatus, [
            call(.apply, restart: true, force: true),
            call(.status),
        ])

        await engine.resumeNext()
        await operation.value
        XCTAssertFalse(model.isBusy)
        XCTAssertTrue(model.menuState.allowsTermination)
        XCTAssertEqual(model.envelope, status)
    }

#if !canImport(XCTest)
    @Test
#endif
    @MainActor
    func testDomainErrorRemainsVisibleWithoutAutomaticStatus() async {
        let domainError = makeEnvelope(
            operation: .apply,
            ok: false,
            session: "official",
            errorCode: "RESTART_REQUIRED",
            recoveryActions: ["authorize-restart", "cancel"]
        )
        let engine = ScriptedEngine([.envelope(domainError)])
        let model = StudioModel(engine: engine)

        await model.perform(.apply)

        let calls = await engine.recordedCalls()
        XCTAssertEqual(calls, [call(.apply)])
        XCTAssertEqual(model.envelope, domainError)
        XCTAssertEqual(model.envelope?.error?.code, .restartRequired)
        XCTAssertNil(model.clientError)
    }

#if !canImport(XCTest)
    @Test
#endif
    @MainActor
    func testSuccessfulMutationPreservesItsEnvelopeWhenStatusTransportFails() async {
        let mutation = makeEnvelope(operation: .pause, session: "paused", verified: false)
        let engine = ScriptedEngine([
            .envelope(mutation),
            .failure(.launchFailed),
        ])
        let model = StudioModel(engine: engine)

        await model.perform(.pause, restartAuthorized: true, forceAuthorized: true)

        let calls = await engine.recordedCalls()
        XCTAssertEqual(calls, [
            call(.pause, restart: true, force: true),
            call(.status),
        ])
        XCTAssertEqual(model.envelope, mutation)
        XCTAssertEqual(model.clientError, .launchFailed)
        XCTAssertFalse(model.isBusy)
    }

#if !canImport(XCTest)
    @Test
#endif
    @MainActor
    func testTransportErrorIsSafeAndKeepsStaleState() async {
        let staleEnvelope = makeEnvelope(operation: .status, session: "active")
        let engine = ScriptedEngine([
            .envelope(staleEnvelope),
            .foreignFailure,
        ])
        let model = StudioModel(engine: engine)
        await model.refresh(.status)

        await model.perform(.verify)

        XCTAssertEqual(model.envelope, staleEnvelope)
        XCTAssertEqual(model.clientError, .transportFailed)
        XCTAssertFalse(model.isBusy)
        XCTAssertNil(model.progress)
    }

#if !canImport(XCTest)
    @Test
#endif
    @MainActor
    func testCancellationReconcilesStatusInIndependentTaskAndKeepsCancellationVisible() async throws {
        let fixture = try makeTemporaryDirectory()
        let started = fixture.appendingPathComponent("started")
        let calls = fixture.appendingPathComponent("calls")
        let stale = try modelJSON(makeEnvelope(
            operation: .status,
            ok: false,
            session: "stale",
            errorCode: "STATE_UNSAFE",
            recoveryActions: ["restore", "diagnostics", "cancel"]
        ))
        let script = try makeExecutable(in: fixture, body: """
        /usr/bin/printf '%s\\n' "$@" >> '\(calls.path)'
        if [ "$1" = "status" ]; then
          /usr/bin/printf '%s\\n' '\(stale)'
          exit 1
        fi
        /usr/bin/touch '\(started.path)'
        trap '' TERM
        while :; do /bin/sleep 1; done
        """)
        let model = StudioModel(engine: EngineClient(adapterURL: script, timeout: 10, terminationGrace: 0.02))
        let operation = Task { await model.perform(.apply) }

        try await waitUntil { self.fileManager.fileExists(atPath: started.path) }
        operation.cancel()
        await operation.value

        XCTAssertEqual(model.clientError, .cancelled)
        XCTAssertEqual(model.envelope?.state.session, .stale)
        XCTAssertEqual(model.envelope?.error?.code, .stateUnsafe)
        XCTAssertEqual(try String(contentsOf: calls, encoding: .utf8), "apply\nstatus\n")
        XCTAssertFalse(model.isBusy)
        XCTAssertNil(model.progress)
    }

#if !canImport(XCTest)
    @Test
#endif
    @MainActor
    func testTimeoutReconcilesStatusWithoutAuthorizationAndKeepsTimeoutVisible() async throws {
        let fixture = try makeTemporaryDirectory()
        let calls = fixture.appendingPathComponent("calls")
        let stale = try modelJSON(makeEnvelope(
            operation: .status,
            ok: false,
            session: "stale",
            errorCode: "STATE_UNSAFE",
            recoveryActions: ["restore", "diagnostics", "cancel"]
        ))
        let script = try makeExecutable(in: fixture, body: """
        /usr/bin/printf '%s\\n' "$@" >> '\(calls.path)'
        if [ "$1" = "status" ]; then
          /usr/bin/printf '%s\\n' '\(stale)'
          exit 1
        fi
        trap '' TERM
        while :; do /bin/sleep 1; done
        """)
        let client = EngineClient(adapterURL: script, timeout: 2, terminationGrace: 0.02)
        let model = StudioModel(engine: client)

        await model.perform(
            .apply,
            restartAuthorized: true,
            forceAuthorized: true,
            deleteUserThemes: false
        )

        XCTAssertEqual(model.clientError, .timedOut)
        XCTAssertEqual(model.envelope?.state.session, .stale)
        XCTAssertEqual(model.envelope?.error?.code, .stateUnsafe)
        XCTAssertEqual(
            try String(contentsOf: calls, encoding: .utf8),
            "apply\n--restart-authorized\n--force-authorized\nstatus\n"
        )
        XCTAssertFalse(model.isBusy)
        XCTAssertNil(model.progress)
    }

#if !canImport(XCTest)
    @Test
#endif
    @MainActor
    func testCancelledParentUsesUncancelledReconciliationTaskAndRejectsReentry() async throws {
        let mutation = makeEnvelope(operation: .apply)
        let stale = makeEnvelope(
            operation: .status,
            ok: false,
            session: "stale",
            errorCode: "STATE_UNSAFE",
            recoveryActions: ["restore", "diagnostics", "cancel"]
        )
        let engine = ScriptedEngine([
            .envelope(mutation),
            .suspendedRequiresUncancelled(stale),
        ])
        let model = StudioModel(engine: engine)
        let operation = Task { await model.perform(.apply) }
        operation.cancel()

        try await waitUntil { await engine.recordedCalls().count == 2 }
        XCTAssertTrue(model.isBusy)
        await model.perform(.restore)
        let calls = await engine.recordedCalls()
        XCTAssertEqual(calls, [call(.apply), call(.status)])
        await engine.resumeNext()
        await operation.value

        XCTAssertEqual(model.envelope, stale)
        XCTAssertEqual(model.clientError, .cancelled)
        XCTAssertFalse(model.isBusy)
        XCTAssertNil(model.progress)
    }

#if !canImport(XCTest)
    @Test
#endif
    @MainActor
    func testLateProgressFromOlderAndCompletedGenerationsIsIgnored() async throws {
        let mutation = makeEnvelope(operation: .apply)
        let status = makeEnvelope(operation: .status)
        let engine = ScriptedEngine([
            .suspended(mutation, progress: [.applying]),
            .suspended(status, progress: [.checking]),
        ])
        let model = StudioModel(engine: engine)
        let operation = Task { await model.perform(.apply) }

        try await waitUntil { await engine.recordedCalls().count == 1 }
        await settleMainActor()
        XCTAssertEqual(model.progress, .applying)
        await engine.resumeNext()
        try await waitUntil { await engine.recordedCalls().count == 2 }
        await settleMainActor()
        XCTAssertEqual(model.progress, .checking)

        await engine.emitProgress(forCall: 0, .uninstalling)
        await settleMainActor()
        XCTAssertEqual(model.progress, .checking)

        await engine.resumeNext()
        await operation.value
        XCTAssertNil(model.progress)
        await engine.emitProgress(forCall: 1, .restoring)
        await settleMainActor()
        XCTAssertNil(model.progress)
    }

#if !canImport(XCTest)
    @Test
#endif
    @MainActor
    func testLaunchRunsPreflightOnlyOnce() async {
        let preflight = makeEnvelope(operation: .preflight)
        let engine = ScriptedEngine([.envelope(preflight)])
        let model = StudioModel(engine: engine)

        await model.launch()
        await model.launch()

        XCTAssertEqual(await engine.recordedCalls(), [call(.preflight)])
        XCTAssertEqual(model.envelope, preflight)
    }

#if !canImport(XCTest)
    @Test
#endif
    @MainActor
    func testRestartConfirmationDoesNotRetryUntilConfirmed() async {
        let ready = makeEnvelope(operation: .status, availableActions: ["apply"])
        let restartRequired = makeEnvelope(
            operation: .apply,
            ok: false,
            session: "official",
            errorCode: "RESTART_REQUIRED",
            recoveryActions: ["authorize-restart", "cancel"]
        )
        let applied = makeEnvelope(operation: .apply)
        let status = makeEnvelope(operation: .status)
        let engine = ScriptedEngine([
            .envelope(ready),
            .envelope(restartRequired),
            .envelope(applied),
            .envelope(status),
        ])
        let model = StudioModel(engine: engine)

        await model.refresh(.status)
        await model.request(.apply)

        XCTAssertEqual(await engine.recordedCalls(), [call(.status), call(.apply)])
        XCTAssertEqual(model.presentation, .restartConfirmation(.apply, deleteUserThemes: false))

        await model.confirmPresentation()

        XCTAssertEqual(await engine.recordedCalls(), [
            call(.status),
            call(.apply),
            call(.apply, restart: true),
            call(.status),
        ])
        XCTAssertNil(model.presentation)
    }

#if !canImport(XCTest)
    @Test
#endif
    @MainActor
    func testInstallCloseRequirementUsesRestartConfirmation() async {
        let ready = makeEnvelope(
            operation: .status,
            install: "not-installed",
            session: "official",
            availableActions: ["install"]
        )
        let closeRequired = makeEnvelope(
            operation: .install,
            ok: false,
            session: "official",
            errorCode: "CODEX_CLOSE_REQUIRED",
            recoveryActions: ["authorize-restart", "cancel"]
        )
        let installed = makeEnvelope(operation: .install)
        let status = makeEnvelope(operation: .status)
        let engine = ScriptedEngine([
            .envelope(ready),
            .envelope(closeRequired),
            .envelope(installed),
            .envelope(status),
        ])
        let model = StudioModel(engine: engine)

        await model.refresh(.status)
        await model.request(.install)

        XCTAssertEqual(await engine.recordedCalls(), [call(.status), call(.install)])
        XCTAssertEqual(model.presentation, .restartConfirmation(.install, deleteUserThemes: false))

        await model.confirmPresentation()

        XCTAssertEqual(await engine.recordedCalls(), [
            call(.status),
            call(.install),
            call(.install, restart: true),
            call(.status),
        ])
    }

#if !canImport(XCTest)
    @Test
#endif
    @MainActor
    func testForceStopRequiresASecondConfirmation() async {
        let ready = makeEnvelope(operation: .status, availableActions: ["apply"])
        let restartRequired = makeEnvelope(
            operation: .apply,
            ok: false,
            session: "official",
            errorCode: "RESTART_REQUIRED",
            recoveryActions: ["authorize-restart", "cancel"]
        )
        let forceRequired = makeEnvelope(
            operation: .apply,
            ok: false,
            session: "official",
            errorCode: "FORCE_STOP_REQUIRED",
            recoveryActions: ["authorize-force-stop", "cancel"]
        )
        let applied = makeEnvelope(operation: .apply)
        let status = makeEnvelope(operation: .status)
        let engine = ScriptedEngine([
            .envelope(ready),
            .envelope(restartRequired),
            .envelope(forceRequired),
            .envelope(applied),
            .envelope(status),
        ])
        let model = StudioModel(engine: engine)

        await model.refresh(.status)
        await model.request(.apply)
        await model.confirmPresentation()

        XCTAssertEqual(await engine.recordedCalls(), [
            call(.status),
            call(.apply),
            call(.apply, restart: true),
        ])
        XCTAssertEqual(model.presentation, .forceStopConfirmation(.apply, deleteUserThemes: false))

        await model.confirmPresentation()

        XCTAssertEqual(await engine.recordedCalls(), [
            call(.status),
            call(.apply),
            call(.apply, restart: true),
            call(.apply, restart: true, force: true),
            call(.status),
        ])
    }

#if !canImport(XCTest)
    @Test
#endif
    @MainActor
    func testCancellingConfirmationDoesNotCallAdapter() async {
        let engine = ScriptedEngine([.envelope(makeEnvelope(operation: .status, availableActions: ["restore"]))])
        let model = StudioModel(engine: engine)

        await model.refresh(.status)
        await model.request(.restore)
        model.cancelPresentation()

        XCTAssertEqual(await engine.recordedCalls(), [call(.status)])
        XCTAssertNil(model.presentation)
    }

#if !canImport(XCTest)
    @Test
#endif
    @MainActor
    func testRestoreRequiresConfirmationBeforeItRuns() async {
        let ready = makeEnvelope(operation: .status, availableActions: ["restore"])
        let restored = makeEnvelope(operation: .restore, session: "official", verified: false)
        let status = makeEnvelope(operation: .status, session: "official", verified: false)
        let engine = ScriptedEngine([.envelope(ready), .envelope(restored), .envelope(status)])
        let model = StudioModel(engine: engine)

        await model.refresh(.status)
        await model.request(.restore)
        XCTAssertEqual(model.presentation, .restoreConfirmation)
        XCTAssertEqual(await engine.recordedCalls(), [call(.status)])

        await model.confirmPresentation()

        XCTAssertEqual(await engine.recordedCalls(), [call(.status), call(.restore), call(.status)])
    }

#if !canImport(XCTest)
    @Test
#endif
    @MainActor
    func testUninstallKeepsThemesByDefaultAndDeletesOnlyWhenSelected() async {
        let ready = makeEnvelope(operation: .status, availableActions: ["uninstall"])
        let uninstalled = makeEnvelope(operation: .uninstall, session: "official", verified: false)
        let status = makeEnvelope(
            operation: .status,
            session: "official",
            verified: false,
            availableActions: ["uninstall"]
        )
        let engine = ScriptedEngine([
            .envelope(ready),
            .envelope(uninstalled), .envelope(status),
            .envelope(uninstalled), .envelope(status),
        ])
        let model = StudioModel(engine: engine)

        await model.refresh(.status)
        await model.request(.uninstall)
        XCTAssertEqual(model.presentation, .uninstallConfirmation)
        await model.confirmPresentation()
        await model.request(.uninstall)
        await model.confirmPresentation(deleteUserThemes: true)

        XCTAssertEqual(await engine.recordedCalls(), [
            call(.status),
            call(.uninstall),
            call(.status),
            call(.uninstall, delete: true),
            call(.status),
        ])
    }

#if !canImport(XCTest)
    @Test
#endif
    @MainActor
    func testUninstallDeletionSelectionSurvivesRestartAndForceConfirmations() async {
        let ready = makeEnvelope(operation: .status, availableActions: ["uninstall"])
        let restartRequired = makeEnvelope(
            operation: .uninstall,
            ok: false,
            session: "official",
            verified: false,
            errorCode: "RESTART_REQUIRED",
            recoveryActions: ["authorize-restart", "cancel"]
        )
        let forceRequired = makeEnvelope(
            operation: .uninstall,
            ok: false,
            session: "official",
            verified: false,
            errorCode: "FORCE_STOP_REQUIRED",
            recoveryActions: ["authorize-force-stop", "cancel"]
        )
        let uninstalled = makeEnvelope(operation: .uninstall, session: "official", verified: false)
        let status = makeEnvelope(operation: .status, session: "official", verified: false)
        let engine = ScriptedEngine([
            .envelope(ready),
            .envelope(restartRequired),
            .envelope(forceRequired),
            .envelope(uninstalled),
            .envelope(status),
        ])
        let model = StudioModel(engine: engine)

        await model.refresh(.status)
        await model.request(.uninstall)
        await model.confirmPresentation(deleteUserThemes: true)
        XCTAssertEqual(model.presentation, .restartConfirmation(.uninstall, deleteUserThemes: true))
        await model.confirmPresentation()
        XCTAssertEqual(model.presentation, .forceStopConfirmation(.uninstall, deleteUserThemes: true))
        await model.confirmPresentation()

        XCTAssertEqual(await engine.recordedCalls(), [
            call(.status),
            call(.uninstall, delete: true),
            call(.uninstall, restart: true, delete: true),
            call(.uninstall, restart: true, force: true, delete: true),
            call(.status),
        ])
    }

#if !canImport(XCTest)
    @Test
#endif
    @MainActor
    func testMenuProjectionTracksPreflightBusyAndConfirmationTransitions() async {
        let ready = makeEnvelope(operation: .preflight, availableActions: ["apply", "pause", "restore"])

        let busy = StudioMenuState(envelope: ready, isBusy: true, presentation: nil)
        XCTAssertEqual(busy.primaryOperation, .apply)
        XCTAssertFalse(busy.primaryEnabled)
        XCTAssertEqual(busy.pauseResumeOperation, .pause)
        XCTAssertFalse(busy.pauseResumeEnabled)
        XCTAssertFalse(busy.restoreEnabled)
        XCTAssertFalse(busy.allowsTermination)

        let idle = StudioMenuState(envelope: ready, isBusy: false, presentation: nil)
        XCTAssertTrue(idle.primaryEnabled)
        XCTAssertTrue(idle.pauseResumeEnabled)
        XCTAssertTrue(idle.restoreEnabled)
        XCTAssertTrue(idle.allowsTermination)

        let confirming = StudioMenuState(
            envelope: ready,
            isBusy: false,
            presentation: .restartConfirmation(.apply, deleteUserThemes: false)
        )
        XCTAssertEqual(confirming.primaryOperation, .apply)
        XCTAssertFalse(confirming.primaryEnabled)
        XCTAssertEqual(confirming.pauseResumeOperation, .pause)
        XCTAssertFalse(confirming.pauseResumeEnabled)
        XCTAssertFalse(confirming.restoreEnabled)
        XCTAssertTrue(confirming.allowsTermination)
    }

#if !canImport(XCTest)
    @Test
#endif
    @MainActor
    func testCancelledUninstallDoesNotCarryDeletionToNextAttempt() async {
        let ready = makeEnvelope(operation: .status, availableActions: ["uninstall"])
        let reconciliation = makeEnvelope(operation: .status, availableActions: ["uninstall"])
        let uninstalled = makeEnvelope(operation: .uninstall, session: "official", verified: false)
        let status = makeEnvelope(operation: .status, session: "official", verified: false)
        let engine = ScriptedEngine([
            .envelope(ready),
            .failure(.cancelled),
            .envelope(reconciliation),
            .envelope(uninstalled),
            .envelope(status),
        ])
        let model = StudioModel(engine: engine)

        await model.refresh(.status)
        await model.request(.uninstall)
        await model.confirmPresentation(deleteUserThemes: true)
        await model.request(.uninstall)
        await model.confirmPresentation()

        XCTAssertEqual(await engine.recordedCalls(), [
            call(.status),
            call(.uninstall, delete: true),
            call(.status),
            call(.uninstall),
            call(.status),
        ])
    }

#if !canImport(XCTest)
    @Test
#endif
    @MainActor
    func testTerminalUninstallErrorDoesNotCarryDeletionToNextAttempt() async {
        let ready = makeEnvelope(operation: .status, availableActions: ["uninstall"])
        let terminalError = makeEnvelope(
            operation: .uninstall,
            ok: false,
            session: "official",
            verified: false,
            errorCode: "OPERATION_FAILED",
            availableActions: ["uninstall"]
        )
        let uninstalled = makeEnvelope(operation: .uninstall, session: "official", verified: false)
        let status = makeEnvelope(operation: .status, session: "official", verified: false)
        let engine = ScriptedEngine([
            .envelope(ready),
            .envelope(terminalError),
            .envelope(uninstalled),
            .envelope(status),
        ])
        let model = StudioModel(engine: engine)

        await model.refresh(.status)
        await model.request(.uninstall)
        await model.confirmPresentation(deleteUserThemes: true)
        await model.request(.uninstall)
        await model.confirmPresentation()

        XCTAssertEqual(await engine.recordedCalls(), [
            call(.status),
            call(.uninstall, delete: true),
            call(.uninstall),
            call(.status),
        ])
    }

#if !canImport(XCTest)
    @Test
#endif
    @MainActor
    func testTransportFailedUninstallDoesNotCarryDeletionToNextAttempt() async {
        let ready = makeEnvelope(operation: .status, availableActions: ["uninstall"])
        let uninstalled = makeEnvelope(operation: .uninstall, session: "official", verified: false)
        let status = makeEnvelope(operation: .status, session: "official", verified: false)
        let engine = ScriptedEngine([
            .envelope(ready),
            .foreignFailure,
            .envelope(uninstalled),
            .envelope(status),
        ])
        let model = StudioModel(engine: engine)

        await model.refresh(.status)
        await model.request(.uninstall)
        await model.confirmPresentation(deleteUserThemes: true)
        await model.request(.uninstall)
        await model.confirmPresentation()

        XCTAssertEqual(await engine.recordedCalls(), [
            call(.status),
            call(.uninstall, delete: true),
            call(.uninstall),
            call(.status),
        ])
    }

#if !canImport(XCTest)
    @Test
#endif
    @MainActor
    func testSuccessfulUninstallDoesNotCarryDeletionToNextAttempt() async {
        let ready = makeEnvelope(operation: .status, availableActions: ["uninstall"])
        let status = makeEnvelope(
            operation: .status,
            session: "official",
            verified: false,
            availableActions: ["uninstall"]
        )
        let uninstalled = makeEnvelope(operation: .uninstall, session: "official", verified: false)
        let engine = ScriptedEngine([
            .envelope(ready),
            .envelope(uninstalled), .envelope(status),
            .envelope(uninstalled), .envelope(status),
        ])
        let model = StudioModel(engine: engine)

        await model.refresh(.status)
        await model.request(.uninstall)
        await model.confirmPresentation(deleteUserThemes: true)
        await model.request(.uninstall)
        await model.confirmPresentation()

        XCTAssertEqual(await engine.recordedCalls(), [
            call(.status),
            call(.uninstall, delete: true),
            call(.status),
            call(.uninstall),
            call(.status),
        ])
    }

#if !canImport(XCTest)
    @Test
#endif
    @MainActor
    func testUnavailableRequestMakesNoAdapterCall() async {
        let unavailable = makeEnvelope(operation: .status, availableActions: [])
        let engine = ScriptedEngine([
            .envelope(unavailable),
            .envelope(makeEnvelope(operation: .apply)),
        ])
        let model = StudioModel(engine: engine)

        await model.refresh(.status)
        XCTAssertFalse(model.canRequest(.apply))
        await model.request(.apply)

        XCTAssertEqual(await engine.recordedCalls(), [call(.status)])
    }

#if !canImport(XCTest)
    @Test
#endif
    @MainActor
    func testRequestBeforePreflightMakesNoAdapterCall() async {
        let engine = ScriptedEngine([])
        let model = StudioModel(engine: engine)

        await model.request(.apply)

        XCTAssertEqual(await engine.recordedCalls(), [])
    }

#if !canImport(XCTest)
    @Test
#endif
    @MainActor
    func testRecoveryRestoreRemainsRequestableWhenUnavailableInState() async {
        let recovery = makeEnvelope(
            operation: .status,
            ok: false,
            session: "stale",
            verified: false,
            errorCode: "STATE_UNSAFE",
            recoveryActions: ["restore", "cancel"],
            availableActions: []
        )
        let engine = ScriptedEngine([.envelope(recovery)])
        let model = StudioModel(engine: engine)

        await model.refresh(.status)
        XCTAssertTrue(model.canRequest(.restore))
        await model.request(.restore)

        XCTAssertEqual(model.presentation, .restoreConfirmation)
        XCTAssertEqual(await engine.recordedCalls(), [call(.status)])
    }

#if !canImport(XCTest)
    @Test
#endif
    @MainActor
    func testVerifiedPresentationRequiresExplicitVerifiedState() async {
        let applied = makeEnvelope(operation: .apply)
        let unverifiedStatus = makeEnvelope(operation: .status, verified: false)
        let unverifiedModel = StudioModel(engine: ScriptedEngine([
            .envelope(makeEnvelope(operation: .status, availableActions: ["apply"])),
            .envelope(applied),
            .envelope(unverifiedStatus),
        ]))

        await unverifiedModel.refresh(.status)
        await unverifiedModel.request(.apply)

        XCTAssertFalse(unverifiedModel.isVerified)

        let verifiedStatus = makeEnvelope(operation: .status, verified: true)
        let verifiedModel = StudioModel(engine: ScriptedEngine([
            .envelope(makeEnvelope(operation: .status, availableActions: ["apply"])),
            .envelope(applied),
            .envelope(verifiedStatus),
        ]))

        await verifiedModel.refresh(.status)
        await verifiedModel.request(.apply)

        XCTAssertTrue(verifiedModel.isVerified)
    }

    private func call(
        _ operation: EngineOperation,
        restart: Bool = false,
        force: Bool = false,
        delete: Bool = false
    ) -> ScriptedEngine.Call {
        ScriptedEngine.Call(
            operation: operation,
            restartAuthorized: restart,
            forceAuthorized: force,
            deleteUserThemes: delete
        )
    }

    private func makeEnvelope(
        operation: EngineOperation,
        ok: Bool = true,
        install: String = "ready",
        session: String = "active",
        verified: Bool? = true,
        errorCode: String = "INTERNAL_ERROR",
        recoveryActions: [String] = ["retry", "diagnostics", "cancel"],
        availableActions: [String]? = nil
    ) -> EngineEnvelope {
        var object = envelopeObject(operation: operation.rawValue, ok: ok)
        state(object)["install"] = install
        state(object)["session"] = session
        state(object)["verified"] = verified ?? NSNull()
        if let availableActions { state(object)["availableActions"] = availableActions }
        if !ok {
            object["error"] = errorObject(code: errorCode, recoveryActions: recoveryActions)
        }
        return try! JSONDecoder().decode(
            EngineEnvelope.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
    }

    private func modelJSON(_ envelope: EngineEnvelope) throws -> String {
        String(decoding: try JSONEncoder().encode(envelope), as: UTF8.self)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = fileManager.temporaryDirectory.appendingPathComponent("dream-skin-model-tests-\(UUID().uuidString)")
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        let fileManager = self.fileManager
        addTeardownBlock { try? fileManager.removeItem(at: url) }
        return url
    }

    private func makeExecutable(in directory: URL, body: String) throws -> URL {
        let url = directory.appendingPathComponent("adapter.sh")
        try Data("#!/bin/bash\n\(body)\n".utf8).write(to: url)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }

    @MainActor
    private func waitUntil(_ condition: @escaping @MainActor () async -> Bool) async throws {
        for _ in 0..<2_500 {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTFail("Timed out waiting for condition.")
        throw TestWaitError.timedOut
    }

    @MainActor
    private func settleMainActor() async {
        for _ in 0..<5 { await Task.yield() }
    }
}
