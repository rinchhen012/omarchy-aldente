#!/bin/bash
set -euo pipefail

if (( EUID == 0 )); then
  echo "Run this as your normal user, not with sudo/root." >&2
  exit 1
fi

PLUGIN_ID="$USER.power"

echo "==> Restoring full charging"
sudo /usr/bin/omarchy-battery-charge-limit 100 || true

echo "==> Deactivating the firmware limit"
if [[ -f /usr/local/src/smc-limit/smc_limit.ko ]]; then
  sudo insmod /usr/local/src/smc-limit/smc_limit.ko deactivate=1 2>/dev/null || true
  sudo rmmod smc_limit 2>/dev/null || true
fi

echo "==> Disabling and removing services"
sudo systemctl disable --now smc-limit-hold.service smc-limit.service smc-limit.path 2>/dev/null || true
sudo rm -f /etc/systemd/system/smc-limit.service \
           /etc/systemd/system/smc-limit.path \
           /etc/systemd/system/smc-limit-hold.service
sudo rm -rf /usr/local/src/smc-limit /usr/local/lib/smc-limit
sudo systemctl daemon-reload

echo "==> Unmasking the stock asahi save path"
sudo systemctl unmask macsmc-battery-charge-control-end-threshold.path 2>/dev/null || true
sudo systemctl start macsmc-battery-charge-control-end-threshold.path 2>/dev/null || true

echo "==> Removing obsolete udev helper"
sudo rm -f /etc/udev/rules.d/95-omarchy-battery-auto-discharge.rules \
           /usr/local/lib/omarchy-battery-auto-discharge.sh
sudo udevadm control --reload

echo
echo "System parts removed. The panel clone is still here:"
echo "  $HOME/.config/omarchy/plugins/$PLUGIN_ID"
echo "Remove it with: omarchy plugin remove $PLUGIN_ID --yes"
