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

if [ "$fail" -eq 0 ]; then
  printf '\nall checks passed\n'
else
  printf '\nverify failed\n'
fi

exit "$fail"
