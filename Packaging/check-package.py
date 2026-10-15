from pathlib import Path
import hashlib, json, os, plistlib, re, shutil, subprocess, tempfile, zipfile

packaging = Path(__file__).parent
project = json.loads(subprocess.check_output(['/usr/bin/plutil', '-convert', 'json', '-o', '-', str(packaging.parent / 'Acouplet.xcodeproj/project.pbxproj')]))
app_target = project['objects']['500000000000000000000001']
assert '400000000000000000000009' not in app_target['buildPhases']
assert 'A00000000000000000000003' not in app_target['dependencies']
assert '40000000000000000000000B' in app_target['buildPhases']
assert 'A00000000000000000000004' in app_target['dependencies']
resources = project['objects']['400000000000000000000005']['files']
resource_paths = [project['objects'][project['objects'][key]['fileRef']]['path'] for key in resources]
assert 'LICENSE' in resource_paths and 'THIRD-PARTY-NOTICES.md' in resource_paths
assert project['objects']['700000000000000000000003']['buildSettings']['ACOUPLET_DISTRIBUTION'] == 'development'

stub_source = r'''#!/usr/bin/python3
from pathlib import Path
import json, os, plistlib, re, shutil, subprocess, sys
root = Path(os.environ['ACOUPLET_PACKAGE_CHECK_ROOT'])
mode = os.environ['ACOUPLET_PACKAGE_CHECK_MODE']
name = Path(sys.argv[0]).name
args = sys.argv[1:]
with (root / 'commands.jsonl').open('a') as log:
    log.write(json.dumps([name, *args]) + '\n')
if name == 'release-source.py':
    record = Path(args[2])
    if args[0] == 'capture':
        development = args[3:] == ['--development']
        if mode == 'source-dirty' and not development: sys.exit('Production packaging requires clean source.')
        record.write_text(json.dumps({'development': development}))
    else:
        development = json.loads(record.read_text())['development']
        if not development and (mode == 'source-drift' or (mode == 'source-drift-archive' and (root / 'dist/Acouplet.zip.pending').exists())):
            sys.exit('Release source changed during packaging.')
        state = 'development (dirty)' if development else 'production clean'
        print('Revision: ' + 'a' * 40 + '\nSource tree: ' + 'b' * 40 + '\nSource input SHA256: ' + 'c' * 64 + '\nWorktree: ' + state)
elif name == 'xcrun':
    assert args[0] == 'xcodebuild' and args[-1] == 'build', args
    assert '-allowProvisioningUpdates' not in args, args
    if mode == 'build-failure': sys.exit(65)
    settings = dict(arg.split('=', 1) for arg in args if '=' in arg)
    app = root / '.build/Build/Products/Release/Acouplet.app'
    controls = app / 'Contents/PlugIns/Acouplet Controls.appex'
    assert not controls.exists()
    app.mkdir(parents=True, exist_ok=True)
    helper = app / 'Contents/Helpers/Acouplet Battery Publisher'
    helper.parent.mkdir(parents=True)
    hud = app / 'Contents/Frameworks/SonyNativeHUD.dylib'
    hud.parent.mkdir(parents=True)
    hud_check = app / 'Contents/Helpers/SonyNativeHUDCheck'
    sparkle = app / 'Contents/Frameworks/Sparkle.framework'
    sparkle_codes = [sparkle / 'Versions/B/XPCServices/Installer.xpc', sparkle / 'Versions/B/Autoupdate', sparkle / 'Versions/B/Updater.app', sparkle]
    ldac_audio = app / 'Contents/Helpers/Acouplet Audio.app'
    ldac_audio.mkdir()
    ldac_driver = app / 'Contents/Helpers/AcoupletLDACOutput.driver'
    ldac_driver.mkdir()
    ldac_codes = [app / 'Contents/Helpers' / name for name in ['LDACSignaling', 'LDACMediaTransport', 'SonyAudioConnection', 'LDACLogObserver', 'Acouplet Audio.app', 'AcoupletLDACOutput.driver']]
    for bundle in sparkle_codes:
        if bundle.name == 'Autoupdate': bundle.touch()
        else: bundle.mkdir(parents=True, exist_ok=True)
    (sparkle / 'Resources').mkdir()
    (sparkle / 'Resources/Info.plist').write_bytes(plistlib.dumps({'CFBundleShortVersionString': '2.10.0'}))
    team = settings.get('DEVELOPMENT_TEAM', 'ABCDE12345')
    adhoc = settings['CODE_SIGN_IDENTITY'] == '-'
    for bundle in (app, helper, hud, hud_check, *sparkle_codes, *ldac_codes):
        metadata = {'apple': not adhoc, 'team': 'not set' if adhoc else team,
                    'developer_id': settings['CODE_SIGN_IDENTITY'].startswith('Developer ID Application') or bool(re.fullmatch(r'[0-9A-Fa-f]{40}', settings['CODE_SIGN_IDENTITY'])),
                    'runtime': settings.get('ENABLE_HARDENED_RUNTIME') == 'YES',
                    'debuggable': settings.get('CODE_SIGN_INJECT_BASE_ENTITLEMENTS') != 'NO'}
        if mode == 'adhoc-output': metadata['apple'] = False
        if mode == 'development-output': metadata['developer_id'] = False
        if mode == 'development-driver' and bundle == ldac_driver: metadata['developer_id'] = False
        if mode == 'development-helper' and bundle == helper: metadata['developer_id'] = False
        if mode == 'wrong-team': metadata['team'] = 'OTHER67890'
        if mode == 'missing-team': metadata['team'] = 'not set'
        if mode == 'missing-runtime-app' and bundle == app: metadata['runtime'] = False
        if mode == 'debuggable-app' and bundle == app: metadata['debuggable'] = True
        metadata['helper'] = bundle == helper
        metadata['build'] = settings['CURRENT_PROJECT_VERSION']
        if mode == 'wrong-build' and bundle == helper: metadata['build'] = '1'
        if bundle == helper:
            if mode == 'different-helper-team': metadata['team'] = 'OTHER67890'
            if mode == 'adhoc-helper': metadata['apple'] = False
            if mode == 'missing-runtime-helper': metadata['runtime'] = False
            if mode == 'debuggable-helper': metadata['debuggable'] = True
        if bundle == hud:
            if mode == 'different-hud-team': metadata['team'] = 'OTHER67890'
            if mode == 'missing-runtime-hud': metadata['runtime'] = False
        if bundle == hud_check:
            if mode == 'different-hud-check-team': metadata['team'] = 'OTHER67890'
            if mode == 'missing-runtime-hud-check': metadata['runtime'] = False
            if mode == 'debuggable-hud-check': metadata['debuggable'] = True
        if bundle == sparkle:
            if mode == 'different-sparkle-team': metadata['team'] = 'OTHER67890'
            if mode == 'missing-runtime-sparkle': metadata['runtime'] = False
        if bundle in ldac_codes:
            if mode == 'different-ldac-team': metadata['team'] = 'OTHER67890'
            if mode == 'missing-runtime-ldac': metadata['runtime'] = False
            if mode == 'debuggable-ldac': metadata['debuggable'] = True
        if bundle == ldac_audio:
            (bundle / 'Contents').mkdir()
            (bundle / 'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleVersion': '1' if mode == 'wrong-audio-build' else metadata['build']}))
        if bundle == ldac_driver:
            (bundle / 'Contents/Resources').mkdir(parents=True)
            (bundle / 'Contents/Info.plist').write_bytes(plistlib.dumps({
                'CFBundleIdentifier': 'unrelated' if mode == 'wrong-driver-identity' else 'dev.baglayan.Acouplet.LDACOutput',
                'CFBundleVersion': '1' if mode == 'wrong-driver-build' else metadata['build']}))
            for name in ('NullAudio.c', 'LICENSE.txt'):
                shutil.copy2(root / 'Helpers/LDAC/VirtualOutput' / name, bundle / 'Contents/Resources' / name)
            if mode == 'changed-apple-source': (bundle / 'Contents/Resources/NullAudio.c').write_text('changed')
        metadata_file = bundle / 'signature.json' if bundle.is_dir() else bundle.with_suffix('.signature.json')
        metadata_file.write_text(json.dumps(metadata))
        if bundle == app:
            (bundle / 'Contents').mkdir(exist_ok=True)
            distribution = settings['ACOUPLET_DISTRIBUTION'] if mode != 'wrong-distribution' else ('production' if settings['ACOUPLET_DISTRIBUTION'] == 'development' else 'development')
            feed = 'https://baglayan.dev/updates/appcast.xml' if distribution != 'development' or mode == 'development-upstream-feed' else ''
            (bundle / 'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleVersion': metadata['build'], 'CFBundleExecutable': 'Acouplet',
                'AcoupletDistribution': distribution,
                'SUFeedURL': feed, 'SUPublicEDKey': 'AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE=',
                'SUVerifyUpdateBeforeExtraction': True, 'SURequireSignedFeed': True, 'SUSignedFeedFailureExpirationInterval': 0,
                'SUEnableInstallerLauncherService': False, 'SUEnableDownloaderService': False, 'SUEnableSystemProfiling': False,
                'SUEnableAutomaticChecks': True, 'SUAutomaticallyUpdate': False}))
    for relative in ('Contents/MacOS/Acouplet', 'Contents/Helpers/Acouplet Battery Publisher', 'Contents/Frameworks/SonyNativeHUD.dylib', 'Contents/Helpers/SonyNativeHUDCheck', 'Contents/Resources/Assets.car', 'Contents/Frameworks/Sparkle.framework/Versions/B/Sparkle', 'Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app/Contents/MacOS/Updater', 'Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Installer.xpc/Contents/MacOS/Installer', 'Contents/Helpers/LDACSignaling', 'Contents/Helpers/LDACMediaTransport', 'Contents/Helpers/SonyAudioConnection', 'Contents/Helpers/LDACLogObserver', 'Contents/Helpers/Acouplet Audio.app/Contents/MacOS/AcoupletAudio', 'Contents/Helpers/AcoupletLDACOutput.driver/Contents/MacOS/AcoupletVirtualOutput'):
        binary = app / relative
        binary.parent.mkdir(parents=True, exist_ok=True)
        binary.write_text(relative)
    for notice in ('LICENSE', 'THIRD-PARTY-NOTICES.md'):
        shutil.copy2(root / notice, app / 'Contents/Resources' / notice)
    for notice in ('LICENSE', 'NOTICE'):
        shutil.copy2(root / 'Vendor/libldac' / notice, app / 'Contents/Resources' / ('LDAC-' + notice + '.txt'))
    if mode == 'missing-ldac-notice': (app / 'Contents/Resources/LDAC-NOTICE.txt').unlink()
    (app / 'Contents/Resources/Sparkle-LICENSE.txt').write_text('Copyright (c) 2006-2013 Andy Matuschak.')
    if mode == 'missing-license': (app / 'Contents/Resources/LICENSE').unlink()
    if mode == 'stale-notices': (app / 'Contents/Resources/THIRD-PARTY-NOTICES.md').write_text('stale')
    if mode == 'embedded-controls': controls.mkdir(parents=True)
    if mode == 'missing-helper': helper.with_suffix('.signature.json').unlink(); helper.unlink()
    if mode == 'missing-hud': hud.with_suffix('.signature.json').unlink(); hud.unlink()
    if mode == 'missing-hud-check': hud_check.with_suffix('.signature.json').unlink(); hud_check.unlink()
elif name == 'codesign':
    target = Path(args[-1])
    metadata_file = target / 'signature.json' if target.is_dir() else target.with_suffix('.signature.json')
    if not metadata_file.exists(): sys.exit(1)
    metadata = json.loads(metadata_file.read_text())
    if args[0] == '--display':
        if '--entitlements' in args:
            entitlements = {}
            if metadata['helper']:
                if mode in ('sandboxed-helper', 'inherited-helper'): entitlements['com.apple.security.app-sandbox'] = True
                if mode == 'inherited-helper': entitlements['com.apple.security.inherit'] = True
                if mode == 'extra-helper-entitlement': entitlements['com.apple.security.device.bluetooth'] = True
            if mode == 'sandboxed-app' and target == root / '.build/Build/Products/Release/Acouplet.app':
                entitlements['com.apple.security.app-sandbox'] = True
            if metadata['debuggable']: entitlements['com.apple.security.get-task-allow'] = True
            sys.stdout.buffer.write(plistlib.dumps(entitlements).replace(b'\n', b'').replace(b'\t', b''))
        else:
            flags = '0x10000(runtime)' if metadata['runtime'] else '0x0(none)'
            print('CodeDirectory v=20500 size=1 flags=' + flags + ' hashes=1+7', file=sys.stderr)
            print('TeamIdentifier=' + metadata['team'], file=sys.stderr)
    elif args[0] == '--force':
        assert '--preserve-metadata=entitlements' in args and '--options' in args and args[args.index('--options') + 1] == 'runtime'
        assert (target / 'Contents/Resources/Acouplet LDAC Output.pkg').is_file()
        assert (target / 'Contents/Resources/Acouplet LDAC Removal.pkg').is_file()
        (target / 'Contents/MacOS/Acouplet').write_text('resigned app')
        (target / 'Contents/_CodeSignature').mkdir(exist_ok=True)
        (target / 'Contents/_CodeSignature/CodeResources').write_text('sealed installer')
    else:
        assert args[0] == '--verify', args
        if mode == 'invalid-signature': sys.exit(1)
        if '--test-requirement==anchor apple generic' in args and not metadata['apple']: sys.exit(1)
        if any('field.1.2.840.113635.100.6.1.13' in arg for arg in args) and not (metadata['apple'] and metadata['developer_id']): sys.exit(1)
elif name == 'otool':
    if '-L' in args: print('@rpath/Sparkle.framework/Versions/B/Sparkle')
    else:
        metadata = json.loads(Path(args[-1]).with_suffix('.signature.json').read_text())
        print(args[-1] + ':')
        print(plistlib.dumps({'CFBundleVersion': metadata['build']}).decode())
elif name == 'ditto':
    if args[0] == '-c': subprocess.run(['/usr/bin/ditto', *args], check=True)
    else: shutil.copytree(args[0], args[1])
elif name == 'pkgbuild':
    if '--nopayload' in args:
        assert '--root' not in args and '--component-plist' not in args
        assert args[args.index('--identifier') + 1] == 'dev.baglayan.Acouplet.LDACOutput.Removal'
        scripts = Path(args[args.index('--scripts') + 1])
        assert [path.name for path in scripts.iterdir()] == ['postinstall']
        assert '@ACOUPLET_LDAC_SIGNING_TEAM_ID@' not in (scripts / 'postinstall').read_text()
        Path(args[-1]).write_text('driver-only uninstaller')
    else:
        payload = Path(args[args.index('--root') + 1])
        assert [path.name for path in payload.iterdir()] == ['AcoupletLDACOutput.driver']
        assert args[args.index('--install-location') + 1] == '/Library/Audio/Plug-Ins/HAL'
        assert args[args.index('--identifier') + 1] == 'dev.baglayan.Acouplet.LDACOutput'
        components = plistlib.loads(Path(args[args.index('--component-plist') + 1]).read_bytes())
        assert components[0]['BundleIsRelocatable'] is False and components[0]['BundleHasStrictIdentifier'] is True
        Path(args[-1]).write_text('driver-only installer')
elif name == 'pkgutil':
    assert args[0] == '--check-signature' and Path(args[-1]).is_file()
else:
    raise AssertionError('Unexpected stub: ' + name)
'''


def check(name, signing, mode='success', succeeds=True, local=False, panes=False, direct=False):
    with tempfile.TemporaryDirectory(prefix='acouplet-package-check-') as directory:
        root = Path(directory).resolve()
        scripts = root / 'Packaging'
        scripts.mkdir()
        stubs = root / 'stubs'
        stubs.mkdir()
        source = (packaging / 'package.sh').read_text()
        for tool in ('xcrun', 'codesign', 'ditto', 'otool', 'pkgbuild', 'pkgutil'):
            stub = stubs / tool
            stub.write_text(stub_source)
            stub.chmod(0o755)
            source = source.replace(('/usr/sbin/' if tool == 'pkgutil' else '/usr/bin/') + tool, str(stub))
        source = source.replace('/Applications/Acouplet.app/Contents/Info.plist', str(root / 'installed.plist'))
        script = scripts / 'package.sh'
        script.write_text(source)
        (scripts / 'release-source.py').write_text(stub_source)
        for filename in ('Install.command', 'Uninstall Service.command', 'Uninstall LDAC Output.command', 'README.txt'):
            shutil.copy2(packaging / filename, scripts / filename)
        builder = (packaging / 'build-ldac-output-installer.sh').read_text()
        for tool in ('codesign', 'ditto', 'pkgbuild', 'pkgutil'):
            builder = builder.replace(('/usr/sbin/' if tool == 'pkgutil' else '/usr/bin/') + tool, str(stubs / tool))
        (scripts / 'build-ldac-output-installer.sh').write_text(builder)
        shutil.copytree(packaging / 'LDACOutputInstaller', scripts / 'LDACOutputInstaller')
        shutil.copytree(packaging / 'LDACOutputUninstaller', scripts / 'LDACOutputUninstaller')
        (scripts / 'fetch-sparkle.sh').write_text('exit 0\n')
        (scripts / 'check-sparkle-bundle.py').write_text((packaging / 'check-sparkle-bundle.py').read_text().replace('/usr/bin/otool', str(stubs / 'otool')))
        for filename in ('LICENSE', 'THIRD-PARTY-NOTICES.md'):
            (root / filename).write_text(filename)
        (root / 'Vendor/libldac').mkdir(parents=True)
        for filename in ('LICENSE', 'NOTICE'): (root / 'Vendor/libldac' / filename).write_text(filename)
        (root / 'Helpers/LDAC/VirtualOutput').mkdir(parents=True)
        for filename in ('NullAudio.c', 'LICENSE.txt'): (root / 'Helpers/LDAC/VirtualOutput' / filename).write_text(filename)
        package = root / '.build/package/Acouplet'
        package.mkdir(parents=True)
        if mode == 'stale-controls':
            (root / '.build/Build/Products/Release/Acouplet.app/Contents/PlugIns/Acouplet Controls.appex').mkdir(parents=True)
        expected_build = 2
        if mode in ('counter-restore', 'counter-persisted'):
            (root / 'installed.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier': 'dev.baglayan.Acouplet', 'CFBundleVersion': '12'}))
            expected_build = 13
            if mode == 'counter-persisted':
                (root / '.build/package-build-number').write_text('20\n')
                expected_build = 21
        if 'ACOUPLET_BUILD_NUMBER' in signing:
            expected_build = signing['ACOUPLET_BUILD_NUMBER']
        previous = package / 'previous'
        previous.write_text('previous package')
        local_previous = root / '.build/local-update/Acouplet/previous'
        if direct:
            local_previous.parent.mkdir(parents=True)
            local_previous.write_text('previous development package')
        archive = root / 'dist/Acouplet.zip'
        archive.parent.mkdir()
        archive.write_text('previous archive')
        environment = {key: value for key, value in os.environ.items()
                       if key not in ('CODE_SIGN_IDENTITY', 'ACOUPLET_INSTALLER_SIGNING_IDENTITY', 'DEVELOPMENT_TEAM', 'CODE_SIGN_STYLE', 'SONY_PANE_DEVICES', 'ACOUPLET_MARKETING_VERSION', 'ACOUPLET_BUILD_NUMBER', 'ACOUPLET_NO_SONY_ARTWORK', 'ACOUPLET_SONY_ARTWORK_DIR')}
        environment.update(signing, ACOUPLET_PACKAGE_CHECK_ROOT=str(root), ACOUPLET_PACKAGE_CHECK_MODE=mode)
        if panes:
            manifest = root / 'devices.json'
            manifest.write_text('{"devices": [{"address":"00:11:22:33:44:55","modelName":"WF-1000XM5","systemSymbol":"earbuds.stemless"}]}')
            environment['SONY_PANE_DEVICES'] = str(manifest)
            (scripts / 'build-preference-panes.py').write_text("raise AssertionError('Deferred preference pane builder must not run')\n")
            old_package = root / '.build/local-update/Acouplet' if local else package
            (old_package / 'PreferencePanes/Sony-001122334455.prefPane').mkdir(parents=True)

        result = subprocess.run(['/bin/zsh', str(script), *(['--local'] if local else ['--direct'] if direct else [])], env=environment, text=True, capture_output=True)
        assert (result.returncode == 0) == succeeds, (name, result.returncode, result.stdout, result.stderr)
        log = root / 'commands.jsonl'
        commands = [json.loads(line) for line in log.read_text().splitlines()] if log.exists() else []
        builds = [command for command in commands if command[0] == 'xcrun']
        if 'ACOUPLET_BUILD_NUMBER' in signing and not re.fullmatch(r'[1-9][0-9]*', signing['ACOUPLET_BUILD_NUMBER']):
            assert not commands, commands
            assert 'ACOUPLET_BUILD_NUMBER must be a positive integer' in result.stderr, result.stderr
        elif 'ACOUPLET_MARKETING_VERSION' in signing and not re.fullmatch(r'[0-9]+(\.[0-9]+){1,2}', signing['ACOUPLET_MARKETING_VERSION']):
            assert not commands, commands
            assert 'ACOUPLET_MARKETING_VERSION must contain' in result.stderr, result.stderr
        elif signing.get('CODE_SIGN_IDENTITY') == '':
            assert not commands, commands
            assert 'CODE_SIGN_IDENTITY is empty' in result.stderr, result.stderr
        elif mode == 'source-dirty' and not local:
            assert not builds and len(commands) == 1 and commands[0][1] == 'capture', commands
            assert not (root / '.build/package-build-number').exists()
        else:
            assert len(builds) == 1, builds
            settings = dict(arg.split('=', 1) for arg in builds[0] if '=' in arg)
            identity = signing.get('CODE_SIGN_IDENTITY', 'Apple Development' if local else 'Developer ID Application')
            assert settings['CURRENT_PROJECT_VERSION'] == str(expected_build), settings
            assert settings['MARKETING_VERSION'] == signing.get('ACOUPLET_MARKETING_VERSION', '0.' + str(expected_build)), settings
            assert settings['ACOUPLET_DISTRIBUTION'] == ('development' if local else 'production'), settings
            counter = root / '.build/package-build-number'
            if 'ACOUPLET_BUILD_NUMBER' in signing:
                assert counter.read_text().strip() == '20' if mode == 'counter-persisted' else not counter.exists()
            else:
                assert counter.read_text().strip() == str(expected_build)
            assert settings['ACOUPLET_PUBLIC_APIS_ONLY'] == 'NO', settings
            assert settings['ACOUPLET_NO_SONY_ARTWORK'] == signing.get('ACOUPLET_NO_SONY_ARTWORK', 'NO' if signing.get('ACOUPLET_SONY_ARTWORK_DIR') else 'YES'), settings
            assert settings['ACOUPLET_SONY_ARTWORK_DIR'] == signing.get('ACOUPLET_SONY_ARTWORK_DIR', ''), settings
            assert settings['CODE_SIGN_IDENTITY'] == identity, settings
            assert settings['CODE_SIGN_INJECT_BASE_ENTITLEMENTS'] == 'NO', settings
            assert settings['ENABLE_HARDENED_RUNTIME'] == 'YES', settings
            assert settings.get('DEVELOPMENT_TEAM') == signing.get('DEVELOPMENT_TEAM'), settings
            manual = identity != '-' and (not local or 'CODE_SIGN_IDENTITY' in signing or not signing.get('DEVELOPMENT_TEAM'))
            assert settings.get('CODE_SIGN_STYLE') == ('Manual' if manual else None), settings
            assert '-allowProvisioningUpdates' not in builds[0], builds[0]
            if succeeds and identity != '-':
                checks = [command for command in commands if '--test-requirement==anchor apple generic' in command]
                assert [Path(command[-1]).name for command in checks] == ['Acouplet.app', 'Acouplet Battery Publisher', 'SonyNativeHUD.dylib', 'SonyNativeHUDCheck', 'Installer.xpc', 'Autoupdate', 'Updater.app', 'Sparkle.framework', 'LDACSignaling', 'LDACMediaTransport', 'SonyAudioConnection', 'LDACLogObserver', 'Acouplet Audio.app', 'AcoupletLDACOutput.driver'], checks
                developer_id_checks = [command for command in commands if any('field.1.2.840.113635.100.6.1.13' in arg for arg in command)]
                assert [Path(command[-1]).name for command in developer_id_checks] == ([] if local else [Path(command[-1]).name for command in checks]), developer_id_checks
                assert all('--all-architectures' in command for command in developer_id_checks), developer_id_checks
        if succeeds:
            assert commands[0][:2] == ['release-source.py', 'capture'], commands[0]
            assert any(command[:2] == ['release-source.py', 'verify'] for command in commands)
            for notice in ('LICENSE', 'THIRD-PARTY-NOTICES.md'):
                assert (root / '.build/Build/Products/Release/Acouplet.app/Contents/Resources' / notice).read_bytes() == (root / notice).read_bytes()
            entitlements = [command for command in commands if '--entitlements' in command]
            assert [Path(command[-1]).name for command in entitlements] == ['Acouplet.app', 'Acouplet Battery Publisher', 'SonyNativeHUD.dylib', 'SonyNativeHUDCheck', 'Installer.xpc', 'Autoupdate', 'Updater.app', 'Sparkle.framework', 'LDACSignaling', 'LDACMediaTransport', 'SonyAudioConnection', 'LDACLogObserver', 'Acouplet Audio.app', 'AcoupletLDACOutput.driver'], entitlements
            if local:
                assert previous.read_text() == 'previous package'
                assert archive.read_text() == 'previous archive'
                assert not any(command[:2] == ['ditto', '-c'] for command in commands)
                package = root / '.build/local-update/Acouplet'
                receipt = (package / 'Local Build Receipt.txt').read_text()
                assert 'Prepared UTC:' in receipt and 'Revision:' in receipt and 'Worktree:' in receipt
                assert 'Signing identity: ' + identity in receipt
                assert 'Release hardening: app and bundled helpers use hardened runtime without debugger access' in receipt
                assert 'Build number: ' + str(expected_build) in receipt
                assert 'Device preference panes:' not in receipt
                assert ('Permission continuity: ad-hoc signature' in receipt) == (identity == '-')
            else:
                assert not previous.exists()
                if direct:
                    assert archive.read_text() == 'previous archive'
                    assert local_previous.read_text() == 'previous development package'
                    assert not any(command[:2] == ['ditto', '-c'] for command in commands)
            receipt = (package / ('Local Build Receipt.txt' if local else 'Build Receipt.txt')).read_text()
            assert 'Revision: ' + 'a' * 40 in receipt and 'Source input SHA256: ' + 'c' * 64 in receipt
            assert ('Worktree: development (dirty)' if local else 'Worktree: production clean') in receipt
            if local:
                assert 'Release app: ' + str(root / '.build/Build/Products/Release/Acouplet.app') in receipt
            else:
                if not direct:
                    with zipfile.ZipFile(archive) as contents:
                        assert contents.read('Acouplet/Build Receipt.txt').decode() == receipt
                assert str(root) not in receipt, receipt
                assert 'Release app: Acouplet.app\n' in receipt
            for line in receipt.splitlines():
                if not line.startswith('SHA256\t'): continue
                _, digest, relative = line.split('\t')
                assert hashlib.sha256((package / 'Acouplet.app' / relative).read_bytes()).hexdigest() == digest
            assert receipt.count('SHA256\t') == 19
            assert not (package / 'Acouplet LDAC Output.pkg').exists()
            assert not (package / 'Acouplet LDAC Removal.pkg').exists()
            assert (package / 'Acouplet.app/Contents/Resources/Acouplet LDAC Removal.pkg').read_text() == 'driver-only uninstaller'
            assert (package / 'Acouplet.app/Contents/Resources/Acouplet LDAC Output.pkg').read_text() == 'driver-only installer'
            assert (package / 'Acouplet.app/Contents/MacOS/Acouplet').read_text() == 'resigned app'
            assert (package / 'Uninstall LDAC Output.command').is_file()
            assert 'Driver installer SHA256: ' in receipt
            distribution = 'development' if local else 'production'
            assert 'Distribution: ' + distribution in receipt and 'Configuration: Release' in receipt
            info = plistlib.loads((package / 'Acouplet.app/Contents/Info.plist').read_bytes())
            assert info['AcoupletDistribution'] == distribution
            assert not (package / 'Acouplet.app/Contents/PlugIns/Acouplet Controls.appex').exists()
            assert not (package / 'PreferencePanes').exists()
            assert not list(package.rglob('*.prefPane'))
        else:
            if mode != 'source-drift-archive': assert previous.read_text() == 'previous package'
            assert archive.read_text() == 'previous archive'
            if mode not in ('source-drift', 'source-drift-archive'): assert not any(command[0] == 'ditto' for command in commands), commands
            if mode == 'source-drift': assert not (package / 'Acouplet.app').exists()
            if mode.startswith('source-'):
                assert commands[-1][0] == 'release-source.py'
            if mode.startswith('missing-runtime-'): assert 'must enable hardened runtime' in result.stderr, result.stderr
            if mode.startswith('debuggable-'): assert 'must omit debugger access in Release' in result.stderr, result.stderr
            if mode == 'sandboxed-app': assert 'must omit the sandbox entitlement' in result.stderr, result.stderr
            if mode == 'wrong-distribution': assert 'must declare the requested' in result.stderr, result.stderr
            if mode == 'development-upstream-feed': assert 'Incorrect Sparkle policy: SUFeedURL' in result.stderr, result.stderr
        print(name + ': passed')


check('default-developer-id', {})
check('production-rejects-dirty-source-before-build', {}, 'source-dirty', False)
check('production-rejects-source-drift-before-staging', {}, 'source-drift', False)
check('production-rejects-source-drift-before-archive-replacement', {}, 'source-drift-archive', False)
check('local-allows-dirty-source', {}, 'source-dirty', local=True)
check('default-missing-identity-no-fallback', {}, 'build-failure', False)
check('default-rejects-ad-hoc-output', {}, 'adhoc-output', False)
check('explicit-ad-hoc-with-team', {'CODE_SIGN_IDENTITY': '-', 'DEVELOPMENT_TEAM': 'ABCDE12345'}, local=True)
check('automatic-team', {'DEVELOPMENT_TEAM': 'ABCDE12345'})
check('local-apple-development', {'CODE_SIGN_IDENTITY': 'Apple Development', 'DEVELOPMENT_TEAM': 'ABCDE12345'}, local=True)
check('developer-id', {'CODE_SIGN_IDENTITY': 'Developer ID Application: Example (ABCDE12345)', 'DEVELOPMENT_TEAM': 'ABCDE12345'})
check('developer-id-fingerprint', {'CODE_SIGN_IDENTITY': 'A' * 40})
check('production-rejects-apple-development', {'CODE_SIGN_IDENTITY': 'Apple Development'}, succeeds=False)
check('production-rejects-ad-hoc', {'CODE_SIGN_IDENTITY': '-'}, succeeds=False)
check('fingerprint-cannot-bypass-developer-id', {'CODE_SIGN_IDENTITY': 'A' * 40}, 'development-output', False)
check('production-rejects-development-driver', {}, 'development-driver', False)
check('production-rejects-development-helper', {}, 'development-helper', False)
check('local-development-fingerprint', {'CODE_SIGN_IDENTITY': 'A' * 40}, 'development-output', local=True)
check('existing-project-team', {'CODE_SIGN_IDENTITY': 'Developer ID Application'})
check('empty-identity', {'CODE_SIGN_IDENTITY': ''}, succeeds=False)
check('missing-identity-no-fallback', {'CODE_SIGN_IDENTITY': 'Developer ID Application'}, 'build-failure', False)
check('unexpected-ad-hoc-output', {'CODE_SIGN_IDENTITY': 'Developer ID Application'}, 'adhoc-output', False)
check('requested-team-mismatch', {'DEVELOPMENT_TEAM': 'ABCDE12345'}, 'wrong-team', False)
check('missing-team', {'CODE_SIGN_IDENTITY': 'Developer ID Application'}, 'missing-team', False)
check('invalid-signature', {'CODE_SIGN_IDENTITY': 'Developer ID Application'}, 'invalid-signature', False)
check('sandboxed-direct-app', {'CODE_SIGN_IDENTITY': 'Developer ID Application'}, 'sandboxed-app', False)
check('production-rejects-development-metadata', {}, 'wrong-distribution', False)
check('local-rejects-production-metadata', {}, 'wrong-distribution', False, local=True)
check('production-ignores-development-environment', {'ACOUPLET_DISTRIBUTION': 'development'})
check('local-ignores-production-environment', {'ACOUPLET_DISTRIBUTION': 'production'}, local=True)
check('local-rejects-upstream-update-feed', {}, 'development-upstream-feed', False, local=True)
check('website-stage-production-without-zip', {}, direct=True)
check('missing-license', {}, 'missing-license', False)
check('stale-notices', {}, 'stale-notices', False)
check('missing-ldac-notice', {}, 'missing-ldac-notice', False)
for failure in ('different-ldac-team', 'missing-runtime-ldac', 'debuggable-ldac', 'wrong-audio-build', 'wrong-driver-build', 'wrong-driver-identity', 'changed-apple-source'):
    check(failure, {'CODE_SIGN_IDENTITY': 'Developer ID Application'}, failure, False)
for failure in ('missing-runtime-app', 'debuggable-app'):
    check(failure, {'CODE_SIGN_IDENTITY': 'Developer ID Application'}, failure, False)

check('local-stage-receipt-without-archive', {}, local=True)
check('local-ad-hoc-receipt-without-archive', {'CODE_SIGN_IDENTITY': '-'}, local=True)

for failure in ('missing-helper', 'adhoc-helper', 'different-helper-team', 'missing-runtime-helper', 'debuggable-helper', 'sandboxed-helper', 'inherited-helper', 'extra-helper-entitlement', 'wrong-build', 'missing-hud', 'different-hud-team', 'missing-runtime-hud', 'missing-hud-check', 'different-hud-check-team', 'missing-runtime-hud-check', 'debuggable-hud-check', 'different-sparkle-team', 'missing-runtime-sparkle'):
    check(failure, {'CODE_SIGN_IDENTITY': 'Developer ID Application'}, failure, False)
check('counter-restored-from-installed', {}, 'counter-restore', local=True)
check('counter-keeps-larger-persisted-build', {}, 'counter-persisted', local=True)
check('patch-version-with-increasing-build', {'ACOUPLET_MARKETING_VERSION': '0.24.5'}, 'counter-restore', local=True)
check('invalid-marketing-version', {'ACOUPLET_MARKETING_VERSION': '0.24.5-beta'}, succeeds=False)
check('explicit-ci-build-ignores-installed-app', {'ACOUPLET_BUILD_NUMBER': '31', 'ACOUPLET_MARKETING_VERSION': '0.31'}, 'counter-restore', direct=True)
check('explicit-ci-build-preserves-local-counter', {'ACOUPLET_BUILD_NUMBER': '31', 'ACOUPLET_NO_SONY_ARTWORK': 'YES'}, 'counter-persisted', direct=True)
check('external-photographs', {'ACOUPLET_SONY_ARTWORK_DIR': '/private/Sony Photos.xcassets'}, local=True)
check('explicit-photo-exclusion', {'ACOUPLET_SONY_ARTWORK_DIR': '/private/Sony Photos.xcassets', 'ACOUPLET_NO_SONY_ARTWORK': 'YES'}, local=True)
for value in ('', '0', '-1', '1.2', '03', 'abc'):
    check('invalid-explicit-ci-build-' + value, {'ACOUPLET_BUILD_NUMBER': value}, succeeds=False)

check('deferred-device-panes-local', {}, local=True, panes=True)
check('deferred-device-panes-archive', {}, panes=True)

check('deferred-controls-local', {}, 'embedded-controls', False, local=True)
check('deferred-controls-archive', {}, 'embedded-controls', False)
check('deferred-controls-stale-build-output', {}, 'stale-controls', local=True)
