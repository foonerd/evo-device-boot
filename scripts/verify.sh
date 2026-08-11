#!/usr/bin/env bash
# verify.sh - check that evo-device-boot is installed and active.
#
# Read-only. Safe to run as non-root (will skip checks it cannot read).
# Exits non-zero if any required check fails.
#
# Usage:
#   scripts/verify.sh

set -uo pipefail

THEME_NAME="evo"
THEME_DST="/usr/share/plymouth/themes/$THEME_NAME"
fail=0

check() {
  local label="$1" cond="$2"
  if eval "$cond" >/dev/null 2>&1; then
    printf '  ok    %s\n' "$label"
  else
    printf '  FAIL  %s\n' "$label"
    fail=1
  fi
}

printf '%s\n' 'evo-device-boot verify'
printf '%s\n' '----------------------'

check "theme dir present"      "[ -d '$THEME_DST' ]"
check "theme manifest present" "[ -f '$THEME_DST/evo.plymouth' ]"
check "theme script present"   "[ -f '$THEME_DST/evo.script' ]"
check "background present"     "[ -f '$THEME_DST/assets/bg.png' ]"
check "glyph frames present"   "[ \"\$(find '$THEME_DST/assets' -maxdepth 1 -name 'glyph-*.png' 2>/dev/null | wc -l)\" -gt 0 ]"

WARMUP_UNIT_DST="/etc/systemd/system/evo-splash-warmup.service"
if [ -f "$WARMUP_UNIT_DST" ]; then
  check "warmup unit enabled"  "systemctl is-enabled evo-splash-warmup.service >/dev/null 2>&1"
  check "warmup unit sleep value present" "grep -q 'ExecStart=/bin/sleep' '$WARMUP_UNIT_DST'"
fi

RETAIN_DROPIN_DST="/etc/systemd/system/plymouth-quit.service.d/10-evo-retain-splash.conf"
check "retain-splash drop-in present" "[ -f '$RETAIN_DROPIN_DST' ]"
check "retain-splash drop-in active in effective unit" \
  "systemctl show -p ExecStart --value plymouth-quit.service 2>/dev/null | grep -q -- '--retain-splash'"

if command -v plymouth-set-default-theme >/dev/null 2>&1; then
  cur=$(plymouth-set-default-theme 2>/dev/null || echo "")
  check "default theme is $THEME_NAME" "[ '$cur' = '$THEME_NAME' ]"
else
  printf '  skip  plymouth-set-default-theme not on PATH\n'
fi

if [ -f /boot/firmware/cmdline.txt ]; then
  check "cmdline.txt has splash"           "grep -q ' splash' /boot/firmware/cmdline.txt"
  check "cmdline.txt has plymouth.ignore"  "grep -q 'plymouth.ignore-serial-consoles' /boot/firmware/cmdline.txt"
  check "cmdline.txt has cursor=0"         "grep -q 'vt.global_cursor_default=0' /boot/firmware/cmdline.txt"
fi

if [ -f /boot/firmware/config.txt ]; then
  check "config.txt has disable_splash=1"  "grep -qE '^[[:space:]]*disable_splash[[:space:]]*=[[:space:]]*1' /boot/firmware/config.txt"
fi

if [ -f /etc/default/grub ]; then
  check "grub cmdline has splash"          "grep -q 'GRUB_CMDLINE_LINUX_DEFAULT=.*splash' /etc/default/grub"
  check "grub cmdline has cursor=0"        "grep -q 'GRUB_CMDLINE_LINUX_DEFAULT=.*vt.global_cursor_default=0' /etc/default/grub"
fi

# ---------------------------------------------------------------------------
# Kiosk-side handoff invariants (checked only when evo-kiosk.service is
# installed — headless targets legitimately have no kiosk unit and are
# skipped without failing the run).
#
# The seamless Plymouth -> kiosk handoff requires either:
#   (a) Framework retain-splash drop-in (already checked above) — the
#       transitional shape where evo-device-boot free-runs the quit and
#       the compositor covers the retained frame before the FB is
#       reclaimed.
#   (b) Kiosk-owned Plymouth quit — the DM shape (GDM/SDDM pattern) in
#       which evo-kiosk.service `Conflicts=plymouth-quit.service` +
#       `OnFailure=plymouth-quit.service`, and evo-kiosk-launch calls
#       `plymouth deactivate` before exec labwc and `plymouth quit
#       --retain-splash` after first frame.
# One of these MUST hold. Both are safe to coexist during rollout.
#
# Regardless of which shape is in effect, the kiosk unit's TTY handling
# MUST NOT wipe the retained framebuffer, and the unit's ordering MUST
# NOT gate compositor start on network-online (which would reintroduce
# the ~8-9 s dark hold that seamless handoff exists to eliminate).
# ---------------------------------------------------------------------------

if systemctl cat evo-kiosk.service >/dev/null 2>&1; then
  # Deploy shape: either retain-splash drop-in OR kiosk owns quit
  # (or both, during rollout). Fail only if neither is present.
  KIOSK_CONFLICTS_QUIT=false
  if systemctl show -p Conflicts --value evo-kiosk.service 2>/dev/null \
        | tr ' ' '\n' | grep -qx 'plymouth-quit.service'; then
    KIOSK_CONFLICTS_QUIT=true
  fi
  RETAIN_DROPIN_ACTIVE=false
  if systemctl show -p ExecStart --value plymouth-quit.service 2>/dev/null \
        | grep -q -- '--retain-splash'; then
    RETAIN_DROPIN_ACTIVE=true
  fi
  check "handoff owner present (retain-splash drop-in OR kiosk Conflicts plymouth-quit)" \
    "[ \"$KIOSK_CONFLICTS_QUIT\" = 'true' ] || [ \"$RETAIN_DROPIN_ACTIVE\" = 'true' ]"

  # VT-wipe flags: TTYReset and TTYVTDisallocate MUST both be `no` on
  # the same VT as the splash (tty1). Either at yes clears the
  # framebuffer during kiosk startup and destroys the retained splash
  # regardless of the drop-in.
  check "evo-kiosk TTYReset=no"          \
    "[ \"\$(systemctl show -p TTYReset --value evo-kiosk.service 2>/dev/null)\" = 'no' ]"
  check "evo-kiosk TTYVTDisallocate=no"  \
    "[ \"\$(systemctl show -p TTYVTDisallocate --value evo-kiosk.service 2>/dev/null)\" = 'no' ]"
  check "evo-kiosk TTYPath=/dev/tty1"    \
    "[ \"\$(systemctl show -p TTYPath --value evo-kiosk.service 2>/dev/null)\" = '/dev/tty1' ]"

  # Ordering: kiosk MUST NOT gate on network-online. evo-ui.service
  # ordering is the same rule (kiosk usually After=evo-ui too).
  check "evo-kiosk After= does not include network-online.target" \
    "! systemctl show -p After --value evo-kiosk.service 2>/dev/null | tr ' ' '\n' | grep -qx 'network-online.target'"
  if systemctl cat evo-ui.service >/dev/null 2>&1; then
    check "evo-ui After= does not include network-online.target" \
      "! systemctl show -p After --value evo-ui.service 2>/dev/null | tr ' ' '\n' | grep -qx 'network-online.target'"
  fi
else
  printf '  skip  evo-kiosk.service not installed (headless target)\n'
fi

if [ "$fail" -eq 0 ]; then
  printf '\nall checks passed\n'
else
  printf '\nverify failed\n'
fi

exit "$fail"
