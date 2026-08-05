#!/usr/bin/env bash
# LeechTunnel installer — downloads the obfuscated LEECH core (latest release) + the configurator
# into /root/leech and launches the interactive menu.
#
#   bash <(curl -fsSL https://raw.githubusercontent.com/ALIZA4004/LeechTunnel/main/install.sh)
#
set -e
if [[ $EUID -ne 0 ]]; then
  echo "Please run as root:  sudo -i   then re-run this command."
  exit 1
fi
REPO="https://raw.githubusercontent.com/ALIZA4004/LeechTunnel/main"
CORE_URL="https://github.com/ALIZA4004/LeechTunnel/releases/latest/download/leech"
DIR="/root/leech"
mkdir -p "$DIR"

echo "==> downloading LEECH core (obfuscated, latest release)..."
# download to a temp name and atomically move it into place — a plain `curl -o` over a
# core that is already running fails with "Text file busy" (ETXTBSY); rename never does.
curl -fL --progress-bar -o "$DIR/leech.new" "$CORE_URL"
chmod +x "$DIR/leech.new"
mv -f "$DIR/leech.new" "$DIR/leech"
echo "==> downloading configurator..."
curl -fsSL -o "$DIR/leech.sh.new" "$REPO/leech.sh"
mv -f "$DIR/leech.sh.new" "$DIR/leech.sh"
chmod +x "$DIR/leech"

# make a convenient 'leech' command
cp -f "$DIR/leech.sh" /usr/local/bin/leech 2>/dev/null && chmod +x /usr/local/bin/leech 2>/dev/null || true

echo "==> launching configurator (re-run any time with:  leech )"
cd "$DIR"
exec bash leech.sh
