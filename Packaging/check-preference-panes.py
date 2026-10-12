from pathlib import Path
from unittest.mock import patch
import importlib.util, json, plistlib, subprocess, tempfile

packaging = Path(__file__).parent
spec = importlib.util.spec_from_file_location('pane_builder', packaging / 'build-preference-panes.py')
builder = importlib.util.module_from_spec(spec)
spec.loader.exec_module(builder)
repo = packaging.parent

devices = [
    {'address': '00:11:22:33:44:55', 'modelName': 'WF-1000XM5', 'systemSymbol': 'earbuds.stemless'},
    {'address': 'AA:BB:CC:33:44:55', 'modelName': 'WF-1000XM5', 'systemSymbol': 'earbuds.stemless'},
    {'address': '00:11:22:33:44:66', 'modelName': 'WH-1000XM5', 'systemSymbol': 'headphones'},
]
for scenario in ('three-devices', 'duplicate-address', 'invalid-address', 'invalid-icon', 'empty', 'ad-hoc', 'failed-signature'):
    with tempfile.TemporaryDirectory(prefix='sony-pane-build-check-') as directory:
        root = Path(directory)
        values = json.loads(json.dumps(devices))
        if scenario == 'duplicate-address': values[1]['address'] = values[0]['address'].lower()
        if scenario == 'invalid-address': values[0]['address'] = '../../Other'
        if scenario == 'invalid-icon': values[0]['systemSymbol'] = '../../Other'
        if scenario == 'empty': values = []
        manifest = root / 'devices.json'
        manifest.write_text(json.dumps({'devices': values}))
        output = root / 'PreferencePanes'
        commands, principals = [], set()

        def run(args, **kwargs):
            commands.append(args)
            if args[1:4] == ['--sdk', 'macosx', '--show-sdk-path']:
                return subprocess.CompletedProcess(args, 0, stdout='/mock/SDK\n')
            if args[1] == 'swiftc':
                principal_source = Path(next(value for value in args if value.endswith('.swift') and Path(value).name.startswith('SonyPane')))
                suffix = principal_source.stem.removeprefix('SonyPane')
                assert '@objc(SonyPreferencePane_' + suffix + ')' in principal_source.read_text()
                assert args[args.index('-module-name') + 1] == 'SonyPane' + suffix
                principals.add('SonyPreferencePane_' + suffix)
                Path(args[args.index('-o') + 1]).write_text(args[args.index('-target') + 1])
            elif args[1] == 'lipo':
                slices = args[3:args.index('-output')]
                assert len(slices) == 2 and all(Path(value).exists() for value in slices)
                Path(args[-1]).write_text('universal bundle')
            elif args[0] == '/usr/bin/codesign':
                bundle = Path(args[-1])
                info = plistlib.loads((bundle / 'Contents/Info.plist').read_bytes())
                suffix = info['SonyDeviceAddress'].replace(':', '')
                assert info['CFBundleIdentifier'] == 'dev.baglayan.Acouplet.preference-pane.' + suffix.lower()
                assert info['NSPrincipalClass'] == 'SonyPreferencePane_' + suffix
                assert info['CFBundleVersion'] == '7'
                assert info['AcoupletAppTeam'] == 'ABCDE12345'
                assert (bundle / 'Contents/MacOS' / info['CFBundleExecutable']).exists()
                icon = 'Earbuds.tiff' if info['SonyDeviceSystemSymbol'] == 'earbuds.stemless' else 'Headphones.tiff'
                assert info['NSPrefPaneIconFile'] == icon
                assert (bundle / 'Contents/Resources' / icon).read_bytes() == (repo / 'PreferencePane/Resources' / icon).read_bytes()
                if info['SonyDeviceModelName'] == 'WF-1000XM5':
                    assert info['NSPrefPaneIconLabel'] == 'WF-1000XM5 · ' + info['SonyDeviceAddress']
                else:
                    assert info['NSPrefPaneIconLabel'] == 'WH-1000XM5'
                if args[1] == '--force':
                    assert args[args.index('--sign') + 1] == 'existing-identity'
                    assert args[args.index('--options') + 1] == 'runtime'
                else:
                    assert '--test-requirement==anchor apple generic and certificate leaf[subject.OU] = "ABCDE12345"' in args
                    if scenario == 'failed-signature': raise subprocess.CalledProcessError(1, args)
            else:
                raise AssertionError(args)
            return subprocess.CompletedProcess(args, 0)

        failed = False
        with patch.object(builder.subprocess, 'run', run):
            try:
                builder.build(repo, manifest, output, '-' if scenario == 'ad-hoc' else 'existing-identity', 'ABCDE12345', '7')
            except (ValueError, subprocess.CalledProcessError):
                failed = True
        assert failed == (scenario != 'three-devices'), scenario
        if not failed:
            assert len(principals) == len(list(output.glob('*.prefPane'))) == 3
            assert len([args for args in commands if args[1] == 'swiftc']) == 6
        else:
            assert not output.exists()
            if scenario != 'failed-signature': assert not commands
        assert not list(root.glob('sony-panes-*'))
        print(scenario + ': passed')
