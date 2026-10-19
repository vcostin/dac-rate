#!/usr/bin/env bash
# Install dac-rate for the current user (no root needed).
#   ./install.sh              check dependencies, then install
#   ./install.sh --check      only check dependencies
#   ./install.sh --uninstall  remove the program (rules stay; run 'dac-rate reset' first to drop them)
set -euo pipefail
cd "$(dirname "$0")"

BIN="$HOME/.local/bin/dac-rate"
GUI="$HOME/.local/bin/dac-rate-gui"
APP="${XDG_DATA_HOME:-$HOME/.local/share}/applications/dac-rate.desktop"
LOGIN_ITEM="${XDG_CONFIG_HOME:-$HOME/.config}/autostart/dac-rate-gui.desktop"

has_pyside6() {
  command -v python3 >/dev/null && python3 -c 'import PySide6.QtWidgets, PySide6.QtNetwork' 2>/dev/null
}

refresh_menu() {
  if command -v update-desktop-database >/dev/null; then
    update-desktop-database -q "$(dirname "$APP")" || true
  fi
}

# Distro family from /etc/os-release: arch, debian, fedora, or empty.
distro() {
  local id="" like="" f=${OS_RELEASE:-/etc/os-release}
  if [[ -r $f ]]; then
    # shellcheck source=/dev/null
    id=$(. "$f" && echo "${ID:-}")
    # shellcheck source=/dev/null
    like=$(. "$f" && echo "${ID_LIKE:-}")
  fi
  case " $id $like " in
    *" arch "*) echo arch ;;
    *" debian "*|*" ubuntu "*) echo debian ;;
    *" fedora "*|*" rhel "*) echo fedora ;;
  esac
}

# Package that provides a command, per distro family.
pkg() {
  local cmd=$1 fam=$2
  case $cmd in
    pw-dump|pw-cat|pw-metadata)
      case $fam in debian) echo pipewire-bin ;; fedora) echo pipewire-utils ;; *) echo pipewire ;; esac ;;
    aplay) echo alsa-utils ;;
    notify-send) case $fam in debian) echo libnotify-bin ;; *) echo libnotify ;; esac ;;
    update-desktop-database) echo desktop-file-utils ;;
    pyside6)
      case $fam in
        arch) echo pyside6 ;;
        debian) echo "python3-pyside6.qtcore python3-pyside6.qtgui python3-pyside6.qtwidgets python3-pyside6.qtnetwork" ;;
        *) echo python3-pyside6 ;;
      esac ;;
    *) echo "$cmd" ;;
  esac
}

install_cmd() {
  case $1 in
    arch) echo "sudo pacman -S --needed" ;;
    debian) echo "sudo apt install" ;;
    fedora) echo "sudo dnf install" ;;
    *) echo "install with your package manager:" ;;
  esac
}

# Print what is missing; return 1 if something required is missing.
check_deps() {
  local fam c v missing=() pkgs=() optional=() ok=0
  fam=$(distro)

  for c in pw-dump pw-cat pw-metadata wireplumber jq; do
    command -v "$c" >/dev/null || missing+=("$c")
  done
  if (( BASH_VERSINFO[0] < 4 )); then
    echo "bash $BASH_VERSION is too old; dac-rate needs bash 4 or newer." >&2
    ok=1
  fi
  if command -v wireplumber >/dev/null; then
    v=$(wireplumber --version 2>/dev/null | awk '/libwireplumber/ && !done { print $NF; done = 1 }')
    case $v in
      0.[0-4].*)
        echo "WirePlumber $v is too old; dac-rate needs 0.5 or newer (see the README for which distros have it)." >&2
        ok=1 ;;
    esac
  fi
  if (( ${#missing[@]} )); then
    for c in "${missing[@]}"; do
      v=$(pkg "$c" "$fam")
      [[ " ${pkgs[*]} " == *" $v "* ]] || pkgs+=("$v")
    done
    echo "Missing required: ${missing[*]}" >&2
    echo "  $(install_cmd "$fam") ${pkgs[*]}" >&2
    ok=1
  fi
  if ! systemctl --user show-environment >/dev/null 2>&1; then
    echo "Note: no systemd user session; after changing a rate, log out and back in to apply it."
  fi

  has_pyside6 \
    || optional+=("$(pkg pyside6 "$fam") (the app window and tray icon; without it the launcher opens a simple picker)")
  command -v kdialog >/dev/null || command -v zenity >/dev/null \
    || optional+=("kdialog or zenity (simple picker without PySide6; otherwise the picker runs in the terminal)")
  command -v aplay >/dev/null \
    || optional+=("$(pkg aplay "$fam") (exact rates for non-USB cards)")
  command -v notify-send >/dev/null \
    || optional+=("$(pkg notify-send "$fam") (desktop notification after a change)")
  command -v update-desktop-database >/dev/null \
    || optional+=("$(pkg update-desktop-database "$fam") (refreshes the app menu)")
  if (( ${#optional[@]} )); then
    echo "Optional, not installed:"
    printf '  - %s\n' "${optional[@]}"
  fi
  (( ok == 0 )) && echo "Dependencies OK."
  return "$ok"
}

if [[ ${1:-} == --uninstall ]]; then
  pkill -f "$GUI" 2>/dev/null || true
  rm -f "$BIN" "$GUI" "$APP" "$LOGIN_ITEM"
  refresh_menu
  echo "Removed $BIN, $GUI, the menu launcher and the login item"
  echo "Rules left in ~/.config/wireplumber/wireplumber.conf.d/60-dac-rate-*.conf (delete them to undo the rates)."
  exit 0
fi

check_deps || exit 1
[[ ${1:-} == --check ]] && exit 0

install -Dm755 dac-rate "$BIN"
install -Dm755 dac-rate-gui "$GUI"
install -Dm644 dac-rate.desktop "$APP"
# The launcher opens the app when PySide6 is there, else the simple picker.
# Absolute paths, so it works even if ~/.local/bin is not on PATH.
if has_pyside6; then launcher=$GUI; else launcher=$BIN; fi
sed -i "s|^Exec=.*|Exec=\"$launcher\"|" "$APP"
refresh_menu

echo "Installed $BIN and $GUI"
if has_pyside6; then
  echo "Open 'DAC Sample Rate' from your app menu, or run: dac-rate-gui"
else
  echo "PySide6 is not installed, so the menu launcher opens the simple picker."
  echo "For the full app, install it and run ./install.sh again."
fi
echo "Command line: dac-rate devices; dac-rate use <device>; dac-rate set 96000 (or auto)"
case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) echo "Note: ~/.local/bin is not on your PATH." ;; esac
