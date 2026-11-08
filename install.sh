#!/bin/bash
set -euo pipefail

if (( EUID == 0 )); then
  echo "Run this as your normal user, not with sudo/root." >&2
  exit 1
fi

REPO_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
TARGET_USER=$USER
TARGET_HOME=$HOME
PLUGIN_ID="$TARGET_USER.power"
PLUGIN_DIR="$TARGET_HOME/.config/omarchy/plugins/$PLUGIN_ID"

command -v omarchy >/dev/null || { echo "omarchy not found" >&2; exit 1; }
omarchy-hw-apple-silicon || { echo "This is only for Apple Silicon Macs." >&2; exit 1; }

echo "==> Installing the firmware-limit module source"
sudo install -d -m 0755 /usr/local/src/smc-limit /usr/local/lib/smc-limit
sudo install -m 0644 "$REPO_DIR/src/smc_limit.c" "$REPO_DIR/src/Makefile" \
  /usr/local/src/smc-limit/
sudo make -C "/lib/modules/$(uname -r)/build" M=/usr/local/src/smc-limit modules

echo "==> Installing the controller scripts"
sudo install -m 0755 \
  "$REPO_DIR/scripts/apply.sh" \
  "$REPO_DIR/scripts/hold.sh" \
  "$REPO_DIR/scripts/topup.sh" \
  /usr/local/lib/smc-limit/

echo "==> Installing systemd units"
sudo install -m 0644 \
  "$REPO_DIR/systemd/smc-limit.service" \
  "$REPO_DIR/systemd/smc-limit.path" \
  "$REPO_DIR/systemd/smc-limit-hold.service" \
  /etc/systemd/system/

echo "==> Installing the sleep hook"
sudo install -d -m 0755 /etc/systemd/system-sleep
sudo install -m 0755 "$REPO_DIR/sleep-hook/smc-limit" /etc/systemd/system-sleep/smc-limit

echo "==> Masking the stock asahi save path"
sudo systemctl stop macsmc-battery-charge-control-end-threshold.path 2>/dev/null || true
sudo systemctl mask macsmc-battery-charge-control-end-threshold.path >/dev/null

echo "==> Removing the obsolete udev helper"
sudo rm -f /etc/udev/rules.d/95-omarchy-battery-auto-discharge.rules \
           /usr/local/lib/omarchy-battery-auto-discharge.sh
sudo udevadm control --reload

echo "==> Setting the saved limit to 80%"
sudo /usr/bin/omarchy-battery-charge-limit 80 || true

echo "==> Enabling services"
sudo systemctl daemon-reload
sudo systemctl enable smc-limit.service smc-limit.path smc-limit-hold.service
sudo systemctl restart smc-limit.path
sudo systemctl restart smc-limit-hold.service

echo "==> Installing the power panel clone"
if [[ ! -d $PLUGIN_DIR ]]; then
  omarchy plugin clone omarchy.power
fi
install -d -m 0755 "$PLUGIN_DIR"
for file in manifest.json Panel.qml Model.js; do
  sed "s/__USER__/$TARGET_USER/g" "$REPO_DIR/panel/$file" >"$PLUGIN_DIR/$file"
done
if ! grep -q "\"id\": \"$PLUGIN_ID\"" "$TARGET_HOME/.config/omarchy/shell.json"; then
  omarchy bar put "$PLUGIN_ID" || true
fi
omarchy bar set "$PLUGIN_ID" showPercentage true || true
omarchy-shell shell rescanPlugins >/dev/null 2>&1 || true

echo
echo "Done."
printf '  hold service: '; systemctl is-active smc-limit-hold.service || true
printf '  asahi save path: '; systemctl is-enabled macsmc-battery-charge-control-end-threshold.path || true
/usr/bin/omarchy-battery-charge-limit
