# Changelog

## 1.3.0

- `install.sh` says what it's doing: `Installing`, `Upgrading 1.2.1 → 1.3.0`, `Reinstalling` or `Downgrading` (asks first, or `--force`). It shows the source (`git describe`) and warns about uncommitted changes, commits after the tag, or a tag that doesn't match `VERSION` (that last one stops unless `--force`). Builds that aren't a clean release tag are marked, for example `1.3.0 (1.3.0-2-gabc1234-dirty)`, in `--version` and in the app.
- It replaces files in one step (temp file + rename), then checks the installed versions.
- If the app is running, it is restarted on the new version in the same mode: through its systemd login unit when it started at login, otherwise stopped and started again. The login item is pointed at the installed app if it points somewhere else.
- `./install.sh --dry-run` shows what would happen without changing anything.
- The app quits cleanly on SIGTERM (systemd stop or restart, logout, the installer), so a rate change in progress finishes. `--uninstall` uses this too, instead of killing the app.
- The app shows its version: next to the login option (it opens an About box) and as an About item in the tray menu. Qt gets it too (`setApplicationVersion`).
- CI also runs the installer tests.

## 1.2.1

- App: when started in the tray at login before the desktop's tray is ready, it now waits up to 60 seconds for the tray instead of opening the window (which quit the app when closed). Only if no tray appears does it show the window, as before. A second launch still shows the window while it waits, and closing that window keeps it running.

## 1.2.0

- New app, `dac-rate-gui` (Qt / PySide6): pick the device, choose Auto / Lock / default, set the advanced options, see the live hardware rate and any conflicting config. Changes apply in the background and errors show in a dialog.
- Tray icon with the live rate as a badge, and a menu to switch without opening the window. "Start in the tray when I log in" adds a login item. Only one copy runs; launching it again shows the window.
- The menu launcher opens the app when PySide6 is installed, and the simple picker otherwise. `install.sh` checks for PySide6 and gives the package names per distro; uninstall also removes the login item.
- `dac-rate --json` for `devices`, `rates` and `status` (used by the app).
- CI also runs the app's tests offscreen against a fake `dac-rate`.

## 1.1.1

- README: a Dependencies section with package names for Arch, Debian/Ubuntu and Fedora, install commands, and which distro releases ship WirePlumber 0.5.
- `install.sh` checks all dependencies (including the WirePlumber version and bash 4), lists everything missing at once with the install command for your distro, and notes missing optional tools. `./install.sh --check` only checks.

## 1.1.0

- Rules now match the whole card by default (`-m card`), so they keep working after a profile change (Analog, Digital, Pro Audio). `-m port` matches one card on one USB port (for identical DACs); `-m node` matches one exact output.
- `-q N` sets the resampler quality; it's remembered for later changes, and `-q default` removes it.
- Supported rates are read from the driver (`aplay --dump-hw-params`) for non-USB cards. `dac-rate rates` shows where the list came from.
- `dac-rate status` lists other configs that set rates for the same card, and whether they win, plus any runtime `clock.force-rate`.
- Auto mode merges your own `default.clock.allowed-rates` instead of replacing it.
- Errors from the launcher appear in a dialog. Desktop notifications are only sent from the picker window. `DAC_RATE_GUI` can pick `kdialog`, `zenity` or the terminal.
- Rules written by 1.0 are replaced automatically the next time you set a rate.
- CI: syntax check, ShellCheck and desktop-entry validation.

## 1.0.0

- First release: lock or Auto per device through a WirePlumber rule, picker window, installer.
