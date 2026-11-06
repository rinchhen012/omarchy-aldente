#!/bin/bash
# Hold the displayed charge at the saved limit, and top up when it falls below.
set -uo pipefail

battery=/sys/class/power_supply/macsmc-battery
saved=/etc/udev/macsmc-battery.conf

# Recover from an interrupted top-up and get CHLS/bf in sync.
/usr/local/lib/smc-limit/apply.sh >/dev/null 2>&1 || true

while true; do
  if [[ ! -r $battery/charge_behaviour ]]; then
    sleep 15
    continue
  fi

  limit=100
  if [[ -r $saved ]]; then
    while IFS= read -r line || [[ -n $line ]]; do
      [[ $line == CHARGE_CONTROL_END_THRESHOLD=* ]] && limit=${line#*=}
    done <"$saved"
  fi
  [[ $limit =~ ^[0-9]+$ ]] || limit=100
  limit=$((10#$limit))

  ac=0
  /usr/bin/omarchy power present >/dev/null 2>&1 && ac=1

  ui=""
  if [[ -r $battery/energy_now && -r $battery/energy_full ]]; then
    ui=$(awk '{printf "%.2f", ($1 / $2) * 100}' \
      < <(cat "$battery/energy_now" "$battery/energy_full" | tr '\n' ' '))
  fi

  # Top up whenever the displayed charge is below the limit.
  if (( ac == 1 && limit < 100 )) && [[ -n $ui ]] &&
     awk -v u="$ui" -v l="$limit" 'BEGIN { exit !(u < l) }'; then
    logger -t smc-limit "displayed ${ui}% is below ${limit}%; topping up"
    /usr/local/lib/smc-limit/topup.sh
    sleep 5
    continue
  fi

  desired=""
  if (( ac == 1 && limit < 100 )) && [[ -n $ui ]]; then
    if awk -v u="$ui" -v l="$limit" 'BEGIN { exit !(u > l + 0.5) }'; then
      desired=auto-discharge
    elif awk -v u="$ui" -v l="$limit" 'BEGIN { exit !(u <= l + 0.1) }'; then
      desired=auto
    fi
  else
    desired=auto
  fi

  if [[ -n $desired ]]; then
    current=$(cat "$battery/charge_behaviour" 2>/dev/null || true)
    if [[ $desired == auto-discharge && $current != *"[auto-discharge]"* ]]; then
      printf 'auto-discharge\n' >"$battery/charge_behaviour" 2>/dev/null || true
    elif [[ $desired == auto && $current != "[auto]"* ]]; then
      printf 'auto\n' >"$battery/charge_behaviour" 2>/dev/null || true
    fi
  fi

  sleep 15
done
