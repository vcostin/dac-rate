# dac-rate

Pick the sample rate of a USB DAC (or any ALSA output) on Linux with PipeWire, and keep it after reboots and replugs.

By default PipeWire runs most outputs at 48 kHz and resamples everything to that. `dac-rate` lets you either:

- **lock** a device to one rate (for example 192 kHz), so everything is resampled to that rate once, in PipeWire, or
- set it to **Auto**, so the device switches to each file's own rate (44.1 kHz music plays at 44.1 kHz, 96 kHz plays at 96 kHz).

It runs as your user, needs no root, and only touches the device you pick.

## Requirements

- PipeWire with **WirePlumber 0.5 or newer** (check with `wireplumber --version`)
- `jq`
- systemd user services, to restart the audio services when the rate changes. Without systemd, log out and back in to apply a change.
- Optional: `kdialog` (KDE) or `zenity` (GNOME and others) for the picker window. Without them it asks in the terminal.
- Optional: `aplay` (alsa-utils), to read the exact rates of non-USB cards.

Tested on Arch Linux, KDE Plasma 6 (Wayland), PipeWire 1.6, WirePlumber 0.5.18, with a Fosi Audio SK02 USB DAC. The lock holds after a reboot, after turning the DAC off and on, and after switching the card's profile.

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
dac-rate rates                # rates the device supports, and where that list came from
dac-rate set 192000           # lock to 192 kHz
dac-rate set auto             # follow the content
dac-rate reset                # remove the rule, back to PipeWire defaults
dac-rate status               # rule, hardware rate, and any other config that affects the device
```

Or open **DAC Sample Rate** from the app menu and pick from the list. Run `dac-rate` with no arguments in a terminal for the same picker there.

Changing the rate restarts WirePlumber, so sound pauses for about a second. Turning Auto on or off restarts PipeWire as well, and a few apps may need restarting to get sound back.

### Options

| Option | What it does |
|---|---|
| `-d DEVICE` | Act on another device without changing the remembered one. |
| `-m card` | *(default)* The rule covers every output of this card, in any profile (Analog, Digital, Pro Audio). |
| `-m port` | The rule covers this card only when plugged into **this USB port**. Use this for two identical DACs. |
| `-m node` | The rule covers this exact output only, for example one HDMI output of a graphics card. |
| `-q N` | Resampler quality 0–14 (PipeWire's default is 4; 10 is high quality and uses more CPU). `-q default` removes it. |
| `-n` | Write the rule without restarting anything; it prints the command to apply it. |

`-m` and `-q` are remembered in the rule, so a later `dac-rate set 96000` keeps them.

Each card has one rule. With `-m node`, the rule covers one output of that card; setting a second output of the same card is refused until you reset the first or switch to `-m card`.

To choose the picker yourself, set `DAC_RATE_GUI=kdialog`, `zenity` or `0` (terminal). If a change fails from the launcher, the error appears in a dialog.

## Check that it works

Play something, then:

```bash
grep -E '^rate|closed' /proc/asound/card*/pcm*p/sub0/hw_params
```

or run `pw-top` and look at your device's line. The FORMAT column shows the rate the device runs at, such as `S32LE 2 192000`.

When nothing is playing, the device shows `closed`. That's normal: PipeWire releases it after a few seconds of silence.

## Lock or Auto, and bit-perfect playback

**Lock** converts everything to one rate. 44.1 kHz music on a 192 kHz lock is resampled once, by PipeWire, with the quality set by `-q`. It's simple and predictable, and your DAC's display always shows the same rate. It is not bit-perfect.

**Auto** lets the device follow the content, but only while **one** source is playing. PipeWire runs one clock per device, so if a second sound at a different rate starts (a browser tab, a notification), it's converted to the rate of whatever started first.

For bit-perfect playback, all of these must hold:

- `dac-rate set auto` on the device
- only the music player is playing
- the player's volume and the system volume are at 100% (use the DAC's own volume knob instead)
- the player doesn't convert the audio itself (check its output or resampling settings)

Browsers and many games produce 48 kHz audio themselves, so Auto changes nothing for them.

## How it works

`dac-rate set` writes one WirePlumber rule per card:

```
~/.config/wireplumber/wireplumber.conf.d/60-dac-rate-<card>.conf
```

The rule sets `audio.allowed-rates` on the card's playback outputs: one rate for a lock, or every rate the card supports for Auto. WirePlumber applies it whenever the device appears (at login, after a replug, when you turn the DAC on, or after a profile change), so the rate survives reboots without a startup script.

Auto also needs the rates in PipeWire's global list, otherwise PipeWire never leaves 48 kHz. For that it writes:

```
~/.config/pipewire/pipewire.conf.d/60-dac-rate.conf   (default.clock.allowed-rates)
```

That file merges in any `default.clock.allowed-rates` you set yourself, always keeps 44.1 and 48 kHz, and is removed when no device is in Auto mode. While it exists, other outputs can switch rates too.

**Supported rates** come from, in order:

1. the USB descriptor (`/proc/asound/cardN/stream0`) on USB devices,
2. the driver itself via `aplay --dump-hw-params`, which only works while the device is idle,
3. a standard 44.1–192 kHz list, which `dac-rate rates` labels as a guess.

**Conflicts:** `dac-rate status` lists other WirePlumber files that set rates for the same card, and says whether they win or lose against dac-rate (files load in name order). It also warns about a runtime `clock.force-rate`, which some scripts set and which forces every device.

## Limitations

- **WirePlumber 0.4** (Lua config) is not supported.
- **ALSA outputs only.** Bluetooth headphones get their rate from the codec (SBC, AAC, LDAC), not from PipeWire, so this tool can't change it.
- **A rate change always interrupts sound.** The DAC has to be reopened to switch rates, so there's a short gap even without a restart.
- **No exclusive mode.** PipeWire has nothing like Windows' WASAPI exclusive mode. Players that need it must open the ALSA device directly (mpd and some others can), outside PipeWire.
- **No native DSD.** This tool handles PCM rates only.
- **Rate lists are only as good as the driver.** If a driver reports a rate it can't play, `dac-rate` will offer it.
- **Conflict detection is a best effort.** It finds files that mention the card's name; a rule with a broader pattern (for example `~alsa_output.usb-.*`) isn't detected.

## Troubleshooting

- **The rate doesn't change:** run `dac-rate status` while something plays and read any warnings it lists. If the rule is right but the rate isn't, restart the audio stack (`systemctl --user restart pipewire pipewire-pulse wireplumber`).
- **An app plays to the wrong output:** some players are set to a specific device in their own settings and ignore the system default. Check the player's audio-device option.
- **A rate isn't offered:** check where the list came from with `dac-rate rates`. If it says "standard list", stop playback and run it again so the driver can be asked.
- **Two identical DACs swap settings:** use `-m port` on each.

## Uninstall

```bash
dac-rate reset        # for each device you set up
./install.sh --uninstall
```

## License

MIT, see [LICENSE](LICENSE).
