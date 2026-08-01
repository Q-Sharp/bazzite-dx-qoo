# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Repository Is

A custom [bootc](https://github.com/bootc-dev/bootc) OS image (`bazzite-dx-qoo`) derived from the Universal Blue `image-template`. It builds on top of `ghcr.io/ublue-os/bazzite-dx-nvidia:stable` and adds:

- **CoolerControl** (installed from the `codifryed/CoolerControl` COPR, which is enabled only for the install and disabled again)
- **nct6687 out-of-tree kernel module** (MSI NCT6687D-R fan control), compiled against the image's kernel and signed with a MOK key for Secure Boot

The result is published to GHCR by CI; end users consume it via `sudo bootc switch ghcr.io/q-sharp/bazzite-dx-qoo`.

## Build Architecture

The build is a single pipeline: `Containerfile` → `build_files/build.sh` → `bootc container lint`.

- **`Containerfile`**: bind-mounts `build_files/` and `system_files/` as `/ctx` from a scratch stage (they are never copied into the final image) and runs `/ctx/build.sh`.
- **`build_files/build.sh`**: the place to install packages or make image modifications. It first copies `system_files/` onto `/`, then installs packages, then builds the kernel module. The module build queries the image's kernel version via `rpm -q kernel`, installs whichever build deps are missing (`kernel-devel-matched`, `gcc`, `make`, `git`), clones nct6687d at the commit pinned in `NCT6687D_COMMIT` (bumped by a Renovate regex manager in `.github/renovate.json5`), compiles, signs with `/ctx/MOK.priv` + `/ctx/MOK.der`, installs to `/usr/lib/modules/<kver>/extra/`, runs `depmod`, ships `MOK.der` to `/etc/pki/mok/MOK.der`, and removes exactly the build deps it installed.
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
- The kickstart in `disk_config/iso.toml` hardcodes the published image URL (`ghcr.io/q-sharp/bazzite-dx-qoo:latest`) — update it if the image name or organization changes.
