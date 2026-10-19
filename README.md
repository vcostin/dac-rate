# dac-rate

Pick the sample rate of a USB DAC (or any ALSA output) on Linux with PipeWire, and keep it after reboots and replugs.

By default PipeWire runs most outputs at 48 kHz and resamples everything to that. `dac-rate` lets you either:

- **lock** a device to one rate (for example 192 kHz), so everything is resampled to that rate once, in PipeWire, or
- set it to **Auto**, so the device switches to each file's own rate (44.1 kHz music plays at 44.1 kHz, 96 kHz plays at 96 kHz).

It runs as your user, needs no root, and only touches the device you pick.

## Requirements

- PipeWire with **WirePlumber 0.5 or newer** (check with `wireplumber --version`)
- `jq`
- Optional: `kdialog` (KDE) or `zenity` (GNOME and others) for the picker window. Without them it asks in the terminal.

Tested on Arch Linux, KDE Plasma 6 (Wayland), PipeWire 1.6, WirePlumber 0.5.18, with a Fosi Audio SK02 USB DAC. The lock holds after a reboot and after turning the DAC off and on.

<p align="center">
  <img src="docs/fosi-sk02-192k.jpg" width="280" alt="Fosi Audio SK02 with its 192 kHz PCM light on">
  <br>
  <em>Fosi Audio SK02 after <code>dac-rate set 192000</code>: the DAC's own PCM light shows 192.</em>
</p>

## Install

```bash
git clone https://github.com/vcostin/dac-rate.git && cd dac-rate
./install.sh
```

This copies `dac-rate` to `~/.local/bin` and adds a **DAC Sample Rate** launcher to your app menu.

## Use

```bash
dac-rate devices              # list outputs; * marks the remembered one
dac-rate use "SK02"           # remember a device (node name or part of its name)
dac-rate rates                # rates the device supports
dac-rate set 192000           # lock to 192 kHz
dac-rate set auto             # follow the content
dac-rate reset                # remove the rule, back to PipeWire defaults
dac-rate status               # current rule and the rate the hardware runs at
```

Or open **DAC Sample Rate** from the app menu and pick from the list. Run `dac-rate` with no arguments in a terminal for the same picker there.

`-d DEVICE` acts on another device without changing the remembered one. Changing the rate restarts WirePlumber, so sound pauses for about a second; Auto mode restarts PipeWire as well.

## Check that it works

Play something, then:

```bash
grep -E '^rate|closed' /proc/asound/card*/pcm*p/sub0/hw_params
```

or run `pw-top` and look at your device's line. The FORMAT column shows the rate the device runs at, such as `S32LE 2 192000`.

When nothing is playing, the device shows `closed`. That's normal: PipeWire releases it after a few seconds of silence.

## How it works

`dac-rate set` writes a WirePlumber rule for that one device:

```
~/.config/wireplumber/wireplumber.conf.d/60-dac-rate-<device>.conf
```

The rule sets `audio.allowed-rates` on the device's node: one rate for a lock, or every rate the device supports for Auto. WirePlumber applies it whenever the device appears (at login, after a replug, or when you turn the DAC on). The rate therefore survives reboots without a startup script.

Auto also needs the rates in PipeWire's global list, otherwise PipeWire never leaves 48 kHz. For that it writes:

```
~/.config/pipewire/pipewire.conf.d/60-dac-rate.conf   (default.clock.allowed-rates)
```

That file always keeps 44.1 and 48 kHz, and it's removed when no device is in Auto mode. If you already set `default.clock.allowed-rates` yourself, this file overrides it while Auto is on.

On USB DACs the supported rates come from `/proc/asound/cardN/stream0`. For other cards it offers 44.1 to 192 kHz.

## Troubleshooting

- **The rate doesn't change:** run `dac-rate status` while something plays. If the rule is right but the rate isn't, restart the audio stack (`systemctl --user restart pipewire pipewire-pulse wireplumber`) and check that no other config forces a rate (`grep -r rate ~/.config/pipewire ~/.config/wireplumber`).
- **An app plays to the wrong output:** some players are set to a specific device in their own settings and ignore the system default. Check the player's audio-device option.
- **A rate isn't offered:** the device doesn't report it. See `cat /proc/asound/card*/stream0`.

## Uninstall

```bash
dac-rate reset        # for each device you set up
./install.sh --uninstall
```

## License

MIT, see [LICENSE](LICENSE).
