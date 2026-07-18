import Darwin
import Foundation

public enum SelectiveConfigRestore {
    private static let settingKeys = ["appearanceTheme", "appearanceDarkCodeThemeId"]

    public static func restore(configURL: URL, backupURL: URL) throws {
        let lock = try ConfigLock(configURL: configURL)
        defer { lock.release() }

        let originalBytes: Data
        do {
            originalBytes = try Data(contentsOf: configURL)
        } catch where isNoSuchFile(error) {
            throw RestoreError("Codex config not found: \(configURL.path)")
        }
        var content = try decodeStrictUTF8(originalBytes, label: "Codex config")
        let originalStat = try regularFileStat(
            at: configURL,
            invalidMessage: "Codex config must be a regular file, not a symbolic link."
        )
        guard !content.contains("\"\"\"") && !content.contains("'''") else {
            throw RestoreError("Refusing to rewrite TOML containing multiline strings.")
        }
        try assertSupportedTOMLLayout(content)
        try assertNoAmbiguousDesktopTables(content)
        var section = try desktopSection(content)
        let preferredNewline = content.contains("\r\n") ? "\r\n" : "\n"

        let backupBytes: Data
        do {
            backupBytes = try Data(contentsOf: backupURL)
        } catch where isNoSuchFile(error) {
            throw RestoreError("No selective pre-install theme backup is available.")
        } catch {
            throw RestoreError("Could not read the theme backup: \(error.localizedDescription)")
        }
        let backupContent: String
        do {
            backupContent = try decodeStrictUTF8(backupBytes, label: "Theme backup")
            if backupContent.hasPrefix("\u{feff}") {
                throw RestoreError("Theme backup JSON contains a UTF-8 BOM.")
            }
        } catch {
            throw RestoreError("Could not read the theme backup: \(error.localizedDescription)")
        }
        let values: [String: String?]
        do {
            let object = try JSONSerialization.jsonObject(with: Data(backupContent.utf8))
            values = try validateBackup(object, configURL: configURL)
        } catch let error as RestoreError {
            throw error
        } catch {
            throw RestoreError("Could not read the theme backup: \(error.localizedDescription)")
        }

        if section == nil {
            if !settingKeys.contains(where: { values[$0] ?? nil != nil }) {
                try assertConfigUnchanged(
                    at: configURL,
                    expectedBytes: originalBytes,
                    expectedStat: originalStat
                )
                try removeBackup(backupURL)
                return
            }
            content = trimEnd(content) + preferredNewline + preferredNewline + "[desktop]" + preferredNewline
            section = try desktopSection(content)
        }

        guard let section else {
            throw RestoreError("Could not locate the [desktop] table.")
        }
        var body = String(content[section.bodyRange])
        try assertNoAmbiguousSettings(body)
        for key in settingKeys {
            body = try replaceSetting(
                in: body,
                key: key,
                line: values[key] ?? nil,
                preferredNewline: preferredNewline
            )
        }
        let restored = String(content[..<section.bodyRange.lowerBound])
            + body
            + String(content[section.bodyRange.upperBound...])

        try assertConfigUnchanged(
            at: configURL,
            expectedBytes: originalBytes,
            expectedStat: originalStat
        )
        try atomicWrite(
            Data(restored.utf8),
            to: configURL,
            mode: mode_t(originalStat.st_mode & 0o777),
            expectedBytes: originalBytes,
            expectedStat: originalStat
        )
        try removeBackup(backupURL)
    }

    private static func decodeStrictUTF8(_ data: Data, label: String) throws -> String {
        let bom = Data([0xef, 0xbb, 0xbf])
        let payload = data.starts(with: bom) ? data.dropFirst(bom.count) : data[...]
        guard let decoded = String(data: payload, encoding: .utf8), Data(decoded.utf8) == payload else {
            throw RestoreError("\(label) is not valid UTF-8; nothing was changed.")
        }
        let content = data.starts(with: bom) ? "\u{feff}" + decoded : decoded
        guard !content.contains("\0") else {
            throw RestoreError("\(label) contains NUL characters; nothing was changed.")
        }
        return content
    }

    private struct DesktopSection {
        let bodyRange: Range<String.Index>
    }

    private static func desktopSection(_ content: String) throws -> DesktopSection? {
        let headerPattern = #"(?m)^(?:\x{FEFF})?[\t ]*\[[\t ]*desktop[\t ]*\][\t ]*(?:#[^\r\n]*)?(?:\r?\n|$)"#
        let headerRegex = try NSRegularExpression(pattern: headerPattern)
        let fullRange = NSRange(content.startIndex..<content.endIndex, in: content)
        let headers = headerRegex.matches(in: content, range: fullRange)
        guard headers.count <= 1 else {
            throw RestoreError("Refusing to rewrite multiple [desktop] tables.")
        }
        guard let header = headers.first, let headerRange = Range(header.range, in: content) else {
            return nil
        }
        let bodyStart = headerRange.upperBound
        let remainderRange = NSRange(bodyStart..<content.endIndex, in: content)
        let nextHeader = try NSRegularExpression(pattern: #"(?m)^[\t ]*\["#)
            .firstMatch(in: content, range: remainderRange)
            .flatMap { Range($0.range, in: content) }
        return DesktopSection(bodyRange: bodyStart..<(nextHeader?.lowerBound ?? content.endIndex))
    }

    private static func assertSupportedTOMLLayout(_ content: String) throws {
        for rawLine in content.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = String(rawLine)
            if line.hasSuffix("\r") { line.removeLast() }
            let structure = tomlStructure(for: line)
            guard let assignment = structure.firstIndex(of: "=") else { continue }
            var depth = 0
            for character in structure[structure.index(after: assignment)...] {
                if character == "[" { depth += 1 }
                if character == "]" { depth -= 1 }
            }
            if depth > 0 {
                throw RestoreError("Refusing to rewrite TOML containing multiline arrays.")
            }
        }
    }

    private static func assertNoAmbiguousDesktopTables(_ content: String) throws {
        let patterns = [
            #"(?m)^(?:\x{FEFF})?[\t ]*\[[\t ]*[\"']desktop[\"'][\t ]*\][\t ]*(?:#[^\r\n]*)?(?:\r?\n|$)"#,
            #"(?m)^(?:\x{FEFF})?[\t ]*\[[\t ]*\"[^\"\r\n]*\\[^\"\r\n]*\"[\t ]*\][\t ]*(?:#[^\r\n]*)?(?:\r?\n|$)"#,
        ]
        let range = NSRange(content.startIndex..<content.endIndex, in: content)
        for pattern in patterns where try NSRegularExpression(pattern: pattern).firstMatch(in: content, range: range) != nil {
            throw RestoreError("Refusing to rewrite a quoted or escaped [desktop] table.")
        }
    }

    private static func assertNoAmbiguousSettings(_ body: String) throws {
        let keys = settingKeys.map(NSRegularExpression.escapedPattern).joined(separator: "|")
        let patterns = [
            "(?m)^[\\t ]+(?:\(keys))[\\t ]*=",
            "(?m)^[\\t ]*[\\\"'](?:\(keys))[\\\"'][\\t ]*=",
            #"(?m)^[\t ]*\"[^\"\r\n]*\\[^\"\r\n]*\"[\t ]*="#,
        ]
        let range = NSRange(body.startIndex..<body.endIndex, in: body)
        for pattern in patterns where try NSRegularExpression(pattern: pattern).firstMatch(in: body, range: range) != nil {
            throw RestoreError("Refusing to rewrite quoted, escaped, or indented appearance settings.")
        }
    }

    private static func tomlStructure(for line: String) -> String {
        var result = ""
        var quote: Character?
        var escaped = false
        for character in line {
            if quote == "\"" {
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == quote {
                    quote = nil
                }
                continue
            }
            if quote == "'" {
                if character == quote { quote = nil }
                continue
            }
            if character == "\"" || character == "'" {
                quote = character
            } else if character == "#" {
                break
            } else {
                result.append(character)
            }
        }
        return result
    }

    private static func settingMatches(in body: String, key: String) throws -> [NSTextCheckingResult] {
        let pattern = "(?m)^\(NSRegularExpression.escapedPattern(for: key))[\\t ]*=.*$"
        let regex = try NSRegularExpression(pattern: pattern)
        let matches = regex.matches(in: body, range: NSRange(body.startIndex..<body.endIndex, in: body))
        guard matches.count <= 1 else {
            throw RestoreError("Refusing to rewrite duplicate \(key) settings.")
        }
        return matches
    }

    private static func replaceSetting(
        in body: String,
        key: String,
        line: String?,
        preferredNewline: String
    ) throws -> String {
        _ = try settingMatches(in: body, key: key)
        let token = NSRegularExpression.escapedPattern(for: key)
        let regex = try NSRegularExpression(pattern: "(?m)^\(token)[\\t ]*=.*(?:\\r?\\n)?")
        let fullRange = NSRange(body.startIndex..<body.endIndex, in: body)
        let match = regex.firstMatch(in: body, range: fullRange).flatMap { Range($0.range, in: body) }
        let newline = body.contains("\r\n") ? "\r\n" : preferredNewline

        guard let line else {
            guard let match else { return body }
            return String(body[..<match.lowerBound]) + String(body[match.upperBound...])
        }
        if let match {
            return String(body[..<match.lowerBound]) + line + newline + String(body[match.upperBound...])
        }
        let separator = !body.isEmpty && !body.hasSuffix("\n") ? newline : ""
        return body + separator + line + newline
    }

    private static func validateBackup(_ object: Any, configURL: URL) throws -> [String: String?] {
        guard
            let backup = object as? [String: Any],
            let schemaVersion = backup["schemaVersion"] as? NSNumber,
            CFGetTypeID(schemaVersion) != CFBooleanGetTypeID(),
            schemaVersion.intValue == 1,
            schemaVersion.doubleValue == 1,
            backup["platform"] as? String == "darwin",
            backup["configPath"] as? String == configURL.path,
            let rawValues = backup["values"] as? [String: Any]
        else {
            throw RestoreError("Theme backup identity or schema does not match this config; nothing was restored.")
        }
        guard Set(rawValues.keys) == Set(settingKeys), rawValues.count == settingKeys.count else {
            throw RestoreError("Theme backup contains unexpected or missing settings; nothing was restored.")
        }

        var values: [String: String?] = [:]
        for key in settingKeys {
            let rawLine = rawValues[key]
            if rawLine is NSNull {
                values[key] = nil
                continue
            }
            guard let line = rawLine as? String, validAssignment(line, key: key) else {
                throw RestoreError("Theme backup contains an invalid \(key) assignment; nothing was restored.")
            }
            values[key] = line
        }
        return values
    }

    private static func validAssignment(_ line: String, key: String) -> Bool {
        let invalidControls = CharacterSet(charactersIn: "\u{0000}"..."\u{0008}")
            .union(CharacterSet(charactersIn: "\u{000b}"..."\u{001f}"))
            .union(CharacterSet(charactersIn: "\u{007f}"..."\u{009f}"))
            .union(CharacterSet(charactersIn: "\u{2028}\u{2029}"))
        guard !line.contains("\n"), line.rangeOfCharacter(from: invalidControls) == nil else { return false }
        let scalars = Array(line.unicodeScalars)
        let keyScalars = Array(key.unicodeScalars)
        guard scalars.starts(with: keyScalars) else { return false }
        var index = keyScalars.count
        while index < scalars.count, scalars[index] == " " || scalars[index] == "\t" { index += 1 }
        guard index < scalars.count, scalars[index] == "=" else { return false }
        index += 1
        while index < scalars.count, scalars[index] == " " || scalars[index] == "\t" { index += 1 }
        guard let valueEnd = tomlStringEnd(scalars, start: index) else { return false }
        index = valueEnd
        while index < scalars.count, scalars[index] == " " || scalars[index] == "\t" { index += 1 }
        return index == scalars.count || scalars[index] == "#"
    }

    private static func tomlStringEnd(_ scalars: [Unicode.Scalar], start: Int) -> Int? {
        guard start < scalars.count, scalars[start] == "\"" || scalars[start] == "'" else { return nil }
        let quote = scalars[start]
        var index = start + 1
        while index < scalars.count {
            let scalar = scalars[index]
            if scalar == quote { return index + 1 }
            if quote == "\"", scalar == "\\" {
                index += 1
                guard index < scalars.count else { return nil }
                switch scalars[index] {
                case "\"", "\\", "b", "t", "n", "f", "r":
                    index += 1
                case "u", "U":
                    let digits = scalars[index] == "u" ? 4 : 8
                    guard index + digits < scalars.count else { return nil }
                    var value: UInt32 = 0
                    for offset in 1...digits {
                        guard let digit = hexDigitValue(scalars[index + offset]) else { return nil }
                        value = (value * 16) + digit
                    }
                    guard value <= 0x10ffff, !(0xd800...0xdfff).contains(value) else { return nil }
                    index += digits + 1
                default:
                    return nil
                }
            } else {
                index += 1
            }
        }
        return nil
    }

    private static func hexDigitValue(_ scalar: Unicode.Scalar) -> UInt32? {
        switch scalar.value {
        case 0x30...0x39: return scalar.value - 0x30
        case 0x41...0x46: return scalar.value - 0x41 + 10
        case 0x61...0x66: return scalar.value - 0x61 + 10
        default: return nil
        }
    }

    private static func trimEnd(_ content: String) -> String {
        var end = content.endIndex
        while end > content.startIndex {
            let previous = content.index(before: end)
            guard content[previous].isWhitespace else { break }
            end = previous
        }
        return String(content[..<end])
    }

    private static func regularFileStat(at url: URL, invalidMessage: String) throws -> stat {
        var value = stat()
        guard Darwin.lstat(url.path, &value) == 0 else {
            throw posixError("Could not inspect \(url.path)")
        }
        guard value.st_mode & S_IFMT == S_IFREG else {
            throw RestoreError(invalidMessage)
        }
        return value
    }

    private static func assertConfigUnchanged(
        at configURL: URL,
        expectedBytes: Data,
        expectedStat: stat
    ) throws {
        var currentStat = stat()
        guard
            Darwin.lstat(configURL.path, &currentStat) == 0,
            currentStat.st_mode & S_IFMT == S_IFREG,
            currentStat.st_dev == expectedStat.st_dev,
            currentStat.st_ino == expectedStat.st_ino
        else {
            throw RestoreError("Codex config file identity changed during this operation; nothing was overwritten.")
        }
        guard try Data(contentsOf: configURL) == expectedBytes else {
            throw RestoreError("Codex config changed during this operation; nothing was overwritten.")
        }
    }

    private static func atomicWrite(
        _ data: Data,
        to url: URL,
        mode: mode_t,
        expectedBytes: Data,
        expectedStat: stat
    ) throws {
        let temporary = URL(fileURLWithPath: "\(url.path).\(getpid()).\(UUID().uuidString).tmp")
        var descriptor: Int32 = -1
        defer {
            if descriptor >= 0 { Darwin.close(descriptor) }
            _ = Darwin.unlink(temporary.path)
        }

        descriptor = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL, mode)
        guard descriptor >= 0 else { throw posixError("Could not create config temporary file") }
        guard Darwin.fchmod(descriptor, mode) == 0 else {
            throw posixError("Could not set config temporary file permissions")
        }
        try data.withUnsafeBytes { bytes in
            guard var cursor = bytes.baseAddress else { return }
            var remaining = bytes.count
            while remaining > 0 {
                let written = Darwin.write(descriptor, cursor, remaining)
                if written < 0 && errno == EINTR { continue }
                guard written > 0 else { throw posixError("Could not write config temporary file") }
                remaining -= written
                cursor = cursor.advanced(by: written)
            }
        }
        guard Darwin.close(descriptor) == 0 else {
            descriptor = -1
            throw posixError("Could not close config temporary file")
        }
        descriptor = -1

        try assertConfigUnchanged(at: url, expectedBytes: expectedBytes, expectedStat: expectedStat)
        guard Darwin.rename(temporary.path, url.path) == 0 else {
            throw posixError("Could not atomically replace Codex config")
        }
    }

    private static func removeBackup(_ url: URL) throws {
        guard Darwin.unlink(url.path) == 0 else {
            throw posixError("Could not delete the restored theme backup")
        }
    }

    private static func isNoSuchFile(_ error: Error) -> Bool {
        (error as NSError).domain == NSCocoaErrorDomain
            && (error as NSError).code == NSFileReadNoSuchFileError
    }

    private static func posixError(_ action: String) -> RestoreError {
        RestoreError("\(action): \(String(cString: strerror(errno)))")
    }
}

private struct RestoreError: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
}

private final class ConfigLock {
    private let url: URL

    init(configURL: URL) throws {
        url = URL(fileURLWithPath: configURL.path + ".dream-skin.lock", isDirectory: true)
        let deadline = Date().addingTimeInterval(5)
        while true {
            if Darwin.mkdir(url.path, 0o700) == 0 {
                do {
                    try writeOwner()
                    return
                } catch {
                    try? FileManager.default.removeItem(at: url)
                    throw error
                }
            }
            guard errno == EEXIST else {
                throw RestoreError("Could not create config lock: \(String(cString: strerror(errno)))")
            }
            var lockStat = stat()
            guard Darwin.lstat(url.path, &lockStat) == 0 else { continue }
            guard lockStat.st_mode & S_IFMT == S_IFDIR else {
                throw RestoreError("Unsafe config lock path: \(url.path)")
            }
            let modified = Date(timeIntervalSince1970: TimeInterval(lockStat.st_mtimespec.tv_sec)
                + TimeInterval(lockStat.st_mtimespec.tv_nsec) / 1_000_000_000)
            if Date().timeIntervalSince(modified) > 30, !ownerIsAlive() {
                try FileManager.default.removeItem(at: url)
                continue
            }
            guard Date() < deadline else {
                throw RestoreError("Another Dream Skin config operation is still running; try again shortly.")
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
    }

    func release() {
        try? FileManager.default.removeItem(at: url)
    }

    private func writeOwner() throws {
        let ownerURL = url.appendingPathComponent("owner.json")
        let owner: [String: Any] = [
            "pid": Int(getpid()),
            "createdAt": ISO8601DateFormatter().string(from: Date()),
        ]
        let data = try JSONSerialization.data(withJSONObject: owner) + Data([0x0a])
        let descriptor = Darwin.open(ownerURL.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard descriptor >= 0 else {
            throw RestoreError("Could not create config lock owner: \(String(cString: strerror(errno)))")
        }
        defer { Darwin.close(descriptor) }
        try data.withUnsafeBytes { bytes in
            guard var cursor = bytes.baseAddress else { return }
            var remaining = bytes.count
            while remaining > 0 {
                let written = Darwin.write(descriptor, cursor, remaining)
                if written < 0 && errno == EINTR { continue }
                guard written > 0 else {
                    throw RestoreError("Could not write config lock owner: \(String(cString: strerror(errno)))")
                }
                remaining -= written
                cursor = cursor.advanced(by: written)
            }
        }
    }

    private func ownerIsAlive() -> Bool {
        let ownerURL = url.appendingPathComponent("owner.json")
        guard
            let data = try? Data(contentsOf: ownerURL),
            let object = try? JSONSerialization.jsonObject(with: data),
            let owner = object as? [String: Any],
            let number = owner["pid"] as? NSNumber,
            CFGetTypeID(number) != CFBooleanGetTypeID(),
            number.int64Value > 0,
            number.int64Value <= Int64(Int32.max)
        else { return false }
        if Darwin.kill(pid_t(number.int32Value), 0) == 0 { return true }
        return errno == EPERM
    }
}
