import Darwin
import Foundation

@main
enum LDACSessionDiagnosticsCheck {
    static func main() throws {
        // The fixture folders carry dates from 1970, so these checks keep the count limit and ignore the age.
        let countOnly = LDACNativeSession.DiagnosticsRetention(maxAge: .infinity, maxCount: 7, maxBytes: .max)
        if CommandLine.arguments.count == 3, ["--live", "--finish"].contains(CommandLine.arguments[1]) {
            let directory = URL(fileURLWithPath: CommandLine.arguments[2])
            let active = try LDACNativeSession.beginDiagnostics(in: directory, retention: countOnly)
            try FileHandle.standardOutput.write(contentsOf: Data([1]))
            withExtendedLifetime(active) { _ = FileHandle.standardInput.readDataToEndOfFile() }
            if CommandLine.arguments[1] == "--finish" {
                try LDACNativeSession.completeDiagnostics(in: directory, releasing: active, retention: countOnly)
            }
            return
        }
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: root) }
        let active = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let concurrent = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        var children: [Process] = []
        defer {
            for child in children where child.isRunning {
                child.terminate()
                child.waitUntilExit()
            }
        }
        for directory in [active, concurrent] {
            let child = Process()
            child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
            child.arguments = ["--live", directory.path]
            child.standardInput = Pipe()
            child.standardOutput = Pipe()
            try child.run()
            children.append(child)
        }
        for child in children {
            let output = child.standardOutput as! Pipe
            let ready = try output.fileHandleForReading.read(upToCount: 1)
            precondition(ready == Data([1]))
        }
        for directory in [active, concurrent] {
            try Data("unchanged".utf8).write(to: directory.appendingPathComponent("session.log"))
            try manager.setAttributes([.modificationDate: Date(timeIntervalSince1970: -1)], ofItemAtPath: directory.path)
        }
        var inactive: [URL] = []
        for index in 0..<10 {
            let directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try manager.createDirectory(at: directory, withIntermediateDirectories: false)
            try Data("diagnostic \(index)".utf8).write(to: directory.appendingPathComponent("session.log"))
            if index.isMultiple(of: 2) {
                let marker = directory.appendingPathComponent("completed")
                try Data().write(to: marker)
                try manager.setAttributes([.modificationDate: Date(timeIntervalSince1970: Double(index))], ofItemAtPath: marker.path)
            } else {
                try Data().write(to: directory.appendingPathComponent("active.lock"))
            }
            try manager.setAttributes([.modificationDate: Date(timeIntervalSince1970: Double(index))], ofItemAtPath: directory.path)
            inactive.append(directory)
        }
        let legacy = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let legacyLog = legacy.appendingPathComponent("session.log")
        try manager.createDirectory(at: legacy, withIntermediateDirectories: false)
        try Data("legacy diagnostics".utf8).write(to: legacyLog)
        try manager.setAttributes([.modificationDate: Date(timeIntervalSince1970: -2)], ofItemAtPath: legacy.path)
        let legacyHandle = try FileHandle(forWritingTo: legacyLog)
        defer { try? legacyHandle.close() }
        let current = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let unrelated = root.appendingPathComponent("unrelated", isDirectory: true)
        try manager.createDirectory(at: unrelated, withIntermediateDirectories: false)
        try Data().write(to: unrelated.appendingPathComponent("completed"))
        let linked = root.appendingPathComponent(UUID().uuidString)
        try manager.createSymbolicLink(at: linked, withDestinationURL: unrelated)
        let currentLock = try LDACNativeSession.beginDiagnostics(in: current, retention: countOnly)
        defer { try? currentLock.close() }
        for (index, directory) in inactive.enumerated() {
            precondition(manager.fileExists(atPath: directory.path) == (index >= 3))
        }
        try LDACNativeSession.completeDiagnostics(in: current, retention: countOnly)
        for (index, directory) in inactive.enumerated() {
            precondition(manager.fileExists(atPath: directory.path) == (index >= 3))
        }
        precondition(manager.fileExists(atPath: current.appendingPathComponent("completed").path))
        precondition(manager.fileExists(atPath: unrelated.path))
        precondition(manager.fileExists(atPath: linked.path))
        precondition(manager.fileExists(atPath: legacy.path))
        precondition(!manager.fileExists(atPath: legacy.appendingPathComponent("active.lock").path))
        for directory in [active, concurrent] {
            let contents = try Data(contentsOf: directory.appendingPathComponent("session.log"))
            precondition(contents == Data("unchanged".utf8))
            precondition(!manager.fileExists(atPath: directory.appendingPathComponent("completed").path))
        }
        precondition(kill(children[0].processIdentifier, SIGKILL) == 0)
        children[0].waitUntilExit()
        try LDACNativeSession.completeDiagnostics(in: current, retention: countOnly)
        precondition(!manager.fileExists(atPath: active.path))
        precondition(manager.fileExists(atPath: concurrent.path))
        for directory in inactive.suffix(7) { precondition(manager.fileExists(atPath: directory.path)) }
        try legacyHandle.close()
        try LDACNativeSession.completeDiagnostics(in: current, retention: countOnly)
        let legacyContents = try Data(contentsOf: legacyLog)
        precondition(legacyContents == Data("legacy diagnostics".utf8))
        precondition(!manager.fileExists(atPath: legacy.appendingPathComponent("completed").path))
        precondition(!manager.fileExists(atPath: legacy.appendingPathComponent("active.lock").path))
        let finishing = root.appendingPathComponent("finishing", isDirectory: true)
        try manager.createDirectory(at: finishing, withIntermediateDirectories: false)
        for index in 0..<8 {
            let directory = finishing.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try manager.createDirectory(at: directory, withIntermediateDirectories: false)
            let marker = directory.appendingPathComponent("completed")
            try Data().write(to: marker)
            try manager.setAttributes([.modificationDate: Date(timeIntervalSince1970: Double(index))], ofItemAtPath: marker.path)
        }
        for _ in 0..<2 {
            let child = Process()
            child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
            child.arguments = ["--finish", finishing.appendingPathComponent(UUID().uuidString).path]
            child.standardInput = Pipe()
            child.standardOutput = Pipe()
            try child.run()
            children.append(child)
        }
        for child in children.suffix(2) {
            let output = child.standardOutput as! Pipe
            let ready = try output.fileHandleForReading.read(upToCount: 1)
            precondition(ready == Data([1]))
        }
        for child in children.suffix(2) {
            let input = child.standardInput as! Pipe
            try input.fileHandleForWriting.close()
        }
        for child in children.suffix(2) {
            child.waitUntilExit()
            precondition(child.terminationStatus == 0)
        }
        let histories = try manager.contentsOfDirectory(at: finishing, includingPropertiesForKeys: nil)
            .filter { UUID(uuidString: $0.lastPathComponent) != nil }
        precondition(histories.count == 8)
        let suite = "LDACSessionDiagnosticsCheck.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let control = LDACPriorityControl(request: { _, _ in }, state: { .init(phase: "idle", error: nil) })
        var made = 0
        precondition(!LDACPlaybackPriority.isDisabled(in: defaults))
        precondition(LDACPlaybackPriority.control(in: defaults, { made += 1; return control }) != nil && made == 1)
        defaults.set(true, forKey: LDACPlaybackPriority.disabledKey)
        precondition(LDACPlaybackPriority.isDisabled(in: defaults))
        precondition(LDACPlaybackPriority.control(in: defaults, { made += 1; return control }) == nil && made == 1)
        defaults.removeObject(forKey: LDACPlaybackPriority.disabledKey)
        precondition(LDACPlaybackPriority.control(in: defaults, { made += 1; return control }) != nil && made == 2)
        try checkRetentionByAgeAndSize(in: root)
        try checkSessionLogRotation(in: root)
        print("LDAC diagnostic retention checks passed: mixed completed/managed-orphan limit, a week of sessions with count and size caps, legacy preservation, concurrent live locks and completion, forced-exit recovery, unrelated paths; the playback priority A/B switch skips the driver request only while set; a full session log moves to session.log.1 and a new one starts")
    }

    /// A week of sessions is kept, the oldest go first when the count or size cap is passed, and the running
    /// session is never removed (L7).
    private static func checkRetentionByAgeAndSize(in root: URL) throws {
        let manager = FileManager.default
        let base = root.appendingPathComponent("retention", isDirectory: true)
        try manager.createDirectory(at: base, withIntermediateDirectories: false)
        let day: TimeInterval = 24 * 3600
        func session(ageDays: Double, bytes: Int) throws -> URL {
            let directory = base.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try manager.createDirectory(at: directory, withIntermediateDirectories: false)
            try Data(count: bytes).write(to: directory.appendingPathComponent("session.log"))
            let marker = directory.appendingPathComponent("completed")
            try Data().write(to: marker)
            let date = Date(timeIntervalSinceNow: -ageDays * day)
            try manager.setAttributes([.modificationDate: date], ofItemAtPath: marker.path)
            try manager.setAttributes([.modificationDate: date], ofItemAtPath: directory.path)
            return directory
        }
        let old = try session(ageDays: 8, bytes: 10)
        let recent = try [6.5, 3, 1, 0.1].map { try session(ageDays: $0, bytes: 10) }
        let current = base.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let lock = try LDACNativeSession.beginDiagnostics(in: current)
        precondition(!manager.fileExists(atPath: old.path), "A session older than a week must go")
        for directory in recent { precondition(manager.fileExists(atPath: directory.path), "A session under a week old must stay") }
        precondition(manager.fileExists(atPath: current.path))
        // Size cap: 30 bytes allowed, 10 each, so the three newest stay and the oldest goes first.
        let sized = LDACNativeSession.DiagnosticsRetention(maxAge: 7 * day, maxCount: 200, maxBytes: 30)
        try LDACNativeSession.completeDiagnostics(in: current, releasing: lock, retention: sized)
        precondition(!manager.fileExists(atPath: recent[0].path))
        for directory in recent.dropFirst() { precondition(manager.fileExists(atPath: directory.path)) }
        precondition(manager.fileExists(atPath: current.path), "The finished current session is never removed by its own prune")
    }

    /// A full session log keeps its lines in `session.log.1`, replacing an older one, and logging goes on in a new
    /// `session.log`, so a session never holds more than twice the limit (L13).
    private static func checkSessionLogRotation(in root: URL) throws {
        let directory = root.appendingPathComponent("rotation", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let url = directory.appendingPathComponent("session.log")
        let previous = directory.appendingPathComponent("session.log.1")
        precondition(FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]))
        var log: FileHandle? = try FileHandle(forWritingTo: url)
        defer { try? log?.close() }
        var bytes = 0
        func append(_ text: String) {
            bytes = LDACNativeSession.appendSessionLog(Data(text.utf8), to: &log, at: url, loggedBytes: bytes, limit: 12)
        }
        func contents(_ file: URL) -> String? { (try? Data(contentsOf: file)).map { String(decoding: $0, as: UTF8.self) } }
        append("first\n")
        append("more\n")
        precondition(contents(url) == "first\nmore\n" && bytes == 11 && !FileManager.default.fileExists(atPath: previous.path),
                     "The log rotated before it was full")
        append("third\n")
        precondition(contents(previous) == "first\nmore\n", "The first lines of the session were lost")
        precondition(contents(url) == "third\n" && bytes == 6)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        precondition((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        append("fourth\n")
        precondition(contents(previous) == "third\n", "An older session.log.1 was kept instead of replaced")
        precondition(contents(url) == "fourth\n")
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        precondition(names == ["session.log", "session.log.1"], "\(names)")

        // A handle without a known file still records, and only skips the rotation.
        let unnamed = directory.appendingPathComponent("unnamed.log")
        precondition(FileManager.default.createFile(atPath: unnamed.path, contents: nil))
        var handle: FileHandle? = try FileHandle(forWritingTo: unnamed)
        defer { try? handle?.close() }
        var written = 0
        for line in ["first\n", "more\n", "third\n"] {
            written = LDACNativeSession.appendSessionLog(Data(line.utf8), to: &handle, at: nil, loggedBytes: written, limit: 12)
        }
        precondition(contents(unnamed) == "first\nmore\nthird\n" && written == 17, "A log without a known file stopped recording")
        precondition(!FileManager.default.fileExists(atPath: unnamed.path + ".1"))
    }
}
