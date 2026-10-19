#!/usr/bin/env bash
# Install dac-rate for the current user (no root needed).
#   ./install.sh            install
#   ./install.sh --uninstall  remove the program (rules stay; run 'dac-rate reset' first to drop them)
set -euo pipefail
cd "$(dirname "$0")"

BIN="$HOME/.local/bin/dac-rate"
APP="${XDG_DATA_HOME:-$HOME/.local/share}/applications/dac-rate.desktop"

refresh_menu() {
  if command -v update-desktop-database >/dev/null; then
    update-desktop-database -q "$(dirname "$APP")" || true
  fi
}

if [[ ${1:-} == --uninstall ]]; then
  rm -f "$BIN" "$APP"
  refresh_menu
  echo "Removed $BIN and $APP"
  echo "Rules left in ~/.config/wireplumber/wireplumber.conf.d/60-dac-rate-*.conf (delete them to undo the rates)."
  exit 0
fi

for c in pw-dump pw-cat jq wireplumber; do
  command -v "$c" >/dev/null || { echo "Missing '$c'. Install PipeWire, WirePlumber and jq first." >&2; exit 1; }
done

install -Dm755 dac-rate "$BIN"
install -Dm644 dac-rate.desktop "$APP"
# Use the absolute path so the launcher works even if ~/.local/bin is not on PATH.
sed -i "s|^Exec=.*|Exec=$BIN|" "$APP"
refresh_menu

echo "Installed $BIN"
echo "Next: dac-rate devices; dac-rate use <device>; dac-rate set 96000 (or auto)"
case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) echo "Note: ~/.local/bin is not on your PATH." ;; esac
