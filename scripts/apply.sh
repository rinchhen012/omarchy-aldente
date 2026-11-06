#!/bin/bash
# Mirror the saved Omarchy charge limit into the Apple Silicon firmware limit.
set -uo pipefail

exec 8>/run/smc-limit.lock
flock -w 60 8 || exit 0

battery=/sys/class/power_supply/macsmc-battery
saved=/etc/udev/macsmc-battery.conf
src=/usr/local/src/smc-limit
mod=$src/smc_limit.ko

[[ -d $battery ]] || exit 0

limit=100
if [[ -r $saved ]]; then
  while IFS= read -r line || [[ -n $line ]]; do
    [[ $line == CHARGE_CONTROL_END_THRESHOLD=* ]] && limit=${line#*=}
  done <"$saved"
fi

[[ $limit =~ ^[0-9]+$ ]] || exit 0
limit=$((10#$limit))
(( limit > 100 )) && limit=100

# Keep the kernel threshold in sync, but do not rewrite an unchanged value.
current_end=$(cat "$battery/charge_control_end_threshold" 2>/dev/null || true)
if [[ $current_end != "$limit" ]]; then
  printf '%s\n' "$limit" >"$battery/charge_control_end_threshold" 2>/dev/null || true
fi

# Force-discharge only when AC is connected and the displayed (energy)
# percentage is actually above the limit. The SMC's own gauge reads higher.
ui_int=0
if [[ -r $battery/energy_now && -r $battery/energy_full ]]; then
  ui_int=$(awk '{printf "%d", ($1 / $2) * 100}' \
    < <(cat "$battery/energy_now" "$battery/energy_full" | tr '\n' ' '))
fi

current_behaviour=$(cat "$battery/charge_behaviour" 2>/dev/null || true)
if (( limit < 100 )) && /usr/bin/omarchy power present >/dev/null 2>&1 &&
   (( ui_int > limit )); then
  [[ $current_behaviour == *"[auto-discharge]"* ]] ||
    printf 'auto-discharge\n' >"$battery/charge_behaviour" 2>/dev/null || true
else
  [[ $current_behaviour == "[auto]"* ]] ||
    printf 'auto\n' >"$battery/charge_behaviour" 2>/dev/null || true
fi

if (( limit < 100 )); then
  lower=$((limit - 5))
  (( lower < 10 )) && lower=10
  args=(upper="$limit" lower="$lower")
else
  args=(deactivate=1)
fi

rmmod smc_limit 2>/dev/null || true

if ! insmod "$mod" "${args[@]}" 2>/dev/null; then
  make -C "/lib/modules/$(uname -r)/build" M="$src" modules >/tmp/smc-limit-build.log 2>&1 || {
    logger -t smc-limit "module build failed; kernel fallback stays active"
    exit 0
  }
  if ! insmod "$mod" "${args[@]}" 2>/dev/null; then
    logger -t smc-limit "module load failed; kernel fallback stays active"
    exit 0
  fi
fi

rmmod smc_limit 2>/dev/null || true

if (( limit < 100 )); then
  logger -t smc-limit "applied firmware limit ${limit}%/${lower}% (displayed ${ui_int}%)"
else
  logger -t smc-limit "firmware limit disabled (100%)"
fi

exit 0
