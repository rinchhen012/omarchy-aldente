#!/bin/bash
# Charge to the displayed limit, then restore the normal hold settings.
set -uo pipefail

battery=/sys/class/power_supply/macsmc-battery
saved=/etc/udev/macsmc-battery.conf
src=/usr/local/src/smc-limit
mod=$src/smc_limit.ko

[[ -d $battery ]] || exit 0

exec 9>/run/smc-limit.lock
flock -w 60 9 || exit 0

changed=0
cleanup() {
  if (( changed == 1 )); then
    flock -u 9 2>/dev/null || true
    /usr/local/lib/smc-limit/apply.sh >/dev/null 2>&1 || true
    changed=0
  fi
}
trap cleanup EXIT INT TERM

read_limit() {
  local limit=100 line
  if [[ -r $saved ]]; then
    while IFS= read -r line || [[ -n $line ]]; do
      [[ $line == CHARGE_CONTROL_END_THRESHOLD=* ]] && limit=${line#*=}
    done <"$saved"
  fi
  [[ $limit =~ ^[0-9]+$ ]] || limit=100
  printf '%s' "$((10#$limit))"
}

read_ui() {
  awk '{printf "%.2f", ($1 / $2) * 100}' \
    < <(cat "$battery/energy_now" "$battery/energy_full" 2>/dev/null | tr '\n' ' ')
}

limit=$(read_limit)
(( limit < 100 )) || exit 0

ui=$(read_ui)
[[ -n $ui ]] || exit 0

# Only take over when the display is below the target.
awk -v u="$ui" -v l="$limit" 'BEGIN { exit !(u < l) }' || exit 0

/usr/bin/omarchy power present >/dev/null 2>&1 || exit 0

logger -t smc-limit "top-up start: displayed ${ui}% -> ${limit}%"

# From here on, any exit or signal must restore the normal limit.
changed=1

rmmod smc_limit 2>/dev/null || true
if ! insmod "$mod" upper=90 lower=85 2>/dev/null; then
  make -C "/lib/modules/$(uname -r)/build" M="$src" modules >/tmp/smc-limit-build.log 2>&1 || true
  insmod "$mod" upper=90 lower=85 2>/dev/null ||
    logger -t smc-limit "top-up: firmware module load failed"
fi

printf '90\n' >"$battery/charge_control_end_threshold" 2>/dev/null || true
printf 'auto\n' >"$battery/charge_behaviour" 2>/dev/null || true

reached=0
for _ in $(seq 1 3600); do
  if ! /usr/bin/omarchy power present >/dev/null 2>&1; then
    logger -t smc-limit "top-up aborted: AC disconnected"
    break
  fi

  now_limit=$(read_limit)
  if (( now_limit != limit )); then
    logger -t smc-limit "top-up aborted: limit changed to ${now_limit}%"
    break
  fi

  ui_now=$(read_ui)
  if [[ -n $ui_now ]] &&
     awk -v u="$ui_now" -v l="$limit" 'BEGIN { exit !(u >= l) }'; then
    reached=1
    logger -t smc-limit "top-up reached: displayed ${ui_now}%"
    break
  fi

  sleep 5
done

cleanup

if (( reached == 1 )); then
  logger -t smc-limit "top-up done"
else
  logger -t smc-limit "top-up stopped before reaching the limit"
fi

exit 0
