import Darwin
import Dispatch
import Foundation

public enum EngineClientError: Error, Equatable, Sendable {
    case invalidRequest
    case launchFailed
    case timedOut
    case cancelled
    case outputLimitExceeded
    case invalidUTF8
    case invalidResponse
    case invalidProgress
    case unexpectedExit
    case transportFailed
}

extension EngineClientError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidRequest:
            "The requested Studio operation is invalid."
        case .launchFailed:
            "The Studio engine could not be started."
        case .timedOut:
            "The Studio operation timed out."
        case .cancelled:
            "The Studio operation was cancelled."
        case .outputLimitExceeded:
            "The Studio engine returned too much data."
        case .invalidUTF8, .invalidResponse, .invalidProgress, .unexpectedExit:
            "The Studio engine returned an invalid response."
        case .transportFailed:
            "The Studio engine could not complete the request."
        }
    }
}

public struct EngineClient: EngineRunning, Sendable {
    fileprivate static let outputLimit = 1_048_576

    private let adapterURL: URL
    private let timeout: TimeInterval
    private let terminationGrace: TimeInterval

    public init(adapterURL: URL) {
        self.init(adapterURL: adapterURL, timeout: 180, terminationGrace: 1)
    }

    init(adapterURL: URL, timeout: TimeInterval, terminationGrace: TimeInterval) {
        precondition(timeout > 0 && terminationGrace >= 0)
        self.adapterURL = adapterURL
        self.timeout = timeout
        self.terminationGrace = terminationGrace
    }

    public func run(
        _ operation: EngineOperation,
        restartAuthorized: Bool,
        forceAuthorized: Bool,
        deleteUserThemes: Bool,
        onProgress: @escaping @Sendable (EngineProgress) -> Void
    ) async throws -> EngineEnvelope {
        guard !forceAuthorized || restartAuthorized,
              !deleteUserThemes || operation == .uninstall else {
            throw EngineClientError.invalidRequest
        }
        guard !Task.isCancelled else { throw EngineClientError.cancelled }

        var arguments = [operation.rawValue]
        if restartAuthorized { arguments.append("--restart-authorized") }
        if forceAuthorized { arguments.append("--force-authorized") }
        if deleteUserThemes { arguments.append("--delete-user-themes") }

        let invocation = Invocation(
            executableURL: adapterURL,
            arguments: arguments,
            timeout: timeout,
            terminationGrace: terminationGrace
        )
        return try await withTaskCancellationHandler {
            try await invocation.execute(operation: operation, onProgress: onProgress)
        } onCancel: {
            invocation.requestTermination(.cancelled)
        }
    }
}

private final class Invocation: @unchecked Sendable {
    enum TerminationReason {
        case cancelled
        case timedOut
        case protocolViolation
    }

    private enum StreamFailure {
        case outputLimitExceeded
        case transportFailed
        case invalidProgress

        var clientError: EngineClientError {
            switch self {
            case .outputLimitExceeded: .outputLimitExceeded
            case .transportFailed: .transportFailed
            case .invalidProgress: .invalidProgress
            }
        }
    }

    private struct StreamResult {
        let data: Data
        let failure: StreamFailure?
    }

    private enum WaitResult: Equatable {
        case exited(Int32)
        case signalled
        case failed
    }

    private let executableURL: URL
    private let arguments: [String]
    private let timeout: TimeInterval
    private let terminationGrace: TimeInterval
    private let lock = NSLock()
    private let terminationGroup = DispatchGroup()
    private var processGroup: pid_t?
    private var reason: TerminationReason?
    private var ioComplete = false
    private var decisionCommitted = false
    private var terminationScheduled = false
    private var timeoutWorkItem: DispatchWorkItem?

    init(executableURL: URL, arguments: [String], timeout: TimeInterval, terminationGrace: TimeInterval) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.timeout = timeout
        self.terminationGrace = terminationGrace
    }

    func execute(
        operation: EngineOperation,
        onProgress: @escaping @Sendable (EngineProgress) -> Void
    ) async throws -> EngineEnvelope {
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let childPID: pid_t

        do {
            childPID = try spawn(stdoutPipe: stdoutPipe, stderrPipe: stderrPipe)
        } catch {
            close(pipe: stdoutPipe)
            close(pipe: stderrPipe)
            throw EngineClientError.launchFailed
        }

        stdoutPipe.fileHandleForWriting.closeFile()
        stderrPipe.fileHandleForWriting.closeFile()
        register(pid: childPID)

        async let stdout = Self.readStdout(
            descriptor: stdoutPipe.fileHandleForReading.fileDescriptor,
            limit: EngineClient.outputLimit,
            onFailure: { [weak self] in self?.requestTermination(.protocolViolation) }
        )
        async let stderr = Self.readStderr(
            descriptor: stderrPipe.fileHandleForReading.fileDescriptor,
            limit: EngineClient.outputLimit,
            onProgress: onProgress,
            onFailure: { [weak self] in self?.requestTermination(.protocolViolation) }
        )
        async let waitResult = Self.observeExit(of: childPID)

        let (stdoutResult, stderrResult, processResult) = await (stdout, stderr, waitResult)
        completeIO()
        stdoutPipe.fileHandleForReading.closeFile()
        stderrPipe.fileHandleForReading.closeFile()

        switch terminationReason {
        case .cancelled:
            try await finishTermination(.cancelled, pid: childPID)
        case .timedOut:
            try await finishTermination(.timedOut, pid: childPID)
        case .protocolViolation:
            try await finishTermination(
                stdoutResult.failure?.clientError ?? stderrResult.failure?.clientError ?? .invalidResponse,
                pid: childPID
            )
        case nil:
            break
        }

        if let failure = stdoutResult.failure ?? stderrResult.failure {
            try await reject(failure.clientError, pid: childPID)
        }
        guard case let .exited(exitCode) = processResult else {
            try await reject(processResult == .failed ? .transportFailed : .unexpectedExit, pid: childPID)
        }

        let envelope: EngineEnvelope
        do {
            envelope = try Self.decode(stdoutResult.data)
        } catch let error as EngineClientError {
            try await reject(error, pid: childPID)
        } catch {
            try await reject(.invalidResponse, pid: childPID)
        }
        guard envelope.operation == operation else { try await reject(.invalidResponse, pid: childPID) }

        switch exitCode {
        case 0 where envelope.ok:
            return try await accept(envelope, pid: childPID)
        case 1 where !envelope.ok && envelope.error?.code != .invalidRequest:
            return try await accept(envelope, pid: childPID)
        case 2 where !envelope.ok && envelope.error?.code == .invalidRequest:
            return try await accept(envelope, pid: childPID)
        case 0, 1, 2:
            try await reject(.invalidResponse, pid: childPID)
        default:
            try await reject(.unexpectedExit, pid: childPID)
        }
    }

    func requestTermination(_ requestedReason: TerminationReason) {
        let reservedProcessGroup: pid_t?
        lock.lock()
        if decisionCommitted {
            lock.unlock()
            return
        }
        if requestedReason == .timedOut && ioComplete {
            lock.unlock()
            return
        }
        if reason == nil { reason = requestedReason }
        reservedProcessGroup = reserveTerminationLocked()
        timeoutWorkItem?.cancel()
        lock.unlock()
        if let reservedProcessGroup { performTermination(pid: reservedProcessGroup) }
    }

    private var terminationReason: TerminationReason? {
        lock.lock()
        defer { lock.unlock() }
        return reason
    }

    private func register(pid childPID: pid_t) {
        lock.lock()
        processGroup = childPID
        let shouldScheduleTimeout = reason == nil
        let timeoutWorkItem = DispatchWorkItem { [weak self] in
            self?.requestTermination(.timedOut)
        }
        self.timeoutWorkItem = timeoutWorkItem
        let reservedProcessGroup = reserveTerminationLocked()
        lock.unlock()

        if let reservedProcessGroup {
            performTermination(pid: reservedProcessGroup)
        } else if shouldScheduleTimeout {
            DispatchQueue.global(qos: .userInitiated).asyncAfter(
                deadline: .now() + timeout,
                execute: timeoutWorkItem
            )
        }
    }

    private func completeIO() {
        lock.lock()
        ioComplete = true
        timeoutWorkItem?.cancel()
        lock.unlock()
    }

    private func reserveTerminationLocked() -> pid_t? {
        guard reason != nil, let processGroup, !terminationScheduled else { return nil }
        terminationScheduled = true
        terminationGroup.enter()
        return processGroup
    }

    private func performTermination(pid childPID: pid_t) {
        guard Self.processGroupExists(childPID) else {
            finishTermination(pid: childPID)
            return
        }
        _ = Darwin.kill(-childPID, SIGTERM)
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + terminationGrace) { [self] in
            lock.lock()
            let stillOwned = processGroup == childPID && reason != nil
            lock.unlock()
            if stillOwned && Self.processGroupExists(childPID) {
                _ = Darwin.kill(-childPID, SIGKILL)
            }
            finishTermination(pid: childPID)
        }
    }

    private func finishTermination(pid childPID: pid_t) {
        lock.lock()
        if processGroup == childPID { processGroup = nil }
        lock.unlock()
        terminationGroup.leave()
    }

    private func waitForTermination() async {
        await withCheckedContinuation { continuation in
            terminationGroup.notify(queue: .global(qos: .userInitiated)) {
                continuation.resume()
            }
        }
    }

    private func reject(_ error: EngineClientError, pid childPID: pid_t) async throws -> Never {
        requestTermination(.protocolViolation)
        await waitForTermination()
        let finalError: EngineClientError
        switch terminationReason {
        case .cancelled: finalError = .cancelled
        case .timedOut: finalError = .timedOut
        case .protocolViolation, nil: finalError = error
        }
        _ = await Self.reap(childPID)
        await Self.waitForProcessGroupExit(childPID)
        throw finalError
    }

    private func accept(_ envelope: EngineEnvelope, pid childPID: pid_t) async throws -> EngineEnvelope {
        let winningReason = lock.withLock {
            let winningReason = reason
            if winningReason == nil {
                decisionCommitted = true
                processGroup = nil
            }
            timeoutWorkItem?.cancel()
            return winningReason
        }

        if let winningReason {
            await waitForTermination()
            let error: EngineClientError = switch winningReason {
            case .cancelled: .cancelled
            case .timedOut: .timedOut
            case .protocolViolation: .invalidResponse
            }
            _ = await Self.reap(childPID)
            await Self.waitForProcessGroupExit(childPID)
            throw error
        }
        guard await Self.reap(childPID) else { throw EngineClientError.transportFailed }
        return envelope
    }

    private func finishTermination(_ error: EngineClientError, pid childPID: pid_t) async throws -> Never {
        await waitForTermination()
        _ = await Self.reap(childPID)
        await Self.waitForProcessGroupExit(childPID)
        throw error
    }

    private func spawn(stdoutPipe: Pipe, stderrPipe: Pipe) throws -> pid_t {
        var fileActions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&fileActions) == 0 else { throw EngineClientError.launchFailed }
        defer { posix_spawn_file_actions_destroy(&fileActions) }
        guard posix_spawnattr_init(&attributes) == 0 else { throw EngineClientError.launchFailed }
        defer { posix_spawnattr_destroy(&attributes) }

        let stdoutRead = stdoutPipe.fileHandleForReading.fileDescriptor
        let stdoutWrite = stdoutPipe.fileHandleForWriting.fileDescriptor
        let stderrRead = stderrPipe.fileHandleForReading.fileDescriptor
        let stderrWrite = stderrPipe.fileHandleForWriting.fileDescriptor
        guard posix_spawn_file_actions_adddup2(&fileActions, stdoutWrite, STDOUT_FILENO) == 0,
              posix_spawn_file_actions_adddup2(&fileActions, stderrWrite, STDERR_FILENO) == 0,
              posix_spawn_file_actions_addclose(&fileActions, stdoutRead) == 0,
              posix_spawn_file_actions_addclose(&fileActions, stderrRead) == 0,
              posix_spawn_file_actions_addclose(&fileActions, stdoutWrite) == 0,
              posix_spawn_file_actions_addclose(&fileActions, stderrWrite) == 0,
              posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP)) == 0,
              posix_spawnattr_setpgroup(&attributes, 0) == 0 else {
            throw EngineClientError.launchFailed
        }

        let values = [executableURL.path] + arguments
        let strings = values.map { strdup($0) }
        defer { strings.forEach { free($0) } }
        var argv = strings + [nil]
        var childPID: pid_t = 0
        let result = executableURL.path.withCString { executablePath in
            argv.withUnsafeMutableBufferPointer { buffer in
                posix_spawn(
                    &childPID,
                    executablePath,
                    &fileActions,
                    &attributes,
                    buffer.baseAddress!,
                    environ
                )
            }
        }
        guard result == 0 else { throw EngineClientError.launchFailed }
        return childPID
    }

    private func close(pipe: Pipe) {
        pipe.fileHandleForReading.closeFile()
        pipe.fileHandleForWriting.closeFile()
    }

    private static func readStdout(
        descriptor: Int32,
        limit: Int,
        onFailure: @escaping @Sendable () -> Void
    ) async -> StreamResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var data = Data()
                var bytesRead = 0
                var failure: StreamFailure?
                var buffer = [UInt8](repeating: 0, count: 16_384)

                while true {
                    let count = buffer.withUnsafeMutableBytes {
                        Darwin.read(descriptor, $0.baseAddress, $0.count)
                    }
                    if count > 0 {
                        bytesRead += count
                        if bytesRead > limit {
                            if failure == nil { onFailure() }
                            failure = .outputLimitExceeded
                        } else if failure == nil {
                            data.append(contentsOf: buffer.prefix(count))
                        }
                    } else if count == 0 {
                        break
                    } else if errno != EINTR {
                        if failure == nil { onFailure() }
                        failure = .transportFailed
                        break
                    }
                }
                continuation.resume(returning: StreamResult(data: data, failure: failure))
            }
        }
    }

    private static func readStderr(
        descriptor: Int32,
        limit: Int,
        onProgress: @escaping @Sendable (EngineProgress) -> Void,
        onFailure: @escaping @Sendable () -> Void
    ) async -> StreamResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var pending = Data()
                var bytesRead = 0
                var failure: StreamFailure?
                var buffer = [UInt8](repeating: 0, count: 16_384)

                while true {
                    let count = buffer.withUnsafeMutableBytes {
                        Darwin.read(descriptor, $0.baseAddress, $0.count)
                    }
                    if count > 0 {
                        bytesRead += count
                        if bytesRead > limit {
                            if failure == nil { onFailure() }
                            failure = .outputLimitExceeded
                        } else if failure == nil {
                            pending.append(contentsOf: buffer.prefix(count))
                            while let newline = pending.firstIndex(of: 0x0a) {
                                let line = Data(pending[..<newline])
                                pending.removeSubrange(...newline)
                                guard parseProgress(line, onProgress: onProgress) else {
                                    failure = .invalidProgress
                                    onFailure()
                                    break
                                }
                            }
                        }
                    } else if count == 0 {
                        break
                    } else if errno != EINTR {
                        if failure == nil { onFailure() }
                        failure = .transportFailed
                        break
                    }
                }
                if failure == nil && !pending.isEmpty {
                    failure = .invalidProgress
                    onFailure()
                }
                continuation.resume(returning: StreamResult(data: Data(), failure: failure))
            }
        }
    }

    private static func parseProgress(
        _ data: Data,
        onProgress: @escaping @Sendable (EngineProgress) -> Void
    ) -> Bool {
        let prefix = "DREAM_SKIN_PROGRESS="
        guard let line = String(data: data, encoding: .utf8),
              line.hasPrefix(prefix),
              let progress = EngineProgress(rawValue: String(line.dropFirst(prefix.count))) else {
            return false
        }
        onProgress(progress)
        return true
    }

    private static func observeExit(of childPID: pid_t) async -> WaitResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var info = siginfo_t()
                var result: Int32
                repeat {
                    result = Darwin.waitid(P_PID, id_t(childPID), &info, WEXITED | WNOWAIT)
                } while result == -1 && errno == EINTR

                guard result == 0 else {
                    continuation.resume(returning: .failed)
                    return
                }
                if info.si_code == CLD_EXITED {
                    continuation.resume(returning: .exited(info.si_status))
                } else {
                    continuation.resume(returning: .signalled)
                }
            }
        }
    }

    private static func reap(_ childPID: pid_t) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var status: Int32 = 0
                var result: pid_t
                repeat {
                    result = Darwin.waitpid(childPID, &status, 0)
                } while result == -1 && errno == EINTR
                continuation.resume(returning: result == childPID)
            }
        }
    }

    private static func waitForProcessGroupExit(_ childPID: pid_t) async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let deadline = DispatchTime.now().uptimeNanoseconds + 1_000_000_000
                while processGroupExists(childPID), DispatchTime.now().uptimeNanoseconds < deadline {
                    usleep(1_000)
                }
                continuation.resume()
            }
        }
    }

    private static func processGroupExists(_ childPID: pid_t) -> Bool {
        Darwin.kill(-childPID, 0) == 0 || errno == EPERM
    }

    private static func decode(_ data: Data) throws -> EngineEnvelope {
        guard !data.isEmpty else { throw EngineClientError.invalidResponse }
        guard !data.starts(with: [0xef, 0xbb, 0xbf]) else { throw EngineClientError.invalidResponse }
        guard String(data: data, encoding: .utf8) != nil else { throw EngineClientError.invalidUTF8 }

        var payload = data
        if payload.last == 0x0a { payload.removeLast() }
        guard payload.first == 0x7b,
              payload.last == 0x7d,
              !payload.contains(0x0a),
              !payload.contains(0x0d) else {
            throw EngineClientError.invalidResponse
        }
        do {
            return try JSONDecoder().decode(EngineEnvelope.self, from: payload)
        } catch {
            throw EngineClientError.invalidResponse
        }
    }
}
