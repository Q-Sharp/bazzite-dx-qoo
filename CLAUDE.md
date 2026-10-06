# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Repository Is

A custom [bootc](https://github.com/bootc-dev/bootc) OS image (`bazzite-dx-qoo`) derived from the Universal Blue `image-template`. It builds on top of `ghcr.io/ublue-os/bazzite-dx-nvidia:latest` and adds:

- **CoolerControl** (installed from the `codifryed/CoolerControl` COPR, which is enabled only for the install and disabled again)
- **nct6687 out-of-tree kernel module** (MSI NCT6687D-R fan control), compiled against the image's kernel and signed with a MOK key for Secure Boot
- **NVIDIA DisplayPort fix** (temporary): while the base image ships NVIDIA 615.71.09, the NVIDIA kernel modules are rebuilt with the fix from [open-gpu-kernel-modules#1406](https://github.com/NVIDIA/open-gpu-kernel-modules/pull/1406) (monitors staying black after DPMS wake) and signed with the same MOK key

The result is published to GHCR by CI; end users consume it via `sudo bootc switch ghcr.io/q-sharp/bazzite-dx-qoo`.

## Build Architecture

The build is a single pipeline: `Containerfile` → `build_files/build.sh` → `bootc container lint`.

- **`Containerfile`**: bind-mounts `build_files/` and `system_files/` as `/ctx` from a scratch stage (they are never copied into the final image) and runs `/ctx/build.sh`.
- **`build_files/build.sh`**: the place to install packages or make image modifications. It first copies `system_files/` onto `/`, then installs packages, then builds the kernel module. The module build queries the image's kernel version via `rpm -q kernel`, installs whichever build deps are missing (`kernel-devel-matched`, `gcc`, `gcc-c++`, `make`, `git`), clones nct6687d from upstream master, compiles, signs with `/ctx/MOK.priv` + `/ctx/MOK.der`, installs to `/usr/lib/modules/<kver>/extra/`, runs `depmod`, ships `MOK.der` to `/etc/pki/mok/MOK.der`, calls `nvidia-dp-fix.sh`, writes the NVIDIA option file, removes exactly the build deps it installed, and rebuilds the initramfs.
- **`build_files/nvidia-dp-fix.sh`**: called by `build.sh` with the kernel version. Does nothing unless the stock NVIDIA module reports version 615.71.09 and `/ctx/MOK.priv` exists. Otherwise it clones NVIDIA's `open-gpu-kernel-modules` at that tag, applies the patches the stock Bazzite kmod is built with (negativo17 `nvidia-kmod.spec` and `ublue-os/akmods` `patches/ogc`, fetched from commit-pinned URLs), then every patch in `build_files/nvidia-patches/`, builds all modules and replaces the stock `extra/nvidia/*.ko.xz` with stripped, MOK-signed, xz-compressed builds.
- **NVIDIA VRAM accounting switch**: `build.sh` writes `/usr/lib/modprobe.d/zz-nvidia-memacct.conf`, which appends `RmMemacctMode=0` to whatever `NVreg_RegistryDwords` the base image sets. Driver 615 added cgroup-based VRAM accounting; together with Bazzite's `dmemcg-booster` it makes games see only about 4 GB of VRAM.
- **Initramfs rebuild**: the last build step in `build.sh` regenerates the initramfs with the same dracut call as bazzite-dx. The initramfs contains the NVIDIA modules and `modprobe.d` and loads the modules before the root filesystem is mounted, so module or option changes have no effect without it.
- **`system_files/`**: overlay copied verbatim onto the image root (`usr/lib/modules-load.d/nct6687.conf` loads the module at boot; `usr/lib/modprobe.d/nct6687.conf` sets `force=true`; `usr/share/ublue-os/just/60-custom.just` adds the `ujust enroll-nct6687-signing-key` recipe via bazzite's optional import hook).
- **`image-template.env`**: image parameters (`IMAGE_NAME`, `REPO_ORGANIZATION`, `BIB_IMAGE`, …) loaded by the Justfile via dotenv. Change names/metadata here, not in the Justfile.

## Common Commands

All recipes come from the `Justfile` (defaults are filled from `image-template.env`, so bare invocations work):

```bash
just build              # Build the container image with podman
just rechunk            # Rechunk with Chunkah (what CI uses)
just ostree-rechunk     # Classic rpm-ostree rechunker (requires root)

just check              # Validate Justfile syntax (CI runs this)
just fix                # Auto-format Justfile
just lint               # shellcheck on all *.sh
just format             # shfmt on all *.sh

just build-qcow2        # Build a VM disk image via bootc-image-builder (also: build-raw, build-iso)
just run-vm-qcow2       # Boot the built image in a QEMU container, web console on localhost:8006
just spawn-vm           # Boot via systemd-vmspawn instead
just clean              # Remove build artifacts (output/, _build*, …)
```

To test a locally built image on a bootc host, the image must be in root's container storage (build with `sudo just build`, or the `_rootful_load_image` recipe copies it), then:

```bash
sudo bootc switch --transport containers-storage localhost/bazzite-dx-qoo:latest
```

## CI (GitHub Actions)

- **`build.yml`**: runs on push to main, PRs, daily at 10:05 UTC, and manual dispatch. Pipeline: `just check` → `just lint` (shellcheck) → write `MOK.priv` from secret → `sudo just build` → `just rechunk` (Chunkah) → tag → push to GHCR → cosign sign. Push/sign steps only run on the default branch, never on PRs.
- **`build-disk.yml`**: builds qcow2/anaconda-iso disk images via bootc-image-builder, optionally uploading to S3. Its `IMAGE_NAME` env is hardcoded to `bazzite-dx-qoo` and must be kept in sync with `IMAGE_NAME` in `image-template.env`.

## Known Gotchas

- `build.sh` runs with `set -ouex pipefail`, so any failing command aborts the whole image build — guard genuinely optional steps with `|| true` (as done for `modinfo`).
- `just check` runs `just --fmt --check` on every `*.just` file in the repo, including `system_files/usr/share/ublue-os/just/60-custom.just` — new ujust recipes must be fmt-clean or CI fails.
- `nvidia-dp-fix.sh` replaces the NVIDIA modules with MOK-signed ones. A machine without the MOK enrolled gets no display under Secure Boot; a build without `MOK.priv` (local builds, fork PRs) keeps the stock modules and therefore the DisplayPort bug.
- The stock patch list in `nvidia-dp-fix.sh` is a snapshot of what negativo17 and ublue-os/akmods applied to 615.71.09 on 2026-10-06; patches they add later for the same driver version are not picked up. Delete the script, `nvidia-patches/`, its call in `build.sh` and `gcc-c++` from the dep list once Bazzite ships a driver with the fix.
- `NVreg_RegistryDwords` is a single string and the last `options nvidia` line wins. Add further NVIDIA registry keys to the line generated in `build.sh`, not in a separate file. The value is `;`-separated, so it is set through `modprobe.d` plus the initramfs rebuild rather than as a kernel argument.
- The kickstart in `disk_config/iso.toml` hardcodes the published image URL (`ghcr.io/q-sharp/bazzite-dx-qoo:latest`) — update it if the image name or organization changes.
