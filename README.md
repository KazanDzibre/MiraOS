# Mira

A minimal Linux distribution for the living room. Boots straight into its own
launcher on a Raspberry Pi 4 wired to a TV, and gets driven from the couch with
a gyroscopic remote.

Named for the variable star in Cetus — and because *mira* means "look".

## Why "Mira"

**Mira** (Omicron Ceti) is a star in the constellation Cetus, the Whale. It was
the first star found to change its brightness on a regular cycle: David
Fabricius noticed it in 1596, and Johannes Hevelius later named it *Mira* —
Latin for "wonderful" or "astonishing" — because it kept fading from sight and
coming back. Over about 332 days it swells from invisible to one of the
brighter stars in the sky, then dims again.

That is a fair description of a TV box: dark most of the day, then lighting up
the room in the evening.

The second meaning is the plainer one. In Spanish and Italian, *mira* means
"look" — which is the whole job of the thing: you sit down, point the remote,
and look.

The star theme carries through the project: releases are named after variable
stars, starting with 0.1.0 **Algol**, and the launcher's logo is a star.

## What it is

Raspberry Pi OS is a desktop distro pretending to be an appliance: slow to boot,
full of packages that will never run, and tuned for nothing in particular. Mira
is built for exactly one job — putting video on a screen and letting you choose
what to watch — and contains nothing that does not serve it.

**v1 scope:** Jellyfin playback over a NetBird tunnel to a home server, driven by
the remote. YouTube and a general plugin system are deliberately v2; see
`docs/` for why that sequencing matters.

## Targets

Two images are built from one source tree. Everything above the kernel — the
shell, the services, the overlay — is shared.

| Target | Arch | Output | Purpose |
|---|---|---|---|
| `rpi4` | aarch64 | `out/mira-rpi4-*.img` | The real appliance. Hardware video decode via `rpivid` and `bcm2835-codec`. |
| `vm` | x86_64 | `out/mira-vm-*.iso` | Local testing. Hybrid BIOS+UEFI ISO that runs entirely from RAM. |

The VM target exists to check how the OS *looks and feels* without reflashing an
SD card every iteration. It is not a second product — it is a fast mirror of the
real one, and it software-decodes video because no VM has a VideoCore.

## Building

```sh
./scripts/build.sh vm          # -> out/mira-vm-latest.iso
./scripts/run-vm.sh            # boot it in QEMU
./scripts/run-vm.sh --gl       # with virgl 3D, needed once the shell renders
./scripts/run-vm.sh --serial   # console on this terminal, for debugging
```

The first build takes 30–60 minutes and compiles a full cross toolchain.
Subsequent builds are incremental. `--clean` discards the build tree for a
target; `--menuconfig` opens Buildroot's config UI.

**Do not put a full rebuild in your edit-test loop.** Build the image once, then
push changes to a running system over the network — see *Development* below.

## Layout

```
buildroot/            Buildroot 2026.02.3 (LTS), vendored, gitignored
buildroot-external/   Our BR2_EXTERNAL tree: configs, board files, packages
  configs/            One defconfig per target
  board/mira/         Kernel seeds, bootloader configs, rootfs overlay
  package/            Mira's own packages
shell/                Mira Shell - the Flutter launcher
services/             mirad (supervisor), mira-inputd (CEC bridge)
scripts/              build.sh, run-vm.sh
out/                  Built images land here
```

## Components

| Name | What it is |
|---|---|
| **Mira** | The OS |
| **Mira Shell** (`mira-shell`) | The launcher UI, written in Flutter, rendered by flutter-pi straight to DRM/KMS |
| `mirad` | System supervisor. Prepares state, owns `mira-shell`, restarts it with backoff |
| `mira-inputd` | Bridges HDMI-CEC to uinput so TV remote keys arrive as ordinary input events |
| `mira-update` | A/B image updates via the Pi's `tryboot` mechanism |

Releases are named after variable stars: 0.1.0 is **Algol**.

## Host requirements

A cross toolchain is built from source, so the host needs relatively little:

```sh
sudo pacman -S --needed base-devel bc rsync wget cpio unzip python perl qemu-full
```

`xorriso` is built by Buildroot itself and is not needed on the host.

## Development

Full rebuilds are for the image, not for iteration. For shell work:

```sh
flutterpi_tool build --arch=arm64 --release
rsync -a build/flutter_assets/ mira.local:/var/lib/mira/shell-dev/
ssh mira.local 'killall mira-shell'     # mirad restarts it
```

For UI work specifically, run a debug engine build and use `flutter attach` over
the network for hot reload — seconds per iteration instead of minutes.

## Status

Early. The distro builds and boots; the shell does not exist yet. `mirad` is
written to hold gracefully when `mira-shell` is absent, so a bare image is a
working, diagnosable system rather than a boot loop.
