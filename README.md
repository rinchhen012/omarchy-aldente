# omarchy-aldente

AlDente-style battery charge limiting for Omarchy on Apple Silicon.

The target behavior:

- Charge to 80% and hold there on AC.
- If the displayed charge is above 80%, force-discharge down to 80% first.
- If it falls below 80%, top up to 80% automatically.
- While at 80% on AC, run from the charger and leave the battery idle.
- Show discharging while force-discharging, charging while topping up, and
  holding at the limit in the Omarchy power panel.

## Why it is not just a sysfs threshold

The Apple SMC's charge-limit gauge (`BUIC`) reads several points higher than
the percentage UPower displays. A raw `charge_control_end_threshold=80` stops
charging when the SMC gauge reaches 80, which is about 76% in the Omarchy bar.
The SMC also hardcodes a 5-point restart hysteresis and no longer exposes the
legacy `CH0B`/`CH0C` charging gates on current firmware.

This project therefore layers:

1. **Native firmware limit** — `bfF0`/`bfD0`/`bfE0`, applied by a tiny
   out-of-tree kernel module (`smc_limit`). This is the macOS 27-era firmware
   charge limit.
2. **Kernel CHLS limit** — the normal 80/75 sysfs threshold, retained as a
   fallback and for status reporting.
3. **Hold controller** (`smc-limit-hold.service`) — watches the *displayed*
   energy percentage and selects `auto-discharge` only above 80%, `auto` at
   or below 80%.
4. **Top-up controller** — when the display falls below 80%, temporarily
   raises the limit to 90/85, lets the SMC charge, stops at 80%, then restores
   80/75. It aborts if AC is removed or the saved limit changes.
5. **Panel clone** — `~/.config/omarchy/plugins/<user>.power`, fixing the
   panel's "AC connected means charging" logic so force-discharge is shown as
   discharging and the limit is shown as holding.

The stock asahi path unit
`macsmc-battery-charge-control-end-threshold.path` is masked. Without that, a
temporary top-up threshold would overwrite the saved 80% in
`/etc/udev/macsmc-battery.conf`. The Omarchy command still writes the saved
limit itself.

## Survives what?

| Event | Survives? | Notes |
|---|---|---|
| `omarchy update` / pacman upgrades | Yes | Files live in `/usr/local`, `/etc/systemd/system`, `/etc/udev`, and the home config. Package updates do not touch them. |
| Kernel update | Yes, mostly | The module rebuilds at boot if `linux-aurora-headers`, `make`, and `gcc` are installed. If the build breaks, the kernel 80/75 limit still holds; top-up may be degraded until the module builds. |
| Booting macOS and back | Yes | The saved 80% is on the Linux filesystem. Linux udev restores the CHLS limit, then systemd reapplies the firmware limit and behavior. macOS may change the SMC in the meantime; Linux reapplies on boot. |
| Full Omarchy reinstall | No, unless /home is kept | `/etc` and `/usr/local` are wiped. Re-run `./install.sh` from this repo. The panel clone lives in home and survives if `/home` is preserved. |
| Omarchy shell/plugin update | Mostly | The power panel is a clone. It will not receive upstream fixes automatically. If the plugin API changes, re-clone and re-apply the small diff. |

## Install

Run as your normal user (not root; the script uses `sudo`):

```bash
cd ~/Work/omarchy-aldente
./install.sh
```

Requirements:

- Omarchy on Apple Silicon (`omarchy-hw-apple-silicon`)
- `linux-aurora-headers`, `make`, `gcc`
- `flock` (util-linux)
- `omarchy` on PATH

The installer sets the saved limit to 80% and enables the services.

## Uninstall

```bash
cd ~/Work/omarchy-aldente
./uninstall.sh
```

This restores 100%, deactivates the firmware limit, removes the services and
module source, and unmasks the stock asahi save path. The power panel clone is
left in place; remove it with:

```bash
omarchy plugin remove "$USER.power" --yes
```

## Useful commands

```bash
# Show the saved limit (SMC units)
/usr/bin/omarchy-battery-charge-limit

# Change the saved limit
/usr/bin/omarchy battery charge limit 80
/usr/bin/omarchy battery charge limit 100

# Watch the controllers
journalctl -t smc-limit -f
systemctl status smc-limit-hold.service
systemctl is-enabled macsmc-battery-charge-control-end-threshold.path

# Show the displayed percentage and power flow
upower -i /org/freedesktop/UPower/devices/battery_macsmc_battery |
  grep -E 'state|percentage|energy-rate'
```

## Backing up / versioning

This directory is intended to be a git repository:

```bash
cd ~/Work/omarchy-aldente
git init
git add .
git commit -m "Apple Silicon AlDente-style charge limit for Omarchy"

# Optional: push to a private remote
git remote add origin git@github.com:<you>/omarchy-aldente.git
git branch -M main
git push -u origin main
```

On a reinstall, clone the repo and run `./install.sh` again.

## Caveats

- The `smc_limit` module is out-of-tree and taints the kernel. It is loaded
  only briefly to write the SMC keys, then unloaded.
- The firmware-limit module rebuild depends on kernel headers and compiler.
- The top-up temporarily uses a 90/85 limit. A crash during that window is
  recovered at next boot: the asahi udev rule restores the saved 80, then the
  apply service restores 80/75.
- The displayed percentage and the SMC gauge differ; the controllers use the
  displayed percentage so the bar holds at 80.
- Raw writes to `/sys/class/power_supply/macsmc-battery/charge_control_end_threshold`
  are not persisted while the stock save path is masked. Use the Omarchy
  command to change the saved limit.
