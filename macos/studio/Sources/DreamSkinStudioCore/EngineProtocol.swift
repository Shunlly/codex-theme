import Foundation

public enum EngineOperation: String, Codable, CaseIterable, Sendable {
    case preflight
    case install
    case apply
    case status
    case pause
    case resume
    case restore
    case verify
    case uninstall
}

public enum EngineProgress: String, Codable, CaseIterable, Sendable {
    case checking
    case preparing
    case installing
    case launching
    case connecting
    case applying
    case verifying
    case pausing
    case restoring
    case uninstalling
}

public struct EngineState: Codable, Equatable, Sendable {
    public enum Install: String, Codable, CaseIterable, Sendable {
        case notInstalled = "not-installed"
        case ready
    }

    public enum Codex: String, Codable, CaseIterable, Sendable {
        case notInstalled = "not-installed"
        case needsFirstRun = "needs-first-run"
        case stopped
        case running
    }

    public enum Session: String, Codable, CaseIterable, Sendable {
        case official
        case active
        case paused
        case stale
    }

    public enum Operation: String, Codable, CaseIterable, Sendable {
        case idle
        case busy
    }

    public enum Action: String, Codable, CaseIterable, Sendable {
        case install
        case apply
        case pause
        case resume
        case restore
        case verify
        case uninstall
    }

    public let install: Install
    public let codex: Codex
    public let session: Session
    public let operation: Operation
    public let themeName: String?
    public let requiresRestart: Bool
    public let availableActions: [Action]
    public let verified: Bool?

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case install
        case codex
        case session
        case operation
        case themeName
        case requiresRestart
        case availableActions
        case verified
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.strictContainer(keys: CodingKeys.allCases.map(\.rawValue))
        install = try container.decode(Install.self, forKey: "install")
        codex = try container.decode(Codex.self, forKey: "codex")
        session = try container.decode(Session.self, forKey: "session")
        operation = try container.decode(Operation.self, forKey: "operation")
        themeName = try container.decodeRequiredNullable(String.self, forKey: "themeName")
        requiresRestart = try container.decode(Bool.self, forKey: "requiresRestart")
        availableActions = try container.decode([Action].self, forKey: "availableActions")
        verified = try container.decodeRequiredNullable(Bool.self, forKey: "verified")
        try requireUnique(availableActions, decoder: decoder)
        guard session != .active || (install == .ready && codex == .running) else {
            throw protocolCorrupted(decoder)
        }
    }
}

public struct EngineError: Codable, Equatable, Sendable {
    public enum Code: String, Codable, CaseIterable, Sendable {
        case invalidRequest = "INVALID_REQUEST"
        case operationBusy = "OPERATION_BUSY"
        case codexNotInstalled = "CODEX_NOT_INSTALLED"
        case codexFirstRunRequired = "CODEX_FIRST_RUN_REQUIRED"
        case codexIdentityInvalid = "CODEX_IDENTITY_INVALID"
        case runtimeInvalid = "RUNTIME_INVALID"
        case codexCloseRequired = "CODEX_CLOSE_REQUIRED"
        case restartRequired = "RESTART_REQUIRED"
        case forceStopRequired = "FORCE_STOP_REQUIRED"
        case stateUnsafe = "STATE_UNSAFE"
        case portUnavailable = "PORT_UNAVAILABLE"
        case configUnsafe = "CONFIG_UNSAFE"
        case configChanged = "CONFIG_CHANGED"
        case configBackupMissing = "CONFIG_BACKUP_MISSING"
        case themeInvalid = "THEME_INVALID"
        case injectorFailed = "INJECTOR_FAILED"
        case verifyFailed = "VERIFY_FAILED"
        case liveRemoveFailed = "LIVE_REMOVE_FAILED"
        case operationFailed = "OPERATION_FAILED"
        case internalError = "INTERNAL_ERROR"
    }

    public enum RecoveryAction: String, Codable, CaseIterable, Sendable {
        case openCodex = "open-codex"
        case authorizeRestart = "authorize-restart"
        case authorizeForceStop = "authorize-force-stop"
        case retry
        case restore
        case diagnostics
        case cancel
    }

    public let code: Code
    public let message: String
    public let recoveryActions: [RecoveryAction]

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case code
        case message
        case recoveryActions
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.strictContainer(keys: CodingKeys.allCases.map(\.rawValue))
        code = try container.decode(Code.self, forKey: "code")
        message = try container.decode(String.self, forKey: "message")
        recoveryActions = try container.decode([RecoveryAction].self, forKey: "recoveryActions")
        guard !message.isEmpty else { throw protocolCorrupted(decoder) }
        try requireUnique(recoveryActions, decoder: decoder)
    }
}

public struct EngineEnvelope: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let ok: Bool
    public let operation: EngineOperation
    public let state: EngineState
    public let error: EngineError?

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion
        case ok
        case operation
        case state
        case error
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.strictContainer(keys: CodingKeys.allCases.map(\.rawValue))
        schemaVersion = try container.decode(Int.self, forKey: "schemaVersion")
        ok = try container.decode(Bool.self, forKey: "ok")
        operation = try container.decode(EngineOperation.self, forKey: "operation")
        state = try container.decode(EngineState.self, forKey: "state")
        error = try container.decodeRequiredNullable(EngineError.self, forKey: "error")

        guard schemaVersion == 1, ok == (error == nil) else {
            throw protocolCorrupted(decoder)
        }
        if ok {
            switch operation {
            case .apply, .resume, .verify:
                guard state.verified == true else { throw protocolCorrupted(decoder) }
            default:
                break
            }
        }
    }
}

public protocol EngineRunning: Sendable {
    func run(
        _ operation: EngineOperation,
        restartAuthorized: Bool,
        forceAuthorized: Bool,
        deleteUserThemes: Bool,
        onProgress: @escaping @Sendable (EngineProgress) -> Void
    ) async throws -> EngineEnvelope
}

private struct AnyCodingKey: CodingKey, Hashable {
    let stringValue: String
    let intValue: Int?

    init(_ stringValue: String) {
        self.stringValue = stringValue
        intValue = nil
    }

    init?(stringValue: String) {
        self.init(stringValue)
    }

    init?(intValue: Int) {
        stringValue = String(intValue)
        self.intValue = intValue
    }
}

private extension Decoder {
    func strictContainer(keys: [String]) throws -> KeyedDecodingContainer<AnyCodingKey> {
        let container = try container(keyedBy: AnyCodingKey.self)
        guard Set(container.allKeys.map(\.stringValue)) == Set(keys) else {
            throw protocolCorrupted(self)
        }
        return container
    }
}

private extension KeyedDecodingContainer where Key == AnyCodingKey {
    func decode<Value: Decodable>(_ type: Value.Type, forKey key: String) throws -> Value {
        try decode(type, forKey: AnyCodingKey(key))
    }

    func decodeRequiredNullable<Value: Decodable>(_ type: Value.Type, forKey key: String) throws -> Value? {
        let codingKey = AnyCodingKey(key)
        guard contains(codingKey) else {
            throw DecodingError.keyNotFound(
                codingKey,
                DecodingError.Context(codingPath: codingPath, debugDescription: "Missing protocol key.")
            )
        }
        return try decodeIfPresent(type, forKey: codingKey)
    }
}

private func requireUnique<Value: Hashable>(_ values: [Value], decoder: any Decoder) throws {
    guard Set(values).count == values.count else { throw protocolCorrupted(decoder) }
}

private func protocolCorrupted(_ decoder: any Decoder) -> DecodingError {
    .dataCorrupted(DecodingError.Context(
        codingPath: decoder.codingPath,
        debugDescription: "Invalid Studio protocol envelope."
    ))
}
