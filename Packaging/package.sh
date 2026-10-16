#!/bin/zsh
set -euo pipefail

repo_root="${0:A:h:h}"
local_update=false
direct_release=false
if (( $# )); then
    if (( $# != 1 )) || [[ "$1" != --local && "$1" != --direct ]]; then
        print -u2 "Usage: Packaging/package.sh [--local | --direct]"
        exit 2
    fi
    if [[ "$1" == --local ]]; then local_update=true; else direct_release=true; fi
fi
distribution=production
if [[ "$local_update" == true ]]; then distribution=development; fi
no_sony_artwork="${ACOUPLET_NO_SONY_ARTWORK:-YES}"
if [[ -n "${ACOUPLET_SONY_ARTWORK_DIR:-}" ]] && ! (( ${+ACOUPLET_NO_SONY_ARTWORK} )); then no_sony_artwork=NO; fi
if [[ -z "${DEVELOPER_DIR:-}" ]]; then
  if [[ -d /Applications/Xcode-beta.app/Contents/Developer ]]; then DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer; else DEVELOPER_DIR="$(/usr/bin/xcode-select -p)"; fi
fi
export DEVELOPER_DIR
package_name="Acouplet"
package_dir="$repo_root/.build/package/$package_name"
build_app="$repo_root/.build/Build/Products/Release/Acouplet.app"
archive_path="$repo_root/dist/$package_name.zip"
if [[ "$local_update" == true ]]; then
    package_dir="$repo_root/.build/local-update/$package_name"
fi

if (( ${+CODE_SIGN_IDENTITY} )) && [[ -z "$CODE_SIGN_IDENTITY" ]]; then
    print -u2 "CODE_SIGN_IDENTITY is empty. Choose an existing Apple signing identity, or use '-' explicitly for ad-hoc signing."
    exit 1
fi
default_signing_identity='Developer ID Application'
if [[ "$local_update" == true ]]; then default_signing_identity='Apple Development'; fi
signing_identity="${CODE_SIGN_IDENTITY:-$default_signing_identity}"
signing_settings=("CODE_SIGN_IDENTITY=$signing_identity" CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO ENABLE_HARDENED_RUNTIME=YES)
if [[ -n "${DEVELOPMENT_TEAM:-}" ]]; then
    signing_settings+=("DEVELOPMENT_TEAM=$DEVELOPMENT_TEAM")
fi
if [[ "$signing_identity" != - ]] && { [[ "$local_update" == false ]] || (( ${+CODE_SIGN_IDENTITY} )) || [[ -z "${DEVELOPMENT_TEAM:-}" ]]; }; then
    signing_settings+=(CODE_SIGN_STYLE=Manual)
fi

mkdir -p "$repo_root/.build"
if (( ${+ACOUPLET_BUILD_NUMBER} )); then
    if [[ ! "$ACOUPLET_BUILD_NUMBER" =~ '^[1-9][0-9]*$' ]]; then
        print -u2 "ACOUPLET_BUILD_NUMBER must be a positive integer. The previous package was kept."
        exit 1
    fi
    build_number="$ACOUPLET_BUILD_NUMBER"
else
    build_counter="$repo_root/.build/package-build-number"
    previous_build=1
    if [[ -f "$build_counter" ]]; then
        previous_build="$(<"$build_counter")"
        if [[ ! "$previous_build" =~ '^[1-9][0-9]*$' ]]; then
            print -u2 "The saved package build number is invalid. The previous package was kept."
            exit 1
        fi
    fi
    installed_info="/Applications/Acouplet.app/Contents/Info.plist"
    if [[ -f "$installed_info" ]] && [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$installed_info")" == dev.baglayan.Acouplet ]]; then
        installed_build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$installed_info")"
        if [[ ! "$installed_build" =~ '^[1-9][0-9]*$' ]]; then
            print -u2 "The installed app build number is invalid. The previous package was kept."
            exit 1
        fi
        if (( installed_build > previous_build )); then previous_build=$installed_build; fi
    fi
    build_number=$(( previous_build + 1 ))
fi
marketing_version="${ACOUPLET_MARKETING_VERSION:-0.$build_number}"
if [[ ! "$marketing_version" =~ '^[0-9]+(\.[0-9]+){1,2}$' ]]; then
    print -u2 "ACOUPLET_MARKETING_VERSION must contain two or three numeric components. The previous package was kept."
    exit 1
fi
source_record="$(mktemp "$repo_root/.build/package-source.XXXXXX")"
trap 'rm -f "$source_record"' EXIT
source_options=()
if [[ "$local_update" == true ]]; then source_options=(--development); fi
/usr/bin/python3 "$repo_root/Packaging/release-source.py" capture "$repo_root" "$source_record" "${source_options[@]}"
if ! (( ${+ACOUPLET_BUILD_NUMBER} )); then
    print -r -- "$build_number" > "$build_counter.tmp"
    mv "$build_counter.tmp" "$build_counter"
fi
if [[ "$local_update" == false ]]; then mkdir -p "$repo_root/dist"; fi
rm -rf "$build_app/Contents/PlugIns/Acouplet Controls.appex"
rm -f "$build_app/Contents/Resources/Acouplet LDAC Output.pkg" "$build_app/Contents/Resources/Acouplet LDAC Removal.pkg"
/bin/zsh "$repo_root/Packaging/fetch-sparkle.sh"
print "Building Acouplet…"
if ! /usr/bin/xcrun xcodebuild \
    -project "$repo_root/Acouplet.xcodeproj" \
    -scheme "Acouplet" \
    -configuration Release \
    -derivedDataPath "$repo_root/.build" \
    "CURRENT_PROJECT_VERSION=$build_number" "MARKETING_VERSION=$marketing_version" "ACOUPLET_DISTRIBUTION=$distribution" \
    ACOUPLET_PUBLIC_APIS_ONLY=NO "ACOUPLET_NO_SONY_ARTWORK=$no_sony_artwork" "ACOUPLET_SONY_ARTWORK_DIR=${ACOUPLET_SONY_ARTWORK_DIR:-}" "${signing_settings[@]}" build > "$repo_root/.build/package-build.log" 2>&1; then
    tail -n 60 "$repo_root/.build/package-build.log"
    exit 1
fi
actual_distribution="$(/usr/libexec/PlistBuddy -c 'Print :AcoupletDistribution' "$build_app/Contents/Info.plist" 2>/dev/null || true)"
if [[ "$actual_distribution" != "$distribution" ]]; then
    print -u2 "The signed app must declare the requested $distribution distribution. The previous package was kept."
    exit 1
fi
if [[ -e "$build_app/Contents/PlugIns/Acouplet Controls.appex" ]]; then
    print -u2 "The deferred Controls extension must not be embedded. The previous package was kept."
    exit 1
fi
for notice in LICENSE THIRD-PARTY-NOTICES.md; do
    if ! /usr/bin/cmp -s "$repo_root/$notice" "$build_app/Contents/Resources/$notice"; then
        print -u2 "The signed app must contain the current $notice. The previous package was kept."
        exit 1
    fi
done
for notice in LICENSE NOTICE; do
    if ! /usr/bin/cmp -s "$repo_root/Vendor/libldac/$notice" "$build_app/Contents/Resources/LDAC-$notice.txt"; then
        print -u2 "The signed app must contain the current LDAC $notice. The previous package was kept."
        exit 1
    fi
done
/usr/bin/python3 "$repo_root/Packaging/check-sparkle-bundle.py" "$build_app"
/usr/bin/codesign --verify --deep --strict "$build_app"
signing_team="${DEVELOPMENT_TEAM:-}"
helper="$build_app/Contents/Helpers/Acouplet Battery Publisher"
hud="$build_app/Contents/Frameworks/SonyNativeHUD.dylib"
hud_check="$build_app/Contents/Helpers/SonyNativeHUDCheck"
sparkle="$build_app/Contents/Frameworks/Sparkle.framework"
ldac_audio="$build_app/Contents/Helpers/Acouplet Audio.app"
ldac_driver="$build_app/Contents/Helpers/AcoupletLDACOutput.driver"
if [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$ldac_driver/Contents/Info.plist")" != dev.baglayan.Acouplet.LDACOutput ]] ||
   ! /usr/bin/cmp -s "$repo_root/Helpers/LDAC/VirtualOutput/NullAudio.c" "$ldac_driver/Contents/Resources/NullAudio.c" ||
   ! /usr/bin/cmp -s "$repo_root/Helpers/LDAC/VirtualOutput/LICENSE.txt" "$ldac_driver/Contents/Resources/LICENSE.txt"; then
    print -u2 "The signed app must contain the owned LDAC output driver and unchanged Apple source/license. The previous package was kept."
    exit 1
fi
ldac_codes=("$build_app/Contents/Helpers/LDACSignaling" "$build_app/Contents/Helpers/LDACMediaTransport" "$build_app/Contents/Helpers/SonyAudioConnection" "$build_app/Contents/Helpers/LDACLogObserver" "$ldac_audio" "$ldac_driver")
for signed_bundle in "$build_app" "$helper" "$hud" "$hud_check" "$sparkle/Versions/B/XPCServices/Installer.xpc" "$sparkle/Versions/B/Autoupdate" "$sparkle/Versions/B/Updater.app" "$sparkle" "${ldac_codes[@]}"; do
    signature="$(/usr/bin/codesign --display --verbose=2 "$signed_bundle" 2>&1)"
    signature_flags="$(print -r -- "$signature" | /usr/bin/sed -n 's/^CodeDirectory .*flags=[^(]*(\([^)]*\)).*/\1/p')"
    if [[ ",$signature_flags," != *,runtime,* ]]; then
        print -u2 "The app and bundled helpers must enable hardened runtime. The previous package was kept."
        exit 1
    fi
    entitlements="$(/usr/bin/codesign --display --entitlements - --xml "$signed_bundle" 2>/dev/null)"
    debugging_allowed="$(print -r -- "$entitlements" | /usr/bin/plutil -extract 'com\.apple\.security\.get-task-allow' raw -o - - 2>/dev/null || true)"
    if [[ "$debugging_allowed" == true ]]; then
        print -u2 "The app and bundled helpers must omit debugger access in Release. The previous package was kept."
        exit 1
    fi
    if [[ "$signed_bundle" == "$build_app" ]] && print -r -- "$entitlements" | /usr/bin/plutil -extract 'com\.apple\.security\.app-sandbox' raw -o - - >/dev/null 2>&1; then
        print -u2 "The direct app must omit the sandbox entitlement so LDAC can use its signaling helper. The previous package was kept."
        exit 1
    fi
    if [[ "$signed_bundle" == "$helper" ]]; then
        sandbox_keys="$(print -r -- "$entitlements" | /usr/bin/plutil -convert xml1 -o - - | /usr/bin/grep -c '<key>com.apple.security\.' || true)"
        if [[ "$sandbox_keys" != 0 ]]; then
            print -u2 "The direct battery helper must omit sandbox entitlements to run independently of the app. The previous package was kept."
            exit 1
        fi
        actual_build="$(/usr/bin/otool -arch "$(/usr/bin/uname -m)" -P "$helper" | /usr/bin/sed -n '/<?xml/,$p' | /usr/bin/plutil -extract CFBundleVersion raw -o - -)"
    elif [[ "$signed_bundle" == "$build_app" || "$signed_bundle" == "$ldac_audio" || "$signed_bundle" == "$ldac_driver" ]]; then
        actual_build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$signed_bundle/Contents/Info.plist")"
    fi
    if [[ ("$signed_bundle" == "$build_app" || "$signed_bundle" == "$helper" || "$signed_bundle" == "$ldac_audio" || "$signed_bundle" == "$ldac_driver") && "$actual_build" != "$build_number" ]]; then
        print -u2 "The app and helper must share the new package build number. The previous package was kept."
        exit 1
    fi
    if [[ "$local_update" == false ]] && ! /usr/bin/codesign --verify --strict --all-architectures --test-requirement='=anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.13] exists' "$signed_bundle"; then
        print -u2 "Production packages require Developer ID Application signatures. Use --local for development signing. The previous package was kept."
        exit 1
    fi
    if [[ "$signing_identity" != - ]]; then
        if ! /usr/bin/codesign --verify --strict --test-requirement='=anchor apple generic' "$signed_bundle"; then
            print -u2 "The requested Apple certificate signature is missing or invalid. The previous package was kept."
            exit 1
        fi
        bundle_team="$(print -r -- "$signature" | sed -n 's/^TeamIdentifier=//p')"
        if [[ -z "$bundle_team" || "$bundle_team" == 'not set' || (-n "$signing_team" && "$bundle_team" != "$signing_team") ]]; then
            print -u2 "The app and bundled helpers must use the requested signing team. The previous package was kept."
            exit 1
        fi
        signing_team="$bundle_team"
    fi
done

/bin/sh "$repo_root/Packaging/build-ldac-output-installer.sh" "$ldac_driver" \
    "$build_app/Contents/Resources/Acouplet LDAC Output.pkg" "$marketing_version"
/usr/bin/codesign --force --sign "$signing_identity" --options runtime --preserve-metadata=entitlements --generate-entitlement-der "$build_app"
/usr/bin/codesign --verify --deep --strict "$build_app"
/usr/bin/python3 "$repo_root/Packaging/release-source.py" verify "$repo_root" "$source_record" > /dev/null
rm -rf "$package_dir"
mkdir -p "$package_dir"
/usr/bin/ditto "$build_app" "$package_dir/Acouplet.app"
cp "$repo_root/Packaging/Install.command" "$package_dir/Install.command"
cp "$repo_root/Packaging/Uninstall Service.command" "$package_dir/Uninstall Service.command"
cp "$repo_root/Packaging/Uninstall LDAC Output.command" "$package_dir/Uninstall LDAC Output.command"
cp "$repo_root/Packaging/README.txt" "$package_dir/README.txt"
cp "$repo_root/LICENSE" "$package_dir/LICENSE"
cp "$repo_root/THIRD-PARTY-NOTICES.md" "$package_dir/THIRD-PARTY-NOTICES.md"
chmod +x "$package_dir/Install.command" "$package_dir/Uninstall Service.command" "$package_dir/Uninstall LDAC Output.command"
/usr/bin/codesign --verify --deep --strict "$package_dir/Acouplet.app"
source_provenance="$(/usr/bin/python3 "$repo_root/Packaging/release-source.py" verify "$repo_root" "$source_record")"
receipt="$package_dir/Build Receipt.txt"
if [[ "$local_update" == true ]]; then receipt="$package_dir/Local Build Receipt.txt"; fi
{
    print "Prepared UTC: $(/bin/date -u +%Y-%m-%dT%H:%M:%SZ)"
    print -r -- "$source_provenance"
    print -r -- "Signing identity: $signing_identity"
    print -r -- "Build number: $build_number"
    print -r -- "Distribution: $actual_distribution"
    print "Configuration: Release"
    print "Control Center gallery: deferred; extension excluded"
    print "Release hardening: app and bundled helpers use hardened runtime without debugger access"
    print "LDAC output: driver installer embedded; authorize installation from the app and restart the Mac to activate"
    print -r -- "Driver installer signing identity: ${ACOUPLET_INSTALLER_SIGNING_IDENTITY:-unsigned local package}"
    print -r -- "Driver installer SHA256: $(/usr/bin/shasum -a 256 "$build_app/Contents/Resources/Acouplet LDAC Output.pkg" | /usr/bin/awk '{print $1}')"
    if [[ "$signing_identity" == - ]]; then
        print "Permission continuity: ad-hoc signature; a changed build may request Bluetooth access again"
    fi
    if [[ "$local_update" == true ]]; then
        print -r -- "Release app: $build_app"
    else
        print "Release app: Acouplet.app"
    fi
    for relative in "Contents/MacOS/Acouplet" "Contents/Helpers/Acouplet Battery Publisher" "Contents/Frameworks/SonyNativeHUD.dylib" "Contents/Helpers/SonyNativeHUDCheck" "Contents/Resources/Assets.car" "Contents/Frameworks/Sparkle.framework/Versions/B/Sparkle" "Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate" "Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app/Contents/MacOS/Updater" "Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Installer.xpc/Contents/MacOS/Installer" "Contents/Helpers/LDACSignaling" "Contents/Helpers/LDACMediaTransport" "Contents/Helpers/SonyAudioConnection" "Contents/Helpers/LDACLogObserver" "Contents/Helpers/Acouplet Audio.app/Contents/MacOS/AcoupletAudio" "Contents/Helpers/AcoupletLDACOutput.driver/Contents/MacOS/AcoupletVirtualOutput" "Contents/Helpers/AcoupletLDACOutput.driver/Contents/Info.plist" "Contents/Resources/Acouplet LDAC Output.pkg" "Contents/Resources/Acouplet LDAC Removal.pkg" "Contents/_CodeSignature/CodeResources"; do
        /usr/bin/cmp "$build_app/$relative" "$package_dir/Acouplet.app/$relative"
        digest="$(/usr/bin/shasum -a 256 "$build_app/$relative" | /usr/bin/awk '{print $1}')"
        print -r -- $'SHA256\t'"$digest"$'\t'"$relative"
    done
    print "Release/staged identity and strict signature verification: passed"
} > "$receipt"
if [[ "$local_update" == true ]]; then
    print "Local build prepared; distribution ZIP unchanged."
    if [[ "$signing_identity" == - ]]; then
        print "This ad-hoc build may request Bluetooth permission again. Use a consistent Apple signing identity to retain access across updates."
    fi
    print "Install it with the command below. It quits the running app and its background service itself:"
    print -r -- "  \"$package_dir/Install.command\" --require-stopped"
    print -r -- "Build receipt: $receipt"
elif [[ "$direct_release" == true ]]; then
    print -r -- "Production build staged for website release: $package_dir"
    print -r -- "Build receipt: $receipt"
else
    /usr/bin/ditto -c -k --sequesterRsrc --keepParent "$package_dir" "$archive_path.pending"
    /usr/bin/python3 "$repo_root/Packaging/release-source.py" verify "$repo_root" "$source_record" > /dev/null
    mv "$archive_path.pending" "$archive_path"
    print "Package: $archive_path"
fi
print "Extracted installer: $package_dir/Install.command"
