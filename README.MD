# EDID Resize — Simple EDID screen size editor for Windows 11

An EDID (Extended Display Identification Data) editor that lets you override your monitor's reported physical screen size so you can control how the Windows 11 virtual keyboard behaves.

The original tool ([migueltek.com/tool/simple-edid-editor-for-win-11](https://migueltek.com/tool/simple-edid-editor-for-win-11/)) is a web app. This repo ports it to a standalone PowerShell/WinForms desktop app (`EDID-Resize.ps1`, also available pre-built as `EDID-Resize.exe`) — no browser or manual `.reg` export/import round trip needed.

## The problem it solves

Windows 11 chooses the virtual keyboard mode based on the screen's reported physical size:

- **Under 18 inches** — keyboard is locked to *undocking mode* with a small layout.
- **18 inches or larger** — keyboard cannot use *docking mode* at all.

This tool overrides the EDID data Windows reads for your display so you can nudge the reported diagonal size below the 18" threshold to unlock docked mode.

## How it works

Windows directly supports EDID overrides via the registry. 

The WinForms app:

1. Detects local monitors and reads their EDID block 0 data straight from the registry
2. Automatically backs up the `Device Parameters` registry key before making changes
3. Lets you edit the EDID (e.g. change the reported diagonal size) through the UI
4. Writes the modified EDID directly to the `EDID_OVERRIDE` value at:
   `HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Enum\DISPLAY\[MONITOR_PATH]\Device Parameters\EDID_OVERRIDE`
5. Can also remove the `EDID_OVERRIDE` value to revert to the original EDID

Because it edits the registry directly, it requires Administrator privileges. The application launches elevated by default.

## Requirements

- Windows 11
- Administrator access

## Usage

1. Run `EDID-Resize.bat` (or `EDID-Resize.exe`, or `EDID-Resize.ps1` directly) and accept the UAC elevation prompt.
2. Select the monitor you want to modify from the detected list.
3. Set the desired screen diagonal (≥18" triggers docking-mode eligibility, <18" forces undocked mode).
4. Apply the change to write the `EDID_OVERRIDE` registry value.
5. Restart your computer for the change to take effect.
6. To revert, use the app's remove/restore option (or delete the `EDID_OVERRIDE` value) and restart.

## Warnings

Incorrect EDID data can cause display malfunction. Use at your own risk! 
You are fully responsible for any damage caused by editing EDID data.

## Known limitations

- Possible UI scaling inconsistencies with applications after the override.
- Some applications may have their own display-size-dependent quirks.
- The keyboard mode remains fixed until the EDID override is removed.
