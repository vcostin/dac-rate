# Changelog

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
