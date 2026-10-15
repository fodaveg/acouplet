#!/bin/zsh
set -euo pipefail

package_dir="${0:A:h}"
require_stopped=false
if (( $# )); then
    if (( $# != 1 )) || [[ "$1" != --require-stopped ]]; then
        print -u2 "Usage: Install.command [--require-stopped]"
        exit 2
    fi
    require_stopped=true
fi
local_receipt="$package_dir/Local Build Receipt.txt"
verify_local_update=false
if [[ "$require_stopped" == true && -f "$local_receipt" ]]; then verify_local_update=true; fi
source_app="$package_dir/Acouplet.app"
installed_app="/Applications/Acouplet.app"
installed_executable="$installed_app/Contents/MacOS/Acouplet"
installed_controls="$installed_app/Contents/PlugIns/Acouplet Controls.appex"
staged_app="/Applications/.Acouplet.installing-$$.app"
backup_app="/Applications/.Acouplet.previous-$$.app"
label="dev.baglayan.Acouplet.agent"
domain="gui/$(id -u)"
plist_path="$HOME/Library/LaunchAgents/$label.plist"
backup_plist="$plist_path.previous-$$"
process_pattern='^/Applications/Acouplet\.app/Contents/MacOS/Acouplet( |$)'
legacy_apps=("/Applications/XM5 Control Native.app" "/Applications/XM5 Control.app")
legacy_identifiers=(local.xm5control.native local.xm5control)
legacy_labels=(local.xm5control.native.agent local.xm5control.agent)
legacy_patterns=('^/Applications/XM5 Control Native\.app/Contents/MacOS/XM5 Control( |$)' '^/Applications/XM5 Control\.app/Contents/MacOS/XM5 Control( |$)')
legacy_loaded=()

if [[ "$require_stopped" == true ]]; then
    for pattern in "$process_pattern" "$legacy_patterns[@]"; do
        if /usr/bin/pgrep -f "$pattern" >/dev/null; then
            print -u2 "Quit Acouplet and its previous versions normally before installing this update. Nothing was replaced."
            exit 1
        fi
    done
fi
if (( EUID == 0 )); then
    print -u2 "Run this installer as your normal logged-in user, without sudo."
    exit 1
fi
if [[ ! -d "$source_app" ]]; then
    print -u2 "Keep Install.command beside Acouplet.app in the extracted package."
    exit 1
fi
if [[ ! -w /Applications ]]; then
    print -u2 "Your account needs permission to install apps in /Applications."
    exit 1
fi
exec 9> /Applications/.Acouplet-install.lock
if ! /usr/bin/lockf -s -t 0 9; then
    print -u2 "Another Acouplet installation or service removal is running."
    exit 1
fi
exec 8> /Applications/.XM5-Control-install.lock
if ! /usr/bin/lockf -s -t 0 8; then
    print -u2 "A previous application installer or service removal is running."
    exit 1
fi
if [[ -e "$staged_app" || -L "$staged_app" || -e "$backup_app" || -L "$backup_app" || -e "$backup_plist" || -L "$backup_plist" ]]; then
    print -u2 "Recovery files already exist for this installation attempt; nothing was replaced."
    exit 1
fi
if [[ -e "$installed_app" || -L "$installed_app" ]] &&
   [[ -L "$installed_app" || -L "$installed_app/Contents" || -L "$installed_app/Contents/Info.plist" || "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$installed_app/Contents/Info.plist")" != dev.baglayan.Acouplet ]]; then
    print -u2 "An unexpected application exists at $installed_app; nothing was replaced."
    exit 1
fi
if [[ -L "$source_app" || -L "$source_app/Contents" || -L "$source_app/Contents/Info.plist" || "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$source_app/Contents/Info.plist")" != dev.baglayan.Acouplet ]]; then
    print -u2 "This package does not contain the expected Acouplet application."
    exit 1
fi
if [[ -e "$source_app/Contents/PlugIns/Acouplet Controls.appex" || -L "$source_app/Contents/PlugIns/Acouplet Controls.appex" ]]; then
    print -u2 "This package still includes the deferred Control Center extension; nothing was replaced."
    exit 1
fi
if [[ -e "$installed_controls" || -L "$installed_controls" ]] &&
   [[ -L "$installed_controls" || "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$installed_controls/Contents/Info.plist")" != dev.baglayan.Acouplet.controls ]]; then
    print -u2 "An unexpected Controls extension exists in the installed app; nothing was replaced."
    exit 1
fi
/usr/bin/codesign --verify --deep --strict "$source_app"
app_team="$(/usr/bin/codesign --display --verbose=2 "$source_app" 2>&1 | /usr/bin/sed -n 's/^TeamIdentifier=//p')"
if [[ ! "$app_team" =~ '^[A-Z0-9]{10}$' ]]; then
    print -u2 "This package requires an Apple-signed application; nothing was replaced."
    exit 1
fi
if [[ -d "$installed_app" ]]; then
    /usr/bin/codesign --verify --deep --strict --test-requirement="=anchor apple generic and identifier \"dev.baglayan.Acouplet\" and certificate leaf[subject.OU] = \"$app_team\"" "$installed_app"
fi

pane_directory="$HOME/Library/PreferencePanes"
source_panes=("$package_dir"/PreferencePanes/*.prefPane(N))
pane_stages=()
if [[ -e "$package_dir/PreferencePanes" ]]; then
    if [[ -L "$package_dir/PreferencePanes" || ${#source_panes} == 0 || -L "$pane_directory" ]]; then
        print -u2 "The device preference-pane directory is invalid; nothing was replaced."
        exit 1
    fi
    pane_team="$app_team"
    if [[ ! "$pane_team" =~ '^[A-Z0-9]{10}$' ]]; then
        print -u2 "Device preference panes require an Apple-signed app; nothing was replaced."
        exit 1
    fi
    for pane in "$source_panes[@]"; do
        pane_info="$pane/Contents/Info.plist"
        address="$(/usr/libexec/PlistBuddy -c 'Print :SonyDeviceAddress' "$pane_info")"
        if [[ -L "$pane" || ! "$address" =~ '^([0-9A-F]{2}:){5}[0-9A-F]{2}$' ]]; then
            print -u2 "A device preference pane has an invalid address; nothing was replaced."
            exit 1
        fi
        suffix="${address//:/}"
        pane_id="dev.baglayan.Acouplet.preference-pane.${suffix:l}"
        if [[ "${pane:t}" != "Sony-$suffix.prefPane" ||
              "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$pane_info")" != "$pane_id" ||
              "$(/usr/libexec/PlistBuddy -c 'Print :NSPrincipalClass' "$pane_info")" != "SonyPreferencePane_$suffix" ]]; then
            print -u2 "A device preference pane does not match its pinned identity; nothing was replaced."
            exit 1
        fi
        /usr/bin/codesign --verify --deep --strict --test-requirement="=anchor apple generic and certificate leaf[subject.OU] = \"$pane_team\"" "$pane"
        target="$pane_directory/${pane:t}"
        if [[ -e "$target" || -L "$target" ]]; then
            target_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$target/Contents/Info.plist")"
            if [[ -L "$target" || -L "$target/Contents" || -L "$target/Contents/Info.plist" ||
                  "$target_id" != "$pane_id" && "$target_id" != "local.xm5control.native.preference-pane.${suffix:l}" ]]; then
                print -u2 "An unexpected preference pane exists at $target; nothing was replaced."
                exit 1
            fi
            /usr/bin/codesign --verify --deep --strict --test-requirement="=anchor apple generic and identifier \"$target_id\" and certificate leaf[subject.OU] = \"$pane_team\"" "$target"
        fi
        for recovery in "$pane_directory/.${pane:t}.installing-$$" "$pane_directory/.${pane:t}.previous-$$"; do
            if [[ -e "$recovery" || -L "$recovery" ]]; then
                print -u2 "Preference-pane recovery files already exist; nothing was replaced."
                exit 1
            fi
        done
    done
fi

if [[ "$verify_local_update" == true ]]; then
    local_release_app="$(/usr/bin/sed -n 's/^Release app: //p' "$local_receipt")"
    local_binaries=("Contents/MacOS/Acouplet" "Contents/Helpers/Acouplet Battery Publisher" "Contents/Frameworks/SonyNativeHUD.dylib" "Contents/Helpers/SonyNativeHUDCheck" "Contents/Resources/Assets.car" "Contents/Frameworks/Sparkle.framework/Versions/B/Sparkle" "Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate" "Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app/Contents/MacOS/Updater" "Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Installer.xpc/Contents/MacOS/Installer" "Contents/Helpers/LDACSignaling" "Contents/Helpers/LDACMediaTransport" "Contents/Helpers/SonyAudioConnection" "Contents/Helpers/LDACLogObserver" "Contents/Helpers/Acouplet Audio.app/Contents/MacOS/AcoupletAudio" "Contents/Helpers/AcoupletLDACOutput.driver/Contents/MacOS/AcoupletVirtualOutput" "Contents/Helpers/AcoupletLDACOutput.driver/Contents/Info.plist" "Contents/Resources/Acouplet LDAC Output.pkg" "Contents/Resources/Acouplet LDAC Removal.pkg" "Contents/_CodeSignature/CodeResources")
    for relative in "$local_binaries[@]"; do
        expected="$(/usr/bin/awk -F '\t' -v target="$relative" '$1 == "SHA256" && $3 == target { print $2 }' "$local_receipt")"
        if [[ ! "$expected" =~ '^[0-9a-f]{64}$' ]]; then
            print -u2 "The local build receipt is incomplete. Prepare the local build again."
            exit 1
        fi
        for candidate in "$local_release_app/$relative" "$source_app/$relative"; do
            if [[ ! -f "$candidate" || "$(/usr/bin/shasum -a 256 "$candidate" | /usr/bin/awk '{print $1}')" != "$expected" ]]; then
                print -u2 "The Release or staged app changed after preparation. Prepare the local build again."
                exit 1
            fi
        done
    done
fi

if [[ -e "$plist_path" || -L "$plist_path" ]]; then
    if [[ -L "$plist_path" || "$(/usr/libexec/PlistBuddy -c 'Print :Label' "$plist_path")" != "$label" ||
          "$(/usr/libexec/PlistBuddy -c 'Print :ProgramArguments:0' "$plist_path")" != "$installed_executable" ]]; then
        print -u2 "An unexpected service configuration already exists at $plist_path."
        exit 1
    fi
fi
if service_state="$(/bin/launchctl print "$domain/$label" 2>/dev/null)"; then
    if [[ ! -e "$plist_path" || "$(print -r -- "$service_state" | awk '/^[[:space:]]*program = / { sub(/^[[:space:]]*program = /, ""); print; exit }')" != "$installed_executable" ]]; then
        print -u2 "The loaded service cannot be matched to the installed configuration. Run Uninstall Service.command first."
        exit 1
    fi
fi
for index in {1..2}; do
    legacy_app="$legacy_apps[$index]"
    legacy_executable="$legacy_app/Contents/MacOS/XM5 Control"
    legacy_label="$legacy_labels[$index]"
    legacy_plist="$HOME/Library/LaunchAgents/$legacy_label.plist"
    if [[ -e "$legacy_app" || -L "$legacy_app" ]]; then
        if [[ -L "$legacy_app" || -L "$legacy_app/Contents" || -L "$legacy_app/Contents/Info.plist" ||
              -L "$legacy_app/Contents/MacOS" || -L "$legacy_executable" || ! -x "$legacy_executable" ||
              "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$legacy_app/Contents/Info.plist")" != "$legacy_identifiers[$index]" ]]; then
            print -u2 "An unexpected application exists at $legacy_app; nothing was replaced."
            exit 1
        fi
        /usr/bin/codesign --verify --deep --strict --test-requirement="=anchor apple generic and identifier \"$legacy_identifiers[$index]\" and certificate leaf[subject.OU] = \"$app_team\"" "$legacy_app"
        legacy_controls="$legacy_app/Contents/PlugIns/XM5 Controls.appex"
        if [[ -e "$legacy_controls" || -L "$legacy_controls" ]] &&
           [[ -L "$legacy_controls" || "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$legacy_controls/Contents/Info.plist")" != "$legacy_identifiers[$index].controls" ]]; then
            print -u2 "An unexpected Controls extension exists in the previous app; nothing was replaced."
            exit 1
        fi
    fi
    if [[ -e "$legacy_plist" || -L "$legacy_plist" ]]; then
        if [[ -L "$legacy_plist" || "$(/usr/libexec/PlistBuddy -c 'Print :Label' "$legacy_plist")" != "$legacy_label" ||
              "$(/usr/libexec/PlistBuddy -c 'Print :ProgramArguments:0' "$legacy_plist")" != "$legacy_executable" ]]; then
            print -u2 "An unexpected service configuration exists at $legacy_plist; nothing was replaced."
            exit 1
        fi
    fi
    if legacy_service_state="$(/bin/launchctl print "$domain/$legacy_label" 2>/dev/null)"; then
        if [[ ! -f "$legacy_plist" || "$(print -r -- "$legacy_service_state" | awk '/^[[:space:]]*program = / { sub(/^[[:space:]]*program = /, ""); print; exit }')" != "$legacy_executable" ]]; then
            print -u2 "The loaded previous service does not match its installed configuration; nothing was replaced."
            exit 1
        fi
    fi
done

controls_unregistered=false
update_started=false
new_app_installed=false
plist_written=false
service_was_loaded=false
service_should_start=true
install_complete=false
login_item_removed=false
if [[ -e "$plist_path" ]]; then
    service_should_start=false
elif [[ -e "$HOME/Library/LaunchAgents/$legacy_labels[1].plist" ]]; then
    service_should_start=false
    if /bin/launchctl print "$domain/$legacy_labels[1]" >/dev/null 2>&1; then service_should_start=true; fi
fi

restore_installation() {
    if /bin/launchctl print "$domain/$label" >/dev/null 2>&1; then
        /bin/launchctl bootout "$domain/$label" || return 1
    fi
    # The new app removed the login item before its service started; give it back while that app is
    # still in place, because older builds cannot register it from the command line.
    if [[ "$login_item_removed" == true ]] && ! "$installed_executable" --register-login-item >/dev/null; then
        print -u2 "The previous login item could not be restored. Turn on Launch at login in Acouplet Settings if you used it."
    fi
    if [[ -d "$backup_app" ]]; then
        if [[ -e "$installed_app" ]]; then
            mv "$installed_app" "$staged_app" || return 1
        fi
        mv "$backup_app" "$installed_app" || return 1
    elif [[ "$new_app_installed" == true ]]; then
        rm -rf "$installed_app" || return 1
    fi
    if [[ "$plist_written" == true && -e "$backup_plist" ]]; then
        mv -f "$backup_plist" "$plist_path" || return 1
    elif [[ "$plist_written" == true ]]; then
        rm -f "$plist_path" || return 1
    fi
    if [[ "$controls_unregistered" == true ]]; then
        /usr/bin/pluginkit -a "$installed_controls" || return 1
    fi
    if [[ "$service_was_loaded" == true ]]; then
        /bin/launchctl bootstrap "$domain" "$plist_path" || return 1
    fi
    for legacy_label in "$legacy_loaded[@]"; do
        /bin/launchctl bootstrap "$domain" "$HOME/Library/LaunchAgents/$legacy_label.plist" || return 1
    done
}

finish_installation() {
    local exit_code=$?
    if [[ "$install_complete" == false && "$update_started" == true ]]; then
        print -u2 "Installation failed; restoring the previous installation."
        if ! restore_installation; then
            print -u2 "Rollback could not finish. Recovery files were kept; do not delete them:"
            for recovery_path in "$installed_app" "$backup_app" "$staged_app" "$plist_path" "$backup_plist"; do
                [[ ! -e "$recovery_path" ]] || print -u2 -r -- "$recovery_path"
            done
            return 1
        fi
    fi
    for pane_stage in "$pane_stages[@]"; do rm -rf "$pane_stage" || return 1; done
    rm -rf "$staged_app" "$backup_app" || return 1
    rm -f "$backup_plist" || return 1
    return "$exit_code"
}

trap finish_installation EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP
if (( ${#source_panes} )); then
    mkdir -p "$pane_directory"
    for pane in "$source_panes[@]"; do
        pane_stage="$pane_directory/.${pane:t}.installing-$$"
        pane_stages+=("$pane_stage")
        /usr/bin/ditto "$pane" "$pane_stage"
        /usr/bin/codesign --verify --deep --strict "$pane_stage"
    done
fi
/usr/bin/ditto "$source_app" "$staged_app"
/usr/bin/codesign --verify --deep --strict "$staged_app"
if [[ "$verify_local_update" == true ]]; then
    for relative in "$local_binaries[@]"; do /usr/bin/cmp "$source_app/$relative" "$staged_app/$relative"; done
fi
if [[ -e "$plist_path" ]]; then
    cp -p "$plist_path" "$backup_plist"
fi

quit_patterns=("$process_pattern" "$legacy_patterns[@]")
quit_identifiers=(dev.baglayan.Acouplet "$legacy_identifiers[@]")
for index in {1..3}; do
    original_pids="$(/usr/bin/pgrep -f "$quit_patterns[$index]" || true)"
    if [[ -n "$original_pids" ]]; then
        if [[ "$require_stopped" == true ]]; then
            print -u2 "An application opened again. Quit it normally before installing; nothing was replaced."
            exit 1
        fi
        if ! /usr/bin/osascript - "$quit_identifiers[$index]" <<'APPLESCRIPT'
on run arguments
    with timeout of 30 seconds
        set appIdentifier to item 1 of arguments
        if application id appIdentifier is running then
            tell application id appIdentifier to quit
        end if
    end timeout
end run
APPLESCRIPT
        then
            print -u2 "The application did not finish quitting. Nothing was replaced; finish its current operation and try again."
            exit 1
        fi
        for attempt in {1..120}; do
            original_running=false
            for original_pid in ${(f)original_pids}; do
                if /bin/kill -0 "$original_pid" 2>/dev/null; then
                    original_running=true
                    break
                fi
            done
            [[ "$original_running" == true ]] || break
            sleep 0.25
        done
        if [[ "$original_running" == true ]]; then
            print -u2 "The application has not finished quitting. Nothing was replaced; try again after its current operation ends."
            exit 1
        fi
    fi
done

update_started=true
if /bin/launchctl print "$domain/$label" >/dev/null 2>&1; then
    service_was_loaded=true
    service_should_start=true
    /bin/launchctl bootout "$domain/$label"
fi
for legacy_label in "$legacy_labels[@]"; do
    if /bin/launchctl print "$domain/$legacy_label" >/dev/null 2>&1; then
        /bin/launchctl bootout "$domain/$legacy_label"
        legacy_loaded+=("$legacy_label")
    fi
done
for pattern in "$legacy_patterns[@]"; do
    for attempt in {1..20}; do
        if ! /usr/bin/pgrep -f "$pattern" >/dev/null; then break; fi
        sleep 0.25
    done
    if /usr/bin/pgrep -f "$pattern" >/dev/null; then
        print -u2 "The previous application has not stopped. No app files were replaced."
        exit 1
    fi
done
for attempt in {1..20}; do
    if ! /usr/bin/pgrep -f "$process_pattern" >/dev/null; then
        break
    fi
    sleep 0.25
done
if /usr/bin/pgrep -f "$process_pattern" >/dev/null; then
    print -u2 "Acouplet has not stopped. No app files were replaced; try again after it closes."
    exit 1
fi

if [[ -d "$installed_controls" ]]; then
    if ! /usr/bin/pluginkit -r "$installed_controls"; then
        print -u2 "The previous Control Center extension could not be unregistered; nothing was replaced."
        exit 1
    fi
    controls_unregistered=true
fi
if [[ -d "$installed_app" ]]; then
    mv "$installed_app" "$backup_app"
fi
mv "$staged_app" "$installed_app"
new_app_installed=true
/usr/bin/codesign --verify --deep --strict --test-requirement="=anchor apple generic and identifier \"dev.baglayan.Acouplet\" and certificate leaf[subject.OU] = \"$app_team\"" "$installed_app"

mkdir -p "${plist_path:h}"
plist_content="$(cat <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>dev.baglayan.Acouplet.agent</string>
    <key>ProgramArguments</key>
    <array>
        <string>/Applications/Acouplet.app/Contents/MacOS/Acouplet</string>
        <string>--background-service</string>
    </array>
    <key>AssociatedBundleIdentifiers</key>
    <array>
        <string>dev.baglayan.Acouplet</string>
    </array>
    <key>LimitLoadToSessionType</key>
    <string>Aqua</string>
    <key>RunAtLoad</key>
    <true/>
    <key>EnvironmentVariables</key>
    <dict>
        <key>ACOUPLET_SERVICE_POLICY</key>
        <string>successful-exit-v1</string>
    </dict>
    <key>KeepAlive</key>
    <dict>
        <key>SuccessfulExit</key>
        <false/>
    </dict>
</dict>
</plist>
PLIST
)"
expected_configuration="$(print -r -- "$plist_content" | /usr/bin/plutil -convert json -r -o - -)"
if [[ ! -e "$plist_path" ]] ||
   ! existing_configuration="$(/usr/bin/plutil -convert json -r -o - "$plist_path" 2>/dev/null)" ||
   [[ "$existing_configuration" != "$expected_configuration" ]]; then
    plist_written=true
    print -r -- "$plist_content" > "$plist_path"
    chmod 644 "$plist_path"
    /usr/bin/plutil -lint "$plist_path"
fi
if [[ "$service_should_start" == true ]]; then
    # Remove the login item before the service starts. A copy of the app that is still running when
    # the service checks for duplicates makes the service quit, and a clean exit is not relaunched.
    if ! login_item_result="$("$installed_executable" --unregister-login-item)"; then
        print -u2 "The previous login-item registration could not be removed."
        exit 1
    fi
    if [[ "$login_item_result" == *"login-item: removed"* ]]; then login_item_removed=true; fi
    /bin/launchctl bootstrap "$domain" "$plist_path"
    for attempt in {1..20}; do
        service_state="$(/bin/launchctl print "$domain/$label")"
        if [[ "$service_state" == *"state = running"* ]]; then
            install_complete=true
            break
        fi
        sleep 0.25
    done
else
    install_complete=true
fi
if [[ "$install_complete" == false ]]; then
    print -u2 "The replacement background service has not started."
    print -u2 "Check System Settings > General > Login Items & Extensions for Acouplet."
    exit 1
fi

for index in {1..2}; do
    legacy_app="$legacy_apps[$index]"
    legacy_executable="$legacy_app/Contents/MacOS/XM5 Control"
    legacy_label="$legacy_labels[$index]"
    if [[ -d "$legacy_app" ]]; then
        if ! "$legacy_executable" --unregister-login-item; then
            print -u2 "Acouplet is installed, but the previous app could not unregister its login item and was kept. Run the installer again to retry."
            exit 1
        fi
        legacy_controls="$legacy_app/Contents/PlugIns/XM5 Controls.appex"
        if [[ -d "$legacy_controls" ]]; then /usr/bin/pluginkit -r "$legacy_controls"; fi
        if ! /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$legacy_app"; then
            print -u2 "Acouplet is installed, but the previous app could not be unregistered and was kept."
            exit 1
        fi
        rm -rf "$legacy_app"
    fi
    rm -f "$HOME/Library/LaunchAgents/$legacy_label.plist"
done
if ! /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$installed_app"; then
    print -u2 "Acouplet is installed, but its application registration could not be refreshed. Run the installer again to retry."
    exit 1
fi
install_preference_panes() {
    local pane target pane_stage pane_backup
    for pane in "$source_panes[@]"; do
        target="$pane_directory/${pane:t}"
        pane_stage="$pane_directory/.${pane:t}.installing-$$"
        pane_backup="$pane_directory/.${pane:t}.previous-$$"
        if [[ -e "$target" ]]; then mv "$target" "$pane_backup" || return 1; fi
        if ! mv "$pane_stage" "$target"; then
            if [[ -e "$pane_backup" ]]; then
                mv "$pane_backup" "$target" || print -u2 -r -- "Previous pane kept for recovery: $pane_backup"
            fi
            return 1
        fi
        rm -rf "$pane_backup" || return 1
    done
    if (( ${#source_panes} )); then
        local prototype="$pane_directory/Sony Headphones Compatibility.prefPane"
        if [[ -d "$prototype" && ! -L "$prototype" ]] &&
           [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$prototype/Contents/Info.plist")" == (dev.baglayan.Acouplet.research.preference-pane|local.xm5control.research.preference-pane) ]]; then
            /usr/bin/codesign --verify --deep --strict --test-requirement="=anchor apple generic and certificate leaf[subject.OU] = \"$pane_team\"" "$prototype" || return 1
            rm -rf "$prototype" || return 1
        fi
        print "Installed ${#source_panes} device preference pane(s). Reopen System Settings to refresh its sidebar."
    fi
}
if ! install_preference_panes; then
    print -u2 "Acouplet is installed, but its device preference panes could not all be installed. The previous pane was kept where replacement failed. Run the installer again to retry."
    exit 1
fi
if [[ "$verify_local_update" == true ]]; then
    if ! /usr/bin/codesign --verify --deep --strict "$installed_app"; then
        print -u2 "The update is installed, but its signature verification failed. No successful install receipt was written."
        exit 1
    fi
    for relative in "$local_binaries[@]"; do
        if ! /usr/bin/cmp "$source_app/$relative" "$installed_app/$relative" ||
           ! /usr/bin/cmp "$local_release_app/$relative" "$installed_app/$relative"; then
            print -u2 "The update is installed, but Release/staged/installed identity verification failed. No successful install receipt was written."
            exit 1
        fi
    done
    receipt="${package_dir:h}/Local Install-$(/bin/date -u +%Y%m%dT%H%M%SZ)-$$.txt"
    {
        cat "$local_receipt"
        print "Installed UTC: $(/bin/date -u +%Y-%m-%dT%H:%M:%SZ)"
        print -r -- "Installed app: $installed_app"
        print "Control Center gallery: deferred; extension excluded"
        print "Device preference panes installed: ${#source_panes}"
        print "Release/staged/installed identity and strict signature verification: passed"
        print -r -- "Background service requested by existing installer policy: $service_should_start"
    } > "$receipt"
    print -r -- "Install receipt: $receipt"
fi
if [[ "$service_should_start" == true ]]; then
    print "Acouplet is installed and running in the background."
else
    print "Acouplet is updated. Its previously stopped background service remains stopped."
fi
print "Its menu-bar icon appears when a supported Sony device is connected."
print "Background access is managed in System Settings > General > Login Items & Extensions."
if [[ -f "$installed_app/Contents/Resources/Acouplet LDAC Output.pkg" ]]; then
    print "Enable LDAC in the app to authorize its bundled driver installation."
    print "Restart the Mac to activate the driver. This app installer did not install it or restart Core Audio."
fi
