# evo-device-boot - design notes

## The motif

The evoframework.org hero uses a rounded square glyph in the framework
brand green (#00d4aa top to #00a080 bottom) that beats at 1.5 s per
cycle in a lub-dub rhythm, with two outward ripple rings on the brand
primary, the second phase-offset by ~0.21 s. See
evoframework.org/static/css/site.css, `.hero-mark-glyph` and
`@keyframes hero-heartbeat`.

This repo carries that same visual identity into the boot chain so the
device feels like evo from the first frame, before the UI shell mounts.

## Why a beating heart on boot

A boot splash communicates one thing: the device is alive and working.
A static logo does not. The double-beat plus ripple makes "alive"
visible at a glance, and ties cold-power-on directly to the brand mark
the user already sees in the web UI.

## No text

The theme is deliberately text-free. Three reasons:

1. The heart visual alone communicates "device is alive." We
   considered captions ("heart on, sound on", "resting heart",
   "one more beat") and prototyped them; the simpler statement is
   stronger.
2. Plymouth's `Image.Rotate()` does not produce a clean result when
   applied to the image returned by `Image.Text()` on every
   Plymouth/freetype combination we tested. Rotated text was the
   thing that broke first on Pi 5 + DSI. Removing the caption
   removes the runtime rotation requirement entirely.
3. A rounded-square heart is shape-invariant under rotation, so
   the theme renders correctly on any panel mounting without the
   script having to know which way the panel is oriented.

If text ever returns, the path forward is to pre-render caption PNGs
in `tools/render-frames.py` with a bundled TTF, rotated to match the
target panel mount, and blit them directly - never calling
`Image.Rotate` on a Plymouth-generated text image at runtime.

## Boot chain across targets

Both arches use Plymouth as the splash renderer. Trixie ships Plymouth
24.x with full DRM/KMS support, so we can assume a real graphics
framebuffer is up by the time plymouthd starts. No fbcon-fallback
handling.

### Raspberry Pi (arm)

    firmware (start.elf)
      -> reads /boot/firmware/config.txt
      -> applies dtoverlay=vc4-kms-v3d (Trixie default)
      -> disable_splash=1 suppresses the firmware rainbow square
    kernel + vc4-kms-v3d
      -> KMS framebuffer up
    initramfs
      -> plymouthd starts, loads /usr/share/plymouth/themes/evo
      -> theme renders heart at native panel resolution
    systemd
      -> user space comes up, plymouth keeps drawing
      -> evo UI shell mounts and takes over the framebuffer

Required /boot/firmware/cmdline.txt additions (one line, space-separated):

    quiet splash plymouth.ignore-serial-consoles vt.global_cursor_default=0

Required /boot/firmware/config.txt additions:

    disable_splash=1

### amd64

    firmware (UEFI or BIOS)
    bootloader (GRUB)
      -> GRUB_CMDLINE_LINUX_DEFAULT in /etc/default/grub
    kernel + i915 / amdgpu / nouveau
      -> KMS framebuffer up
    initramfs
      -> plymouthd starts as above

Required /etc/default/grub:

    GRUB_CMDLINE_LINUX_DEFAULT="quiet splash vt.global_cursor_default=0"

Followed by `update-grub`.

### Initramfs

Both arches on Trixie default to initramfs-tools. The Plymouth theme is
embedded in the initramfs so it appears before root mount. After
install we must rebuild it:

    plymouth-set-default-theme -R evo

The -R is the part operators forget. Without it the theme is on disk
but the initramfs still embeds the previous one and you see the wrong
splash for the first few seconds.

## Asset strategy

PNG frame sequence, pre-rendered, not runtime-scaled per frame.

- 45 frames per beat cycle = 1.5 s at 30 fps, looped.
- Three sprite layers: heart glyph, outer ripple ring, inner ripple
  ring.
- Two ring sequences are identical in shape; the second is phase-
  offset by ~6 frames (0.21 s) to match the CSS animation-delay.
- Rendered onto a 640x640 transparent canvas; the glyph occupies a
  240 px box at native scale. That gives the max-scale ripple ring
  (2.6 * 240 = 624 px) comfortable room without wasting transparent
  pixels.
- evo.script reads Window.GetWidth / Window.GetHeight at startup,
  computes a single asset_scale so the glyph occupies ~17 percent of
  the smaller screen dimension, and calls Image:Scale once per sprite
  to bake that scale in. From then on, the refresh callback only
  swaps Image references; it never scales.
- Source of truth is tools/render-frames.py. Parameters (brand
  colours, scale curve, ring opacity curve, canvas size) are constants
  at the top of that file, lifted verbatim from site.css.

Memory budget at runtime (135 sprites at 640x640 RGBA + the scaled
copies) is roughly 140 MB resident in plymouthd during early boot.
Comfortable on the Pi 4 / Pi 5 reference targets (2-8 GB RAM). If we
ever need to support Pi Zero 2 W (512 MB), reduce CANVAS_W/H and
FRAMES_PER_CYCLE proportionally in render-frames.py.

Trade-off considered: runtime CSS-like animation via per-frame
Image:Scale would let us ship one PNG per layer instead of 135.
Rejected because Image:Scale uses Cairo and is too slow to hit 30 fps
reliably on Pi 4 / Pi 5 during early boot while the CPU is also doing
initramfs work. The startup-only scale is essentially free.

## Orientation and rotation

The theme is rotation-agnostic by construction. The glyph and ring
sprites are rounded squares; they look identical under 90/180/270
degree rotation, except for the orientation of the vertical
gradient, which becomes horizontal on a landscape-mounted panel.
We accept that small asymmetry rather than trying to compensate for
it in the script.

For the rest of the boot chain (kernel console, plymouthd, UI shell)
to share one orientation, set it at the KMS layer in
/boot/firmware/cmdline.txt:

    ... video=DSI-1:720x1280@60,rotate=270 ...

This rotates the framebuffer at the DRM layer, so everything above
it sees one orientation. scripts/install.sh exposes opt-in
EVO_BOOT_DSI_ROTATE and EVO_BOOT_HDMI_ROTATE toggles that append
the appropriate video= clause. They are off by default. An existing
video=<connector>: clause is left alone unless
EVO_BOOT_VIDEO_OVERWRITE=1, on the principle that an explicit
operator choice outranks our default.

Caveat learned on Pi 5 + DSI Touch Display 2: the kernel does not
always honour the rotate= flag at the Plymouth framebuffer (the
flag is set, but fbset still reports the native portrait geometry).
The compositor in userspace honours it, so the desktop is landscape,
but plymouthd is not. This was the original motivation to keep the
theme text-free and shape-symmetric: it removes the entire problem.

## Splash duration

The Plymouth splash is dismissed by `plymouth-quit.service`, which
fires when a foreground service (typically a getty or display
manager) takes the framebuffer. On a Pi 5 with this image that
handoff takes about two seconds from `plymouth-start.service`, so
the heart only gets ~one full lub-dub before it disappears.

To give the brand moment more screen time, we install a small
systemd oneshot, `evo-splash-warmup.service`, ordered
`After=plymouth-start.service` and
`Before=plymouth-quit.service plymouth-quit-wait.service`. Its
ExecStart is `/bin/sleep N` where N is templated from
`EVO_BOOT_SPLASH_HOLD_SECONDS` (default 3) at install time. systemd
will not run `plymouth-quit.service` until the warmup unit has
finished, so the splash is guaranteed to be visible for at least
N seconds.

Three alternatives we considered and rejected:

1. Block in the initramfs. Cheap, but it delays root mount, which
   blocks every userland service - not just the splash. Wrong layer.
2. Loop inside `evo.script`'s refresh callback. Plymouth's refresh
   model is "ask for next frame"; there is no clean way to keep the
   loop running once systemd decides plymouthd should quit.
3. A user-space sleep wedged into a getty unit. Couples the hold to
   one specific foreground unit; on a headless or differently-
   configured target the wedge would be in the wrong place.

The dedicated oneshot is the cleanest and most decoupled answer.

### Why the default is 3 seconds

The default `EVO_BOOT_SPLASH_HOLD_SECONDS=3` is calibrated for the
worst case (best case?) the theme will encounter: a Pi 5 booting
from NVMe, where the natural plymouth-start to plymouth-quit window
is only about 2 seconds. Without the warmup the heart only gets
one full lub-dub before it disappears. 3 seconds guarantees two
clean beats, which is the minimum where the rhythm is recognisable.

The behaviour scales naturally to slower targets. The warmup is
"hold for AT LEAST N seconds"; if the natural boot ordering already
takes longer than N (microSD card, older Pi, encrypted root, larger
initramfs), `evo-splash-warmup.service` finishes well before
plymouth-quit would have fired anyway and the unit is a no-op. One
knob, one default, two correct behaviours.

## Future work

- fbcon-logo/ - the LOGO_LINUX_CLUT224 PPM the kernel draws during
  very early boot, before plymouthd. Worth doing on Pi where the gap
  between firmware handoff and plymouth start is visible.
- grub-theme/ - amd64-only menu theming: brand background and font.
  Only relevant on multi-boot or dev systems. Reference devices boot
  straight through.
- packaging/debian/ - a proper .deb so we can ship via an evo apt
  repo. Today's path is scripts/install.sh; the .deb is the same
  install logic wrapped in dpkg postinst / postrm.
- Pre-rendered caption PNGs - if we ever want text on the splash,
  render it in Python with a bundled TTF and blit the resulting PNG
  directly. Avoids Plymouth's Image.Rotate-on-text failure mode and
  gives us typographic control.
- Multi-resolution asset variants - if the single-scale approach
  shows aliasing on a particular panel, ship a small set of pre-
  rendered sizes and pick at startup.
