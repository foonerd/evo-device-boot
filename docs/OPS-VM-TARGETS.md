# Operations note — VM targets

`evo-device-boot` is designed for hardware devices with a real GPU / DRM
device (Pi 5, x86 mini-PC, etc). VM targets — VirtualBox, VMware
Workstation / ESXi, QEMU, Hyper-V — are supported for acceptance runs
and CI, but they carry graphics-stack caveats that hardware targets do
not. This document is the pinned reference for those caveats so a fresh
VM re-provision has a canonical place to check.

Nothing in this document lives in the `install.sh` code path — VM
configuration is an operator concern, not a boot-layer concern.

## 1. VirtualBox — turn 3D acceleration OFF for kiosk acceptance

**Symptom**: labwc / Wayland compositor freezes shortly after taking
DRM master. Panel goes black; no crash log; systemd shows
`evo-kiosk.service` still active but no frames.

**Cause**: VirtualBox's default GPU (`VBoxSVGA` or `VMSVGA`) advertises
3D acceleration to the guest when the "Enable 3D Acceleration"
checkbox in Display settings is ticked. The guest-side driver
(`vmwgfx` on VMware-flavoured emulated GPUs) opens the accelerated
path and then hits fence-completion hangs under Wayland's DMA-BUF
allocation pattern.

**Fix (operator action, not code)**: in the VM's Display settings,
**untick "Enable 3D Acceleration"**. Save. Cold-restart the VM
(warm restart is not always sufficient — the vmwgfx driver may still
be loaded).

**`WLR_RENDERER=pixman` alone is not sufficient**. That env var forces
the software renderer inside labwc, but the underlying vmwgfx driver
may still open the accelerated DMA path for buffer allocation and
hit the same fence-hang class. Turn 3D off at the hypervisor.

## 2. VMware Workstation / ESXi — same class

**Symptom + fix**: identical to VirtualBox. Turn off 3D acceleration
in the VM's video adapter settings.

**Alternative**: change the display controller from the VMware SVGA
default to a simpler emulated GPU (bochs, `qemu -vga std` equivalent)
if the hypervisor offers one. Not always available; 3D-off is the
universal workaround.

## 3. QEMU — prefer virtio-vga or virtio-gpu-gl only when tested

**QEMU virtio-gpu-gl** works with Wayland when the host has a real GPU
and virglrenderer is available, but the setup is fragile. Default to
`-vga std` (bochs) or `-vga virtio` without the `gl` flag for
acceptance runs. The compositor drops to software rendering and the
splash-to-kiosk handoff works reliably.

## 4. Hyper-V — enhanced session vs basic

**Enhanced Session Mode** (RDP-based) does NOT expose a DRM device the
compositor can take. Kiosk cannot start. Use **basic session
(vmconnect without enhanced mode)** for kiosk acceptance so the
Hyper-V synthetic GPU exposes `/dev/dri/card0`.

## 5. Splash to kiosk on a VM (any hypervisor)

The seamless Plymouth → labwc handoff (`plymouth quit --retain-splash`
+ compositor takes DRM on the same VT) works on any VM that presents
a real DRM device WITHOUT hardware-accelerated 3D. The retained
framebuffer relies on the DRM driver keeping the last scanout buffer
alive across the plymouth-quit → labwc-modeset gap. Some virtualised
DRM drivers do not honour that on fast-restart paths; if the panel
flashes black between splash and UI on a VM but works on hardware,
the split is virtualised-DRM, not the drop-in.

## 6. Where to check first when a VM boot flickers

Run `sudo /usr/local/share/evo-device-boot/scripts/verify.sh` — the
canonical on-device triage helper. It prints the effective
`plymouth-quit` ExecStart, whether the retain-splash drop-in is
present, and the warmup unit state. On a VM where those all read
correct but the panel still flickers, the split is upstream of
`evo-device-boot` and the guidance in §§1–4 applies.
