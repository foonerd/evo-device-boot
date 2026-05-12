#!/usr/bin/env bash
# install.sh - install evo-device-boot artefacts on the target host.
#
# Self-contained: no evo runtime dependency. Any integrator (the
# evo-device-audio bootstrap, evo operational, a debos image recipe,
# or a human operator) can invoke this script and get the same result.
#
# Idempotent: every step checks state before writing. Re-runs are no-ops.
#
# Usage:
#   sudo scripts/install.sh
#   sudo EVO_BOOT_SKIP_CMDLINE=1 scripts/install.sh        # theme only
#   sudo EVO_BOOT_SKIP_INITRAMFS=1 scripts/install.sh      # no -R rebuild
#   sudo EVO_BOOT_RENDER_FRAMES=always scripts/install.sh  # re-render
#   sudo EVO_BOOT_AUTO_APT=1 scripts/install.sh            # apt-install deps
#   sudo EVO_BOOT_DSI_ROTATE=270 EVO_BOOT_DSI_PANEL=720x1280@60 \
#        scripts/install.sh                                # set DSI rotation
#
# Exit codes:
#   0 - install complete and verified
#   1 - operator error (not root, missing prerequisite, wrong invocation)
#   2 - install error (a step failed; previous steps left in place)
#
# Toggles:
#   EVO_BOOT_SKIP_CMDLINE=1      skip cmdline.txt / grub patching
#   EVO_BOOT_SKIP_CONFIG=1       skip config.txt patching (Pi only)
#   EVO_BOOT_SKIP_INITRAMFS=1    skip plymouth-set-default-theme -R
#   EVO_BOOT_RENDER_FRAMES=auto  auto|skip|always (default auto)
#                                  auto   = render only if assets missing
#                                  skip   = never render; fail if missing
#                                  always = re-render every install
#   EVO_BOOT_AUTO_APT=0          if 1, apt-install missing prerequisites
#                                  (plymouth, plymouth-themes, python3-pil).
#                                  Default 0: fail fast with the apt
#                                  command for the operator to run.
#   EVO_BOOT_DSI_ROTATE=         empty | 0 | 90 | 180 | 270. If set,
#                                  appends video=DSI-1:PANEL,rotate=N to
#                                  cmdline.txt unless a video=DSI-1
#                                  clause is already present. Use
#                                  EVO_BOOT_DSI_PANEL to set PANEL
#                                  (default 720x1280@60, the official
#                                  Pi Touch Display 2).
#   EVO_BOOT_DSI_PANEL=720x1280@60   resolution+refresh for the DSI rotate clause
#   EVO_BOOT_HDMI_ROTATE=        empty | 0 | 90 | 180 | 270. Same as
#                                  DSI but for video=HDMI-A-1. Set
#                                  EVO_BOOT_HDMI_PANEL to match your panel.
#   EVO_BOOT_HDMI_PANEL=1920x1080@60 resolution+refresh for the HDMI rotate clause
#   EVO_BOOT_VIDEO_OVERWRITE=0   if 1, replace an existing
#                                  video=DSI-1 / video=HDMI-A-1 clause
#                                  rather than leaving it alone.
#   EVO_BOOT_SPLASH_HOLD_SECONDS=3
#                                  Seconds to hold the Plymouth splash
#                                  before letting it quit, via a small
#                                  systemd oneshot ordered before
#                                  plymouth-quit.service. 0 disables
#                                  (removes the unit if present).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

THEME_NAME="evo"
THEME_SRC="$REPO_DIR/plymouth"
THEME_DST="/usr/share/plymouth/themes/$THEME_NAME"
ASSETS_SRC="$THEME_SRC/assets"

EVO_BOOT_SKIP_CMDLINE="${EVO_BOOT_SKIP_CMDLINE:-0}"
EVO_BOOT_SKIP_CONFIG="${EVO_BOOT_SKIP_CONFIG:-0}"
EVO_BOOT_SKIP_INITRAMFS="${EVO_BOOT_SKIP_INITRAMFS:-0}"
EVO_BOOT_RENDER_FRAMES="${EVO_BOOT_RENDER_FRAMES:-auto}"
EVO_BOOT_AUTO_APT="${EVO_BOOT_AUTO_APT:-0}"
EVO_BOOT_DSI_ROTATE="${EVO_BOOT_DSI_ROTATE:-}"
EVO_BOOT_DSI_PANEL="${EVO_BOOT_DSI_PANEL:-720x1280@60}"
EVO_BOOT_HDMI_ROTATE="${EVO_BOOT_HDMI_ROTATE:-}"
EVO_BOOT_HDMI_PANEL="${EVO_BOOT_HDMI_PANEL:-1920x1080@60}"
EVO_BOOT_VIDEO_OVERWRITE="${EVO_BOOT_VIDEO_OVERWRITE:-0}"
EVO_BOOT_SPLASH_HOLD_SECONDS="${EVO_BOOT_SPLASH_HOLD_SECONDS:-3}"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

log() { printf '[evo-boot] %s\n' "$*"; }
die() { printf '[evo-boot] ERROR: %s\n' "$*" >&2; exit "${2:-2}"; }

require_root() {
  if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    die "must be run as root (try: sudo $0)" 1
  fi
}

detect_arch() {
  case "$(uname -m)" in
    aarch64|armv7l|armv6l) echo "arm" ;;
    x86_64|amd64)          echo "amd64" ;;
    *) die "unsupported arch: $(uname -m)" 1 ;;
  esac
}

# ---------------------------------------------------------------------------
# Step 0 - ensure prerequisites (plymouth, Pillow)
# ---------------------------------------------------------------------------

apt_packages_missing() {
  local missing=""
  command -v plymouth-set-default-theme >/dev/null 2>&1 \
    || missing+=" plymouth"
  # plymouth-themes provides /usr/share/plymouth/themes/spinner et al.
  # used by uninstall fallback. Not strictly required for install but
  # recommended.
  [ -d /usr/share/plymouth/themes/spinner ] \
    || missing+=" plymouth-themes"
  python3 -c "from PIL import Image" 2>/dev/null \
    || missing+=" python3-pil"
  printf '%s' "$missing"
}

ensure_prereqs() {
  local missing
  missing=$(apt_packages_missing)
  if [ -z "$missing" ]; then
    log "prerequisites present"
    return 0
  fi
  if [ "$EVO_BOOT_AUTO_APT" = "1" ]; then
    log "installing missing packages:$missing"
    DEBIAN_FRONTEND=noninteractive apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y $missing
  else
    log "missing prerequisites:$missing"
    log "either run:"
    log "    sudo apt install$missing"
    log "or re-run this script with EVO_BOOT_AUTO_APT=1"
    die "prerequisites missing" 1
  fi
}

# ---------------------------------------------------------------------------
# Step 1 - ensure asset PNGs exist
# ---------------------------------------------------------------------------

ensure_assets() {
  local count
  count=$(find "$ASSETS_SRC" -maxdepth 1 -name 'glyph-*.png' 2>/dev/null | wc -l)

  case "$EVO_BOOT_RENDER_FRAMES" in
    skip)
      if [ "$count" -eq 0 ]; then
        die "assets missing and EVO_BOOT_RENDER_FRAMES=skip" 1
      fi
      log "assets present ($count glyph frames); render skipped"
      ;;
    always)
      log "re-rendering frames (EVO_BOOT_RENDER_FRAMES=always)"
      rm -f "$ASSETS_SRC"/*.png
      render_frames
      ;;
    auto)
      if [ "$count" -eq 0 ]; then
        log "no frames in $ASSETS_SRC; rendering"
        render_frames
      else
        log "assets present ($count glyph frames); render skipped"
      fi
      ;;
    *)
      die "EVO_BOOT_RENDER_FRAMES must be one of: auto, skip, always" 1
      ;;
  esac
}

render_frames() {
  python3 "$REPO_DIR/tools/render-frames.py"
}

# ---------------------------------------------------------------------------
# Step 2 - install theme into /usr/share/plymouth/themes/evo
# ---------------------------------------------------------------------------

install_theme() {
  log "installing theme to $THEME_DST"
  install -d -m 0755 "$THEME_DST"
  install -d -m 0755 "$THEME_DST/assets"
  install -m 0644 "$THEME_SRC/evo.plymouth" "$THEME_DST/evo.plymouth"
  install -m 0644 "$THEME_SRC/evo.script"   "$THEME_DST/evo.script"
  install -m 0644 "$ASSETS_SRC"/*.png       "$THEME_DST/assets/"
}

# ---------------------------------------------------------------------------
# Step 2b - splash warmup systemd unit (optional)
# ---------------------------------------------------------------------------

WARMUP_UNIT_NAME="evo-splash-warmup.service"
WARMUP_UNIT_DST="/etc/systemd/system/$WARMUP_UNIT_NAME"
WARMUP_UNIT_SRC="$REPO_DIR/systemd/$WARMUP_UNIT_NAME"

install_warmup_unit() {
  local hold="$EVO_BOOT_SPLASH_HOLD_SECONDS"
  case "$hold" in
    0)
      if [ -f "$WARMUP_UNIT_DST" ]; then
        log "splash warmup disabled (EVO_BOOT_SPLASH_HOLD_SECONDS=0); removing unit"
        systemctl disable "$WARMUP_UNIT_NAME" 2>/dev/null || true
        rm -f "$WARMUP_UNIT_DST"
        systemctl daemon-reload
      else
        log "splash warmup disabled (EVO_BOOT_SPLASH_HOLD_SECONDS=0)"
      fi
      return 0
      ;;
    ''|*[!0-9]*)
      die "EVO_BOOT_SPLASH_HOLD_SECONDS must be a non-negative integer (got '$hold')" 1
      ;;
  esac
  if [ ! -f "$WARMUP_UNIT_SRC" ]; then
    die "warmup unit template not found at $WARMUP_UNIT_SRC" 2
  fi
  log "installing splash warmup unit (hold ${hold}s)"
  sed "s|__HOLD_SECONDS__|$hold|" "$WARMUP_UNIT_SRC" > "$WARMUP_UNIT_DST"
  chmod 0644 "$WARMUP_UNIT_DST"
  systemctl daemon-reload
  if ! systemctl is-enabled "$WARMUP_UNIT_NAME" >/dev/null 2>&1; then
    systemctl enable "$WARMUP_UNIT_NAME" >/dev/null 2>&1 || \
      log "warning: could not enable $WARMUP_UNIT_NAME (may need a manual systemctl enable)"
  fi
}

# ---------------------------------------------------------------------------
# Step 3 - select theme + (optionally) rebuild initramfs
# ---------------------------------------------------------------------------

select_theme() {
  if [ "$EVO_BOOT_SKIP_INITRAMFS" = "1" ]; then
    log "setting default theme to $THEME_NAME (initramfs NOT rebuilt)"
    plymouth-set-default-theme "$THEME_NAME"
  else
    log "setting default theme to $THEME_NAME and rebuilding initramfs"
    plymouth-set-default-theme -R "$THEME_NAME"
  fi
}

# ---------------------------------------------------------------------------
# Step 4a - Pi cmdline.txt token append (idempotent)
# ---------------------------------------------------------------------------

patch_pi_cmdline_tokens() {
  local f="/boot/firmware/cmdline.txt"
  if [ ! -f "$f" ]; then
    log "no $f, skipping cmdline token patch"
    return 0
  fi
  local cur
  cur=" $(cat "$f") "
  local missing=""
  for tok in quiet splash plymouth.ignore-serial-consoles vt.global_cursor_default=0; do
    case "$cur" in
      *" $tok "*) ;;
      *) missing+=" $tok" ;;
    esac
  done
  if [ -n "$missing" ]; then
    log "appending to $f:$missing"
    cp "$f" "$f.evo-boot.bak.$(date +%s)"
    sed -i "1s|\$|$missing|" "$f"
  else
    log "$f already has all required tokens"
  fi
}

# ---------------------------------------------------------------------------
# Step 4b - Pi config.txt disable_splash
# ---------------------------------------------------------------------------

patch_pi_config() {
  local f="/boot/firmware/config.txt"
  if [ ! -f "$f" ]; then
    log "no $f, skipping config patch"
    return 0
  fi
  if grep -qE '^[[:space:]]*disable_splash[[:space:]]*=[[:space:]]*1' "$f"; then
    log "$f already has disable_splash=1"
  else
    log "appending disable_splash=1 to $f"
    {
      printf '\n# evo-device-boot: suppress firmware rainbow square\n'
      printf 'disable_splash=1\n'
    } >> "$f"
  fi
}

# ---------------------------------------------------------------------------
# Step 4c - KMS rotation, opt-in
# ---------------------------------------------------------------------------

# Append a video=<connector>:<panel>,rotate=<deg> clause to cmdline.txt
# if no clause for that connector is already present. The operator
# typically sets this once at provisioning time and never touches it
# again; we honour their existing choice unless EVO_BOOT_VIDEO_OVERWRITE=1.
apply_video_clause() {
  local connector="$1" panel="$2" rotate="$3"
  case "$rotate" in
    0|90|180|270) ;;
    "") return 0 ;;  # toggle empty, nothing to do
    *) die "rotate must be 0, 90, 180 or 270 (got '$rotate')" 1 ;;
  esac
  local f="/boot/firmware/cmdline.txt"
  if [ ! -f "$f" ]; then
    log "no $f, cannot apply $connector rotation"
    return 0
  fi
  local clause="video=${connector}:${panel},rotate=${rotate}"
  if grep -qE "(^| )video=${connector}:[^ ]*" "$f"; then
    if [ "$EVO_BOOT_VIDEO_OVERWRITE" = "1" ]; then
      log "replacing existing video=${connector} clause with $clause"
      cp "$f" "$f.evo-boot.bak.$(date +%s)"
      sed -i -E "s| video=${connector}:[^ ]*| ${clause}|g; s|^video=${connector}:[^ ]*|${clause}|g" "$f"
    else
      log "video=${connector} already in cmdline.txt; leaving operator's setting alone"
      log "  (set EVO_BOOT_VIDEO_OVERWRITE=1 to replace it with $clause)"
    fi
    return 0
  fi
  log "appending $clause to $f"
  cp "$f" "$f.evo-boot.bak.$(date +%s)"
  sed -i "1s|\$| ${clause}|" "$f"
}

apply_rotation() {
  apply_video_clause "DSI-1"     "$EVO_BOOT_DSI_PANEL"  "$EVO_BOOT_DSI_ROTATE"
  apply_video_clause "HDMI-A-1"  "$EVO_BOOT_HDMI_PANEL" "$EVO_BOOT_HDMI_ROTATE"
}

# ---------------------------------------------------------------------------
# Step 4d - amd64 GRUB
# ---------------------------------------------------------------------------

patch_grub() {
  local f="/etc/default/grub"
  if [ ! -f "$f" ]; then
    log "no $f, skipping grub patch"
    return 0
  fi
  local want='quiet splash vt.global_cursor_default=0'
  if grep -qE "^GRUB_CMDLINE_LINUX_DEFAULT=\".*${want}.*\"" "$f"; then
    log "$f already has the required cmdline tokens"
    return 0
  fi
  log "patching GRUB_CMDLINE_LINUX_DEFAULT in $f"
  cp "$f" "$f.evo-boot.bak.$(date +%s)"
  if grep -q '^GRUB_CMDLINE_LINUX_DEFAULT=' "$f"; then
    sed -i "s|^GRUB_CMDLINE_LINUX_DEFAULT=.*|GRUB_CMDLINE_LINUX_DEFAULT=\"$want\"|" "$f"
  else
    printf 'GRUB_CMDLINE_LINUX_DEFAULT="%s"\n' "$want" >> "$f"
  fi
  if command -v update-grub >/dev/null; then
    log "running update-grub"
    update-grub
  else
    log "update-grub not found; run grub-mkconfig -o /boot/grub/grub.cfg manually"
  fi
}

# ---------------------------------------------------------------------------
# Step 4 - apply cmdline / config patches per arch
# ---------------------------------------------------------------------------

apply_cmdline() {
  if [ "$EVO_BOOT_SKIP_CMDLINE" = "1" ]; then
    log "skipping cmdline patches (EVO_BOOT_SKIP_CMDLINE=1)"
    return 0
  fi
  local arch
  arch=$(detect_arch)
  case "$arch" in
    arm)
      patch_pi_cmdline_tokens
      apply_rotation
      if [ "$EVO_BOOT_SKIP_CONFIG" != "1" ]; then
        patch_pi_config
      fi
      ;;
    amd64)
      patch_grub
      ;;
  esac
}

# ---------------------------------------------------------------------------
# Step 5 - verify
# ---------------------------------------------------------------------------

verify() {
  log "verifying"
  [ -f "$THEME_DST/evo.plymouth" ] || die "theme manifest missing at $THEME_DST"
  [ -f "$THEME_DST/evo.script" ]   || die "theme script missing at $THEME_DST"
  local cur
  cur=$(plymouth-set-default-theme 2>/dev/null || echo unknown)
  if [ "$cur" != "$THEME_NAME" ]; then
    die "active plymouth theme is '$cur', expected '$THEME_NAME'"
  fi
  if [ "$EVO_BOOT_SPLASH_HOLD_SECONDS" != "0" ]; then
    [ -f "$WARMUP_UNIT_DST" ] \
      || die "splash warmup unit missing at $WARMUP_UNIT_DST"
    systemctl is-enabled "$WARMUP_UNIT_NAME" >/dev/null 2>&1 \
      || die "splash warmup unit is installed but not enabled"
  fi
  log "ok - active theme is $THEME_NAME on $(detect_arch)"
}

# ---------------------------------------------------------------------------
# Run
# ---------------------------------------------------------------------------

require_root
ensure_prereqs
ensure_assets
install_theme
install_warmup_unit
select_theme
apply_cmdline
verify
log "install complete"
