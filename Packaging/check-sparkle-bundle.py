from pathlib import Path
import base64, plistlib, subprocess, sys


def code_targets(app):
    framework = app / 'Contents/Frameworks/Sparkle.framework'
    return [framework / 'Versions/B/XPCServices/Installer.xpc', framework / 'Versions/B/Autoupdate',
            framework / 'Versions/B/Updater.app', framework]


def check_bundle(app):
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    # Development builds (package.sh --local) carry no feed: upstream's releases share the signing key and
    # would replace a local build of the fork. The app does not start its updater without one.
    feed = '' if info.get('AcoupletDistribution') == 'development' else 'https://baglayan.dev/updates/appcast.xml'
    expected = {'SUFeedURL': feed,
                'SUVerifyUpdateBeforeExtraction': True, 'SURequireSignedFeed': True,
                'SUSignedFeedFailureExpirationInterval': 0, 'SUEnableInstallerLauncherService': False,
                'SUEnableDownloaderService': False, 'SUEnableSystemProfiling': False,
                'SUEnableAutomaticChecks': True, 'SUAutomaticallyUpdate': False}
    for key, value in expected.items():
        if info.get(key) != value or type(info.get(key)) is not type(value):
            raise ValueError('Incorrect Sparkle policy: ' + key)
    try:
        public_key = base64.b64decode(info['SUPublicEDKey'], validate=True)
    except (KeyError, TypeError, ValueError):
        raise ValueError('Missing or invalid Sparkle Ed25519 public key')
    if len(public_key) != 32 or not any(public_key):
        raise ValueError('Missing or invalid Sparkle Ed25519 public key')
    framework = code_targets(app)[-1]
    framework_info = plistlib.loads((framework / 'Resources/Info.plist').read_bytes())
    if framework_info['CFBundleShortVersionString'] != '2.10.0':
        raise ValueError('Unexpected Sparkle version')
    if (framework / 'Versions/B/XPCServices/Downloader.xpc').exists():
        raise ValueError('Unneeded Sparkle downloader service is embedded')
    for target in code_targets(app):
        if not target.exists():
            raise ValueError('Missing Sparkle nested code: ' + str(target))
    imports = subprocess.check_output(['/usr/bin/otool', '-arch', 'all', '-L', str(app / 'Contents/MacOS' / info['CFBundleExecutable'])])
    if b'@rpath/Sparkle.framework/Versions/B/Sparkle' not in imports:
        raise ValueError('Main executable does not link the bundled Sparkle framework')
    license = app / 'Contents/Resources/Sparkle-LICENSE.txt'
    if not license.is_file() or b'Copyright (c) 2006-2013 Andy Matuschak.' not in license.read_bytes():
        raise ValueError('Missing Sparkle license')


if __name__ == '__main__':
    check_bundle(Path(sys.argv[1]))
    print('Sparkle framework, nested tools, signing key and strict update policy: passed')
