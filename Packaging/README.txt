Acouplet - local development installer

Requires macOS 15.4 or later. This package is not notarized.

Install or update

1. Finish any active headphone operation. The installer quits Acouplet itself.
2. Keep the extracted package together and open Install.command without sudo.
3. Open Acouplet from Applications.

The installer preserves settings and adds a login service that restarts the app
if it crashes. A normal quit leaves it stopped until you open it or log in again.
Manage background access in System Settings > General > Login
Items & Extensions. If installation fails, keep any recovery files named in
the error.

LDAC setup

Use the app's LDAC setup action, approve macOS Installer, then restart the Mac.
Restarting only the app does not reload the audio driver. The output appears
under your device's name, for example WF-1000XM5 LDAC.

Remove

1. Stop LDAC and quit Acouplet.
2. If the audio driver is installed, run Uninstall LDAC Output.command and
   authorize removal while Acouplet is still in Applications.
3. Run Uninstall Service.command, then move the app to Trash.
4. Restart the Mac if you removed the audio driver. Preferences are kept.

Licenses

See LICENSE and THIRD-PARTY-NOTICES.md.
