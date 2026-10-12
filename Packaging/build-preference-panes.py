from pathlib import Path
import json, plistlib, re, shutil, subprocess, sys, tempfile


def build(repo, manifest, output, identity, team, version):
    devices = json.loads(manifest.read_text())['devices']
    if not isinstance(devices, list) or not devices:
        raise ValueError('The pane manifest must list at least one known device.')
    addresses = set()
    for device in devices:
        address = device['address'].upper()
        if not re.fullmatch(r'(?:[0-9A-F]{2}:){5}[0-9A-F]{2}', address) or address in addresses:
            raise ValueError('Each pane needs a unique full Bluetooth address.')
        if not isinstance(device['modelName'], str) or not device['modelName'].strip() or any(ord(c) < 32 for c in device['modelName']):
            raise ValueError('Each pane needs a model name.')
        if device['systemSymbol'] not in ('earbuds.stemless', 'headphones'):
            raise ValueError('Unsupported pane icon.')
        device['address'] = address
        addresses.add(address)
    if identity == '-' or not re.fullmatch(r'[A-Z0-9]{10}', team):
        raise ValueError('Preference panes require the app’s Apple signing identity and team.')
    if output.exists():
        raise ValueError('The pane staging directory already exists.')
    pane_source = repo / 'PreferencePane'
    principal = (pane_source / 'SonyPreferencePane.swift').read_text()
    if principal.count('@objc(SonyPreferencePane)') != 1:
        raise ValueError('The pane principal class declaration changed.')
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='sony-panes-', dir=output.parent) as directory:
        work = Path(directory)
        staged = work / 'PreferencePanes'
        staged.mkdir()
        sdk = subprocess.run(['/usr/bin/xcrun', '--sdk', 'macosx', '--show-sdk-path'], check=True, capture_output=True, text=True).stdout.strip()
        for device in devices:
            suffix = device['address'].replace(':', '')
            principal_name = 'SonyPreferencePane_' + suffix
            module = 'SonyPane' + suffix
            bundle = staged / ('Sony-' + suffix + '.prefPane')
            contents = bundle / 'Contents'
            (contents / 'MacOS').mkdir(parents=True)
            (contents / 'Resources').mkdir()
            source = work / (module + '.swift')
            source.write_text(principal.replace('@objc(SonyPreferencePane)', '@objc(' + principal_name + ')'))
            icon = 'Earbuds.tiff' if device['systemSymbol'] == 'earbuds.stemless' else 'Headphones.tiff'
            shutil.copy2(pane_source / 'Resources' / icon, contents / 'Resources' / icon)
            label = device['modelName']
            if sum(other['modelName'] == label for other in devices) > 1:
                label += ' · ' + device['address']
            info = plistlib.loads((pane_source / 'Info.plist').read_bytes())
            info.update(CFBundleIdentifier='dev.baglayan.Acouplet.preference-pane.' + suffix.lower(),
                        CFBundleName=label, CFBundleDisplayName=label, CFBundleVersion=version,
                        CFBundleIconFile=icon, NSPrefPaneIconFile=icon, NSPrefPaneIconLabel=label,
                        NSPrincipalClass=principal_name, SonyDeviceAddress=device['address'],
                        SonyDeviceModelName=device['modelName'], SonyDeviceSystemSymbol=device['systemSymbol'],
                        AcoupletAppTeam=team)
            (contents / 'Info.plist').write_bytes(plistlib.dumps(info))
            slices = []
            for architecture in ('arm64', 'x86_64'):
                binary = work / (module + '-' + architecture)
                subprocess.run(['/usr/bin/xcrun', 'swiftc', '-swift-version', '6', '-warnings-as-errors', '-O',
                                '-parse-as-library', '-emit-library', '-Xlinker', '-bundle',
                                '-sdk', sdk, '-target', architecture + '-apple-macos27.0', '-module-name', module,
                                str(repo / 'Sources/SonyPreferencePaneTypes.swift'),
                                str(pane_source / 'SonyPreferencePaneClient.swift'),
                                str(pane_source / 'SonyPreferencePaneView.swift'), str(source),
                                '-framework', 'PreferencePanes', '-framework', 'AppKit', '-framework', 'SwiftUI',
                                '-framework', 'Security', '-o', str(binary)], check=True)
                slices.append(str(binary))
            executable = contents / 'MacOS' / info['CFBundleExecutable']
            subprocess.run(['/usr/bin/xcrun', 'lipo', '-create', *slices, '-output', str(executable)], check=True)
            subprocess.run(['/usr/bin/codesign', '--force', '--sign', identity, '--options', 'runtime', str(bundle)], check=True)
            requirement = '=anchor apple generic and certificate leaf[subject.OU] = "' + team + '"'
            subprocess.run(['/usr/bin/codesign', '--verify', '--deep', '--strict', '--test-requirement=' + requirement, str(bundle)], check=True)
        staged.rename(output)
    print('Prepared ' + str(len(devices)) + ' signed device preference pane(s).')


if __name__ == '__main__':
    if len(sys.argv) != 6:
        sys.exit('Usage: build-preference-panes.py MANIFEST OUTPUT SIGNING_IDENTITY TEAM BUILD_NUMBER')
    build(Path(__file__).resolve().parent.parent, Path(sys.argv[1]), Path(sys.argv[2]), *sys.argv[3:])
