# packaging/debian

Placeholder for a Debian source package so we can ship
evo-device-boot via an evo apt repository.

The contents will be the same install logic as `scripts/install.sh`
wrapped in a dpkg postinst (set theme, rebuild initramfs, patch
cmdline) and postrm (revert). Until then, integrators call
`scripts/install.sh` directly.

Tracked in `DESIGN.md` under Future work.
