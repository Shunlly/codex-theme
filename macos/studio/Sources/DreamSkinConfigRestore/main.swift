import Darwin
import DreamSkinConfigRestoreCore
import Foundation

do {
    if CommandLine.arguments.count == 5 && CommandLine.arguments[1] == "--archive-backup" {
        try SelectiveConfigRestore.archiveBackup(
            stagedURL: URL(fileURLWithPath: CommandLine.arguments[2]),
            destinationURL: URL(fileURLWithPath: CommandLine.arguments[3]),
            expectedIdentity: CommandLine.arguments[4]
        )
    } else if CommandLine.arguments.count == 5 && CommandLine.arguments[1] == "--retire-backup" {
        try SelectiveConfigRestore.retireBackup(
            liveURL: URL(fileURLWithPath: CommandLine.arguments[2]),
            archiveURL: URL(fileURLWithPath: CommandLine.arguments[3]),
            expectedIdentity: CommandLine.arguments[4]
        )
    } else if CommandLine.arguments.count == 3 {
        try SelectiveConfigRestore.restore(
            configURL: URL(fileURLWithPath: CommandLine.arguments[1]),
            backupURL: URL(fileURLWithPath: CommandLine.arguments[2])
        )
        print("Restored the saved base-theme keys.")
    } else {
        fputs("Usage: dream-skin-config-restore <config-path> <backup-path> | <--archive-backup|--retire-backup> <backup-path> <archive-path> <expected-identity>\n", stderr)
        exit(64)
    }
} catch {
    fputs("Codex Dream Skin Studio: \(error.localizedDescription)\n", stderr)
    exit(1)
}
