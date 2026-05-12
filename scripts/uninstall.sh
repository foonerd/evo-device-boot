#!/usr/bin/env bash
# uninstall.sh - remove evo-device-boot artefacts from the host.
#
# Removes the installed theme and reverts the default to the distro
# Plymouth theme. Does NOT revert cmdline.txt or /etc/default/grub
# edits; those are kept (they are harmless and operators sometimes
# want them retained). Backups of the original files are left in
# place where they were created.
#
# Usage:
#   sudo scripts/uninstall.sh
#
# Exit codes:
#   0 - removal complete
#   1 - operator error (not root)
#   2 - removal error

set -euo pipefail

log() { printf '[evo-boot] %s\n' "$*"; }
die() { printf '[evo-boot] ERROR: %s\n' "$*" >&2; exit "${2:-2}"; }

if [ "${EUID:-$(id -u)}" -ne 0 ]; then
  die "must be run as root (try: sudo $0)" 1
fi

THEME_NAME="evo"
THEME_DST="/usr/share/plymouth/themes/$THEME_NAME"
WARMUP_UNIT_NAME="evo-splash-warmup.service"
WARMUP_UNIT_DST="/etc/systemd/system/$WARMUP_UNIT_NAME"

if [ -f "$WARMUP_UNIT_DST" ]; then
  log "removing splash warmup unit"
  systemctl disable "$WARMUP_UNIT_NAME" 2>/dev/null || true
  rm -f "$WARMUP_UNIT_DST"
  systemctl daemon-reload
fi

if [ -d "$THEME_DST" ]; then
  log "removing $THEME_DST"
  rm -rf "$THEME_DST"
else
  log "$THEME_DST not present; nothing to remove"
fi

if command -v plymouth-set-default-theme >/dev/null; then
  # Prefer the distro default if it exists; otherwise leave whatever
  # Plymouth picks on its own.
  for candidate in spinner bgrt text details; do
    if [ -d "/usr/share/plymouth/themes/$candidate" ]; then
      log "reverting default theme to $candidate (rebuilding initramfs)"
      plymouth-set-default-theme -R "$candidate" || true
      break
    fi
  done
fi

log "uninstall complete"
log "note: cmdline.txt and /etc/default/grub edits were NOT reverted"
log "      (.evo-boot.bak.* backups are alongside the originals if you want to)"
