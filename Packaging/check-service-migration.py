from pathlib import Path
import errno, os, plistlib, subprocess, tempfile, time, uuid

repo = Path(__file__).resolve().parent.parent
source = (repo / 'Sources/SettingsStore.swift').read_text()
implementation = source[source.index('enum LegacyBackgroundService {'):].removesuffix('#endif\n')
delegate = (repo / 'Sources/AppDelegate.swift').read_text()
helper_entry = delegate.split('        if CommandLine.arguments.contains("--migrate-background-service") {', 1)[1].split('        if CommandLine.arguments.contains("--service-migration-recovery") {', 1)[0]
helper_entry = 'if CommandLine.arguments.contains("--migrate-background-service") {' + helper_entry
helper_entry = helper_entry.replace('            NSApplication.shared.setActivationPolicy(.prohibited)\n', '')
quit_observation = delegate.split('        if [kAEQuitAll, kAEShutDown, kAERestart, kAEReallyLogOut]', 1)[1].split('        } else if backgroundServiceMigrationError', 1)[0]
quit_observation = 'if [kAEQuitAll, kAEShutDown, kAERestart, kAEReallyLogOut]' + quit_observation + '        }'
quit_cancellation = delegate.split('                if interrupted != nil {', 1)[1].split('                }', 1)[0].replace('self?.', '')
# The fixture models only the two migration flags; device cleanup and other flags need the whole delegate.
quit_cancellation = ''.join(line for line in quit_cancellation.splitlines(keepends=True)
                            if 'isSystemTerminating' in line or 'retriesBackgroundServiceMigration' in line)
assert 'isSystemTerminating = false' in quit_cancellation and 'retriesBackgroundServiceMigration = false' in quit_cancellation
domain = f'gui/{os.getuid()}'
label = 'dev.baglayan.Acouplet.migration-check.' + uuid.uuid4().hex
helper_label = label + '.helper'
target = f'{domain}/{label}'
helper_target = f'{domain}/{helper_label}'
recovery_label = label + '.recovery'
recovery_target = f'{domain}/{recovery_label}'


def ctl(*arguments):
    return subprocess.run(['/bin/launchctl', *arguments], capture_output=True, text=True, timeout=20)


def wait_for(predicate):
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(0.1)
    raise AssertionError('Disposable service did not reach the expected state within ten seconds')


def quit_worker(fifo, timeout=3):
    deadline = time.monotonic() + timeout
    while True:
        try:
            descriptor = os.open(fifo, os.O_WRONLY | os.O_NONBLOCK)
        except OSError as error:
            if error.errno != errno.ENXIO or time.monotonic() >= deadline:
                raise
            time.sleep(0.05)
            continue
        try:
            os.write(descriptor, b'quit\n')
            return
        finally:
            os.close(descriptor)


with tempfile.TemporaryDirectory(prefix='acouplet-service-migration-check-') as directory:
    root = Path(directory)
    swift = root / 'migration.swift'
    binary = root / 'migration'
    fixture_implementation = implementation.replace('static let label = "dev.baglayan.Acouplet.agent"', f'static let label = "{label}"')
    fixture_implementation = fixture_implementation.replace('static let migrationLabel = "dev.baglayan.Acouplet.agent.migration"', f'static let migrationLabel = "{helper_label}"')
    fixture_implementation = fixture_implementation.replace('static let executablePath = "/Applications/Acouplet.app/Contents/MacOS/Acouplet"', f'static let executablePath = "{binary}"')
    fixture_implementation = fixture_implementation.replace('Bundle.main.bundleIdentifier', '"dev.baglayan.Acouplet"')
    fixture_implementation = fixture_implementation.replace('Bundle.main.executableURL?.path', 'Optional(executablePath)')
    fixture_implementation = fixture_implementation.replace('NSHomeDirectory()', f'"{root}"')
    fixture_implementation = fixture_implementation.replace('FileManager.default.temporaryDirectory', f'URL(fileURLWithPath: "{root}")')
    fixture_implementation = fixture_implementation.replace('"/Applications/Acouplet.app"', f'"{root / "nonexistent-recovery.app"}"')
    fixture_implementation = fixture_implementation.replace('        let process = Process()\n', f'''        if executable == "/bin/launchctl", arguments == ["bootstrap", domain, plistURL.path],
           FileManager.default.fileExists(atPath: "{root / 'fail-bootstrap'}") {{
            try FileManager.default.removeItem(atPath: "{root / 'fail-bootstrap'}")
            throw failure(91)
        }}
        let process = Process()
''', 1)
    fixture_implementation = fixture_implementation.replace('try command("/usr/bin/open", ["-n", "' + str(root / 'nonexistent-recovery.app') + '", "--args",\n                                              "--background-service", "--service-migration-recovery"])',
                                                          f'try command("/bin/launchctl", ["bootstrap", domain, "{root / "recovery.plist"}"])')
    termination_check = '''
struct TerminationCheck {
    var isSystemTerminating = false
    var retriesBackgroundServiceMigration = true
    mutating func observe(_ quitReason: UInt32?) {
''' + quit_observation + '''
    }
    mutating func cancel() {
''' + quit_cancellation + '''
    }
}
'''
    swift.write_text('import Foundation\nimport AppKit\n' + fixture_implementation + termination_check + r'''
final class FixtureDefaults: UserDefaults, @unchecked Sendable {
    private var values: [String: Any] = [:]
    override func bool(forKey key: String) -> Bool { values[key] as? Bool ?? false }
    override func set(_ value: Any?, forKey key: String) { values[key] = value }
    override func removeObject(forKey key: String) { values.removeValue(forKey: key) }
}

@main
struct MigrationCheck {
    static func main() throws {
        HELPER_ENTRY
        if CommandLine.arguments.contains("--background-service") {
            let defaults = FixtureDefaults()
            let directory = URL(fileURLWithPath: NSHomeDirectory())
            let recovering = CommandLine.arguments.contains("--service-migration-recovery")
            if recovering {
                try Data(String(ProcessInfo.processInfo.processIdentifier).utf8).write(to: directory.appending(path: "recovery-waiting"))
                let retry = try FileHandle(forReadingFrom: directory.appending(path: "recovery-retry"))
                _ = try retry.read(upToCount: 1)
                defaults.removeObject(forKey: LegacyBackgroundService.attemptKey)
            }
            try LegacyBackgroundService.prepare(defaults: defaults)
            if recovering {
                try Data("ready".utf8).write(to: directory.appending(path: "recovery-parent-ready"))
                return
            }
            let log = directory.appending(path: "orchestration-runs")
            let line = "\(ProcessInfo.processInfo.processIdentifier) \(ProcessInfo.processInfo.environment[LegacyBackgroundService.policyKey] ?? "legacy")\n"
            let data = Data(line.utf8)
            if FileManager.default.fileExists(atPath: log.path) {
                let handle = try FileHandle(forWritingTo: log)
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
                try handle.close()
            } else {
                try data.write(to: log)
            }
            let quit = try FileHandle(forReadingFrom: directory.appending(path: "orchestration-quit"))
            _ = try quit.read(upToCount: 1)
            return
        }
        if CommandLine.arguments.count > 1 {
            try LegacyBackgroundService.reload(plistURL: URL(fileURLWithPath: CommandLine.arguments[1]),
                                               domain: CommandLine.arguments[2], label: CommandLine.arguments[3])
            try Data("completed".utf8).write(to: URL(fileURLWithPath: CommandLine.arguments[4]))
            return
        }
        for reason in [kAEQuitAll, kAEShutDown, kAERestart, kAEReallyLogOut] {
            var termination = TerminationCheck()
            termination.observe(reason)
            precondition(termination.isSystemTerminating && !termination.retriesBackgroundServiceMigration)
            termination.observe(nil)
            precondition(termination.isSystemTerminating && !termination.retriesBackgroundServiceMigration)
            termination.cancel()
            termination.observe(nil)
            precondition(!termination.isSystemTerminating)
        }
        for keepAlive: Any in [true, ["SuccessfulExit": false]] {
            let old: [String: Any] = ["Label": LegacyBackgroundService.label,
                                     "ProgramArguments": [LegacyBackgroundService.executablePath, "--background-service"],
                                     "KeepAlive": keepAlive, "StandardErrorPath": "/tmp/acouplet-fixture.log",
                                     "EnvironmentVariables": ["EXISTING_SETTING": "retained"]]
            let data = try PropertyListSerialization.data(fromPropertyList: old, format: .xml, options: 0)
            let migrated = try LegacyBackgroundService.configuration(from: data,
                                                                     executablePath: LegacyBackgroundService.executablePath)
            precondition(migrated["KeepAlive"] as? [String: Bool] == ["SuccessfulExit": false])
            precondition(migrated["EnvironmentVariables"] as? [String: String] ==
                         [LegacyBackgroundService.policyKey: LegacyBackgroundService.policy, "EXISTING_SETTING": "retained"])
            precondition(migrated["StandardErrorPath"] as? String == "/tmp/acouplet-fixture.log")
            // Without a ProcessType launchd clamps the service and its LDAC helpers to the utility QoS.
            precondition(migrated["ProcessType"] as? String == "Interactive")
        }
        let invalid: [String: Any] = ["Label": LegacyBackgroundService.label,
                                     "ProgramArguments": [LegacyBackgroundService.executablePath, "--background-service"],
                                     "Program": "/bin/sh"]
        let data = try PropertyListSerialization.data(fromPropertyList: invalid, format: .xml, options: 0)
        do {
            _ = try LegacyBackgroundService.configuration(from: data, executablePath: LegacyBackgroundService.executablePath)
            preconditionFailure("An overridden executable was accepted")
        } catch {}
    }
}
'''.replace('NSHomeDirectory()', f'"{root}"').replace('HELPER_ENTRY', helper_entry))
    subprocess.run(['/usr/bin/xcrun', 'swiftc', '-swift-version', '6', '-parse-as-library', str(swift), '-o', str(binary)],
                   check=True, timeout=60)
    subprocess.run([str(binary)], check=True, timeout=10)
    worker = root / 'worker.sh'
    worker.write_text('printf "%s %s\\n" "$$" "${ACOUPLET_SERVICE_POLICY:-legacy}" >> "$1"\nread value < "$2"\nexit 0\n')
    fifo = root / 'quit'
    os.mkfifo(fifo)
    log = root / 'runs'
    plist = root / 'service.plist'
    helper_plist = root / 'helper.plist'
    completed = root / 'completed'
    configuration = {'Label': label, 'ProgramArguments': ['/bin/sh', str(worker), str(log), str(fifo)],
                     'RunAtLoad': True, 'KeepAlive': True, 'ThrottleInterval': 1}
    plist.write_bytes(plistlib.dumps(configuration))
    try:
        orphan_fifo = root / 'orphan-quit'
        os.mkfifo(orphan_fifo)
        started = time.monotonic()
        try:
            quit_worker(orphan_fifo, timeout=0.1)
            raise AssertionError('A FIFO with no reader unexpectedly accepted a command')
        except OSError as error:
            assert error.errno == errno.ENXIO and time.monotonic() - started < 1
        result = ctl('bootstrap', domain, str(plist))
        assert result.returncode == 0, result.stderr
        wait_for(lambda: log.exists())
        first_pid = log.read_text().split()[0]
        configuration['KeepAlive'] = {'SuccessfulExit': False}
        configuration['EnvironmentVariables'] = {'ACOUPLET_SERVICE_POLICY': 'successful-exit-v1'}
        plist.write_bytes(plistlib.dumps(configuration))
        quit_worker(fifo)
        wait_for(lambda: len(log.read_text().splitlines()) == 2)
        assert log.read_text().splitlines()[1].endswith('legacy'), 'Editing disk unexpectedly replaced the loaded policy'
        helper_plist.write_bytes(plistlib.dumps({'Label': helper_label, 'RunAtLoad': True, 'LaunchOnlyOnce': True,
                                                'ProgramArguments': [str(binary), str(plist), domain, label, str(completed)]}))
        result = ctl('bootstrap', domain, str(helper_plist))
        assert result.returncode == 0, result.stderr
        wait_for(lambda: completed.exists() and len(log.read_text().splitlines()) == 3)
        helper_plist.unlink()
        third = log.read_text().splitlines()[2].split()
        assert third[0] != first_pid and third[1] == 'successful-exit-v1'
        wait_for(lambda: ctl('print', helper_target).returncode != 0)
        quit_worker(fifo)
        time.sleep(3)
        assert len(log.read_text().splitlines()) == 3, 'Migrated service restarted after successful exit'
        result = ctl('kickstart', target)
        assert result.returncode == 0, result.stderr
        wait_for(lambda: len(log.read_text().splitlines()) == 4)
        crashed_pid = int(log.read_text().splitlines()[3].split()[0])
        os.kill(crashed_pid, 9)
        wait_for(lambda: len(log.read_text().splitlines()) == 5)
        assert log.read_text().splitlines()[4].endswith('successful-exit-v1')
        result = ctl('bootout', target)
        assert result.returncode == 0, result.stderr
        agents = root / 'Library/LaunchAgents'
        agents.mkdir(parents=True)
        orchestration_plist = agents / f'{label}.plist'
        orchestration_log = root / 'orchestration-runs'
        orchestration_fifo = root / 'orchestration-quit'
        os.mkfifo(orchestration_fifo)
        orchestration_plist.write_bytes(plistlib.dumps({'Label': label, 'RunAtLoad': True, 'KeepAlive': True,
                                                       'ProgramArguments': [str(binary), '--background-service']}))
        result = ctl('bootstrap', domain, str(orchestration_plist))
        assert result.returncode == 0, result.stderr
        wait_for(lambda: orchestration_log.exists())
        assert orchestration_log.read_text().splitlines()[0].endswith('successful-exit-v1')
        wait_for(lambda: ctl('print', helper_target).returncode != 0)
        assert not list(root.glob(helper_label + '.*')), 'Migration left a temporary directory behind'
        quit_worker(orchestration_fifo)
        time.sleep(3)
        assert len(orchestration_log.read_text().splitlines()) == 1
        invalid_token = str(uuid.uuid4()).upper()
        failure_environment = {**os.environ, 'XPC_SERVICE_NAME': helper_label, 'ACOUPLET_MIGRATION_TOKEN': invalid_token}
        result = subprocess.run([str(binary), '--migrate-background-service'], env=failure_environment,
                                capture_output=True, text=True, timeout=3)
        assert result.returncode == 1 and 'Background service migration failed:' in result.stderr, result
        helper_plist.write_bytes(plistlib.dumps({'Label': helper_label, 'RunAtLoad': True, 'LaunchOnlyOnce': True,
                                                'ProgramArguments': [str(binary), '--migrate-background-service'],
                                                'EnvironmentVariables': {'ACOUPLET_MIGRATION_TOKEN': invalid_token}}))
        result = ctl('bootstrap', domain, str(helper_plist))
        assert result.returncode == 0, result.stderr
        wait_for(lambda: ctl('print', helper_target).returncode != 0)
        result = ctl('bootout', target)
        assert result.returncode == 0, result.stderr
        orchestration_log.unlink()
        orchestration_plist.write_bytes(plistlib.dumps({'Label': label, 'RunAtLoad': True, 'KeepAlive': True,
                                                       'ProgramArguments': [str(binary), '--background-service']}))
        (root / 'fail-bootstrap').touch()
        recovery_plist = root / 'recovery.plist'
        recovery_plist.write_bytes(plistlib.dumps({'Label': recovery_label, 'RunAtLoad': True, 'LaunchOnlyOnce': True,
                                                  'ProgramArguments': [str(binary), '--background-service', '--service-migration-recovery']}))
        recovery_fifo = root / 'recovery-retry'
        os.mkfifo(recovery_fifo)
        result = ctl('bootstrap', domain, str(orchestration_plist))
        assert result.returncode == 0, result.stderr
        wait_for(lambda: (root / 'recovery-waiting').exists())
        wait_for(lambda: ctl('print', helper_target).returncode != 0)
        assert ctl('print', target).returncode != 0, 'Failed bootstrap left the old job loaded'
        quit_worker(recovery_fifo)
        wait_for(lambda: (root / 'recovery-parent-ready').exists() and orchestration_log.exists())
        assert orchestration_log.read_text().splitlines()[0].endswith('successful-exit-v1')
        wait_for(lambda: ctl('print', helper_target).returncode != 0 and ctl('print', recovery_target).returncode != 0)
        assert not list(root.glob(helper_label + '.*')), 'Recovery left a temporary migration directory behind'
        quit_worker(orchestration_fifo)
        time.sleep(3)
        assert len(orchestration_log.read_text().splitlines()) == 1
        print('Actual migration implementation passed: disk-only edit still respawned; loaded policy changed; clean exit stayed stopped; crash recovered; helper errors exited and unloaded; system quit reasons survived missing callback events and reset on cancellation; orphan FIFO writes were bounded; startup migration and bootstrap-failure recovery coordinated parent exit and cleaned temporary jobs/directories.')
    finally:
        for service in (helper_target, recovery_target, target):
            if ctl('print', service).returncode == 0:
                result = ctl('bootout', service)
                assert result.returncode == 0, result.stderr
