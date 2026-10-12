#!/bin/sh
set -eu

ldac_helpers="$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH/Helpers"
ldac_resources="$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH/Resources"
ldac_build="$DERIVED_FILE_DIR/LDAC"
mkdir -p "$ldac_resources"
/usr/bin/xcrun xcstringstool compile "$SRCROOT/Resources/InfoPlist.xcstrings" --output-directory "$ldac_resources"
if [ "${ACOUPLET_PUBLIC_APIS_ONLY:-NO}" = YES ] || [ "${CONFIGURATION:-}" = AppStore ]; then
    rm -f "$ldac_helpers/LDACSignaling" "$ldac_helpers/LDACMediaTransport" "$ldac_helpers/SonyAudioConnection" "$ldac_helpers/LDACLogObserver"
    rm -rf "$ldac_helpers/Acouplet Audio.app" "$ldac_helpers/AcoupletLDACOutput.driver" "$ldac_build"
    rm -f "$ldac_resources/LDAC-LICENSE.txt" "$ldac_resources/LDAC-NOTICE.txt" "$ldac_resources/Acouplet LDAC Output.pkg" "$ldac_resources/Acouplet LDAC Removal.pkg"
    exit 0
fi
ldac_source="$SRCROOT/Helpers/LDAC"
ldac_encoder="$SRCROOT/Vendor/libldac"
ldac_sdk="${SDKROOT:-$(/usr/bin/xcrun --sdk macosx --show-sdk-path)}"
ldac_clang="$(/usr/bin/xcrun --find clang)"
ldac_arch_flags=""
for ldac_arch in ${ARCHS:-$(/usr/bin/uname -m)}; do ldac_arch_flags="$ldac_arch_flags -arch $ldac_arch"; done
mkdir -p "$ldac_helpers" "$ldac_resources" "$ldac_build"

build_transport() {
    ldac_name="$1"
    ldac_input="$2"
    shift 2
    ldac_info="$ldac_build/$ldac_name-Info.plist"
    /bin/cp "$ldac_source/PublicAVDTPDiscoverProbe.Info.plist" "$ldac_info"
    /usr/bin/plutil -replace CFBundleIdentifier -string "dev.baglayan.Acouplet.$ldac_name" "$ldac_info"
    /usr/bin/plutil -replace CFBundleName -string "$ldac_name" "$ldac_info"
    /usr/bin/plutil -replace NSBluetoothAlwaysUsageDescription -string 'Acouplet uses Bluetooth to play Mac audio through your paired Sony headphones using LDAC.' "$ldac_info"
    "$ldac_clang" $ldac_arch_flags -isysroot "$ldac_sdk" "-mmacosx-version-min=${MACOSX_DEPLOYMENT_TARGET:-15.4}" -O2 -fobjc-arc -fblocks -D_DARWIN_C_SOURCE \
        -framework Foundation -framework CoreFoundation -framework CoreBluetooth -framework IOBluetooth \
        "-Wl,-sectcreate,__TEXT,__info_plist,$ldac_info" "$ldac_source/$ldac_input" "$@" -o "$ldac_helpers/$ldac_name"
    if [ "${CODE_SIGNING_ALLOWED:-NO}" != NO ]; then
        /usr/bin/codesign --force --sign "${EXPANDED_CODE_SIGN_IDENTITY:--}" --identifier "dev.baglayan.Acouplet.$ldac_name" --options runtime --timestamp=none "$ldac_helpers/$ldac_name"
    fi
}

"$ldac_clang" $ldac_arch_flags -isysroot "$ldac_sdk" "-mmacosx-version-min=${MACOSX_DEPLOYMENT_TARGET:-15.4}" -O2 -Wall -Wextra -Werror \
    "$ldac_source/LDACLogObserver.c" -o "$ldac_helpers/LDACLogObserver"
if [ "${CODE_SIGNING_ALLOWED:-NO}" != NO ]; then
    /usr/bin/codesign --force --sign "${EXPANDED_CODE_SIGN_IDENTITY:--}" --identifier "dev.baglayan.Acouplet.LDACLogObserver" --options runtime --timestamp=none "$ldac_helpers/LDACLogObserver"
fi

build_transport LDACSignaling DirectAVDTPSustainedPlaybackProbe.m -DACOUPLET_LDAC_PROBE_ONLY=0
build_transport LDACMediaTransport DirectAVDTPLiveMediaProbe.m -DACOUPLET_LDAC_PROBE_ONLY=0 -I "$ldac_encoder/inc" -I "$ldac_encoder/src" "$ldac_encoder/src/ldacBT.c" "$ldac_encoder/src/ldaclib.c"
build_transport SonyAudioConnection PairedSonyConnectionProbe.m -framework CoreAudio
ldac_audio="$ldac_helpers/Acouplet Audio.app"
mkdir -p "$ldac_audio/Contents/MacOS"
/bin/cp "$ldac_source/AcoupletAudio.Info.plist" "$ldac_audio/Contents/Info.plist"
/usr/bin/plutil -replace CFBundleVersion -string "$CURRENT_PROJECT_VERSION" "$ldac_audio/Contents/Info.plist"
/usr/bin/xcrun xcstringstool compile "$ldac_source/Resources/InfoPlist.xcstrings" --output-directory "$ldac_audio/Contents/Resources"
for ldac_language in en tr; do
    ldac_audio_description="$(/usr/bin/plutil -extract NSAudioCaptureUsageDescription raw -o - "$ldac_audio/Contents/Resources/$ldac_language.lproj/InfoPlist.strings")"
    /usr/bin/plutil -insert NSAudioCaptureUsageDescription -string "$ldac_audio_description" "$ldac_resources/$ldac_language.lproj/InfoPlist.strings"
done
"$ldac_clang" $ldac_arch_flags -isysroot "$ldac_sdk" -mmacosx-version-min=15.4 -O2 -fobjc-arc -fblocks \
    -DACOUPLET_AUDIO_HELPER_BUNDLE_ID='"dev.baglayan.Acouplet.ldac-audio"' -DACOUPLET_AUDIO_HELPER_STREAM_ONLY=1 \
    -framework Foundation -framework CoreFoundation -framework CoreAudio -framework AudioToolbox \
    "$ldac_source/SystemAudioTapRunLoopProbe.m" -o "$ldac_audio/Contents/MacOS/AcoupletAudio"
if [ "${CODE_SIGNING_ALLOWED:-NO}" != NO ]; then
    /usr/bin/codesign --force --sign "${EXPANDED_CODE_SIGN_IDENTITY:--}" --options runtime --timestamp=none "$ldac_audio"
fi
ldac_team="${DEVELOPMENT_TEAM:-5743Y47SC7}"
case "$ldac_team" in
    [ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789][ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789][ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789][ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789][ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789][ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789][ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789][ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789][ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789][ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789]) ;;
    *)
        printf '%s\n' 'DEVELOPMENT_TEAM must be a 10-character Apple team ID to build the LDAC output driver.' >&2
        exit 1
        ;;
esac
ldac_driver="$ldac_helpers/AcoupletLDACOutput.driver"
mkdir -p "$ldac_driver/Contents/MacOS" "$ldac_driver/Contents/Resources"
/bin/cp "$ldac_source/VirtualOutput/Info.plist" "$ldac_driver/Contents/Info.plist"
/usr/bin/plutil -replace CFBundleVersion -string "$CURRENT_PROJECT_VERSION" "$ldac_driver/Contents/Info.plist"
/usr/bin/plutil -replace CFBundleShortVersionString -string "${MARKETING_VERSION:-0.24.9}" "$ldac_driver/Contents/Info.plist"
/bin/cp "$ldac_source/VirtualOutput/NullAudio.c" "$ldac_driver/Contents/Resources/NullAudio.c"
/bin/cp "$ldac_source/VirtualOutput/LICENSE.txt" "$ldac_driver/Contents/Resources/LICENSE.txt"
/bin/cp "$ldac_source/VirtualOutput/Resources/Headphones.png" "$ldac_source/VirtualOutput/Resources/Earbuds.png" "$ldac_source/VirtualOutput/Resources/Speaker.png" "$ldac_driver/Contents/Resources/"
"$ldac_clang" $ldac_arch_flags -isysroot "$ldac_sdk" "-mmacosx-version-min=${MACOSX_DEPLOYMENT_TARGET:-15.4}" -std=gnu11 -O2 -fblocks -Werror -bundle \
    "-DACOUPLET_SIGNING_TEAM=\"$ldac_team\"" -framework CoreAudio -framework CoreFoundation -framework Security "$ldac_source/VirtualOutput/AcoupletVirtualOutput.c" \
    -o "$ldac_driver/Contents/MacOS/AcoupletVirtualOutput"
if [ "${CODE_SIGNING_ALLOWED:-NO}" != NO ]; then
    ldac_timestamp=--timestamp=none
    case "${EXPANDED_CODE_SIGN_IDENTITY_NAME:-}" in
        'Developer ID Application: '*) ldac_timestamp=--timestamp ;;
    esac
    /usr/bin/codesign --force --sign "${EXPANDED_CODE_SIGN_IDENTITY:--}" --options runtime "$ldac_timestamp" "$ldac_driver"
fi
/bin/cp "$ldac_encoder/LICENSE" "$ldac_resources/LDAC-LICENSE.txt"
/bin/cp "$ldac_encoder/NOTICE" "$ldac_resources/LDAC-NOTICE.txt"
