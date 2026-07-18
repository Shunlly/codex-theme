import Darwin
import DreamSkinConfigRestoreCore
import Foundation

guard CommandLine.arguments.count == 3 else {
    fputs("Usage: dream-skin-config-restore <config-path> <backup-path>\n", stderr)
    exit(64)
}

do {
    try SelectiveConfigRestore.restore(
        configURL: URL(fileURLWithPath: CommandLine.arguments[1]),
        backupURL: URL(fileURLWithPath: CommandLine.arguments[2])
    )
    print("Restored the saved base-theme keys.")
} catch {
    fputs("Codex Dream Skin Studio: \(error.localizedDescription)\n", stderr)
    exit(1)
}
