from pathlib import Path
import json, os, plistlib, subprocess, sys, tempfile

packaging = Path(__file__).parent
stub_source = '''#!/usr/bin/python3
from pathlib import Path
import json, os, subprocess, sys
name = Path(sys.argv[0]).name
args = sys.argv[1:]
if name == 'xcrun':
    if args[0] == 'xcstringstool':
        subprocess.run(['/usr/bin/xcrun', *args], env={key: value for key, value in os.environ.items() if key != 'SDKROOT'}, check=True)
        sys.exit(0)
    assert args == ['--find', 'clang'], args
    print(Path(sys.argv[0]).with_name('clang'))
else:
    with Path(os.environ['ACOUPLET_LDAC_CHECK_LOG']).open('a') as log:
        log.write(json.dumps([name, *args]) + '\\n')
    if name == 'clang':
        for arg in args:
            if arg.endswith(('.m', '.c')): assert Path(arg).is_file(), arg
        Path(args[args.index('-o') + 1]).write_text('fixture executable')
    else:
        assert name == 'codesign' and Path(args[-1]).exists(), args
'''

with tempfile.TemporaryDirectory(prefix='acouplet-ldac-build-check-') as directory:
    root = Path(directory)
    for name in ('xcrun', 'clang', 'codesign'):
        stub = root / name
        stub.write_text(stub_source.replace('#!/usr/bin/python3', '#!' + sys.executable))
        stub.chmod(0o755)
    script = root / 'build-ldac.sh'
    script.write_text((packaging / 'build-ldac.sh').read_text()
                      .replace('/usr/bin/xcrun', str(root / 'xcrun'))
                      .replace('/usr/bin/codesign', str(root / 'codesign')))
    log = root / 'commands.jsonl'
    environment = {**os.environ, 'SRCROOT': str(packaging.parent), 'TARGET_BUILD_DIR': str(root),
                   'CONTENTS_FOLDER_PATH': 'Fixture.app/Contents', 'DERIVED_FILE_DIR': str(root / 'derived'),
                   'SDKROOT': '/fixture-sdk', 'ARCHS': 'arm64 x86_64', 'MACOSX_DEPLOYMENT_TARGET': '15.4',
                   'CONFIGURATION': 'Release', 'ACOUPLET_PUBLIC_APIS_ONLY': 'NO', 'CURRENT_PROJECT_VERSION': '245',
                   'CODE_SIGNING_ALLOWED': 'YES', 'EXPANDED_CODE_SIGN_IDENTITY': 'fixture Apple certificate',
                   'EXPANDED_CODE_SIGN_IDENTITY_NAME': 'Apple Development: Fixture (ABCDEFGHIJ)',
                   'DEVELOPMENT_TEAM': '', 'ACOUPLET_LDAC_CHECK_LOG': str(log)}
    subprocess.run(['/bin/sh', str(script)], env=environment, check=True)
    app = root / 'Fixture.app/Contents'
    names = ['LDACSignaling', 'LDACMediaTransport', 'SonyAudioConnection', 'LDACLogObserver', 'Acouplet Audio.app', 'AcoupletLDACOutput.driver']
    assert all((app / 'Helpers' / name).exists() for name in names)
    audio_info = plistlib.loads((app / 'Helpers/Acouplet Audio.app/Contents/Info.plist').read_bytes())
    assert audio_info['CFBundleIdentifier'] == 'dev.baglayan.Acouplet.ldac-audio'
    assert audio_info['LSMinimumSystemVersion'] == '15.4' and audio_info['CFBundleVersion'] == '245'
    for language in ('en', 'tr'):
        main_path = app / 'Resources' / (language + '.lproj') / 'InfoPlist.strings'
        audio_path = app / 'Helpers/Acouplet Audio.app/Contents/Resources' / (language + '.lproj') / 'InfoPlist.strings'
        main_strings = json.loads(subprocess.check_output(['/usr/bin/plutil', '-convert', 'json', '-o', '-', str(main_path)]))
        audio_strings = json.loads(subprocess.check_output(['/usr/bin/plutil', '-convert', 'json', '-o', '-', str(audio_path)]))
        assert set(main_strings) == {'NSBluetoothAlwaysUsageDescription', 'NSAudioCaptureUsageDescription'}
        assert set(audio_strings) == {'NSAudioCaptureUsageDescription'}
        assert main_strings['NSAudioCaptureUsageDescription'] == audio_strings['NSAudioCaptureUsageDescription']
        if language == 'en': assert audio_strings['NSAudioCaptureUsageDescription'] == audio_info['NSAudioCaptureUsageDescription']
    driver = app / 'Helpers/AcoupletLDACOutput.driver'
    driver_info = plistlib.loads((driver / 'Contents/Info.plist').read_bytes())
    assert driver_info['CFBundleIdentifier'] == 'dev.baglayan.Acouplet.LDACOutput'
    assert driver_info['AcoupletLDACDriverRevision'] == 5
    assert driver_info['CFBundleVersion'] == '245' and driver_info['CFBundleExecutable'] == 'AcoupletVirtualOutput'
    assert driver_info['AudioServerPlugIn_MachServices'] == ['com.apple.BTAudioHALPlugin.xpc']
    for name in ('NullAudio.c', 'LICENSE.txt'):
        assert (driver / 'Contents/Resources' / name).read_bytes() == (packaging.parent / 'Helpers/LDAC/VirtualOutput' / name).read_bytes()
    for name in ('Earbuds.png', 'Headphones.png', 'Speaker.png'):
        assert (driver / 'Contents/Resources' / name).read_bytes() == (packaging.parent / 'Helpers/LDAC/VirtualOutput/Resources' / name).read_bytes()
    commands = [json.loads(line) for line in log.read_text().splitlines()]
    compiles = [command for command in commands if command[0] == 'clang']
    signs = [command for command in commands if command[0] == 'codesign']
    assert len(compiles) == len(signs) == 6
    logger = compiles.pop(0)
    logger_sign = signs.pop(0)
    assert logger[-1] == str(app / 'Helpers/LDACLogObserver')
    assert logger_sign[-1] == logger[-1] and '-Werror' in logger
    assert [logger[i + 1] for i, arg in enumerate(logger) if arg == '-arch'] == ['arm64', 'x86_64']
    assert '-mmacosx-version-min=15.4' in logger
    assert logger_sign[logger_sign.index('--options') + 1] == 'runtime'
    assert logger_sign[logger_sign.index('--sign') + 1] == 'fixture Apple certificate'
    for command in compiles:
        assert '-mmacosx-version-min=15.4' in command
    for command in compiles:
        assert [command[i + 1] for i, arg in enumerate(command) if arg == '-arch'] == ['arm64', 'x86_64']
    for command in compiles[:2]:
        assert '-DACOUPLET_LDAC_PROBE_ONLY=0' in command
    assert '-DACOUPLET_LDAC_PROBE_ONLY=0' not in compiles[2]
    capture = compiles[3]
    assert '-DACOUPLET_AUDIO_HELPER_STREAM_ONLY=1' in capture
    assert '-DACOUPLET_AUDIO_HELPER_BUNDLE_ID="dev.baglayan.Acouplet.ldac-audio"' in capture
    assert any(arg.endswith('/Vendor/libldac/src/ldacBT.c') for arg in compiles[1])
    assert '-framework' in compiles[2] and 'CoreAudio' in compiles[2]
    driver_compile = compiles[-1]
    assert '-bundle' in driver_compile and '-std=gnu11' in driver_compile and '-Werror' in driver_compile
    assert 'Security' in [driver_compile[i + 1] for i, arg in enumerate(driver_compile) if arg == '-framework']
    assert any(arg.endswith('/VirtualOutput/AcoupletVirtualOutput.c') for arg in driver_compile)
    assert '-DACOUPLET_SIGNING_TEAM="5743Y47SC7"' in driver_compile
    assert not any('ACOUPLET_SIGNING_TEAM' in arg for command in compiles[:-1] for arg in command)
    assert Path(signs[-1][-1]) == driver
    assert '--timestamp=none' in signs[-1]
    for command in signs:
        assert command[command.index('--sign') + 1] == 'fixture Apple certificate'
        assert command[command.index('--options') + 1] == 'runtime' and '--entitlements' not in command
    for notice in ('LICENSE', 'NOTICE'):
        assert (app / 'Resources' / ('LDAC-' + notice + '.txt')).read_bytes() == (packaging.parent / 'Vendor/libldac' / notice).read_bytes()
    subprocess.run(['/bin/sh', str(script)], env={**environment, 'EXPANDED_CODE_SIGN_IDENTITY_NAME': 'Developer ID Application: Fixture (ABCDEFGHIJ)'}, check=True)
    commands = [json.loads(line) for line in log.read_text().splitlines()]
    signs = [command for command in commands if command[0] == 'codesign']
    assert '--timestamp' in signs[-1] and '--timestamp=none' not in signs[-1]
    subprocess.run(['/bin/sh', str(script)], env={**environment, 'DEVELOPMENT_TEAM': 'ABCDE12345'}, check=True)
    commands = [json.loads(line) for line in log.read_text().splitlines()]
    assert '-DACOUPLET_SIGNING_TEAM="ABCDE12345"' in [command for command in commands if command[0] == 'clang'][-1]
    for team in ('abcde12345', 'ABCDE1234', 'ABCDE12345"', 'ABCDE 2345'):
        before = log.read_bytes()
        failed = subprocess.run(['/bin/sh', str(script)], env={**environment, 'DEVELOPMENT_TEAM': team}, capture_output=True)
        assert failed.returncode != 0 and b'DEVELOPMENT_TEAM' in failed.stderr, team
        assert not any('AcoupletVirtualOutput.c' in line for line in log.read_bytes()[len(before):].decode().splitlines()), team
    previous_log = log.read_bytes()
    for exclusion in ({'ACOUPLET_PUBLIC_APIS_ONLY': 'YES'}, {'CONFIGURATION': 'AppStore'}):
        for name in names:
            target = app / 'Helpers' / name
            if name.endswith(('.app', '.driver')): target.mkdir(exist_ok=True)
            else: target.touch()
        for notice in ('LICENSE', 'NOTICE'): (app / 'Resources' / ('LDAC-' + notice + '.txt')).touch()
        (app / 'Resources/Acouplet LDAC Output.pkg').touch()
        (app / 'Resources/Acouplet LDAC Removal.pkg').touch()
        (root / 'derived/LDAC').mkdir(parents=True, exist_ok=True)
        subprocess.run(['/bin/sh', str(script)], env={**environment, **exclusion}, check=True)
        assert log.read_bytes() == previous_log
        for language in ('en', 'tr'):
            path = app / 'Resources' / (language + '.lproj') / 'InfoPlist.strings'
            strings = json.loads(subprocess.check_output(['/usr/bin/plutil', '-convert', 'json', '-o', '-', str(path)]))
            assert set(strings) == {'NSBluetoothAlwaysUsageDescription'}
        assert all(not (app / 'Helpers' / name).exists() for name in names)
        assert not (app / 'Resources/Acouplet LDAC Output.pkg').exists()
        assert not (app / 'Resources/Acouplet LDAC Removal.pkg').exists()
        assert not list((app / 'Resources').glob('LDAC-*')) and not (root / 'derived/LDAC').exists()
print('LDAC universal helper and HAL driver flags, signing, unchanged Apple source/license and complete public-only exclusion: passed')
