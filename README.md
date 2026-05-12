# evo-device-boot

A beating-heart Plymouth boot theme for evo reference devices on
Debian Trixie. Self-contained installer for Raspberry Pi (arm) and
generic x86_64 (amd64). The brand mark from the evoframework.org
landing page rendered for the boot chain, plus the supporting
artefacts (systemd warmup, KMS rotation toggles, cmdline patching)
that make the splash feel right on hardware as fast as a Pi 5 with
NVMe.

## What it ships

- plymouth/   - Plymouth script theme. Animated heart (rounded
                square in the framework brand green) with twin
                outward ripple rings, beating lub-dub at 1.5 s per
                cycle. Centred on a dark base. No text, no mode-
                specific behaviour - just the heart, on every boot,
                shutdown, and reboot.

- fbcon-logo/ - kernel framebuffer logo (LOGO_LINUX_CLUT224), shown
                during the kernel handoff before plymouthd starts.
                Placeholder for now.

- grub-theme/ - amd64-only GRUB menu theme. Placeholder for now.

- tools/      - parameterised PNG frame generator. The PNGs under
                plymouth/assets/ are produced by tools/render-frames.py
                from a single source of truth (heart parameters lifted
                from evoframework.org/static/css/site.css).

- scripts/    - install.sh, uninstall.sh, verify.sh. Self-contained,
                no evo runtime dependency. Detect Pi vs amd64 and
                handle the cmdline.txt-vs-grub split idempotently.

## Targets

Trixie (Debian 13) on:

- arm   - Raspberry Pi 4 and 5 with vc4-kms-v3d
- amd64 - generic x86_64 with i915 / amdgpu / nouveau KMS

## Orientation

The heart is a rounded square, so it is shape-invariant under
rotation. Mount your panel however you mount it; the heart beats.
The only thing that "rotates" with the panel is the gradient
direction (vertical on the framebuffer becomes horizontal on a
landscape-mounted panel), which is a quiet aesthetic, not a
problem.

If you do want the rest of the boot chain (kernel console, plymouth,
UI shell) to share one orientation, set it once at the KMS layer in
/boot/firmware/cmdline.txt. Common case for the Pi Touch Display 2
(720x1280 portrait native, used in landscape):

        video=DSI-1:720x1280@60,rotate=270

scripts/install.sh can do this with the EVO_BOOT_DSI_ROTATE and
EVO_BOOT_HDMI_ROTATE toggles. They honour an existing
`video=<connector>:` clause; pass `EVO_BOOT_VIDEO_OVERWRITE=1` to
replace one. Note: on Pi 5 + DSI, the rotate= flag is not always
honoured by the Plymouth-side framebuffer; this is one reason the
theme is deliberately text-free and shape-symmetric.

Across panel sizes (from 480p touchscreens up to 1080p monitors)
the theme scales the heart at startup to occupy a consistent ~17
percent of the smaller screen dimension.

## Install

On a target host with the repo cloned locally:

    sudo scripts/install.sh

That will (idempotently):

1. Check prerequisites (plymouth, plymouth-themes, python3-pil) and
   either fail with the apt command for you to run, or apt-install
   them if you pass `EVO_BOOT_AUTO_APT=1`.
2. Render the PNG frame sequence into plymouth/assets/ if missing.
3. Copy the theme to /usr/share/plymouth/themes/evo/.
4. Run `plymouth-set-default-theme -R evo` (rebuilds the initramfs).
5. Patch the boot cmdline:
     Pi    - /boot/firmware/cmdline.txt (Plymouth-friendly tokens)
             and /boot/firmware/config.txt (disable_splash=1).
             Honours an existing video=<connector>: clause.
     amd64 - /etc/default/grub and run update-grub.
6. Verify and exit non-zero on any failure.

To install only the theme (no boot config changes):

    sudo EVO_BOOT_SKIP_CMDLINE=1 scripts/install.sh

To remove:

    sudo scripts/uninstall.sh

To check an existing install:

    scripts/verify.sh

## Integration

This repo has no runtime dependency on the evo steward or any device
crate. It exposes one self-contained installer; any integrator can
call it:

1. evo-device-audio bootstrap.sh can call scripts/install.sh under
   an EVO_INSTALL_BOOT_THEME toggle.
2. evo operational can satisfy a "boot identity" CapabilityIntent by
   running scripts/install.sh on the host.
3. Image build (debos / genimage) can bake the artefacts at build
   time by invoking the same script in a chroot.

## Splash duration

On a fast board (Pi 5) the kernel + initramfs come up in a couple of
seconds, so without help the heart only gets one or two beats on
screen before plymouth-quit fires. A small systemd oneshot unit
(`systemd/evo-splash-warmup.service`) is installed and enabled by
default, ordered `Before=plymouth-quit.service`, holding the splash
for `EVO_BOOT_SPLASH_HOLD_SECONDS` (default 3 seconds, ~2 full beats).

To turn it off:

    sudo EVO_BOOT_SPLASH_HOLD_SECONDS=0 scripts/install.sh

To change the hold time:

    sudo EVO_BOOT_SPLASH_HOLD_SECONDS=5 scripts/install.sh

The hold is "at least N seconds"; the natural boot to plymouth-quit
delay only counts if it is longer than N.

## Repo layout

    evo-device-boot/
      README.md
      DESIGN.md
      LICENSE
      plymouth/
        evo.plymouth
        evo.script
        assets/                 (generated by tools/render-frames.py)
      systemd/
        evo-splash-warmup.service
      fbcon-logo/               (placeholder)
      grub-theme/               (placeholder)
      tools/
        render-frames.py
      scripts/
        install.sh
        uninstall.sh
        verify.sh
      packaging/
        debian/                 (placeholder)

## Licence

Apache-2.0. Mirrors evo-device-audio.
