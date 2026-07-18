import Darwin
import Dispatch
import Foundation
#if canImport(XCTest)
import XCTest
#else
import Testing
#endif
@testable import DreamSkinStudioCore

enum TestWaitError: Error {
    case timedOut
}

#if canImport(XCTest)
typealias CoreTestCase = XCTestCase
#else
class CoreTestCase {
    private var teardownBlocks: [() throws -> Void] = []

    func addTeardownBlock(_ block: @escaping () throws -> Void) {
        teardownBlocks.append(block)
    }

    deinit {
        for block in teardownBlocks.reversed() { try? block() }
    }
}

func XCTAssertTrue(_ value: Bool, _ message: String = "") {
    #expect(value, Comment(rawValue: message))
}

func XCTAssertFalse(_ value: Bool, _ message: String = "") {
    #expect(!value, Comment(rawValue: message))
}

func XCTAssertNil<T>(_ value: T?, _ message: String = "") {
    #expect(value == nil, Comment(rawValue: message))
}

func XCTAssertEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String = "") {
    #expect(actual == expected, Comment(rawValue: message))
}

func XCTAssertThrowsError<T>(_ expression: @autoclosure () throws -> T, _ message: String = "") {
    #expect(throws: (any Error).self, Comment(rawValue: message)) { try expression() }
}

func XCTFail(_ message: String = "") {
    Issue.record(Comment(rawValue: message))
}

@_cdecl("run_dream_skin_studio_core_tests")
public func runDreamSkinStudioCoreTests() {
    Task { await Testing.__swiftPMEntryPoint() as Never }
    dispatchMain()
}

@_used @_section("__DATA,__mod_init_func")
private nonisolated(unsafe) var cltTestEntryPoint: @convention(c) () -> Void = runDreamSkinStudioCoreTests
#endif

final class LockedValues<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Value] = []

    func append(_ value: Value) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }

    var values: [Value] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

#if !canImport(XCTest)
@Suite("EngineClientTests", .serialized)
#endif
final class EngineClientTests: CoreTestCase {
    private let fileManager = FileManager.default

#if !canImport(XCTest)
    @Test
#endif
    func testDecodesFrozenFixturesIncludingUTF8ThemeName() throws {
        struct Fixture: Decodable {
            let name: String
            let response: EngineEnvelope
        }

        let data = try Data(contentsOf: protocolFixturesURL)
        let fixtures = try JSONDecoder().decode([Fixture].self, from: data)

        XCTAssertEqual(fixtures.count, 12)
        XCTAssertEqual(fixtures.first { $0.name == "active-verified" }?.response.state.themeName, "午夜极光")
        XCTAssertEqual(fixtures.first { $0.name == "active-verified" }?.response.state.verified, true)
        XCTAssertEqual(fixtures.first { $0.name == "not-installed" }?.response.state.verified, nil)
        XCTAssertEqual(fixtures.first { $0.name == "restart-required" }?.response.error?.code, .restartRequired)
    }

#if !canImport(XCTest)
    @Test
#endif
    func testRejectsUnknownSchemaKeysEnumsAndMissingNullableKeys() throws {
        try assertDecodeRejected { $0["schemaVersion"] = 2 }
        try assertDecodeRejected { $0["extra"] = true }
        try assertDecodeRejected { state($0)["extra"] = true }
        try assertDecodeRejected { state($0).removeObject(forKey: "themeName") }
        try assertDecodeRejected { state($0).removeObject(forKey: "verified") }
        try assertDecodeRejected { $0.removeValue(forKey: "error") }
        try assertDecodeRejected { $0["operation"] = "future" }
        try assertDecodeRejected { state($0)["install"] = "future" }
        try assertDecodeRejected { state($0)["codex"] = "future" }
        try assertDecodeRejected { state($0)["session"] = "future" }
        try assertDecodeRejected { state($0)["operation"] = "future" }
        try assertDecodeRejected { state($0)["availableActions"] = ["future"] }

        var domainError = envelopeObject(operation: "status", ok: false)
        domainError["error"] = errorObject()
        try assertDecodeRejected(domainError) { error($0)["code"] = "FUTURE_ERROR" }
        try assertDecodeRejected(domainError) { error($0)["recoveryActions"] = ["future"] }
        try assertDecodeRejected(domainError) { error($0)["extra"] = true }
    }

#if !canImport(XCTest)
    @Test
#endif
    func testRejectsInvalidEnvelopeShapesAndDuplicateActions() throws {
        try assertDecodeRejected { state($0)["availableActions"] = ["apply", "apply"] }
        try assertDecodeRejected { $0["error"] = errorObject() }
        try assertDecodeRejected { state($0)["install"] = "not-installed" }
        try assertDecodeRejected { state($0)["codex"] = "stopped" }

        var missingError = envelopeObject(operation: "status", ok: false)
        missingError["error"] = NSNull()
        XCTAssertThrowsError(try decodeEnvelope(missingError))

        var duplicateRecovery = envelopeObject(operation: "status", ok: false)
        duplicateRecovery["error"] = errorObject(recoveryActions: ["retry", "retry"])
        XCTAssertThrowsError(try decodeEnvelope(duplicateRecovery))

        for operation in ["apply", "resume", "verify"] {
            for verified: Any in [false, NSNull()] {
                let unverifiedSuccess = envelopeObject(operation: operation)
                state(unverifiedSuccess)["verified"] = verified
                XCTAssertThrowsError(try decodeEnvelope(unverifiedSuccess))
            }
        }
    }

#if !canImport(XCTest)
    @Test
#endif
    func testAcceptsBusyDomainStateAndAllFrozenEnumValues() throws {
        var object = envelopeObject(operation: "status", ok: false)
        state(object)["operation"] = "busy"
        object["error"] = errorObject(code: "OPERATION_BUSY", recoveryActions: ["retry", "cancel"])

        let envelope = try decodeEnvelope(object)

        XCTAssertEqual(envelope.state.operation, .busy)
        XCTAssertEqual(envelope.error?.code, .operationBusy)
        XCTAssertEqual(Set(EngineOperation.allCases.map(\.rawValue)), [
            "preflight", "install", "apply", "status", "pause", "resume", "restore", "verify", "uninstall",
        ])
        XCTAssertEqual(Set(EngineProgress.allCases.map(\.rawValue)), [
            "checking", "preparing", "installing", "launching", "connecting", "applying", "verifying",
            "pausing", "restoring", "uninstalling",
        ])
        XCTAssertEqual(Set(EngineState.Install.allCases.map(\.rawValue)), ["not-installed", "ready"])
        XCTAssertEqual(Set(EngineState.Codex.allCases.map(\.rawValue)), [
            "not-installed", "needs-first-run", "stopped", "running",
        ])
        XCTAssertEqual(Set(EngineState.Session.allCases.map(\.rawValue)), [
            "official", "active", "paused", "stale",
        ])
        XCTAssertEqual(Set(EngineState.Operation.allCases.map(\.rawValue)), ["idle", "busy"])
        XCTAssertEqual(Set(EngineState.Action.allCases.map(\.rawValue)), [
            "install", "apply", "pause", "resume", "restore", "verify", "uninstall",
        ])
        XCTAssertEqual(Set(EngineError.RecoveryAction.allCases.map(\.rawValue)), [
            "open-codex", "authorize-restart", "authorize-force-stop", "retry", "restore", "diagnostics", "cancel",
        ])
        XCTAssertEqual(Set(EngineError.Code.allCases.map(\.rawValue)), [
            "INVALID_REQUEST", "OPERATION_BUSY", "CODEX_NOT_INSTALLED", "CODEX_FIRST_RUN_REQUIRED",
            "CODEX_IDENTITY_INVALID", "RUNTIME_INVALID", "CODEX_CLOSE_REQUIRED", "RESTART_REQUIRED",
            "FORCE_STOP_REQUIRED", "STATE_UNSAFE", "PORT_UNAVAILABLE", "CONFIG_UNSAFE", "CONFIG_CHANGED",
            "CONFIG_BACKUP_MISSING", "THEME_INVALID", "INJECTOR_FAILED", "VERIFY_FAILED", "LIVE_REMOVE_FAILED",
            "OPERATION_FAILED", "INTERNAL_ERROR",
        ])
    }

#if !canImport(XCTest)
    @Test
#endif
    func testBuildsOnlyFixedArgumentsInExactOrder() async throws {
        let fixture = try makeTemporaryDirectory()
        let marker = fixture.appendingPathComponent("argv")
        let json = try jsonString(envelopeObject(operation: "uninstall"))
        let script = try makeExecutable(in: fixture, body: """
        /usr/bin/printf '%s\\n' "$@" > '\(marker.path)'
        /usr/bin/printf '%s\\n' '\(json)'
        """)
        let client = EngineClient(adapterURL: script)

        let envelope = try await client.run(
            .uninstall,
            restartAuthorized: true,
            forceAuthorized: true,
            deleteUserThemes: true,
            onProgress: { _ in }
        )

        XCTAssertTrue(envelope.ok)
        XCTAssertEqual(
            try String(contentsOf: marker, encoding: .utf8),
            "uninstall\n--restart-authorized\n--force-authorized\n--delete-user-themes\n"
        )
    }

#if !canImport(XCTest)
    @Test
#endif
    func testRejectsInvalidAuthorizationBeforeSpawn() async throws {
        let fixture = try makeTemporaryDirectory()
        let marker = fixture.appendingPathComponent("spawned")
        let json = try jsonString(envelopeObject(operation: "apply"))
        let script = try makeExecutable(in: fixture, body: """
        /usr/bin/touch '\(marker.path)'
        /usr/bin/printf '%s\\n' '\(json)'
        """)
        let client = EngineClient(adapterURL: script)

        await assertClientError(.invalidRequest) {
            _ = try await client.run(
                .apply,
                restartAuthorized: false,
                forceAuthorized: true,
                deleteUserThemes: false,
                onProgress: { _ in }
            )
        }
        await assertClientError(.invalidRequest) {
            _ = try await client.run(
                .apply,
                restartAuthorized: false,
                forceAuthorized: false,
                deleteUserThemes: true,
                onProgress: { _ in }
            )
        }
        XCTAssertFalse(fileManager.fileExists(atPath: marker.path))
    }

#if !canImport(XCTest)
    @Test
#endif
    func testReturnsValidExitZeroOneAndTwoEnvelopes() async throws {
        for (operation, ok, code, exitCode) in [
            ("status", true, nil, 0),
            ("apply", false, "RESTART_REQUIRED", 1),
            ("apply", false, "INVALID_REQUEST", 2),
        ] as [(String, Bool, String?, Int)] {
            let fixture = try makeTemporaryDirectory()
            var object = envelopeObject(operation: operation, ok: ok)
            if let code {
                object["error"] = errorObject(
                    code: code,
                    recoveryActions: code == "INVALID_REQUEST" ? ["cancel"] : ["authorize-restart", "cancel"]
                )
            }
            let json = try jsonString(object)
            let script = try makeExecutable(in: fixture, body: """
            /usr/bin/printf '%s\\n' '\(json)'
            exit \(exitCode)
            """)
            let client = EngineClient(adapterURL: script)
            let requested = EngineOperation(rawValue: operation)!

            let envelope = try await client.run(
                requested,
                restartAuthorized: false,
                forceAuthorized: false,
                deleteUserThemes: false,
                onProgress: { _ in }
            )

            XCTAssertEqual(envelope.ok, ok)
            XCTAssertEqual(envelope.error?.code.rawValue, code)
        }
    }

#if !canImport(XCTest)
    @Test
#endif
    func testRejectsExitEnvelopeMismatchUnknownExitAndMissingJSON() async throws {
        let cases: [(String, Int, EngineOperation)] = [
            (try jsonString(envelopeObject(operation: "status", ok: false, error: errorObject())), 0, .status),
            (try jsonString(envelopeObject(operation: "status")), 1, .status),
            (try jsonString(envelopeObject(operation: "apply", ok: false, error: errorObject(code: "INVALID_REQUEST"))), 1, .apply),
            (try jsonString(envelopeObject(operation: "apply", ok: false, error: errorObject(code: "RESTART_REQUIRED"))), 2, .apply),
            (try jsonString(envelopeObject(operation: "status")), 3, .status),
            ("not-json", 1, .status),
        ]

        for (output, exitCode, operation) in cases {
            let fixture = try makeTemporaryDirectory()
            let script = try makeExecutable(in: fixture, body: """
            /usr/bin/printf '%s\\n' '\(output)'
            exit \(exitCode)
            """)
            let client = EngineClient(adapterURL: script, timeout: 5, terminationGrace: 0.01)
            await assertClientError(exitCode == 3 ? .unexpectedExit : .invalidResponse) {
                _ = try await client.run(
                    operation,
                    restartAuthorized: false,
                    forceAuthorized: false,
                    deleteUserThemes: false,
                    onProgress: { _ in }
                )
            }
        }
    }

#if !canImport(XCTest)
    @Test
#endif
    func testRejectsResponseOperationMismatch() async throws {
        let fixture = try makeTemporaryDirectory()
        let json = try jsonString(envelopeObject(operation: "status"))
        let script = try makeExecutable(in: fixture, body: "/usr/bin/printf '%s\\n' '\(json)'")

        await assertClientError(.invalidResponse) {
            _ = try await EngineClient(adapterURL: script, timeout: 5, terminationGrace: 0.01).run(
                .apply,
                restartAuthorized: false,
                forceAuthorized: false,
                deleteUserThemes: false,
                onProgress: { _ in }
            )
        }
    }

#if !canImport(XCTest)
    @Test
#endif
    func testRejectsEmptyInvalidUTF8BOMExtraAndMultipleStdoutObjects() async throws {
        let valid = try jsonString(envelopeObject(operation: "status"))
        let bodies = [
            ":",
            "/usr/bin/printf '\\377'",
            "/usr/bin/printf '\\357\\273\\277%s\\n' '\(valid)'",
            "/usr/bin/printf 'prefix%s\\n' '\(valid)'",
            "/usr/bin/printf '%s suffix\\n' '\(valid)'",
            "/usr/bin/printf '%s\\n%s\\n' '\(valid)' '\(valid)'",
            "/usr/bin/printf '%s\\n\\n' '\(valid)'",
        ]

        for body in bodies {
            let fixture = try makeTemporaryDirectory()
            let script = try makeExecutable(in: fixture, body: body)
            await assertClientError(body.contains("377") ? .invalidUTF8 : .invalidResponse) {
                _ = try await EngineClient(adapterURL: script, timeout: 5, terminationGrace: 0.01).run(
                    .status,
                    restartAuthorized: false,
                    forceAuthorized: false,
                    deleteUserThemes: false,
                    onProgress: { _ in }
                )
            }
        }
    }

#if !canImport(XCTest)
    @Test
#endif
    func testRejectsStdoutAndStderrBeyondOneMiB() async throws {
        let stdoutFixture = try makeTemporaryDirectory()
        let stdoutScript = try makeExecutable(in: stdoutFixture, body: "/usr/bin/head -c 1048577 /dev/zero")
        await assertClientError(.outputLimitExceeded) {
            _ = try await EngineClient(adapterURL: stdoutScript, timeout: 5, terminationGrace: 0.01).run(
                .status,
                restartAuthorized: false,
                forceAuthorized: false,
                deleteUserThemes: false,
                onProgress: { _ in }
            )
        }

        let stderrFixture = try makeTemporaryDirectory()
        let stderrScript = try makeExecutable(in: stderrFixture, body: """
        /usr/bin/printf 'DREAM_SKIN_PROGRESS ' >&2
        /usr/bin/head -c 1048577 /dev/zero >&2
        """)
        await assertClientError(.outputLimitExceeded) {
            _ = try await EngineClient(adapterURL: stderrScript, timeout: 5, terminationGrace: 0.01).run(
                .status,
                restartAuthorized: false,
                forceAuthorized: false,
                deleteUserThemes: false,
                onProgress: { _ in }
            )
        }
    }

#if !canImport(XCTest)
    @Test
#endif
    func testStreamsChunkedProgressAndRejectsUnknownStderr() async throws {
        let fixture = try makeTemporaryDirectory()
        let json = try jsonString(envelopeObject(operation: "apply"))
        let script = try makeExecutable(in: fixture, body: """
        /usr/bin/printf 'DREAM_SKIN_PRO' >&2
        /bin/sleep 0.02
        /usr/bin/printf 'GRESS checking\\nDREAM_SKIN_PROGRESS applying\\n' >&2
        /usr/bin/printf '%s\\n' '\(json)'
        """)
        let progress = LockedValues<EngineProgress>()

        _ = try await EngineClient(adapterURL: script).run(
            .apply,
            restartAuthorized: false,
            forceAuthorized: false,
            deleteUserThemes: false,
            onProgress: { progress.append($0) }
        )

        XCTAssertEqual(progress.values, [.checking, .applying])

        for stderr in [
            "unexpected text\\n",
            "DREAM_SKIN_PROGRESS future\\n",
            "DREAM_SKIN_PROGRESS=checking\\n",
            "DREAM_SKIN_PROGRESS checking",
        ] {
            let invalidFixture = try makeTemporaryDirectory()
            let invalidScript = try makeExecutable(in: invalidFixture, body: """
            /usr/bin/printf '%s' '\(stderr)' >&2
            /usr/bin/printf '%s\\n' '\(json)'
            """)
            await assertClientError(.invalidProgress) {
                _ = try await EngineClient(adapterURL: invalidScript, timeout: 5, terminationGrace: 0.01).run(
                    .apply,
                    restartAuthorized: false,
                    forceAuthorized: false,
                    deleteUserThemes: false,
                    onProgress: { _ in }
                )
            }
        }
    }

#if !canImport(XCTest)
    @Test
#endif
    func testDrainsLargeStdoutAndStderrConcurrently() async throws {
        let fixture = try makeTemporaryDirectory()
        let script = try makeExecutable(in: fixture, body: """
        /usr/bin/awk 'BEGIN { for (i = 0; i < 18000; i++) print "DREAM_SKIN_PROGRESS checking" > "/dev/stderr" }' &
        /usr/bin/printf '%s' '{"schemaVersion":1,"ok":true,"operation":"status","state":{"install":"ready","codex":"running","session":"active","operation":"idle","themeName":"'
        /usr/bin/head -c 600000 /dev/zero | /usr/bin/tr '\\000' x
        /usr/bin/printf '%s\\n' '","requiresRestart":false,"availableActions":["pause"],"verified":true},"error":null}'
        wait
        """)
        let progress = LockedValues<EngineProgress>()
        let client = EngineClient(adapterURL: script, timeout: 5, terminationGrace: 0.02)

        let envelope = try await client.run(
            .status,
            restartAuthorized: false,
            forceAuthorized: false,
            deleteUserThemes: false,
            onProgress: { progress.append($0) }
        )

        XCTAssertEqual(envelope.state.themeName?.count, 600_000)
        XCTAssertEqual(progress.values.count, 18_000)
    }

#if !canImport(XCTest)
    @Test
#endif
    func testTimeoutTerminatesTermResistantChildAndGrandchildBeforeReturning() async throws {
        let fixture = try makeTemporaryDirectory()
        let childPID = fixture.appendingPathComponent("child-pid")
        let lateMarker = fixture.appendingPathComponent("late-marker")
        let script = try makeTermResistantScript(in: fixture, childPID: childPID, lateMarker: lateMarker)
        let client = EngineClient(adapterURL: script, timeout: 2, terminationGrace: 0.03)

        await assertClientError(.timedOut) {
            _ = try await client.run(
                .apply,
                restartAuthorized: false,
                forceAuthorized: false,
                deleteUserThemes: false,
                onProgress: { _ in }
            )
        }

        let pid = try Int32(String(contentsOf: childPID, encoding: .utf8))!
        XCTAssertFalse(processExists(pid))
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertFalse(fileManager.fileExists(atPath: lateMarker.path))
    }

#if !canImport(XCTest)
    @Test
#endif
    func testCancellationTerminatesTermResistantChildAndGrandchildBeforeReturning() async throws {
        let fixture = try makeTemporaryDirectory()
        let childPID = fixture.appendingPathComponent("child-pid")
        let lateMarker = fixture.appendingPathComponent("late-marker")
        let script = try makeTermResistantScript(in: fixture, childPID: childPID, lateMarker: lateMarker)
        let client = EngineClient(adapterURL: script, timeout: 10, terminationGrace: 0.03)
        let task = Task {
            try await client.run(
                .apply,
                restartAuthorized: false,
                forceAuthorized: false,
                deleteUserThemes: false,
                onProgress: { _ in }
            )
        }

        try await waitUntil { self.fileManager.fileExists(atPath: childPID.path) }
        task.cancel()
        await assertClientError(.cancelled) { _ = try await task.value }

        let pid = try Int32(String(contentsOf: childPID, encoding: .utf8))!
        XCTAssertFalse(processExists(pid))
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertFalse(fileManager.fileExists(atPath: lateMarker.path))
    }

#if !canImport(XCTest)
    @Test
#endif
    func testSuccessfulInvocationLeavesRedirectedWatcherAlive() async throws {
        let fixture = try makeTemporaryDirectory()
        let identities = fixture.appendingPathComponent("identities")
        let json = try jsonString(envelopeObject(operation: "apply"))
        let script = try makeExecutable(in: fixture, body: """
        (
          trap '' TERM
          while :; do /bin/sleep 1; done
        ) </dev/null >/dev/null 2>/dev/null &
        watcher=$!
        /usr/bin/printf '%s %s' "$$" "$watcher" > '\(identities.path)'
        /usr/bin/printf '%s\\n' '\(json)'
        """)

        let envelope = try await EngineClient(adapterURL: script).run(
            .apply,
            restartAuthorized: false,
            forceAuthorized: false,
            deleteUserThemes: false,
            onProgress: { _ in }
        )

        let values = try String(contentsOf: identities, encoding: .utf8)
            .split(separator: " ")
            .compactMap { Int32($0) }
        let processGroup = values[0]
        let watcher = values[1]
        defer { _ = Darwin.kill(-processGroup, SIGKILL) }
        XCTAssertTrue(envelope.ok)
        XCTAssertTrue(processExists(watcher))
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(processExists(watcher))
    }

#if !canImport(XCTest)
    @Test
#endif
    func testLaunchFailureAndCompletionRacesReturnOnce() async throws {
        let missing = URL(fileURLWithPath: "/tmp/dream-skin-missing-\(UUID().uuidString)")
        await assertClientError(.launchFailed) {
            _ = try await EngineClient(adapterURL: missing).run(
                .status,
                restartAuthorized: false,
                forceAuthorized: false,
                deleteUserThemes: false,
                onProgress: { _ in }
            )
        }

        let fixture = try makeTemporaryDirectory()
        let json = try jsonString(envelopeObject(operation: "status"))
        let script = try makeExecutable(in: fixture, body: """
        /bin/sleep 0.015
        /usr/bin/printf '%s\\n' '\(json)'
        """)

        await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<20 {
                group.addTask {
                    let task = Task {
                        try await EngineClient(adapterURL: script, timeout: 0.015, terminationGrace: 0.005).run(
                            .status,
                            restartAuthorized: false,
                            forceAuthorized: false,
                            deleteUserThemes: false,
                            onProgress: { _ in }
                        )
                    }
                    try? await Task.sleep(nanoseconds: 15_000_000)
                    task.cancel()
                    do {
                        return try await task.value.ok
                    } catch let error as EngineClientError {
                        return error == .cancelled || error == .timedOut
                    } catch {
                        return false
                    }
                }
            }
            for await validResult in group {
                XCTAssertTrue(validResult)
            }
        }
    }

    private var protocolFixturesURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("studio/protocol/fixtures-v1.json")
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = fileManager.temporaryDirectory.appendingPathComponent("dream-skin-engine-tests-\(UUID().uuidString)")
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        let fileManager = self.fileManager
        addTeardownBlock { try? fileManager.removeItem(at: url) }
        return url
    }

    private func makeExecutable(in directory: URL, body: String) throws -> URL {
        let url = directory.appendingPathComponent("adapter-\(UUID().uuidString).sh")
        try Data("#!/bin/bash\n\(body)\n".utf8).write(to: url)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }

    private func makeTermResistantScript(in directory: URL, childPID: URL, lateMarker: URL) throws -> URL {
        try makeExecutable(in: directory, body: """
        trap '' TERM
        (
          trap '' TERM
          /bin/sleep 3
          /usr/bin/printf late > '\(lateMarker.path)'
          while :; do /bin/sleep 1; done
        ) &
        child=$!
        /usr/bin/printf '%s' "$child" > '\(childPID.path)'
        wait "$child"
        """)
    }

    private func waitUntil(_ condition: @escaping () -> Bool) async throws {
        for _ in 0..<2_500 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTFail("Timed out waiting for condition.")
        throw TestWaitError.timedOut
    }

    private func processExists(_ pid: Int32) -> Bool {
        Darwin.kill(pid, 0) == 0 || errno == EPERM
    }

    private func assertClientError(
        _ expected: EngineClientError,
        operation: () async throws -> Void
    ) async {
        do {
            try await operation()
            XCTFail("Expected \(expected).")
        } catch let error as EngineClientError {
            XCTAssertEqual(error, expected)
        } catch {
            XCTFail("Unexpected error type: \(type(of: error)).")
        }
    }

    private func assertDecodeRejected(_ mutate: (inout [String: Any]) -> Void) throws {
        try assertDecodeRejected(envelopeObject(operation: "status"), mutate)
    }

    private func assertDecodeRejected(
        _ base: [String: Any],
        _ mutate: (inout [String: Any]) -> Void
    ) throws {
        var object = base
        mutate(&object)
        XCTAssertThrowsError(try decodeEnvelope(object))
    }

    private func decodeEnvelope(_ object: [String: Any]) throws -> EngineEnvelope {
        try JSONDecoder().decode(EngineEnvelope.self, from: JSONSerialization.data(withJSONObject: object))
    }

    private func jsonString(_ object: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }
}

func envelopeObject(
    operation: String,
    ok: Bool = true,
    error errorValue: Any = NSNull()
) -> [String: Any] {
    [
        "schemaVersion": 1,
        "ok": ok,
        "operation": operation,
        "state": NSMutableDictionary(dictionary: [
            "install": "ready",
            "codex": "running",
            "session": "active",
            "operation": "idle",
            "themeName": "午夜极光",
            "requiresRestart": false,
            "availableActions": ["pause", "restore"],
            "verified": true,
        ]),
        "error": errorValue,
    ]
}

func errorObject(
    code: String = "INTERNAL_ERROR",
    recoveryActions: [String] = ["retry", "diagnostics", "cancel"]
) -> NSMutableDictionary {
    NSMutableDictionary(dictionary: [
        "code": code,
        "message": "The operation failed.",
        "recoveryActions": recoveryActions,
    ])
}

@discardableResult
func state(_ object: [String: Any]) -> NSMutableDictionary {
    object["state"] as! NSMutableDictionary
}

@discardableResult
func error(_ object: [String: Any]) -> NSMutableDictionary {
    object["error"] as! NSMutableDictionary
}
