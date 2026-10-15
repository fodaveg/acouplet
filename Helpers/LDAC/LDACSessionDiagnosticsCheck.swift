import Darwin
import Foundation

@main
enum LDACSessionDiagnosticsCheck {
    static func main() throws {
        if CommandLine.arguments.count == 3, ["--live", "--finish"].contains(CommandLine.arguments[1]) {
            let directory = URL(fileURLWithPath: CommandLine.arguments[2])
            let active = try LDACNativeSession.beginDiagnostics(in: directory)
            try FileHandle.standardOutput.write(contentsOf: Data([1]))
            withExtendedLifetime(active) { _ = FileHandle.standardInput.readDataToEndOfFile() }
            if CommandLine.arguments[1] == "--finish" {
                try LDACNativeSession.completeDiagnostics(in: directory, releasing: active)
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
        let currentLock = try LDACNativeSession.beginDiagnostics(in: current)
        defer { try? currentLock.close() }
        for (index, directory) in inactive.enumerated() {
            precondition(manager.fileExists(atPath: directory.path) == (index >= 3))
        }
        try LDACNativeSession.completeDiagnostics(in: current)
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
        try LDACNativeSession.completeDiagnostics(in: current)
        precondition(!manager.fileExists(atPath: active.path))
        precondition(manager.fileExists(atPath: concurrent.path))
        for directory in inactive.suffix(7) { precondition(manager.fileExists(atPath: directory.path)) }
        try legacyHandle.close()
        try LDACNativeSession.completeDiagnostics(in: current)
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
        print("LDAC diagnostic retention checks passed: mixed completed/managed-orphan limit, legacy preservation, concurrent live locks and completion, forced-exit recovery, unrelated paths; the playback priority A/B switch skips the driver request only while set")
    }
}
