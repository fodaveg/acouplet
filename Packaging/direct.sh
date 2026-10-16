#!/bin/zsh
set -euo pipefail

repo_root="${0:A:h:h}"
notarize=false
if (( $# )); then
    if (( $# != 1 )) || [[ "$1" != --notarize ]]; then
        print -u2 "Usage: Packaging/direct.sh [--notarize]"
        exit 2
    fi
    notarize=true
fi
appearance="${ACOUPLET_DMG_APPEARANCE:-pearl}"
if [[ "$appearance" != dark && "$appearance" != pearl ]]; then
    print -u2 "ACOUPLET_DMG_APPEARANCE must be dark or pearl."
    exit 2
fi
if [[ "${CODE_SIGN_IDENTITY:-}" != 'Developer ID Application: '?* && ! "${CODE_SIGN_IDENTITY:-}" =~ '^[[:xdigit:]]{40}$' ]]; then
    print -u2 "Set CODE_SIGN_IDENTITY to the name or SHA-1 fingerprint of an existing Developer ID Application identity."
    exit 1
fi
if [[ "${ACOUPLET_INSTALLER_SIGNING_IDENTITY:-}" != 'Developer ID Installer: '?* && ! "${ACOUPLET_INSTALLER_SIGNING_IDENTITY:-}" =~ '^[[:xdigit:]]{40}$' ]]; then
    print -u2 "Set ACOUPLET_INSTALLER_SIGNING_IDENTITY to an existing Developer ID Installer identity."
    exit 1
fi
if [[ "$notarize" == true && -z "${NOTARY_KEYCHAIN_PROFILE:-}" ]]; then
    print -u2 "Set NOTARY_KEYCHAIN_PROFILE to an existing notarytool Keychain profile for --notarize."
    exit 1
fi
notary_keychain=()
if [[ -n "${NOTARY_KEYCHAIN_PATH:-}" ]]; then notary_keychain=(--keychain "$NOTARY_KEYCHAIN_PATH"); fi
if [[ -z "${DEVELOPER_DIR:-}" ]]; then
  if [[ -d /Applications/Xcode-beta.app/Contents/Developer ]]; then DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer; else DEVELOPER_DIR="$(/usr/bin/xcode-select -p)"; fi
fi
export DEVELOPER_DIR
mkdir -p "$repo_root/.build/direct-release" "$repo_root/dist"
release_dir="$(mktemp -d "$repo_root/.build/direct-release/release.XXXXXX")"
source_record="$release_dir/source-inputs.json"
/usr/bin/python3 "$repo_root/Packaging/release-source.py" capture "$repo_root" "$source_record"
if ! /usr/bin/python3 "$repo_root/Packaging/check-all.py" > "$release_dir/checks.log" 2>&1; then
    tail -n 60 "$release_dir/checks.log"
    exit 1
fi
/usr/bin/python3 "$repo_root/Packaging/release-source.py" verify "$repo_root" "$source_record" > "$release_dir/Source Receipt.txt"
if ! "$repo_root/Packaging/package.sh" --direct > "$release_dir/build.log" 2>&1; then
    tail -n 60 "$release_dir/build.log"
    exit 1
fi
/usr/bin/python3 "$repo_root/Packaging/release-source.py" verify "$repo_root" "$source_record" > "$release_dir/Source Receipt.txt"
stage="$release_dir/payload"
mkdir "$stage"
app="$stage/Acouplet.app"
/usr/bin/ditto "$repo_root/.build/package/Acouplet/Acouplet.app" "$app"
/usr/bin/codesign --force --sign "$CODE_SIGN_IDENTITY" --options runtime --timestamp "$app/Contents/Frameworks/SonyNativeHUD.dylib"
/usr/bin/codesign --force --sign "$CODE_SIGN_IDENTITY" --options runtime --timestamp "$app/Contents/Helpers/SonyNativeHUDCheck"
/usr/bin/codesign --force --sign "$CODE_SIGN_IDENTITY" --options runtime --timestamp --entitlements "$repo_root/Helpers/BatteryHelper.entitlements" --generate-entitlement-der "$app/Contents/Helpers/Acouplet Battery Publisher"
sparkle="$app/Contents/Frameworks/Sparkle.framework"
for sparkle_code in "$sparkle/Versions/B/XPCServices/Installer.xpc" "$sparkle/Versions/B/Autoupdate" "$sparkle/Versions/B/Updater.app" "$sparkle"; do
    /usr/bin/codesign --force --sign "$CODE_SIGN_IDENTITY" --options runtime --timestamp "$sparkle_code"
done
for ldac_code in "$app/Contents/Helpers/LDACSignaling" "$app/Contents/Helpers/LDACMediaTransport" "$app/Contents/Helpers/SonyAudioConnection" "$app/Contents/Helpers/LDACLogObserver" "$app/Contents/Helpers/Acouplet Audio.app" "$app/Contents/Helpers/AcoupletLDACOutput.driver"; do
    /usr/bin/codesign --force --sign "$CODE_SIGN_IDENTITY" --options runtime --timestamp "$ldac_code"
done
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")"
/bin/sh "$repo_root/Packaging/build-ldac-output-installer.sh" "$app/Contents/Helpers/AcoupletLDACOutput.driver" \
    "$app/Contents/Resources/Acouplet LDAC Output.pkg" "$version"
if [[ "$notarize" == true ]]; then
    /usr/bin/python3 "$repo_root/Packaging/release-source.py" verify "$repo_root" "$source_record" > "$release_dir/Source Receipt.txt"
    /usr/bin/python3 "$repo_root/Packaging/notarize-ldac-installer.py" "$app" --profile "$NOTARY_KEYCHAIN_PROFILE" \
        --evidence-dir "$release_dir" "${notary_keychain[@]}"
fi
/usr/bin/swift "$repo_root/Packaging/DMGBackground.swift" \
    "$app/Contents/Resources/AppIcon.icns" "$app/Contents/Resources/DMGBackground.tiff" "$appearance"
/usr/bin/sed 's/$(PRODUCT_BUNDLE_IDENTIFIER)/dev.baglayan.Acouplet/g' "$repo_root/Configuration/Direct.entitlements" > "$release_dir/Direct.entitlements"
/usr/bin/codesign --force --sign "$CODE_SIGN_IDENTITY" --options runtime --timestamp --entitlements "$release_dir/Direct.entitlements" --generate-entitlement-der "$app"
/usr/bin/python3 "$repo_root/Packaging/check-distribution.py" "$stage" --signatures-only > "$release_dir/signatures.json"
/bin/cp "$repo_root/.build/package/Acouplet/Build Receipt.txt" "$release_dir/Original Build Receipt.txt"
for relative in 'Contents/MacOS/Acouplet' 'Contents/Helpers/Acouplet Battery Publisher' 'Contents/Frameworks/SonyNativeHUD.dylib' 'Contents/Helpers/SonyNativeHUDCheck' 'Contents/Resources/Assets.car' 'Contents/Frameworks/Sparkle.framework/Versions/B/Sparkle' 'Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate' 'Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app/Contents/MacOS/Updater' 'Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Installer.xpc/Contents/MacOS/Installer' 'Contents/Helpers/LDACSignaling' 'Contents/Helpers/LDACMediaTransport' 'Contents/Helpers/SonyAudioConnection' 'Contents/Helpers/LDACLogObserver' 'Contents/Helpers/Acouplet Audio.app/Contents/MacOS/AcoupletAudio' 'Contents/Helpers/AcoupletLDACOutput.driver/Contents/MacOS/AcoupletVirtualOutput' 'Contents/Helpers/AcoupletLDACOutput.driver/Contents/Info.plist' 'Contents/Resources/Acouplet LDAC Output.pkg' 'Contents/Resources/Acouplet LDAC Removal.pkg' 'Contents/_CodeSignature/CodeResources'; do
    /usr/bin/shasum -a 256 "$app/$relative"
done > "$release_dir/Binary SHA256.txt"
/usr/bin/ditto "$repo_root/.build/Build/Products/Release/Acouplet.app.dSYM" "$release_dir/Acouplet.app.dSYM"
/usr/bin/ditto "$repo_root/.build/Build/Products/Release/Acouplet Battery Publisher.dSYM" "$release_dir/Acouplet Battery Publisher.dSYM"
for symbols in Sparkle.framework.dSYM Autoupdate.dSYM Updater.app.dSYM Installer.xpc.dSYM; do
    /usr/bin/ditto "$repo_root/.build/Sparkle-2.10.0/Symbols/$symbols" "$release_dir/$symbols"
done
/bin/ln -s /Applications "$stage/Applications"
dmg="$release_dir/Acouplet-$version.dmg"
"$repo_root/Packaging/create-dmg.sh" "$stage" "$dmg"
/usr/bin/codesign --sign "$CODE_SIGN_IDENTITY" --timestamp --identifier dev.baglayan.Acouplet.disk-image "$dmg"
/usr/bin/hdiutil verify "$dmg"
/usr/bin/python3 "$repo_root/Packaging/check-distribution.py" "$stage" --signatures-only --dmg "$dmg" > "$release_dir/dmg-signatures.json"
/usr/bin/python3 "$repo_root/Packaging/release-source.py" verify "$repo_root" "$source_record" > "$release_dir/Source Receipt.txt"
if [[ "$notarize" == true ]]; then
    /usr/bin/xcrun notarytool submit "$dmg" --keychain-profile "$NOTARY_KEYCHAIN_PROFILE" "${notary_keychain[@]}" --wait --output-format json > "$release_dir/notary-result.json"
    submission="$(/usr/bin/python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["id"])' "$release_dir/notary-result.json")"
    /usr/bin/xcrun notarytool log "$submission" --keychain-profile "$NOTARY_KEYCHAIN_PROFILE" "${notary_keychain[@]}" "$release_dir/notary-log.json"
    /usr/bin/python3 -c 'import json, sys; result = json.load(open(sys.argv[1])); sys.exit(0 if result["status"] == "Accepted" else "Notarization was not accepted; previous distribution retained.")' "$release_dir/notary-result.json"
    /usr/bin/xcrun stapler staple "$dmg"
    /usr/bin/python3 "$repo_root/Packaging/check-distribution.py" "$stage" --dmg "$dmg" > "$release_dir/distribution.json"
    /usr/sbin/spctl --assess --type open --context context:primary-signature --verbose=4 "$dmg"
    /usr/sbin/spctl --assess --type execute --verbose=4 "$app"
    /usr/bin/python3 "$repo_root/Packaging/release-source.py" verify "$repo_root" "$source_record" > "$release_dir/Source Receipt.txt"
    final_dmg="$repo_root/dist/${dmg:t}"
    digest="$(/usr/bin/shasum -a 256 "$dmg" | /usr/bin/awk '{print $1}')"
    print -r -- "$digest  $final_dmg" > "$release_dir/SHA256.txt"
    /bin/mv "$dmg" "$final_dmg"
    print -r -- "Notarized DMG: $final_dmg"
else
    print -r -- "Signed DMG awaiting notarization; not ready for public distribution: $dmg"
fi
print -r -- "Release evidence: $release_dir"
