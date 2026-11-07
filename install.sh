#!/usr/bin/env bash
# Install dac-rate for the current user (no root needed).
#   ./install.sh              check dependencies, then install, upgrade or reinstall
#   ./install.sh --dry-run    show what an install would do, change nothing
#   ./install.sh --force      also allow a downgrade, or a checkout whose tag and VERSION disagree
#   ./install.sh --check      only check dependencies
#   ./install.sh --uninstall  remove the program (rules stay; run 'dac-rate reset' first to drop them)
set -euo pipefail
cd "$(dirname "$0")"

BIN="$HOME/.local/bin/dac-rate"
GUI="$HOME/.local/bin/dac-rate-gui"
APP="${XDG_DATA_HOME:-$HOME/.local/share}/applications/dac-rate.desktop"
LOGIN_ITEM="${XDG_CONFIG_HOME:-$HOME/.config}/autostart/dac-rate-gui.desktop"
# The unit systemd generates from the login item (systemd-xdg-autostart-generator).
UNIT='app-dac\x2drate\x2dgui@autostart.service'
STOP_WAIT=35  # seconds; the app lets a rate change finish before it quits (up to 30 s)

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

# --- versions and source -------------------------------------------------------

file_version() {  # VERSION=x.y.z (bash) or VERSION = "x.y.z" (python)
  sed -nE 's/^VERSION ?= ?"?([0-9][0-9A-Za-z.+-]*)"?.*/\1/p' "$1" | head -n1
}

# Version an installed program reports ("dac-rate 1.2.1 (build)" -> 1.2.1), or empty.
installed_version() {
  [[ -x $BIN ]] || return 0
  "$BIN" version 2>/dev/null | awk 'NR == 1 { print $2 }' || true
}

installed_build() {
  [[ -x $BIN ]] || return 0
  "$BIN" version 2>/dev/null | sed -nE '1s/^[^ ]+ [^ ]+ \((.*)\)$/\1/p' || true
}

# 0 if $1 sorts before $2 as a version.
version_lt() {
  [[ $1 != "$2" && $(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n1) == "$1" ]]
}

# Sets SOURCE (for people) and BUILD (baked into the installed files; empty for a clean release tag).
# Returns 1 when the checkout's tag and VERSION disagree.
describe_source() {
  local d base
  SOURCE="" BUILD=""
  if ! command -v git >/dev/null || ! git rev-parse --git-dir >/dev/null 2>&1; then
    SOURCE="not a git checkout, so the exact source is unknown"
    return 0
  fi
  if ! d=$(git describe --tags --dirty --match 'v[0-9]*' 2>/dev/null); then
    d=$(git describe --always --dirty 2>/dev/null || echo unknown)
    SOURCE="$d (no release tag)"
    BUILD="${NEW#v}-dev-$d"
    WARNINGS+=("this checkout has no vX.Y.Z tag; installing a development build")
    return 0
  fi
  SOURCE=$d
  [[ $d == "v$NEW" ]] && return 0  # clean release
  BUILD=${d#v}
  base=${d%-dirty}
  base=$(sed -E 's/-[0-9]+-g[0-9a-f]+$//' <<<"$base")
  [[ $d == *-dirty ]] && WARNINGS+=("the checkout has uncommitted changes")
  if [[ $base == "v$NEW" ]]; then
    [[ $d =~ -[0-9]+-g[0-9a-f]+(-dirty)?$ ]] && WARNINGS+=("this is not the $base release; there are commits after the tag")
  elif version_lt "${base#v}" "$NEW"; then
    WARNINGS+=("$NEW is not released yet (latest tag here is $base); installing a development build")
  else
    echo "The checkout is at $base but the files say VERSION $NEW." >&2
    return 1
  fi
  return 0
}

# --- the running app -------------------------------------------------------------

# PIDs of the installed app (python3 <path to dac-rate-gui> ...), this user only.
gui_pids() {
  local f pid argv
  for f in /proc/[0-9]*/cmdline; do
    pid=${f#/proc/}; pid=${pid%/cmdline}
    [[ -O $f ]] || continue
    mapfile -d '' -t argv 2>/dev/null <"$f" || continue
    (( ${#argv[@]} >= 2 )) || continue
    [[ ${argv[0]##*/} == python* && ${argv[1]} == "$GUI" ]] && echo "$pid"
  done
  return 0
}

pid_has_tray_arg() {
  tr '\0' '\n' <"/proc/$1/cmdline" 2>/dev/null | grep -qx -- --tray
}

unit_active() {
  command -v systemctl >/dev/null && systemctl --user is-active --quiet "$UNIT" 2>/dev/null
}

# Running and not a zombie (an exited process its parent has not collected yet).
alive() {
  local stat
  stat=$(cat "/proc/$1/stat" 2>/dev/null) || return 1
  stat=${stat##*) }
  [[ ${stat%% *} != Z ]]
}

# Send SIGTERM (the app quits cleanly, letting a change finish) and wait.
stop_pids() {
  local pid i
  (( $# )) || return 0
  kill -TERM "$@" 2>/dev/null || true
  for ((i = 0; i < STOP_WAIT * 10; i++)); do
    for pid in "$@"; do
      alive "$pid" && { sleep 0.1; continue 2; }
    done
    return 0
  done
  echo "The app did not quit within $STOP_WAIT s; stopping it." >&2
  kill -KILL "$@" 2>/dev/null || true
}

has_display() {
  [[ -n ${WAYLAND_DISPLAY:-}${DISPLAY:-}${QT_QPA_PLATFORM:-} ]]
}

# --- files -------------------------------------------------------------------------

# Copy to a temp file next to the target, run an optional edit command on it
# (the temp file is its last argument), then rename it over the target.
# A running program never sees a half-written file.
atomic_install() {
  local mode=$1 src=$2 dst=$3 tmp
  shift 3
  mkdir -p "$(dirname "$dst")"
  tmp=$(mktemp "$dst.XXXXXX")
  if ! { cp "$src" "$tmp" && { (( $# == 0 )) || "$@" "$tmp"; } && chmod "$mode" "$tmp" && mv -f "$tmp" "$dst"; }; then
    rm -f "$tmp"
    return 1
  fi
}

# Edits for atomic_install. Values go through the environment, so no character in a path needs escaping.
set_exec() {  # set_exec 'Exec=...' FILE: replace the Exec= line
  local out
  out=$(LINE=$1 awk '/^Exec=/ { print ENVIRON["LINE"]; next } { print }' "$2") && printf '%s\n' "$out" >"$2"
}
set_build() {  # set_build BUILD FILE: fill in BUILD="" / BUILD = ""
  local out
  out=$(B=$1 awk '!done && /^BUILD ?= ?""/ { sub(/""/, "\"" ENVIRON["B"] "\""); done = 1 } { print }' "$2") \
    && printf '%s\n' "$out" >"$2"
}

# An Exec path, quoted per the desktop entry spec when needed (as the app writes it).
desktop_quote() {
  local p=$1
  case $p in
    *[[:space:]\"\'\\\$\`]*)
      p=${p//\\/\\\\}; p=${p//\"/\\\"}; p=${p//\`/\\\`}; p=${p//\$/\\\$}
      printf '"%s"' "$p" ;;
    *) printf '%s' "$p" ;;
  esac
}

# --- commands ----------------------------------------------------------------------

if [[ ${1:-} == --uninstall ]]; then
  if unit_active; then
    systemctl --user stop "$UNIT" || true
  fi
  mapfile -t pids < <(gui_pids)
  stop_pids "${pids[@]+"${pids[@]}"}"
  rm -f "$BIN" "$GUI" "$APP" "$LOGIN_ITEM"
  refresh_menu
  echo "Removed $BIN, $GUI, the menu launcher and the login item"
  echo "Rules left in ~/.config/wireplumber/wireplumber.conf.d/60-dac-rate-*.conf (delete them to undo the rates)."
  exit 0
fi

FORCE=0 DRY_RUN=0 CHECK=0
for arg in "$@"; do
  case $arg in
    --force) FORCE=1 ;;
    --dry-run|-n) DRY_RUN=1 ;;
    --check) CHECK=1 ;;
    *) echo "Unknown option: $arg (see the top of install.sh)" >&2; exit 2 ;;
  esac
done

check_deps || exit 1
(( CHECK )) && exit 0

NEW=$(file_version dac-rate)
if [[ -z $NEW || $NEW != "$(file_version dac-rate-gui)" ]]; then
  echo "VERSION differs between dac-rate (${NEW:-none}) and dac-rate-gui ($(file_version dac-rate-gui)); not installing." >&2
  exit 1
fi
OLD=$(installed_version)
OLD_BUILD=$(installed_build)
WARNINGS=()
SOURCE_OK=1
describe_source || SOURCE_OK=0

if [[ -z $OLD ]]; then
  action="Installing $NEW"
elif [[ $OLD == "$NEW" ]]; then
  action="Reinstalling $NEW"
  [[ -n $OLD_BUILD ]] && action+=" (the installed one was $OLD_BUILD)"
elif version_lt "$OLD" "$NEW"; then
  action="Upgrading $OLD → $NEW"
else
  action="Downgrading $OLD → $NEW"
fi
(( DRY_RUN )) && echo "Dry run, nothing is changed."
echo "$action"
echo "Source: $SOURCE"
for w in "${WARNINGS[@]+"${WARNINGS[@]}"}"; do echo "Warning: $w" >&2; done

if (( ! SOURCE_OK && ! FORCE )); then
  echo "Check out a release tag, fix VERSION, or run ./install.sh --force." >&2
  exit 1
fi
if [[ $action == Downgrading* ]] && (( ! FORCE && ! DRY_RUN )); then
  if [[ -t 0 ]]; then
    read -r -p "Install the older version? [y/N] " answer
    [[ $answer == [yY]* ]] || { echo "Nothing changed."; exit 1; }
  else
    echo "Not downgrading without --force." >&2
    exit 1
  fi
fi

# What to restart afterwards: the login item's systemd unit, or a copy started some other way.
restart=""
mapfile -t pids < <(gui_pids)
if unit_active; then
  restart=unit
elif (( ${#pids[@]} )); then
  restart=tray
  pid_has_tray_arg "${pids[0]}" || restart=window
fi

# The launcher opens the app when PySide6 is there, else the simple picker.
# Absolute paths, so it works even if ~/.local/bin is not on PATH.
if has_pyside6; then launcher=$GUI; else launcher=$BIN; fi
want_login_exec="Exec=$(desktop_quote "$GUI") --tray"
fix_login_item=0
if [[ -f $LOGIN_ITEM ]] && ! grep -qxF -- "$want_login_exec" "$LOGIN_ITEM"; then
  fix_login_item=1
fi

if (( DRY_RUN )); then
  echo "Would install $BIN, $GUI and the menu launcher${BUILD:+, marked as build $BUILD}"
  case $restart in
    unit) echo "Would restart the running app (systemd unit $UNIT)" ;;
    tray|window) echo "Would restart the running app (PID ${pids[*]}, $restart mode)" ;;
  esac
  (( fix_login_item )) && echo "Would point the login item at $GUI"
  exit 0
fi

build_edit=()
[[ -n $BUILD ]] && build_edit=(set_build "$BUILD")
atomic_install 755 dac-rate "$BIN" "${build_edit[@]+"${build_edit[@]}"}"
atomic_install 755 dac-rate-gui "$GUI" "${build_edit[@]+"${build_edit[@]}"}"
atomic_install 644 dac-rate.desktop "$APP" set_exec "Exec=$(desktop_quote "$launcher")"
refresh_menu
if (( fix_login_item )); then
  atomic_install 644 "$LOGIN_ITEM" "$LOGIN_ITEM" set_exec "$want_login_exec"
  echo "Pointed the login item at $GUI"
fi

# Check that what is installed now is what we meant to install.
got=$("$BIN" version 2>/dev/null || true)
want="dac-rate $NEW${BUILD:+ ($BUILD)}"
if [[ $got != "$want" ]]; then
  echo "Installed $BIN reports '$got', expected '$want'." >&2
  exit 1
fi
if has_pyside6; then
  got=$("$GUI" --version 2>/dev/null || true)
  if [[ $got != "dac-rate-gui $NEW${BUILD:+ ($BUILD)}" ]]; then
    echo "Installed $GUI reports '$got', expected 'dac-rate-gui $NEW${BUILD:+ ($BUILD)}'." >&2
    exit 1
  fi
fi
echo "Installed $BIN and $GUI ($NEW${BUILD:+, build $BUILD})"

was=$NEW
[[ -n $OLD && $OLD != "$NEW" ]] && was="$OLD → $NEW"
case $restart in
  unit)
    if systemctl --user restart "$UNIT"; then
      echo "Restarted the running app ($was)"
    else
      echo "Could not restart $UNIT; log out and back in to run the new version." >&2
    fi ;;
  tray|window)
    stop_pids "${pids[@]}"
    if has_display; then
      args=(); [[ $restart == tray ]] && args=(--tray)
      setsid -f "$GUI" "${args[@]+"${args[@]}"}" </dev/null >/dev/null 2>&1
      echo "Restarted the running app ($was)"
    else
      echo "Stopped the running app ($was); no desktop session here, so start it again yourself."
    fi ;;
esac
if has_pyside6; then
  echo "Open 'DAC Sample Rate' from your app menu, or run: dac-rate-gui"
else
  echo "PySide6 is not installed, so the menu launcher opens the simple picker."
  echo "For the full app, install it and run ./install.sh again."
fi
echo "Command line: dac-rate devices; dac-rate use <device>; dac-rate set 96000 (or auto)"
case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) echo "Note: ~/.local/bin is not on your PATH." ;; esac
