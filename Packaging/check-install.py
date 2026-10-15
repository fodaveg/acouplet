from pathlib import Path
import fcntl, hashlib, json, os, plistlib, shutil, subprocess, tempfile

packaging = Path(__file__).parent
service_check = (packaging / 'check-service.sh').read_text().split("<<'PLIST'\n", 1)[1].split('\nPLIST\n', 1)[0]
service_policy = plistlib.loads(service_check.encode())
assert service_policy['KeepAlive'] == {'SuccessfulExit': False} and service_policy['RunAtLoad'] is True
native_label = 'dev.baglayan.Acouplet.agent'
legacy_label = 'local.xm5control.native.agent'
older_label = 'local.xm5control.agent'
stub_source = r'''#!/usr/bin/python3
from pathlib import Path
import json, os, plistlib, re, shutil, subprocess, sys
root = Path(os.environ['ACOUPLET_INSTALL_CHECK_ROOT'])
mode = os.environ['ACOUPLET_INSTALL_CHECK_MODE']
name = Path(sys.argv[0]).name
args = sys.argv[1:]
with (root / 'commands.jsonl').open('a') as log:
    log.write(json.dumps([name, *args]) + '\n')
state_file = root / 'state.json'
process_file = root / 'processes.json'
if name == 'PlistBuddy':
    value = plistlib.loads(Path(args[2]).read_bytes())
    for key in args[1].removeprefix('Print :').split(':'):
        value = value[int(key)] if isinstance(value, list) else value[key]
    print(value)
elif name == 'ditto':
    shutil.copytree(args[0], args[1])
elif name == 'codesign':
    target = Path(args[-1])
    team = (target / 'team').read_text() if (target / 'team').exists() else 'ABCDE12345'
    if args[0] == '--display': print('TeamIdentifier=' + team, file=sys.stderr)
    for argument in args:
        if argument.startswith('--test-requirement='):
            assert 'anchor apple generic' in argument
            if re.search(r'subject.OU] = "([^"]+)"', argument)[1] != team: sys.exit(21)
            expected_id = re.search(r'identifier "([^"]+)"', argument)
            if expected_id and expected_id[1] != plistlib.loads((target / 'Contents/Info.plist').read_bytes())['CFBundleIdentifier']: sys.exit(21)
    if mode == 'legacy-bad-signature' and 'XM5 Control Native.app' in args[-1]: sys.exit(21)
    if mode == 'installed-bad-signature' and '/Applications/Acouplet.app' in args[-1]: sys.exit(21)
    if mode == 'installed-validation-failure' and '/Applications/Acouplet.app' in args[-1] and (Path(args[-1]) / 'version').read_text() == 'new': sys.exit(21)
    if mode == 'pane-bad-signature' and args[-1].endswith('.prefPane'): sys.exit(21)
    if mode == 'pane-stage-failure' and '.prefPane.installing-' in args[-1]: sys.exit(21)
    if mode == 'staging-failure' and '.installing-' in args[-1]: sys.exit(21)
elif name == 'plutil':
    if args[-1] == '-' and mode in ('restore-app-failure', 'move-new-failure', 'restart-failure'): sys.exit(19)
    value = plistlib.loads(sys.stdin.buffer.read() if args[-1] == '-' else Path(args[-1]).read_bytes())
    if args[0] == '-convert':
        print(json.dumps(value, sort_keys=True, indent=2))
    else:
        assert args[0] == '-lint', args
elif name == 'pgrep':
    processes = json.loads(process_file.read_text())
    owners = processes.get('owner', [])
    if args[0] == '-fx':
        assert args[-1].endswith('/Acouplet --ldac-owner'), args
        if not owners: sys.exit(1)
        print('\n'.join(str(pid) for pid in owners))
        sys.exit(0)
    key = 'legacy' if 'XM5 Control Native' in args[-1] else 'older' if 'XM5 Control' in args[-1] else 'native'
    # The LDAC owner worker runs the app's executable, so the app's own pattern finds it too.
    matches = processes[key] + (owners if key == 'native' else [])
    if matches:
        print('\n'.join(str(pid) for pid in matches))
    else:
        sys.exit(0 if mode == 'legacy-running' and 'XM5 Control Native' in args[-1] else 1)
elif name == 'kill':
    assert args[0] == '-0', args
    processes = json.loads(process_file.read_text())
    if mode == 'native-delayed-quit' and processes['quit_requested']:
        processes['exit_checks'] += 1
        if processes['exit_checks'] == 3: processes['native'] = []
        process_file.write_text(json.dumps(processes))
    sys.exit(0 if any(int(args[1]) in processes[key] for key in ('native', 'legacy', 'older')) else 1)
elif name == 'osascript':
    script = sys.stdin.read()
    if args == ['-', 'dev.baglayan.Acouplet']:
        assert 'with timeout of 30 seconds' in script
        if mode in ('native-quit-declined', 'native-quit-timeout'): sys.exit(27)
        processes = json.loads(process_file.read_text())
        processes['quit_requested'] = True
        if mode == 'native-partial-quit': processes['native'] = processes['native'][1:]
        elif mode == 'native-keepalive-relaunch': processes['native'] = [102]
        elif mode not in ('native-quit-stalled', 'native-delayed-quit'): processes['native'] = []
        process_file.write_text(json.dumps(processes))
    else:
        assert args[0] == '-' and args[1] in ('local.xm5control.native', 'local.xm5control'), args
        processes = json.loads(process_file.read_text())
        if mode == 'legacy-quit-declined': sys.exit(27)
        key = 'legacy' if args[1] == 'local.xm5control.native' else 'older'
        processes[key] = []
        process_file.write_text(json.dumps(processes))
elif name == 'pluginkit':
    assert args[0] in ('-r', '-a'), args
    assert Path(args[-1]).is_dir(), args
    if mode == 'controls-unregister-failure' and args[0] == '-r': sys.exit(28)
elif name == 'lsregister':
    if mode == 'legacy-unregister-failure' and args[0] == '-u': sys.exit(22)
    if mode == 'native-register-failure' and args[0] == '-f': sys.exit(26)
elif name == 'mv':
    if mode == 'pane-commit-failure' and '.prefPane.installing-' in args[-2] and args[-1].endswith('Sony-001122334466.prefPane'): sys.exit(23)
    restoring_app = '.previous-' in args[-2] and args[-2].endswith('.app')
    restoring_plist = '.plist.previous-' in args[-2]
    moving_new = '.installing-' in args[-1] and 'Acouplet.app' in args[-2]
    if (mode == 'restore-app-failure' and restoring_app or
        mode == 'restore-plist-failure' and restoring_plist or
        mode == 'move-new-failure' and moving_new): sys.exit(23)
    sys.exit(subprocess.run(['/bin/mv', *args]).returncode)
elif name == 'launchctl':
    state = json.loads(state_file.read_text())
    if args[0] in ('print', 'bootout'):
        label = args[1].split('/')[-1]
        service = state[label]
        if args[0] == 'print':
            if not service['loaded']: sys.exit(1)
            print('state = running\n\tprogram = ' + service['program'])
        else:
            if mode == 'stop-failure' or mode == 'legacy-stop-failure' and label == 'local.xm5control.native.agent': sys.exit(24)
            service['loaded'] = False
            state_file.write_text(json.dumps(state))
            if label == 'dev.baglayan.Acouplet.agent':
                processes = json.loads(process_file.read_text())
                processes['native'] = []
                process_file.write_text(json.dumps(processes))
    elif args[0] == 'bootstrap':
        config = plistlib.loads(Path(args[2]).read_bytes())
        program = Path(config['ProgramArguments'][0])
        version = (program.parents[2] / 'version').read_text()
        if mode in ('bootstrap-failure', 'matching-plist-failure', 'restore-plist-failure', 'login-item-rollback') and version == 'new' or mode == 'restart-failure' and version == 'old': sys.exit(25)
        state[config['Label']] = {'loaded': True, 'program': str(program), 'version': version}
        state_file.write_text(json.dumps(state))
    else:
        raise AssertionError('Unexpected launchctl command: ' + str(args))
elif name in ('Acouplet', 'XM5 Control'):
    assert args == ['--unregister-login-item'] or name == 'Acouplet' and args == ['--register-login-item'], args
    if mode == 'helper-failure' and name == 'Acouplet': sys.exit(19)
    if mode == 'legacy-helper-failure' and name == 'XM5 Control': sys.exit(19)
    if name == 'Acouplet':
        login_item = root / 'login-item.json'
        enabled = json.loads(login_item.read_text())['enabled']
        if args == ['--unregister-login-item']: print('login-item: ' + ('removed' if enabled else 'absent'))
        login_item.write_text(json.dumps({'enabled': args == ['--register-login-item']}))
elif name != 'sleep':
    raise AssertionError('Unexpected stub: ' + name)
'''

replacements = {
    '/usr/libexec/PlistBuddy': 'PlistBuddy', '/usr/bin/codesign': 'codesign',
    '/usr/bin/ditto': 'ditto', '/bin/launchctl': 'launchctl',
    '/usr/bin/osascript': 'osascript', '/usr/bin/pgrep': 'pgrep',
    '/usr/bin/plutil': 'plutil', '/bin/kill': 'kill', '/usr/bin/pluginkit': 'pluginkit',
    '/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister': 'lsregister',
}


def fixture(root, mode):
    (root / 'commands.jsonl').touch()
    package, applications, agents, stubs = (root / name for name in ('package', 'Applications', 'LaunchAgents', 'stubs'))
    for path in (package, applications, agents, stubs): path.mkdir()
    for name in (*replacements.values(), 'mv', 'sleep'):
        stub = stubs / name
        stub.write_text(stub_source)
        stub.chmod(0o755)
    for parent, name, identifier, version in (
        (package, 'Acouplet.app', 'dev.baglayan.Acouplet', 'new'),
        (applications, 'Acouplet.app', 'dev.baglayan.Acouplet', 'old'),
        (applications, 'XM5 Control Native.app', 'local.xm5control.native', 'legacy'),
        (applications, 'XM5 Control.app', 'local.xm5control', 'older'),
    ):
        app = parent / name
        (app / 'Contents/MacOS').mkdir(parents=True)
        (app / 'version').write_text(version)
        (app / 'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier': identifier}))
        executable = app / ('Contents/MacOS/Acouplet' if identifier == 'dev.baglayan.Acouplet' else 'Contents/MacOS/XM5 Control')
        executable.write_text(stub_source)
        executable.chmod(0o755)
        if version == 'old':
            controls = app / 'Contents/PlugIns/Acouplet Controls.appex/Contents'
            controls.mkdir(parents=True)
            (controls / 'Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier': 'dev.baglayan.Acouplet.controls'}))
    if mode == 'embedded-controls':
        (package / 'Acouplet.app/Contents/PlugIns/Acouplet Controls.appex').mkdir(parents=True)
    if mode == 'foreign-controls':
        (applications / 'Acouplet.app/Contents/PlugIns/Acouplet Controls.appex/Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier': 'unrelated'}))
    state = {}
    configs = {}
    for label, app_name, version in ((native_label, 'Acouplet.app', 'old'), (legacy_label, 'XM5 Control Native.app', 'legacy'), (older_label, 'XM5 Control.app', 'older')):
        program = str(applications / app_name / ('Contents/MacOS/Acouplet' if label == native_label else 'Contents/MacOS/XM5 Control'))
        configs[label] = plistlib.dumps({'Label': label, 'ProgramArguments': [program, '--background-service'], 'KeepAlive': True, 'OldConfiguration': 'preserve'})
        if mode in ('matching-plist', 'matching-plist-failure') and label == native_label:
            configs[label] = plistlib.dumps({
                'KeepAlive': {'SuccessfulExit': False}, 'RunAtLoad': True, 'LimitLoadToSessionType': 'Aqua',
                'AssociatedBundleIdentifiers': ['dev.baglayan.Acouplet'],
                'EnvironmentVariables': {'ACOUPLET_SERVICE_POLICY': 'successful-exit-v1'},
                'ProgramArguments': [program, '--background-service'], 'Label': label,
            }, fmt=plistlib.FMT_BINARY, sort_keys=False)
        (agents / (label + '.plist')).write_bytes(configs[label])
        if mode in ('matching-plist', 'matching-plist-failure') and label == native_label:
            os.utime(agents / (label + '.plist'), ns=(1650000000123456789, 1650000000123456789))
        state[label] = {'loaded': True, 'program': program, 'version': version}
    for relative in ('Applications/Unrelated.app/keep', 'Development/Acouplet.app/keep',
                     'Preferences/dev.baglayan.Acouplet.plist', 'Applications/.Acouplet.previous-interrupted.app/keep',
                     'LaunchAgents/dev.baglayan.Acouplet.agent.plist.previous-interrupted', 'LaunchAgents/unrelated.plist'):
        path = root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text('preserve')
    if mode in ('inactive-update', 'fresh-install', 'login-item-rollback'): state[native_label]['loaded'] = False
    if mode == 'fresh-install':
        shutil.rmtree(applications / 'Acouplet.app')
        (agents / (native_label + '.plist')).unlink()
    if mode == 'login-item-rollback': (agents / (native_label + '.plist')).unlink()
    if mode == 'orphan-service': (agents / (native_label + '.plist')).unlink()
    if mode in ('legacy-wrong-team', 'installed-wrong-team'):
        (applications / ('XM5 Control Native.app' if mode == 'legacy-wrong-team' else 'Acouplet.app') / 'team').write_text('OTHER12345')
    if mode == 'unexpected-bundle':
        (applications / 'Acouplet.app/Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier': 'unrelated'}))
    if mode in ('unrelated-legacy', 'repurposed-legacy'):
        (applications / 'XM5 Control Native.app/Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier': 'unrelated'}))
    if mode == 'unrelated-legacy':
        (agents / (legacy_label + '.plist')).unlink()
        state[legacy_label]['loaded'] = False
    if mode in ('unexpected-agent', 'unexpected-legacy-agent'):
        label = native_label if mode == 'unexpected-agent' else legacy_label
        config = plistlib.loads(configs[label])
        config['ProgramArguments'][0] = '/unrelated/program'
        (agents / (label + '.plist')).write_bytes(plistlib.dumps(config))
    if mode in ('unexpected-loaded-service', 'unexpected-loaded-legacy'):
        state[native_label if mode == 'unexpected-loaded-service' else legacy_label]['program'] = '/unrelated/program'
    if mode == 'symlink-agent':
        plist = agents / (native_label + '.plist')
        plist.unlink()
        plist.symlink_to(root / 'Preferences/dev.baglayan.Acouplet.plist')
    (root / 'state.json').write_text(json.dumps(state))
    (root / 'login-item.json').write_text(json.dumps({'enabled': mode in ('success', 'matching-plist', 'fresh-install', 'inactive-update', 'login-item-rollback', 'helper-failure')}))
    (root / 'processes.json').write_text(json.dumps({
        'native': [] if mode in ('inactive-update', 'fresh-install', 'login-item-rollback') else [100, 101] if mode == 'native-partial-quit' else [100],
        'quit_requested': False, 'exit_checks': 0,
        'legacy': [200] if mode in ('legacy-quit-success', 'legacy-quit-declined') else [],
        'older': [201] if mode == 'legacy-quit-success' else [],
        'owner': [150] if mode == 'ldac-owner-running' else [],
    }))
    return configs, state


def run(root, mode, name='Install.command', arguments=()):
    script = (packaging / name).read_text().replace('/Applications', str(root / 'Applications')).replace('$HOME/Library/LaunchAgents', str(root / 'LaunchAgents')).replace('$HOME/Library/PreferencePanes', str(root / 'PreferencePanes'))
    for original, stub in replacements.items(): script = script.replace(original, str(root / 'stubs' / stub))
    assert not any(original in script for original in replacements)
    assert '/Applications' not in script.replace(str(root / 'Applications'), '')
    command = root / 'package' / name
    command.write_text(script)
    env = {**os.environ, 'PATH': str(root / 'stubs') + ':' + os.environ['PATH'],
           'ACOUPLET_INSTALL_CHECK_ROOT': str(root), 'ACOUPLET_INSTALL_CHECK_MODE': mode}
    return subprocess.run(['/bin/zsh', str(command), *arguments], env=env, text=True, capture_output=True, timeout=30)


scenarios = ('helper-failure', 'success', 'matching-plist', 'matching-plist-failure', 'fresh-install', 'inactive-update', 'staging-failure',
             'bootstrap-failure', 'stop-failure', 'restore-app-failure', 'restore-plist-failure',
             'move-new-failure', 'restart-failure', 'legacy-stop-failure', 'legacy-running',
             'legacy-unregister-failure', 'legacy-helper-failure', 'legacy-bad-signature', 'legacy-wrong-team', 'installed-wrong-team', 'legacy-quit-success', 'legacy-quit-declined', 'installed-bad-signature', 'installed-validation-failure', 'native-register-failure', 'unexpected-bundle', 'unexpected-agent',
             'unexpected-legacy-agent', 'unexpected-loaded-service', 'unexpected-loaded-legacy',
             'unrelated-legacy', 'repurposed-legacy', 'symlink-agent', 'orphan-service', 'concurrent-install',
             'native-quit-declined', 'native-quit-timeout', 'native-quit-stalled', 'native-partial-quit',
             'native-keepalive-relaunch', 'native-delayed-quit', 'login-item-rollback',
             'controls-unregister-failure', 'embedded-controls', 'foreign-controls', 'ldac-owner-running')
for scenario in scenarios:
    with tempfile.TemporaryDirectory(prefix='acouplet-install-check-') as directory:
        root = Path(directory)
        configs, original_state = fixture(root, scenario)
        applications, agents = root / 'Applications', root / 'LaunchAgents'
        native = applications / 'Acouplet.app'
        legacy = applications / 'XM5 Control Native.app'
        plist = agents / (native_label + '.plist')
        before_plist = plist.read_bytes() if plist.exists() else None
        before_plist_mtime = plist.stat().st_mtime_ns if plist.exists() else None
        before_plist_inode = plist.stat().st_ino if plist.exists() else None
        with (applications / '.Acouplet-install.lock').open('w') as lock:
            if scenario == 'concurrent-install': fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            result = run(root, scenario)
        output = result.stdout + result.stderr
        state = json.loads((root / 'state.json').read_text())
        successful = scenario in ('success', 'matching-plist', 'fresh-install', 'inactive-update',
                                  'native-keepalive-relaunch', 'native-delayed-quit', 'legacy-quit-success', 'ldac-owner-running')
        assert (result.returncode == 0) == successful, (scenario, result.returncode, output)
        recovery_apps = [path for path in applications.glob('.*previous-*.app') if 'interrupted' not in path.name]
        recovery_plists = [path for path in agents.glob('*.previous-*') if 'interrupted' not in path.name]
        staged_apps = list(applications.glob('.*installing-*.app'))
        if scenario == 'restore-app-failure':
            assert not native.exists() and len(recovery_apps) == len(recovery_plists) == len(staged_apps) == 1, output
            assert (recovery_apps[0] / 'version').read_text() == 'old'
        elif scenario == 'move-new-failure':
            assert (native / 'version').read_text() == 'new' and len(recovery_apps) == len(recovery_plists) == 1, output
        elif scenario in ('restore-plist-failure', 'restart-failure', 'stop-failure'):
            assert (native / 'version').read_text() == 'old' and len(staged_apps) == 1, output
            assert len(recovery_plists) == 1, output
        else:
            assert not recovery_apps and not recovery_plists and not staged_apps, output
            expected = 'new' if successful or scenario in ('legacy-unregister-failure', 'legacy-helper-failure', 'native-register-failure') else 'old'
            assert (native / 'version').read_text() == expected, output
        if successful:
            assert json.loads((root / 'login-item.json').read_text())['enabled'] == (scenario == 'inactive-update'), output
            assert state[native_label]['loaded'] == (scenario != 'inactive-update'), state
            assert plistlib.loads(plist.read_bytes()) == {
                'Label': native_label,
                'ProgramArguments': [str(native / 'Contents/MacOS/Acouplet'), '--background-service'],
                'AssociatedBundleIdentifiers': ['dev.baglayan.Acouplet'],
                'LimitLoadToSessionType': 'Aqua', 'RunAtLoad': True, 'KeepAlive': {'SuccessfulExit': False},
                'EnvironmentVariables': {'ACOUPLET_SERVICE_POLICY': 'successful-exit-v1'},
            }, output
            assert not legacy.exists() and not (applications / 'XM5 Control.app').exists(), output
            assert not state[legacy_label]['loaded'] and not (agents / (legacy_label + '.plist')).exists(), state
        elif scenario in ('legacy-unregister-failure', 'legacy-helper-failure'):
            assert state[native_label]['loaded'] and state[native_label]['version'] == 'new' and legacy.exists(), state
        elif scenario == 'native-register-failure':
            assert state[native_label]['loaded'] and state[native_label]['version'] == 'new', state
            assert not state[legacy_label]['loaded'] and not legacy.exists(), state
            assert 'application registration could not be refreshed' in output
        elif scenario in ('bootstrap-failure', 'matching-plist-failure', 'installed-validation-failure', 'helper-failure'):
            assert state == original_state and plist.read_bytes() == configs[native_label], state
            if scenario == 'helper-failure':
                assert 'previous login-item registration could not be removed' in output and legacy.exists(), output
        elif scenario not in ('restore-app-failure', 'restore-plist-failure', 'move-new-failure', 'restart-failure'):
            assert state == original_state and (plist.read_bytes() if plist.exists() else None) == before_plist, (scenario, state, original_state, output)
        if scenario in ('matching-plist', 'matching-plist-failure'):
            assert plist.read_bytes() == before_plist and plist.stat().st_mtime_ns == before_plist_mtime and plist.stat().st_ino == before_plist_inode, output
        if successful or scenario == 'native-register-failure':
            commands = [json.loads(line) for line in (root / 'commands.jsonl').read_text().splitlines()]
            assert ['lsregister', '-f', str(native)] in commands, commands
            assert (['Acouplet', '--unregister-login-item'] in commands) == (scenario != 'inactive-update'), commands
            assert commands.count(['XM5 Control', '--unregister-login-item']) == 2, commands
            if scenario != 'inactive-update':
                # The login item goes before the service starts, so no copy of the app is running when it checks for duplicates.
                bootstrap_index = next(index for index, command in enumerate(commands)
                                       if command[:2] == ['launchctl', 'bootstrap'] and command[3].endswith(native_label + '.plist'))
                assert commands.index(['Acouplet', '--unregister-login-item']) < bootstrap_index, commands
            assert ['Acouplet', '--register-login-item'] not in commands, commands
        if scenario in ('login-item-rollback', 'helper-failure'):
            assert json.loads((root / 'login-item.json').read_text())['enabled']
            commands = [json.loads(line) for line in (root / 'commands.jsonl').read_text().splitlines()]
            assert ['Acouplet', '--unregister-login-item'] in commands, commands
            # A failed start gives the login item back; a failed removal never took it away.
            assert (['Acouplet', '--register-login-item'] in commands) == (scenario == 'login-item-rollback'), commands
        if scenario.startswith('native-quit-') or scenario == 'native-partial-quit':
            commands = [json.loads(line) for line in (root / 'commands.jsonl').read_text().splitlines()]
            assert ['osascript', '-', 'dev.baglayan.Acouplet'] in commands, commands
            assert not any(command[0] == 'launchctl' and command[1] in ('bootout', 'bootstrap') for command in commands), commands
            assert not any(command[0] == 'mv' for command in commands), commands
            assert plist.stat().st_mtime_ns == before_plist_mtime and plist.stat().st_ino == before_plist_inode, output
            assert 'Nothing was replaced' in output, output
            processes = json.loads((root / 'processes.json').read_text())
            assert processes['native'] == ([101] if scenario == 'native-partial-quit' else [100]), processes
        if scenario == 'legacy-quit-success':
            assert ['osascript', '-', 'local.xm5control.native'] in commands and ['osascript', '-', 'local.xm5control'] in commands, commands
            first_move = next(index for index, command in enumerate(commands) if command[0] == 'mv')
            assert commands.index(['kill', '-0', '200']) < first_move and commands.index(['kill', '-0', '201']) < first_move, commands
        if scenario in ('success', 'native-keepalive-relaunch', 'native-delayed-quit', 'ldac-owner-running'):
            commands = [json.loads(line) for line in (root / 'commands.jsonl').read_text().splitlines()]
            quit_index = commands.index(['osascript', '-', 'dev.baglayan.Acouplet'])
            bootout_index = next(index for index, command in enumerate(commands)
                                if command[:2] == ['launchctl', 'bootout'] and command[2].endswith('/' + native_label))
            assert quit_index < bootout_index, commands
            checks = [command for command in commands[quit_index + 1:bootout_index] if command[0] == 'kill']
            assert checks and all(command == ['kill', '-0', '100'] for command in checks), commands
            assert len(checks) == (3 if scenario == 'native-delayed-quit' else 1), checks
        for marker in root.rglob('keep'): assert marker.read_text() == 'preserve'
        assert (root / 'Preferences/dev.baglayan.Acouplet.plist').read_text() == 'preserve'
        assert (agents / 'unrelated.plist').read_text() == 'preserve'
        assert (agents / (native_label + '.plist.previous-interrupted')).read_text() == 'preserve'
        commands = [json.loads(line) for line in (root / 'commands.jsonl').read_text().splitlines()]
        controls = native / 'Contents/PlugIns/Acouplet Controls.appex'
        unregistered = ['pluginkit', '-r', str(controls)] in commands
        reregistered = ['pluginkit', '-a', str(controls)] in commands
        if successful:
            assert not controls.exists()
            assert unregistered == (scenario != 'fresh-install'), commands
            assert not reregistered, commands
        if scenario in ('bootstrap-failure', 'matching-plist-failure', 'login-item-rollback', 'helper-failure'):
            assert controls.exists() and unregistered and reregistered, commands
        if scenario in ('embedded-controls', 'foreign-controls'):
            assert not unregistered and not reregistered, commands
        if scenario == 'concurrent-install':
            assert run(root, 'success').returncode == 0
        print(scenario + ': passed')

for scenario in ('success', 'orphan-service', 'unexpected-agent', 'unexpected-loaded-legacy',
                 'unexpected-bundle', 'repurposed-legacy', 'stop-failure', 'inactive-update',
                 'native-quit-declined', 'native-quit-timeout', 'native-quit-stalled', 'native-partial-quit',
                 'native-keepalive-relaunch', 'native-delayed-quit', 'legacy-quit-success', 'legacy-quit-declined', 'legacy-wrong-team'):
    with tempfile.TemporaryDirectory(prefix='acouplet-uninstall-check-') as directory:
        root = Path(directory)
        configs, original_state = fixture(root, scenario)
        if scenario == 'inactive-update':
            (root / 'processes.json').write_text(json.dumps({'native': [100], 'quit_requested': False, 'exit_checks': 0, 'legacy': [], 'older': []}))
        result = run(root, scenario, 'Uninstall Service.command')
        state = json.loads((root / 'state.json').read_text())
        if scenario in ('success', 'orphan-service', 'inactive-update', 'native-keepalive-relaunch', 'native-delayed-quit', 'legacy-quit-success'):
            assert result.returncode == 0, result.stdout + result.stderr
            assert all(not service['loaded'] for service in state.values()), state
            assert not any((root / 'LaunchAgents' / (label + '.plist')).exists() for label in configs)
            assert run(root, scenario, 'Uninstall Service.command').returncode == 0
        else:
            assert result.returncode != 0 and state == original_state, result.stdout + result.stderr
            assert all((root / 'LaunchAgents' / (label + '.plist')).exists() for label in configs)
        commands = [json.loads(line) for line in (root / 'commands.jsonl').read_text().splitlines()]
        if scenario.startswith('native-quit-') or scenario == 'native-partial-quit':
            assert ['osascript', '-', 'dev.baglayan.Acouplet'] in commands, commands
            assert not any(command[0] == 'launchctl' and command[1] in ('bootout', 'bootstrap') for command in commands), commands
            assert 'Nothing was removed' in result.stdout + result.stderr
        if scenario in ('success', 'orphan-service', 'native-keepalive-relaunch', 'native-delayed-quit'):
            quit_index = commands.index(['osascript', '-', 'dev.baglayan.Acouplet'])
            bootout_index = next(index for index, command in enumerate(commands)
                                 if command[:2] == ['launchctl', 'bootout'] and command[2].endswith('/' + native_label))
            assert quit_index < bootout_index, commands
            checks = [command for command in commands[quit_index + 1:bootout_index] if command[0] == 'kill']
            assert len(checks) == (3 if scenario == 'native-delayed-quit' else 1), checks
        if scenario == 'inactive-update':
            assert ['osascript', '-', 'dev.baglayan.Acouplet'] in commands, commands
            assert json.loads((root / 'processes.json').read_text())['native'] == []
        assert (root / 'Applications/Acouplet.app/version').read_text() == 'old'
        assert (root / 'Applications/XM5 Control Native.app/version').read_text() == 'legacy'
        assert (root / 'Preferences/dev.baglayan.Acouplet.plist').read_text() == 'preserve'
        print('uninstall-' + scenario + ': passed')

for scenario in ('running', 'running-release-changed', 'local-stopped', 'local-release-changed', 'local-stage-changed', 'local-hud-check-changed', 'local-ldac-media-changed', 'local-audio-capture-changed', 'local-output-driver-changed', 'local-output-driver-info-changed', 'local-driver-installer-changed', 'local-driver-uninstaller-changed', 'local-resource-seal-changed'):
    with tempfile.TemporaryDirectory(prefix='acouplet-local-install-check-') as directory:
        root = Path(directory)
        mode = 'success' if scenario.startswith('running') else 'inactive-update'
        _, initial_state = fixture(root, mode)
        source = root / 'package/Acouplet.app'
        binaries = ('Contents/MacOS/Acouplet', 'Contents/Helpers/Acouplet Battery Publisher', 'Contents/Frameworks/SonyNativeHUD.dylib', 'Contents/Helpers/SonyNativeHUDCheck', 'Contents/Resources/Assets.car', 'Contents/Frameworks/Sparkle.framework/Versions/B/Sparkle', 'Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate', 'Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app/Contents/MacOS/Updater', 'Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Installer.xpc/Contents/MacOS/Installer', 'Contents/Helpers/LDACSignaling', 'Contents/Helpers/LDACMediaTransport', 'Contents/Helpers/SonyAudioConnection', 'Contents/Helpers/LDACLogObserver', 'Contents/Helpers/Acouplet Audio.app/Contents/MacOS/AcoupletAudio', 'Contents/Helpers/AcoupletLDACOutput.driver/Contents/MacOS/AcoupletVirtualOutput', 'Contents/Helpers/AcoupletLDACOutput.driver/Contents/Info.plist', 'Contents/Resources/Acouplet LDAC Output.pkg', 'Contents/Resources/Acouplet LDAC Removal.pkg', 'Contents/_CodeSignature/CodeResources')
        for relative in binaries[1:]:
            binary = source / relative
            binary.parent.mkdir(parents=True, exist_ok=True)
            binary.write_text(relative)
        release = root / 'Release.app'
        shutil.copytree(source, release)
        lines = ['Prepared UTC: 2026-09-27T00:00:00Z', 'Revision: fixture', 'Worktree: dirty', 'Release app: ' + str(release)]
        lines += ['SHA256\t' + hashlib.sha256((source / relative).read_bytes()).hexdigest() + '\t' + relative for relative in binaries]
        (root / 'package/Local Build Receipt.txt').write_text('\n'.join(lines) + '\n')
        if scenario in ('local-release-changed', 'running-release-changed'): (release / binaries[0]).write_text('later build')
        if scenario == 'local-stage-changed': (source / binaries[1]).write_text('changed stage')
        if scenario == 'local-hud-check-changed': (source / 'Contents/Helpers/SonyNativeHUDCheck').write_text('changed probe')
        if scenario == 'local-ldac-media-changed': (source / 'Contents/Helpers/LDACMediaTransport').write_text('changed encoder')
        if scenario == 'local-audio-capture-changed': (release / 'Contents/Helpers/Acouplet Audio.app/Contents/MacOS/AcoupletAudio').write_text('changed capture')
        if scenario == 'local-output-driver-changed': (source / 'Contents/Helpers/AcoupletLDACOutput.driver/Contents/MacOS/AcoupletVirtualOutput').write_text('changed driver')
        if scenario == 'local-output-driver-info-changed': (release / 'Contents/Helpers/AcoupletLDACOutput.driver/Contents/Info.plist').write_text('changed driver metadata')
        if scenario == 'local-driver-installer-changed': (source / 'Contents/Resources/Acouplet LDAC Output.pkg').write_text('changed installer')
        if scenario == 'local-driver-uninstaller-changed': (source / 'Contents/Resources/Acouplet LDAC Removal.pkg').write_text('changed uninstaller')
        if scenario == 'local-resource-seal-changed': (source / 'Contents/_CodeSignature/CodeResources').write_text('changed resource seal')
        result = run(root, mode, arguments=('--require-stopped',))
        commands = [json.loads(line) for line in (root / 'commands.jsonl').read_text().splitlines()]
        # The local-build mode quits the running app itself, but only once the receipt has been verified.
        assert any(command[0] == 'osascript' for command in commands) == (scenario == 'running'), commands
        receipts = list(root.glob('Local Install-*.txt'))
        installed = root / 'Applications/Acouplet.app'
        if scenario in ('local-stopped', 'running'):
            assert result.returncode == 0, result.stdout + result.stderr
            assert len(receipts) == 1
            assert 'Release/staged/installed identity and strict signature verification: passed' in receipts[0].read_text()
            assert 'Installed UTC:' in receipts[0].read_text()
            for relative in binaries: assert (installed / relative).read_bytes() == (release / relative).read_bytes()
            assert json.loads((root / 'state.json').read_text())[native_label]['loaded'] == (scenario == 'running')
        else:
            assert result.returncode != 0, result.stdout + result.stderr
            assert not receipts
            assert (installed / 'version').read_text() == 'old'
            assert json.loads((root / 'state.json').read_text()) == initial_state
        assert (root / 'Preferences/dev.baglayan.Acouplet.plist').read_text() == 'preserve'
        print('require-stopped-' + scenario + ': passed')


for scenario in ('pane-success', 'pane-legacy-target', 'pane-foreign-target', 'pane-symlink-target', 'pane-bad-signature', 'pane-stage-failure', 'pane-commit-failure', 'pane-foreign-prototype'):
    with tempfile.TemporaryDirectory(prefix='acouplet-pane-install-check-') as directory:
        root = Path(directory)
        fixture(root, 'inactive-update')
        panes = root / 'PreferencePanes'
        panes.mkdir()
        for suffix in ('001122334455', '001122334466'):
            info = {'CFBundleIdentifier': 'dev.baglayan.Acouplet.preference-pane.' + suffix.lower(),
                    'SonyDeviceAddress': ':'.join(suffix[i:i + 2] for i in range(0, 12, 2)),
                    'NSPrincipalClass': 'SonyPreferencePane_' + suffix}
            for parent, version in ((root / 'package/PreferencePanes', 'new'), (panes, 'old')):
                pane = parent / ('Sony-' + suffix + '.prefPane')
                (pane / 'Contents').mkdir(parents=True)
                (pane / 'Contents/Info.plist').write_bytes(plistlib.dumps({**info, 'CFBundleIdentifier': 'local.xm5control.native.preference-pane.' + suffix.lower()} if scenario == 'pane-legacy-target' and version == 'old' else info))
                (pane / 'version').write_text(version)
        prototype = panes / 'Sony Headphones Compatibility.prefPane'
        (prototype / 'Contents').mkdir(parents=True)
        prototype_id = 'unrelated' if scenario == 'pane-foreign-prototype' else 'dev.baglayan.Acouplet.research.preference-pane'
        (prototype / 'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier': prototype_id}))
        (panes / 'Other.prefPane').mkdir()
        first = panes / 'Sony-001122334455.prefPane'
        second = panes / 'Sony-001122334466.prefPane'
        if scenario == 'pane-foreign-target':
            (second / 'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier': 'unrelated'}))
        if scenario == 'pane-symlink-target':
            shutil.rmtree(second)
            second.symlink_to(panes / 'Other.prefPane', target_is_directory=True)
        result = run(root, scenario)
        succeeded = scenario in ('pane-success', 'pane-legacy-target', 'pane-foreign-prototype')
        assert (result.returncode == 0) == succeeded, (scenario, result.stdout, result.stderr)
        app = root / 'Applications/Acouplet.app'
        if succeeded:
            assert (app / 'version').read_text() == 'new'
            assert (first / 'version').read_text() == (second / 'version').read_text() == 'new'
            assert prototype.exists() == (scenario == 'pane-foreign-prototype')
        elif scenario == 'pane-commit-failure':
            assert (app / 'version').read_text() == 'new'
            assert (first / 'version').read_text() == 'new' and (second / 'version').read_text() == 'old'
            assert prototype.exists()
            assert 'could not all be installed' in result.stderr
        else:
            assert (app / 'version').read_text() == (first / 'version').read_text() == 'old'
            assert prototype.exists()
        assert (panes / 'Other.prefPane').is_dir()
        assert not list(panes.glob('.*.installing-*')) and not list(panes.glob('.*.previous-*'))
        assert not json.loads((root / 'state.json').read_text())[native_label]['loaded']
        print(scenario + ': passed')

for scenario in ('legacy-controls', 'foreign-legacy-controls', 'concurrent-legacy-install'):
    with tempfile.TemporaryDirectory(prefix='acouplet-legacy-install-check-') as directory:
        root = Path(directory)
        fixture(root, 'success')
        controls = root / 'Applications/XM5 Control Native.app/Contents/PlugIns/XM5 Controls.appex'
        (controls / 'Contents').mkdir(parents=True)
        (controls / 'Contents/Info.plist').write_bytes(plistlib.dumps({
            'CFBundleIdentifier': 'unrelated' if scenario == 'foreign-legacy-controls' else 'local.xm5control.native.controls'}))
        with (root / 'Applications/.XM5-Control-install.lock').open('w') as lock:
            if scenario == 'concurrent-legacy-install': fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            result = run(root, 'success')
        assert (result.returncode == 0) == (scenario == 'legacy-controls'), (scenario, result.stdout, result.stderr)
        commands = [json.loads(line) for line in (root / 'commands.jsonl').read_text().splitlines()]
        assert (['pluginkit', '-r', str(controls)] in commands) == (scenario == 'legacy-controls'), commands
        assert (root / 'Applications/Acouplet.app/version').read_text() == ('new' if scenario == 'legacy-controls' else 'old')
        print(scenario + ': passed')
