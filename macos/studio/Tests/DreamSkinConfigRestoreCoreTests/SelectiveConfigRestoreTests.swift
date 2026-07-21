import Foundation
import Dispatch
#if canImport(XCTest)
import XCTest
#else
import Testing
#endif
@testable import DreamSkinConfigRestoreCore

#if canImport(XCTest)
typealias TestCase = XCTestCase
#else
class TestCase {
    private var teardownBlocks: [() throws -> Void] = []

    func addTeardownBlock(_ block: @escaping () throws -> Void) {
        teardownBlocks.append(block)
    }

    deinit {
        for block in teardownBlocks.reversed() { try? block() }
    }
}

private func XCTAssertTrue(_ value: Bool, _ message: String = "") {
    #expect(value, Comment(rawValue: message))
}

private func XCTAssertFalse(_ value: Bool, _ message: String = "") {
    #expect(!value, Comment(rawValue: message))
}

private func XCTAssertEqual<T: Equatable>(_ actual: T, _ expected: T) {
    #expect(actual == expected)
}

private func XCTAssertNotEqual<T: Equatable>(_ actual: T, _ expected: T) {
    #expect(actual != expected)
}

private func XCTAssertThrowsError<T>(_ expression: @autoclosure () throws -> T) {
    #expect(throws: (any Error).self) { try expression() }
}

@_cdecl("run_dream_skin_config_restore_core_tests")
public func runDreamSkinConfigRestoreCoreTests() {
    Task { await Testing.__swiftPMEntryPoint() as Never }
    dispatchMain()
}

@_used @_section("__DATA,__mod_init_func")
private nonisolated(unsafe) var cltTestEntryPoint: @convention(c) () -> Void = runDreamSkinConfigRestoreCoreTests
#endif

#if !canImport(XCTest)
@Suite("DreamSkinConfigRestoreCoreTests")
#endif
final class SelectiveConfigRestoreTests: TestCase {
    private let fileManager = FileManager.default

#if !canImport(XCTest)
    @Test
#endif
    func testRestoresOnlySavedAppearanceKeysAndPreservesChineseLFContent() throws {
        let fixture = try makeFixture(
            config: """
            model = "gpt-5"
            project = "中文项目"

            [desktop]
            appearanceTheme = "dark"
            appearanceDarkCodeThemeId = "dream-skin"
            keepMe = "保留"
            """ + "\n",
            appearanceTheme: "appearanceTheme = \"system\"",
            appearanceDarkCodeThemeId: "appearanceDarkCodeThemeId = \"vscode-dark\""
        )

        try SelectiveConfigRestore.restore(configURL: fixture.config, backupURL: fixture.backup)

        XCTAssertEqual(
            try Data(contentsOf: fixture.config),
            Data("""
            model = "gpt-5"
            project = "中文项目"

            [desktop]
            appearanceTheme = "system"
            appearanceDarkCodeThemeId = "vscode-dark"
            keepMe = "保留"
            """.appending("\n").utf8)
        )
        XCTAssertTrue(fileManager.fileExists(atPath: fixture.backup.path))
    }

#if !canImport(XCTest)
    @Test
#endif
    func testPreservesCRLFWhenReplacingAndRemovingSettings() throws {
        let content = "model = \"gpt-5\"\r\n\r\n[desktop]\r\nappearanceTheme = \"dark\"\r\nappearanceDarkCodeThemeId = \"dream-skin\"\r\nkeepMe = true\r\n"
        let fixture = try makeFixture(
            config: content,
            appearanceTheme: "appearanceTheme = \"system\"",
            appearanceDarkCodeThemeId: nil
        )

        try SelectiveConfigRestore.restore(configURL: fixture.config, backupURL: fixture.backup)

        let expected = "model = \"gpt-5\"\r\n\r\n[desktop]\r\nappearanceTheme = \"system\"\r\nkeepMe = true\r\n"
        XCTAssertEqual(try Data(contentsOf: fixture.config), Data(expected.utf8))
    }

#if !canImport(XCTest)
    @Test
#endif
    func testPreservesUTF8BOM() throws {
        let bytes = Data([0xef, 0xbb, 0xbf]) + Data("model = \"gpt-5\"\n\n[desktop]\nappearanceTheme = \"dark\"\n".utf8)
        let fixture = try makeFixture(
            configBytes: bytes,
            appearanceTheme: "appearanceTheme = \"system\"",
            appearanceDarkCodeThemeId: nil
        )

        try SelectiveConfigRestore.restore(configURL: fixture.config, backupURL: fixture.backup)

        let restored = try Data(contentsOf: fixture.config)
        XCTAssertEqual(restored.prefix(3), Data([0xef, 0xbb, 0xbf]))
        XCTAssertEqual(restored, Data([0xef, 0xbb, 0xbf]) + Data("model = \"gpt-5\"\n\n[desktop]\nappearanceTheme = \"system\"\n".utf8))
    }

#if !canImport(XCTest)
    @Test
#endif
    func testPreservesUTF8BOMWhenDesktopIsFirstTable() throws {
        let bom = Data([0xef, 0xbb, 0xbf])
        let fixture = try makeFixture(
            configBytes: bom + Data("[desktop]\nappearanceTheme = \"dark\"\n".utf8),
            appearanceTheme: "appearanceTheme = \"system\""
        )

        try SelectiveConfigRestore.restore(configURL: fixture.config, backupURL: fixture.backup)

        XCTAssertEqual(
            try Data(contentsOf: fixture.config),
            bom + Data("[desktop]\nappearanceTheme = \"system\"\n".utf8)
        )
    }

#if !canImport(XCTest)
    @Test
#endif
    func testRejectsInvalidUTF8WithoutChangingConfigOrBackup() throws {
        try assertRejected(configBytes: Data("model = \"gpt-5\"\n# invalid: ".utf8) + Data([0xff, 0x0a]))
    }

#if !canImport(XCTest)
    @Test
#endif
    func testRejectsNULWithoutChangingConfigOrBackup() throws {
        try assertRejected(configBytes: Data("model = \"gpt-5\"\n\0".utf8))
    }

#if !canImport(XCTest)
    @Test
#endif
    func testRejectsSymbolicLinkConfigWithoutChangingTargetOrBackup() throws {
        let directory = try makeTemporaryDirectory()
        let target = directory.appendingPathComponent("target.toml")
        let config = directory.appendingPathComponent("config.toml")
        let backup = directory.appendingPathComponent("backup.json")
        let original = Data("[desktop]\nappearanceTheme = \"dark\"\n".utf8)
        try original.write(to: target)
        try fileManager.createSymbolicLink(at: config, withDestinationURL: target)
        try writeBackup(at: backup, configURL: config)

        XCTAssertThrowsError(try SelectiveConfigRestore.restore(configURL: config, backupURL: backup))
        XCTAssertEqual(try Data(contentsOf: target), original)
        XCTAssertTrue(fileManager.fileExists(atPath: backup.path))
        XCTAssertEqual(try fileManager.destinationOfSymbolicLink(atPath: config.path), target.path)
        XCTAssertFalse(fileManager.fileExists(atPath: config.path + ".dream-skin.lock"))
    }

#if !canImport(XCTest)
    @Test
#endif
    func testRejectsMultipleDesktopTables() throws {
        try assertRejected(config: "[desktop]\nkeep = 1\n[desktop] # duplicate\nkeep = 2\n")
    }

#if !canImport(XCTest)
    @Test
#endif
    func testRejectsDuplicateAppearanceSettings() throws {
        try assertRejected(config: "[desktop]\nappearanceTheme = \"dark\"\nappearanceTheme = \"light\"\n")
    }

#if !canImport(XCTest)
    @Test
#endif
    func testRestoresSpacedDesktopTableWithoutAppendingAnotherTable() throws {
        let fixture = try makeFixture(
            config: "[  desktop  ] # keep\nappearanceTheme = \"dark\"\n",
            appearanceTheme: "appearanceTheme = \"system\""
        )

        try SelectiveConfigRestore.restore(configURL: fixture.config, backupURL: fixture.backup)

        XCTAssertEqual(
            try String(contentsOf: fixture.config, encoding: .utf8),
            "[  desktop  ] # keep\nappearanceTheme = \"system\"\n"
        )
    }

#if !canImport(XCTest)
    @Test
#endif
    func testRejectsQuotedDesktopTableInsteadOfAppendingDuplicate() throws {
        try assertRejected(config: "[\"desktop\"]\nkeep = true\n")
    }

#if !canImport(XCTest)
    @Test
#endif
    func testRejectsIndentedAppearanceKeyInsteadOfAppendingDuplicate() throws {
        try assertRejected(config: "[desktop]\n  appearanceTheme = \"dark\"\n")
    }

#if !canImport(XCTest)
    @Test
#endif
    func testRejectsQuotedAppearanceKeyInsteadOfAppendingDuplicate() throws {
        try assertRejected(config: "[desktop]\n\"appearanceTheme\" = \"dark\"\n")
    }

#if !canImport(XCTest)
    @Test
#endif
    func testRejectsEscapedQuotedDesktopTableInsteadOfAppendingDuplicate() throws {
        try assertRejected(config: "[\"desk\\u0074op\"]\nkeep = true\n")
    }

#if !canImport(XCTest)
    @Test
#endif
    func testRejectsEscapedQuotedAppearanceKeyInsteadOfAppendingDuplicate() throws {
        try assertRejected(config: "[desktop]\n\"\\u0061ppearanceTheme\" = \"dark\"\n")
    }

#if !canImport(XCTest)
    @Test
#endif
    func testRejectsUnsupportedTargetStructuresAndDesktopAliases() throws {
        let targetKeys = [
            "appearanceTheme",
            "appearanceLightCodeThemeId",
            "appearanceDarkCodeThemeId",
        ]
        for key in targetKeys {
            try assertRejected(config: "[desktop]\n\(key).variant = \"dark\"\n")
            try assertRejected(config: "[desktop]\n\"\(key)\".variant = \"dark\"\n")
            try assertRejected(config: "[desktop]\n\(key) = { variant = \"dark\" }\n")
            try assertRejected(config: "desktop.\(key) = \"dark\"\n")
        }

        for config in [
            "desktop = { appearanceTheme = \"dark\" }\n",
            "\"desktop\".appearanceTheme = \"dark\"\n",
            "\"desktop\" = { appearanceTheme = \"dark\" }\n",
            "[[desktop]]\nappearanceTheme = \"dark\"\n",
            "[desktop.appearanceTheme]\nvariant = \"dark\"\n",
            "[\"desktop\".appearanceTheme]\nvariant = \"dark\"\n",
            "[\"desk\\u0074op\".appearanceTheme]\nvariant = \"dark\"\n",
            "\"\\u0064esktop\".appearanceTheme = \"dark\"\n",
        ] {
            try assertRejected(config: config)
        }
    }

#if !canImport(XCTest)
    @Test
#endif
    func testPreservesUnrelatedEscapedKeys() throws {
        let fixture = try makeFixture(
            config: "\"\\u006dodel\" = \"gpt-5\"\n[desktop]\n\"\\u006bkeep\" = \"value\"\n",
            appearanceTheme: "appearanceTheme = \"system\""
        )

        try SelectiveConfigRestore.restore(configURL: fixture.config, backupURL: fixture.backup)

        XCTAssertEqual(
            try String(contentsOf: fixture.config, encoding: .utf8),
            "\"\\u006dodel\" = \"gpt-5\"\n[desktop]\n\"\\u006bkeep\" = \"value\"\nappearanceTheme = \"system\"\n"
        )
    }

#if !canImport(XCTest)
    @Test
#endif
    func testRejectsMultilineStrings() throws {
        try assertRejected(config: "note = \"\"\"value\ncontinued\"\"\"\n[desktop]\nkeep = true\n")
    }

#if !canImport(XCTest)
    @Test
#endif
    func testRejectsMultilineArrays() throws {
        try assertRejected(config: "[desktop]\nrows = [\n  [\"one\", \"two\"],\n]\nappearanceTheme = \"dark\"\n")
    }

#if !canImport(XCTest)
    @Test
#endif
    func testRejectsUnexpectedBackupKey() throws {
        try assertRejectedBackup(values: [
            "appearanceTheme": NSNull(),
            "appearanceDarkCodeThemeId": NSNull(),
            "model": "model = \"unsafe\"",
        ])
    }

#if !canImport(XCTest)
    @Test
#endif
    func testRejectsBackupAssignmentForAnotherKey() throws {
        try assertRejectedBackup(values: [
            "appearanceTheme": "model = \"unsafe\"",
            "appearanceDarkCodeThemeId": NSNull(),
        ])
    }

#if !canImport(XCTest)
    @Test
#endif
    func testRejectsBackupAssignmentContainingNewline() throws {
        try assertRejectedBackup(values: [
            "appearanceTheme": "appearanceTheme = \"dark\"\nmodel = \"unsafe\"",
            "appearanceDarkCodeThemeId": NSNull(),
        ])
    }

#if !canImport(XCTest)
    @Test
#endif
    func testAcceptsCompleteSingleLineStringBackupAssignments() throws {
        let assignments = [
            "appearanceTheme = \"\"",
            "appearanceTheme = ''",
            "appearanceTheme\t=\t\"dark\\tmode\\u0021\"\t# keep escaped content",
            "appearanceTheme = \"dark \\\"quoted\\\" \\\\ path\" # keep comment",
            "appearanceTheme = \"emoji: \\U0001F600\"",
            "appearanceTheme = 'dark # literal \\q'",
            "appearanceTheme = 'literal value'\t",
        ]

        for assignment in assignments {
            let fixture = try makeFixture(
                config: "[desktop]\nkeepMe = true\n",
                appearanceTheme: assignment
            )

            try SelectiveConfigRestore.restore(configURL: fixture.config, backupURL: fixture.backup)

            XCTAssertEqual(
                try String(contentsOf: fixture.config, encoding: .utf8),
                "[desktop]\nkeepMe = true\n\(assignment)\n"
            )
            XCTAssertTrue(fileManager.fileExists(atPath: fixture.backup.path))
        }
    }

#if !canImport(XCTest)
    @Test
#endif
    func testRejectsNonStringAndMalformedBackupAssignments() throws {
        let assignments = [
            "appearanceTheme =",
            "appearanceTheme =   # no value",
            "appearanceTheme = \"unterminated",
            "appearanceTheme = 'unterminated",
            "appearanceTheme = 1",
            "appearanceTheme = true",
            "appearanceTheme = []",
            "appearanceTheme = {}",
            "appearanceTheme = \"\"\"multiline\"\"\"",
            "appearanceTheme = '' extra",
            "appearanceTheme = \"dark\" extra",
            "\"appearanceTheme\" = \"dark\"",
            "appearanceDarkCodeThemeId = \"dark\"",
            "appearanceThemeExtra = \"dark\"",
            " appearanceTheme = \"dark\"",
            "appearanceTheme = \"bad\\q\"",
            "appearanceTheme = \"\\u123\"",
            "appearanceTheme = \"\\uD800\"",
            "appearanceTheme = \"\\U00110000\"",
            "appearanceTheme = 'can't'",
            "appearanceTheme = \"dark\"\r",
            "appearanceTheme = \"dark\"\nmodel = \"unsafe\"",
            "appearanceTheme = \"dark\nunsafe\"",
            "appearanceTheme = \"dark\u{2028}unsafe\"",
            "appearanceTheme = \"dark\u{2029}unsafe\"",
        ]

        for assignment in assignments {
            try assertRejectedBackup(values: [
                "appearanceTheme": assignment,
                "appearanceDarkCodeThemeId": NSNull(),
            ])
        }
    }

#if !canImport(XCTest)
    @Test
#endif
    func testRejectsBackupWithWrongSchemaIdentity() throws {
        let fixture = try makeFixture(config: "[desktop]\nkeep = true\n")
        try writeBackup(
            at: fixture.backup,
            configURL: fixture.config,
            values: defaultValues,
            overrides: ["schemaVersion": 2]
        )
        let original = try Data(contentsOf: fixture.config)

        XCTAssertThrowsError(try SelectiveConfigRestore.restore(configURL: fixture.config, backupURL: fixture.backup))
        XCTAssertEqual(try Data(contentsOf: fixture.config), original)
        XCTAssertTrue(fileManager.fileExists(atPath: fixture.backup.path))
    }

#if !canImport(XCTest)
    @Test
#endif
    func testRejectsBackupJSONWithUTF8BOM() throws {
        let fixture = try makeFixture(config: "[desktop]\nkeep = true\n")
        let backup = try Data(contentsOf: fixture.backup)
        try (Data([0xef, 0xbb, 0xbf]) + backup).write(to: fixture.backup)
        let original = try Data(contentsOf: fixture.config)

        XCTAssertThrowsError(try SelectiveConfigRestore.restore(configURL: fixture.config, backupURL: fixture.backup))
        XCTAssertEqual(try Data(contentsOf: fixture.config), original)
        XCTAssertTrue(fileManager.fileExists(atPath: fixture.backup.path))
    }

#if !canImport(XCTest)
    @Test
#endif
    func testRejectsConfigByteChangeBeforeRename() async throws {
        let padding = String(repeating: "# keep this content 中文\n", count: 750_000)
        let original = Data((padding + "[desktop]\nappearanceTheme = \"dark\"\n").utf8)
        let fixture = try makeFixture(
            configBytes: original,
            appearanceTheme: "appearanceTheme = \"system\"",
            appearanceDarkCodeThemeId: nil
        )
        let config = fixture.config
        let backup = fixture.backup
        let task = Task.detached { () -> Bool in
            do {
                try SelectiveConfigRestore.restore(configURL: config, backupURL: backup)
                return false
            } catch {
                return true
            }
        }
        let deadline = Date().addingTimeInterval(10)
        var sawTemporary = false
        while Date() < deadline {
            let entries = try fileManager.contentsOfDirectory(atPath: fixture.directory.path)
            if entries.contains(where: { $0.hasPrefix("config.toml.") && $0.hasSuffix(".tmp") }) {
                sawTemporary = true
                break
            }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertTrue(sawTemporary, "restore did not reach its same-directory temporary write")
        let concurrentBytes = Data("model = \"changed concurrently\"\n".utf8)
        try concurrentBytes.write(to: config, options: .atomic)

        let restoreWasRejected = await task.value
        XCTAssertTrue(restoreWasRejected)
        XCTAssertEqual(try Data(contentsOf: config), concurrentBytes)
        XCTAssertTrue(fileManager.fileExists(atPath: backup.path))
        XCTAssertFalse(fileManager.fileExists(atPath: config.path + ".dream-skin.lock"))
    }

#if !canImport(XCTest)
    @Test
#endif
    func testMissingBackupDoesNotChangeConfig() throws {
        let directory = try makeTemporaryDirectory()
        let config = directory.appendingPathComponent("config.toml")
        let backup = directory.appendingPathComponent("missing.json")
        let original = Data("[desktop]\nappearanceTheme = \"dark\"\n".utf8)
        try original.write(to: config)

        XCTAssertThrowsError(try SelectiveConfigRestore.restore(configURL: config, backupURL: backup))
        XCTAssertEqual(try Data(contentsOf: config), original)
        XCTAssertFalse(fileManager.fileExists(atPath: config.path + ".dream-skin.lock"))
    }

#if !canImport(XCTest)
    @Test
#endif
    func testRejectsSymlinkedBackupWithoutChangingConfigOrTarget() throws {
        let fixture = try makeFixture(
            config: "[desktop]\nappearanceTheme = \"dream-skin\"\nkeepMe = true\n",
            appearanceTheme: "appearanceTheme = \"system\""
        )
        let target = fixture.directory.appendingPathComponent("theme-backup-target.json")
        try fileManager.moveItem(at: fixture.backup, to: target)
        try fileManager.createSymbolicLink(at: fixture.backup, withDestinationURL: target)
        let originalConfig = try Data(contentsOf: fixture.config)
        let originalTarget = try Data(contentsOf: target)

        XCTAssertThrowsError(try SelectiveConfigRestore.restore(configURL: fixture.config, backupURL: fixture.backup))
        XCTAssertEqual(try Data(contentsOf: fixture.config), originalConfig)
        XCTAssertEqual(try Data(contentsOf: target), originalTarget)
        XCTAssertEqual(
            try fileManager.destinationOfSymbolicLink(atPath: fixture.backup.path),
            target.path
        )
    }

#if !canImport(XCTest)
    @Test
#endif
    func testSavedSettingCreatesMissingDesktopTable() throws {
        let fixture = try makeFixture(
            config: "model = \"gpt-5\"\nkeepMe = true\n",
            appearanceTheme: "appearanceTheme = \"system\"",
            appearanceDarkCodeThemeId: nil
        )

        try SelectiveConfigRestore.restore(configURL: fixture.config, backupURL: fixture.backup)

        XCTAssertEqual(
            try String(contentsOf: fixture.config, encoding: .utf8),
            "model = \"gpt-5\"\nkeepMe = true\n\n[desktop]\nappearanceTheme = \"system\"\n"
        )
    }

#if !canImport(XCTest)
    @Test
#endif
    func testSavedSettingCreatesMissingDesktopTableWithCRLF() throws {
        let fixture = try makeFixture(
            config: "model = \"gpt-5\"\r\nkeepMe = true\r\n",
            appearanceTheme: "appearanceTheme = \"system\""
        )

        try SelectiveConfigRestore.restore(configURL: fixture.config, backupURL: fixture.backup)

        XCTAssertEqual(
            try String(contentsOf: fixture.config, encoding: .utf8),
            "model = \"gpt-5\"\r\nkeepMe = true\r\n\r\n[desktop]\r\nappearanceTheme = \"system\"\r\n"
        )
    }

#if !canImport(XCTest)
    @Test
#endif
    func testSavedSettingUsesCRLFInEmptyDesktopTable() throws {
        let fixture = try makeFixture(
            config: "model = \"gpt-5\"\r\n\r\n[desktop]\r\n",
            appearanceTheme: "appearanceTheme = \"system\""
        )

        try SelectiveConfigRestore.restore(configURL: fixture.config, backupURL: fixture.backup)

        XCTAssertEqual(
            try String(contentsOf: fixture.config, encoding: .utf8),
            "model = \"gpt-5\"\r\n\r\n[desktop]\r\nappearanceTheme = \"system\"\r\n"
        )
    }

#if !canImport(XCTest)
    @Test
#endif
    func testAllNullSettingsWithoutDesktopPreserveBackupWithoutRewritingConfig() throws {
        let fixture = try makeFixture(config: "model = \"gpt-5\"\nkeepMe = true\n")
        let originalIdentity = try fileIdentity(fixture.config)

        try SelectiveConfigRestore.restore(configURL: fixture.config, backupURL: fixture.backup)

        XCTAssertEqual(try String(contentsOf: fixture.config, encoding: .utf8), "model = \"gpt-5\"\nkeepMe = true\n")
        XCTAssertEqual(try fileIdentity(fixture.config), originalIdentity)
        XCTAssertTrue(fileManager.fileExists(atPath: fixture.backup.path))
    }

#if !canImport(XCTest)
    @Test
#endif
    func testSuccessfulRestoreAtomicallyReplacesConfigAndPreservesBackupForLifecycleCommit() throws {
        let fixture = try makeFixture(
            config: "[desktop]\nappearanceTheme = \"dark\"\nkeepMe = true\n",
            appearanceTheme: "appearanceTheme = \"system\"",
            appearanceDarkCodeThemeId: nil
        )
        try fileManager.setAttributes([.posixPermissions: 0o640], ofItemAtPath: fixture.config.path)
        let originalIdentity = try fileIdentity(fixture.config)

        try SelectiveConfigRestore.restore(configURL: fixture.config, backupURL: fixture.backup)

        XCTAssertEqual(try String(contentsOf: fixture.config, encoding: .utf8), "[desktop]\nappearanceTheme = \"system\"\nkeepMe = true\n")
        XCTAssertNotEqual(try fileIdentity(fixture.config), originalIdentity)
        XCTAssertEqual(try posixPermissions(fixture.config), 0o640)
        XCTAssertTrue(fileManager.fileExists(atPath: fixture.backup.path))
        XCTAssertFalse(fileManager.fileExists(atPath: fixture.config.path + ".dream-skin.lock"))
        XCTAssertFalse(try fileManager.contentsOfDirectory(atPath: fixture.directory.path).contains { $0.hasSuffix(".tmp") })
    }

#if !canImport(XCTest)
    @Test
#endif
    func testArchiveCommitConsumesExactStagedBackup() throws {
        let directory = try makeTemporaryDirectory()
        let staged = directory.appendingPathComponent("theme-backup.stage.json")
        let destination = directory.appendingPathComponent("theme-backup.restored.json")
        let original = Data("original recovery bytes\n".utf8)
        try original.write(to: staged)

        try SelectiveConfigRestore.archiveBackup(
            stagedURL: staged,
            destinationURL: destination,
            expectedIdentity: try archiveIdentity(staged)
        )

        XCTAssertFalse(fileManager.fileExists(atPath: staged.path))
        XCTAssertEqual(try Data(contentsOf: destination), original)
        XCTAssertFalse(try fileManager.contentsOfDirectory(atPath: directory.path).contains { $0.hasSuffix(".tmp") })
    }

#if !canImport(XCTest)
    @Test
#endif
    func testArchiveRejectsStagedPathReplacementAfterHoldingOriginalIdentity() throws {
        let directory = try makeTemporaryDirectory()
        let staged = directory.appendingPathComponent("theme-backup.stage.json")
        let displaced = directory.appendingPathComponent("theme-backup.displaced.json")
        let destination = directory.appendingPathComponent("theme-backup.restored.json")
        let original = Data("original recovery bytes\n".utf8)
        let replacement = Data("replacement bytes\n".utf8)
        try original.write(to: staged)
        let expectedIdentity = try archiveIdentity(staged)

        XCTAssertThrowsError(try SelectiveConfigRestore.archiveBackup(
            stagedURL: staged,
            destinationURL: destination,
            expectedIdentity: expectedIdentity,
            beforeCommit: {
                try self.fileManager.moveItem(at: staged, to: displaced)
                try replacement.write(to: staged)
            }
        ))

        XCTAssertEqual(try Data(contentsOf: displaced), original)
        XCTAssertEqual(try Data(contentsOf: staged), replacement)
        XCTAssertFalse(fileManager.fileExists(atPath: destination.path))
        XCTAssertFalse(try fileManager.contentsOfDirectory(atPath: directory.path).contains { $0.hasSuffix(".tmp") })
    }

#if !canImport(XCTest)
    @Test
#endif
    func testArchiveRejectsStagedPathReplacementAfterArchiveCommitBeforeCleanup() throws {
        let directory = try makeTemporaryDirectory()
        let staged = directory.appendingPathComponent("theme-backup.stage.json")
        let displaced = directory.appendingPathComponent("theme-backup.displaced.json")
        let destination = directory.appendingPathComponent("theme-backup.restored.json")
        let original = Data("original recovery bytes\n".utf8)
        let replacement = Data("replacement bytes\n".utf8)
        try original.write(to: staged)

        XCTAssertThrowsError(try SelectiveConfigRestore.archiveBackup(
            stagedURL: staged,
            destinationURL: destination,
            expectedIdentity: try archiveIdentity(staged),
            beforeCleanup: {
                try self.fileManager.moveItem(at: staged, to: displaced)
                try replacement.write(to: staged)
            }
        ))

        XCTAssertEqual(try Data(contentsOf: destination), original)
        XCTAssertEqual(try Data(contentsOf: displaced), original)
        XCTAssertEqual(try Data(contentsOf: staged), replacement)
    }

#if !canImport(XCTest)
    @Test
#endif
    func testArchiveQuarantinePreservesReplacementAfterFinalPathCheck() throws {
        let directory = try makeTemporaryDirectory()
        let staged = directory.appendingPathComponent("theme-backup.stage.json")
        let displaced = directory.appendingPathComponent("theme-backup.displaced.json")
        let destination = directory.appendingPathComponent("theme-backup.restored.json")
        let original = Data("original recovery bytes\n".utf8)
        let replacement = Data("replacement bytes\n".utf8)
        try original.write(to: staged)

        XCTAssertThrowsError(try SelectiveConfigRestore.archiveBackup(
            stagedURL: staged,
            destinationURL: destination,
            expectedIdentity: try archiveIdentity(staged),
            beforeQuarantine: {
                try self.fileManager.moveItem(at: staged, to: displaced)
                try replacement.write(to: staged)
            }
        ))

        XCTAssertEqual(try Data(contentsOf: destination), original)
        XCTAssertEqual(try Data(contentsOf: displaced), original)
        XCTAssertEqual(try Data(contentsOf: staged), replacement)
        XCTAssertFalse(try fileManager.contentsOfDirectory(atPath: directory.path).contains {
            $0.contains(".cleanup.")
        })
    }

#if !canImport(XCTest)
    @Test
#endif
    func testArchiveRejectsDestinationDirectoryRaceWithoutMovingBackupInsideIt() throws {
        let directory = try makeTemporaryDirectory()
        let staged = directory.appendingPathComponent("theme-backup.stage.json")
        let destination = directory.appendingPathComponent("theme-backup.restored.json", isDirectory: true)
        let original = Data("original recovery bytes\n".utf8)
        try original.write(to: staged)
        let expectedIdentity = try archiveIdentity(staged)

        XCTAssertThrowsError(try SelectiveConfigRestore.archiveBackup(
            stagedURL: staged,
            destinationURL: destination,
            expectedIdentity: expectedIdentity,
            beforeCommit: {
                try self.fileManager.createDirectory(at: destination, withIntermediateDirectories: false)
            }
        ))

        XCTAssertEqual(try Data(contentsOf: staged), original)
        XCTAssertTrue(fileManager.fileExists(atPath: destination.path))
        XCTAssertTrue(try fileManager.contentsOfDirectory(atPath: destination.path).isEmpty)
        XCTAssertFalse(try fileManager.contentsOfDirectory(atPath: directory.path).contains { $0.hasSuffix(".tmp") })
    }

#if !canImport(XCTest)
    @Test
#endif
    func testRetirementConsumesExactLiveBackupAfterVerifyingArchive() throws {
        let directory = try makeTemporaryDirectory()
        let live = directory.appendingPathComponent("theme-backup.json")
        let archive = directory.appendingPathComponent("theme-backup.restored.json")
        let original = Data("original recovery bytes\n".utf8)
        try original.write(to: live)
        try original.write(to: archive)

        try SelectiveConfigRestore.retireBackup(
            liveURL: live,
            archiveURL: archive,
            expectedIdentity: try archiveIdentity(live)
        )

        XCTAssertFalse(fileManager.fileExists(atPath: live.path))
        XCTAssertEqual(try Data(contentsOf: archive), original)
    }

#if !canImport(XCTest)
    @Test
#endif
    func testRetirementPreservesReplacementAfterFinalLiveProof() throws {
        let directory = try makeTemporaryDirectory()
        let live = directory.appendingPathComponent("theme-backup.json")
        let displaced = directory.appendingPathComponent("theme-backup.displaced.json")
        let archive = directory.appendingPathComponent("theme-backup.restored.json")
        let original = Data("original recovery bytes\n".utf8)
        let replacement = Data("replacement bytes\n".utf8)
        try original.write(to: live)
        try original.write(to: archive)

        XCTAssertThrowsError(try SelectiveConfigRestore.retireBackup(
            liveURL: live,
            archiveURL: archive,
            expectedIdentity: try archiveIdentity(live),
            beforeQuarantine: {
                try self.fileManager.moveItem(at: live, to: displaced)
                try replacement.write(to: live)
            }
        ))

        XCTAssertEqual(try Data(contentsOf: archive), original)
        XCTAssertEqual(try Data(contentsOf: displaced), original)
        XCTAssertEqual(try Data(contentsOf: live), replacement)
    }

#if !canImport(XCTest)
    @Test
#endif
    func testRetirementRetainsQuarantineOnNoReplaceRecoveryConflict() throws {
        let directory = try makeTemporaryDirectory()
        let live = directory.appendingPathComponent("theme-backup.json")
        let archive = directory.appendingPathComponent("theme-backup.restored.json")
        let original = Data("original recovery bytes\n".utf8)
        let conflict = Data("unexpected live bytes\n".utf8)
        try original.write(to: live)
        try original.write(to: archive)

        XCTAssertThrowsError(try SelectiveConfigRestore.retireBackup(
            liveURL: live,
            archiveURL: archive,
            expectedIdentity: try archiveIdentity(live),
            afterQuarantine: {
                try conflict.write(to: live)
            }
        ))

        XCTAssertEqual(try Data(contentsOf: archive), original)
        XCTAssertEqual(try Data(contentsOf: live), conflict)
        let quarantine = try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .first { $0.lastPathComponent.contains(".cleanup.") }
        XCTAssertTrue(quarantine != nil)
        if let quarantine { XCTAssertEqual(try Data(contentsOf: quarantine), original) }
    }

#if !canImport(XCTest)
    @Test
#endif
    func testRetirementRestoresLiveWhenArchiveChangesBeforeConsumption() throws {
        let directory = try makeTemporaryDirectory()
        let live = directory.appendingPathComponent("theme-backup.json")
        let archive = directory.appendingPathComponent("theme-backup.restored.json")
        let displacedArchive = directory.appendingPathComponent("theme-backup.restored.displaced.json")
        let original = Data("original recovery bytes\n".utf8)
        let replacement = Data("replacement archive bytes\n".utf8)
        try original.write(to: live)
        try original.write(to: archive)

        XCTAssertThrowsError(try SelectiveConfigRestore.retireBackup(
            liveURL: live,
            archiveURL: archive,
            expectedIdentity: try archiveIdentity(live),
            afterQuarantine: {
                try self.fileManager.moveItem(at: archive, to: displacedArchive)
                try replacement.write(to: archive)
            }
        ))

        XCTAssertEqual(try Data(contentsOf: live), original)
        XCTAssertEqual(try Data(contentsOf: displacedArchive), original)
        XCTAssertEqual(try Data(contentsOf: archive), replacement)
    }

    private var defaultValues: [String: Any] {
        [
            "appearanceTheme": NSNull(),
            "appearanceDarkCodeThemeId": NSNull(),
        ]
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("dream-skin-config-restore-tests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: false)
        addTeardownBlock { try? self.fileManager.removeItem(at: directory) }
        return directory
    }

    private func makeFixture(
        config: String,
        appearanceTheme: String? = nil,
        appearanceDarkCodeThemeId: String? = nil
    ) throws -> (directory: URL, config: URL, backup: URL) {
        try makeFixture(
            configBytes: Data(config.utf8),
            appearanceTheme: appearanceTheme,
            appearanceDarkCodeThemeId: appearanceDarkCodeThemeId
        )
    }

    private func makeFixture(
        configBytes: Data,
        appearanceTheme: String? = nil,
        appearanceDarkCodeThemeId: String? = nil
    ) throws -> (directory: URL, config: URL, backup: URL) {
        let directory = try makeTemporaryDirectory()
        let config = directory.appendingPathComponent("config.toml")
        let backup = directory.appendingPathComponent("theme-backup.json")
        try configBytes.write(to: config)
        try writeBackup(
            at: backup,
            configURL: config,
            values: [
                "appearanceTheme": appearanceTheme ?? NSNull(),
                "appearanceDarkCodeThemeId": appearanceDarkCodeThemeId ?? NSNull(),
            ]
        )
        return (directory, config, backup)
    }

    private func writeBackup(
        at backupURL: URL,
        configURL: URL,
        values: [String: Any]? = nil,
        overrides: [String: Any] = [:]
    ) throws {
        var backup: [String: Any] = [
            "schemaVersion": 1,
            "platform": "darwin",
            "configPath": configURL.path,
            "values": values ?? defaultValues,
        ]
        for (key, value) in overrides {
            backup[key] = value
        }
        try JSONSerialization.data(withJSONObject: backup).write(to: backupURL)
    }

    private func assertRejected(config: String) throws {
        try assertRejected(configBytes: Data(config.utf8))
    }

    private func assertRejected(configBytes: Data) throws {
        let fixture = try makeFixture(configBytes: configBytes)
        let original = try Data(contentsOf: fixture.config)
        let originalBackup = try Data(contentsOf: fixture.backup)

        XCTAssertThrowsError(try SelectiveConfigRestore.restore(configURL: fixture.config, backupURL: fixture.backup))
        XCTAssertEqual(try Data(contentsOf: fixture.config), original)
        XCTAssertEqual(try Data(contentsOf: fixture.backup), originalBackup)
        XCTAssertFalse(fileManager.fileExists(atPath: fixture.config.path + ".dream-skin.lock"))
    }

    private func assertRejectedBackup(values: [String: Any]) throws {
        let fixture = try makeFixture(config: "[desktop]\nkeepMe = true\n")
        try writeBackup(at: fixture.backup, configURL: fixture.config, values: values)
        let original = try Data(contentsOf: fixture.config)

        XCTAssertThrowsError(try SelectiveConfigRestore.restore(configURL: fixture.config, backupURL: fixture.backup))
        XCTAssertEqual(try Data(contentsOf: fixture.config), original)
        XCTAssertTrue(fileManager.fileExists(atPath: fixture.backup.path))
    }

    private func fileIdentity(_ url: URL) throws -> String {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        return "\(attributes[.systemNumber]!)\(attributes[.systemFileNumber]!)"
    }

    private func archiveIdentity(_ url: URL) throws -> String {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        return "\(attributes[.systemNumber]!):\(attributes[.systemFileNumber]!)"
    }

    private func posixPermissions(_ url: URL) throws -> Int {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as! NSNumber).intValue
    }
}
