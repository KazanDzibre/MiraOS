# Mira — project context

A minimal Linux distribution for the living room. Boots straight into its own
Flutter launcher on a Raspberry Pi 4 wired to a TV, driven from the couch with a
gyroscopic remote. Replaces a Raspberry Pi OS install that works but is a
desktop distro pretending to be an appliance.

Named for the variable star in Cetus, and because *mira* means "look".
Releases are named after variable stars: 0.1.0 is **Algol**.

## Scope

**v1: Jellyfin + Overseerr + NetBird.** Playback from a home-lab Jellyfin server
over a NetBird tunnel, driven by the remote — plus browsing and requesting new
titles through Overseerr.

Overseerr was added after v1 scope was first drawn, and the reasoning is the
test to apply to anything else proposed for v1: it is another **REST client
rendered by the same Flutter process**, so it costs a screen set and an API
client and *does not touch the DRM-master constraint*. A second **graphical**
process is the expensive kind of addition; a second **HTTP** client is not.

**v2 (deferred, deliberately): YouTube**, a generic app/plugin system, OTA
updates. YouTube is not a missing feature — it is a separate project, and it is
hard precisely because it needs a second graphical process. See *The v2 fork*
below.

## Naming vocabulary

| Component | Name |
|---|---|
| The OS | **Mira** |
| Launcher UI (Flutter) | **Mira Shell** (`mira-shell`) |
| System supervisor | `mirad` |
| CEC → uinput bridge | `mira-inputd` |
| A/B updater | `mira-update` |
| Buildroot external tree | `BR2_EXTERNAL=mira` |
| Persistent state | `/var/lib/mira` |

---

## Hardware reality — read this before proposing anything about video

The target is a **Raspberry Pi 4, 4GB**, currently booting from SD (moving to
USB SSD). The Pi 4's VideoCore VI has a **narrow** hardware decode envelope, and
the Cortex-A72 is **not** a viable software fallback at 1080p or above.

| Codec | Pi 4 hardware | Consequence |
|---|---|---|
| HEVC/H.265 to 4K60 | Yes — `rpivid`, V4L2 stateless | Best path. Zero-copy, near-zero CPU. |
| H.264 to **1080p60** | Yes — `bcm2835-codec`, V4L2 M2M | Fine. The ceiling is 1080p, **not** 4K. |
| H.264 at 4K | **No** | Software only; will not hold framerate. Must transcode. |
| VP9 / AV1 | **No** | Software only. Marginal at 720p, unusable at 1080p. This is why YouTube is hard. |
| MPEG-2 / VC-1 | No | Transcode. |

Note the Pi 5 is *worse* for this job despite a faster CPU: it dropped H.264
hardware decode entirely. Do not "upgrade" the target without re-reading this.

**Therefore:** the Jellyfin **DeviceProfile** must declare exactly this envelope.
Get it right and the server direct-plays what we handle and transcodes what we
don't. Get it wrong and we receive 4K H.264 that stutters, which will look like a
player bug and isn't one. *The DeviceProfile is the Jellyfin integration* — most
of the box's perceived quality lives there.

**Validated against the real server on 2026-09-12** (Jellyfin 10.11.11 at
192.168.100.34:8096, reached over NetBird) with `shell/tool/probe_envelope.dart`:

- 45 titles scanned: 27 H.264, 17 HEVC, 1 AV1.
- HEVC and H.264 at 1080p direct-play; server and profile agree.
- The one AV1 file transcodes, and the profile predicts it. That is the
  no-hardware-at-all claim confirmed on a real file.
- **Still unproven: the H.264 4K ceiling.** The library has no files above
  1080p, so the rule most likely to be wrong has never been exercised. Do not
  treat the agreement above as covering it.

Display: TV is mixed-resolution. UI plane renders at **1080p always**; video
output mode-switches to match content so 4K HEVC gets a native path.

Audio: declare AC3/DTS passthrough in the same profile; let the TV decode.

---

## Architecture

### The DRM master problem (central constraint)

flutter-pi renders **directly to DRM/KMS**, no X11 or Wayland — that is its whole
value. But **only one process can be DRM master**. Any separate video player
process also wants the screen. They cannot coexist.

Three ways out:

1. **Single process** — GStreamer decodes, hands Flutter a zero-copy external
   texture via DMA-BUF. No conflict, because there is only one process.
2. **DRM plane leasing** — flutter-pi stays master, leases a plane to mpv.
   Correct in theory; neither project supports it today without patching.
3. **Process hand-off** — flutter-pi drops master, mpv takes over, hands back.
   Best playback quality, but needs a flutter-pi patch and black-flashes on
   every transition.

**v1 uses option 1.** Because v1 has exactly *one* graphical app, this is not a
compromise — it is simply correct.

### flutter-pi needs libsystemd — solved with our own sd-event

Buildroot 2026.02.3 ships `flutter-pi`, `flutter-engine` and `flutter-sdk-bin`,
but **none of them are usable here**, for two independent reasons found
2026-09-12. Do not "simplify" by switching to them.

**1. `flutter-pi` hard-requires libsystemd**, and Buildroot's
`BR2_PACKAGE_SYSTEMD` `depends on BR2_INIT_SYSTEMD` — so using it would mean
replacing BusyBox init with systemd, which is most of the appliance premise
(2 s boot, one inittab). There is no `elogind` in this Buildroot, and `basu`
provides sd-bus only.

Measured rather than assumed: flutter-pi uses **sd-event in 103 places and
sd-bus in none**, and `<systemd/sd-event.h>` is the only systemd header it
includes. Buildroot's "Event loop and dbus support" comment is stale.

**Resolution: `services/sd-event-shim/`** — Mira implements the ~22 epoll-based
`sd_event_*` functions itself and installs them as `libsystemd` + `libsystemd.pc`.
flutter-pi builds and runs against it unpatched. Two things to know if you touch
it:

- `make test` in that directory runs the suite under ASan/UBSan. It pins the
  ordering rules flutter-pi depends on, including two that are opposites:
  a source whose handle is dropped is **cancelled**, while flutter-pi's platform
  tasks deliberately **never unref** on the success path and must still fire.
- The header must include `<sys/epoll.h>`; systemd's does, and flutter-pi relies
  on getting `EPOLLIN` and friends transitively. The test deliberately does not
  include it, so removing it breaks the build loudly instead of an hour later in
  a cross-compile.

**2. Version skew.** Buildroot's `flutter-engine` builds from source via
gclient/depot-tools (hours, tens of GB) and pins engine **3.29.2**, while
`.toolchain/` pins Flutter **3.47.4**. A mismatched engine fails at runtime
without naming the cause.

**Resolution: `flutter-engine-bin`** installs the prebuilt engine for our exact
engine hash. It is the **JIT** engine, so an ordinary `flutter build bundle`
runs directly with no AOT step. It must also ship **`icudtl.dat`**, which lives
in `artifacts.zip`, not the embedder archive — without it flutter-pi exits with
`icudtl file not found` before it ever reaches graphics.

Because both of our packages shadow upstream names, ours are called
`flutterpi` and `flutter-engine-bin` to avoid kconfig symbol collisions.

### Graphics in the VM — needs virtio-gpu on the host

**flutter-pi cannot run on QEMU's default stdvga.** Established by testing on
2026-09-12, so do not re-litigate it from first principles:

- With only the virgl gallium driver, stdvga (`1234:1111`) gives
  `kmsro: driver missing` -> `Could not create GBM device`.
- Adding **llvmpipe** does not help. Mesa 26 has no software GBM fallback for a
  dumb-buffer KMS device (no `kms_swrast`), so GBM still fails.
  `MESA_LOADER_DRIVER_OVERRIDE=kms_swrast` does change loader behaviour - the
  `kmsro` line disappears - but GBM fails anyway.
- flutter-pi's `ENABLE_SOFTWARE=ON` (which Buildroot disables and Mira enables,
  since upstream defaults it ON) is a software *renderer*, not a way around
  needing a device. flutter-pi still probes for a GBM-capable DRM device first.
- Even `--dummy-display` fails, with "couldn't find a usable render device".
  There is no headless path that avoids EGL.

**So the VM needs a virtio-gpu device with virgl**, which on Arch means display
models that ship as separate packages from `qemu-system-x86`:

```sh
sudo pacman -S qemu-ui-gtk qemu-hw-display-virtio-gpu qemu-hw-display-virtio-gpu-gl
./scripts/run-vm.sh --gl        # virtio-gpu-gl-pci + virgl
```

`run-vm.sh` already prefers virtio-gpu when present and preflights the missing
package by name. Plain `--display gtk` without `--gl` gives a virtio-gpu with no
virgl and therefore no render node, which fails the same way - **`--gl` is
required**, not merely faster.

Whether llvmpipe is worth keeping in the image is open: it costs ~27 MB and
LLVM build time, and it did not solve this. It stays for now only because virgl
is the path being used.

### The v2 fork

The moment a second graphical app exists (YouTube via WPE WebKit, anything
else), option 1 stops working and a compositor or hand-off becomes necessary.
That is a real architectural fork and the main reason v1 stops where it does.

To keep that switch cheap, **all playback goes behind a narrow `MiraPlayer`
interface** (`play`/`pause`/`seek`/`position`/`state`). Swapping the backend must
touch one file, not the UI. Do not let player specifics leak into widgets.

### Known trap: GStreamer software-decode fallback

flutter-pi issues #224 and #230 report hardware decode silently falling back to
software under the Flutter texture path. Near-certain cause is `decodebin`
autoplugging the wrong element.

**Always pin decoder elements explicitly** (`v4l2h264dec`, `v4l2slh265dec`).
Never use `decodebin` in a Mira pipeline. After any pipeline change, verify with
CPU measurement — if a core pegs, it fell back and the pipeline is wrong.

### Video in the VM - was broken, now solved (2026-09-13)

This section records how software-decoded video was made to work under virgl;
the fixes are patches 0004-0006 below. The original symptom: in the VM,
flutter-pi's GStreamer player hung on every film. GStreamer warns
`failed delayed linking some pad of GstURIDecodeBin named src to … queue0`
(the video branch), audio links, the pipeline never prerolls, and
`initialize()` never returns. The shell now times out after 30 s and shows the
failure screen instead of a spinner.

**Ruled out, by testing** - do not retry these:
- Caps filter placement (`src. ! video/x-raw ! queue` vs `src. ! queue ! video/x-raw`).
- A `videoconvert` before the appsink.
- Missing decoders: the VM's FFmpeg has H.264/HEVC/AAC/AC3/EAC3, and the test
  file is an ordinary MP4 (H.264 High, 8-bit yuv420p, AAC stereo).

**Cause, confirmed by patch 0004's log line:**
`[gstreamer video player] 0 importable formats, appsink caps: EMPTY`.
flutter-pi restricts the appsink to formats EGL reports as DMA-BUF importable,
and under virgl that list is empty, so no video pad can ever link. This is a
VM graphics limitation, not a pipeline, decoder or server problem - and it says
nothing yet about the Pi, whose V4L2 decoders emit importable dmabufs.

**Fixes so far, as flutter-pi patches in `buildroot-external/package/flutterpi/`:**
- **0004** logs the importable format count and appsink caps on every open.
- **0005** falls back to the four 8-bit RGB formats (with LINEAR modifier) when
  EGL reports none. Verified: the video branch now links, and frames reach
  flutter-pi. The shell's pipeline has a `videoconvert` before the appsink to
  produce them.
- **0006** copies software-decoded frames into a GBM BO of the frame's real
  size and format. Upstream's copy makes an R8 BO one pixel high and as wide as
  the frame's byte count (6 MB+ at 1080p), and virgl refuses it with
  `Couldn't create GBM BO to copy video frame into.`

**Playback works in the VM, verified 2026-09-13** on *2001: A Space Odyssey*
(H.264 High 1080p MP4, direct play from the real server over NetBird): picture
on screen and correctly letterboxed, position advancing, overlay auto-hide and
wake-on-first-key, and left/right seek past the overture. Expect a burst of
`Dropping frame due to QoS` warnings right after a seek - software decode plus a
CPU colour conversion in a VM, not a Pi measurement.

**Sound verified 2026-09-13**, after two separate fixes. The host needs
`qemu-audio-pipewire` (Arch splits QEMU's audio backends out, like its display
models). That alone gave a *running* QEMU stream linked to the speakers that
carried **pure silence** (measured: peak 0 on the sink monitor while a dialogue
scene played) - because ALSA drivers start muted at zero and a read-only image
restores no mixer state. `board/mira/common/rootfs-overlay/etc/init.d/S15mira-audio`
now runs `alsactl init` and unmutes the usual controls at boot, with
`BR2_PACKAGE_ALSA_UTILS` (+`_ALSACTL`, `_AMIXER`) in the defconfig. Measured
after: peak -28 dBFS, RMS -46 dBFS. The Pi's HDMI audio needs the same script.
To measure, record the speaker sink's monitor with
`pw-record -P '{ stream.capture.sink=true }' --target <sink>`; recording the
QEMU stream node directly returns zeros even when it is playing.

**No voices in films - fixed and measured 2026-09-14.** Music and effects
played but dialogue was missing. Cause, from alsa-lib `pcm_plug.c`: the
`default` ALSA device accepts any channel count, so GStreamer handed it 5.1 or
7.1 unchanged, and plug's DEFAULT route policy resolves to COPY for anything but
mono - channel 0 to left, channel 1 to right, every other channel dropped.
Dialogue lives in the centre channel. Nearly every film in the library is 5.1
or 7.1. The shell's pipeline now ends `audio/x-raw,channels=2 ! autoaudiosink`
so audioconvert downmixes and folds the centre in. Measured in the VM with a
6-channel WAV carrying a tone on the centre channel only, streamed through
`uridecodebin` like a film: old chain peak 0 (silence), new chain -20 dBFS.
The Pi's HDMI audio goes through the same `default` device, so it needs this
too; multichannel PCM or passthrough to the TV would be a later, deliberate
change. `gst-launch-1.0` is in the image; `audiotestsrc` is not.

**Subtitles verified the same day**, entirely by d-pad: Down from the scrub bar
to Play/Pause, right to *Subtitles & audio*, the sheet listing the file's real
tracks plus live OpenSubtitles results from the Jellyfin plugin, picking the
Serbian SRT without restarting the stream, and the lines drawn in sync over the
picture after a 22-minute seek. Found and fixed on the way: real search results
ran underneath the sheet's key hints (demo data is too short to show it).
Progress reporting is verified too: after a reboot the same film resumed at
27:14, where the previous session had left it, so Jellyfin received the
position from `reportProgress`/`reportStopped`.

**Continue Watching needs the playback *start* report.** Found 2026-09-13:
without `POST /Sessions/Playing`, Jellyfin 10.11.11 stores positions but never a
LastPlayedDate, and `Items/Resume` leaves the film out entirely (2001 had a
50-minute position, `LastPlayedDate: null`, and was not in the list).
`PlayerScreen` now calls `reportStart` after every successful open, including
the restart for a new audio track. Home's rail shows progress bars, reloads
quietly whenever a pushed screen closes, and the film page offers
*Mark watched* (`POST /UserPlayedItems/{id}`) and *Clear progress*
(`POST /UserItems/{id}/UserData` with `PlaybackPositionTicks: 0`).

**Home has two rails: Continue Watching, then Recently added** (Jellyfin
`Items` sorted by DateCreated, films only). They share one window a single rail
tall, scrolled by focus through `ensureVisible`, so Down brings the next rail in
while the hero stays put and names the rail its title came from. `_Root` loads
both in parallel and only shows "Nothing to continue yet" when both are empty.

Two layout lessons from the second rail, both found in the VM:
- **The hero measures its title** with a `TextPainter` and gives the synopsis
  only the lines left over. The old fixed height thresholds ignored whether a
  title wrapped, so with the rail label and peek below, "House of Flying
  Daggers" overflowed the hero's buttons by 17 px. The long-title golden now
  renders both rails, and fails on the old rule.
- **The rails window snaps the focused rail to the top.** Focus traversal only
  scrolls far enough to show the new rail, which left a half-cut sliver of the
  previous rail's captions above it.

**Sign-in must be single-flight.** Loading the two rails in parallel made two
concurrent `AuthenticateByName` calls (Jellyfin's activity log: 6 ms apart), and
Jellyfin replaces a device's session on each sign-in - so the first token was
revoked while a rail was using it and the box booted into "Your sign-in is no
longer valid". `JellyfinLibrarySource._signIn` now shares one in-flight sign-in;
`test/jellyfin_signin_test.dart` pins it against a local fake server that
refuses superseded tokens the way Jellyfin does. Demo-data tests cannot catch
this class of bug - the demo source never signs in.

**OK, Back and Menu must not repeat.** `SingleActivator` matches key-repeat
events by default, and flutter-pi forwards the kernel's evdev repeats, so a Back
press that lasted a moment too long popped the player *and* the film page -
seen in the VM as the film page vanishing about two seconds after Back, with no
second press. `RemoteShortcuts` sets `includeRepeats: false` on those bindings;
arrows keep repeating for scrolling and scrubbing.

Both verified in the VM the same day, with temporary key logging (since
removed): one Esc arrived as a single down/up pair 80 ms apart and left the film
page in place, and Jellyfin's activity log showed "is playing ... on Mira"
followed by "finished playing" - the start report reaching the server. Failed
start/progress/stop reports now print `mira jellyfin: ... report failed` to the
serial console instead of vanishing.

None of 0004-0006 touch the DMA-BUF path hardware decoders use, so they should
be inert on the Pi - but that is unverified until Phase 0.

The warning is only visible with `GST_DEBUG=2` on the serial console, which
`mira-shell.sh` now sets.

To read shell and GStreamer output in the VM:
`./scripts/run-vm.sh --gl --serial-log FILE --monitor SOCK` - the monitor socket
path must be under 108 bytes, so keep it short (e.g. `/tmp/mira-mon.sock`).

### Boot and storage (rpi4 target)

```
EEPROM → p1 (FAT32 boot) → kernel + DTB → initramfs → mirad → mira-shell
```

| Part | FS | Contents |
|---|---|---|
| p1 | FAT32 | firmware, kernel, DTBs, `config.txt`, `autoboot.txt` |
| p2 | squashfs | rootfs **A** (read-only) |
| p3 | squashfs | rootfs **B** (read-only) |
| p4 | ext4 | `/var/lib/mira` — config, creds, NetBird state, artwork cache |

Read-only root because it is a TV box and **the power will get pulled
mid-write**. A/B updates use the Pi's **`tryboot`** mechanism: write inactive
slot, update `autoboot.txt`, reboot with tryboot; firmware auto-reverts if the
new slot fails its health signal.

USB SSD boot: `BOOT_ORDER=0xf14` (USB first, SD fallback) via `rpi-eeprom-config`,
keeping the SD as rescue.

---

## Build system

**Buildroot 2026.02.3**, vendored at `buildroot/` (gitignored). The February
releases are Buildroot's LTS line — pinned deliberately for reproducibility.
Do not bump casually.

Two targets share one source tree. Everything above the kernel is common.

| Target | Arch | Output | Purpose |
|---|---|---|---|
| `rpi4` | aarch64 | `out/mira-rpi4-*.img` | The real appliance |
| `vm` | x86_64 | `out/mira-vm-*.iso` | Local look-and-feel testing |

The VM target is a **hybrid BIOS+UEFI ISO that runs entirely from RAM** (rootfs
ships as an initrd). It exists so UI iteration does not require reflashing an SD
card. It is a fast mirror of the appliance, not a second product; it
software-decodes video because no VM has a VideoCore.

### Commands

```sh
./scripts/build.sh vm            # -> out/mira-vm-latest.iso  (30-60 min first time)
./scripts/build.sh vm --clean    # discard build tree for target
./scripts/build.sh vm --menuconfig
./scripts/run-vm.sh              # boot in QEMU under KVM
./scripts/run-vm.sh --gl         # virgl 3D; needed once flutter-pi renders
./scripts/run-vm.sh --serial     # console on terminal — use this to debug boot
```

`run-vm.sh` passes **`-vga none`** deliberately. Without it QEMU adds the
machine's default VGA *on top of* the display device we ask for, and the guest
boots with two indistinguishable DRM cards — flutter-pi then has to guess which
one to take DRM master on, and guessing wrong looks like a rendering bug and is
not one. The VM should mirror the Pi: exactly one display device.

Note also that QEMU's UI backends and virtio-gpu display models are separate
packages on Arch, so a working `qemu-system-x86` can still have no way to open a
window. `run-vm.sh` preflights this and names the missing package.

### Buildroot gotchas already paid for

- **Symbols silently drop.** Setting a symbol in a defconfig does not mean it
  lands — unmet dependencies cause silent omission with no warning.
  **Always verify after generating**: `grep -E "^BR2_FOO=" build/<t>/.config`.
- **Pin toolchain kernel headers.** Without
  `BR2_PACKAGE_HOST_LINUX_HEADERS_CUSTOM_6_18=y`, glibc is unavailable and libc
  falls back to uclibc, which has no `BR2_USE_WCHAR`, which silently disables
  **GRUB2**. One missing line took out the bootloader.
- **Editing `shell/` does not invalidate the `mira-shell` package.** It is a
  local package, so once its stamps exist Buildroot skips it and the image
  silently ships the *previous* bundle - the shell still runs, just the old
  one, which is a genuinely hard failure to spot. Removing `.stamp_built` and
  `.stamp_target_installed` is **not** sufficient - a local package also has
  `.stamp_rsynced`, so Buildroot rebuilds from its previous copy of `shell/`.
  `scripts/build-shell.sh` deletes the whole package build directory for this
  reason; always build the bundle through it.
- **Changing a package's `.mk` does not rebuild it either.** On 2026-09-13
  `flutterpi.mk` gained `-DBUILD_GSTREAMER_VIDEO_PLAYER_PLUGIN=ON`, the image
  build succeeded, and the image still shipped the previous flutter-pi with no
  video player - every film failed with "could not be opened". After editing
  any `.mk`/`Config.in`, run `make -C build/vm <pkg>-dirclean` and verify the
  result in `target/` (for flutter-pi: `readelf -d usr/bin/flutter-pi | grep gst`).
- **glibc, not uclibc/musl** — the Flutter engine links against glibc.
- Kernel `linux.config` files here are **seeds**, not full configs. Buildroot
  runs `olddefconfig` over them, so list only non-default choices.
- Host deps are checked late by Buildroot; `scripts/build.sh` preflights them
  early instead. `xorriso` is built by Buildroot and is *not* a host dep.

---

## Conventions

- **C** (`mirad`, `mira-inputd`): kernel-ish style, tabs, `-Wall -Wextra` clean.
  Comment *why*, not what. Daemons must degrade gracefully rather than exit —
  init will respawn them into a tight loop otherwise.
- **Buildroot packages** live in `buildroot-external/package/<name>/` with
  `Config.in` + `<name>.mk`, sourced from `buildroot-external/Config.in`.
  Local sources use `SITE_METHOD = local` pointing at `../services/<name>`.
- **Never put a full rebuild in the edit-test loop.** Build the image once, then
  rsync over the network and restart the process.
- **Anything user-visible on the console is part of the product.** Boot shows no
  kernel spam, no cursor, no getty on tty1.

## Diagnosability is a feature

A TV box that shows a black screen with no way in is unfixable in the living
room. Deliberate, keep them:

- Serial getty on `ttyS0` (never tty1).
- A "verbose console" GRUB entry alongside the quiet default.
- `mirad` **holds and reports** when `mira-shell` is missing rather than
  exiting — a bare image is a working, diagnosable system, not a boot loop.

---

## Status

- **VM ISO builds and boots, now with the shell in it** (~48 MB; it was 12 MB
  before the engine and bundle). First produced 2026-09-12. GRUB2 for both BIOS and EFI landed — verify it stays that
  way after any toolchain change. Boot-tested in QEMU: GRUB → kernel 6.18.7 →
  initrd → BusyBox init → `mirad`, login prompt in ~2 s, ~22 MB of 2 GB used,
  `bochs-drm` bound with `/dev/dri/card0` present. `mirad` holds and reports the
  missing shell rather than exiting — **observed on real output, not assumed**.
  Quiet console verified showing only `mirad`'s two lines; the verbose GRUB
  entry verified to still show the full kernel and service output.
- Distro skeleton builds and is config-verified; `mirad` written and compiling.
- `mira_rpi4_defconfig` **not yet written** — VM target came first for iteration
  speed.
- **Mira Shell exists and renders.** Flutter **3.47.4** pinned under
  `.toolchain/` by `scripts/setup-flutter.sh` (version + sha256 together).
  `flutter analyze` is clean and `flutter test` passes, including goldens
  rendered at 1920x1080 with the real fonts loaded. Built so far: design tokens,
  the focus system, the `MiraPlayer` firewall with a fake and a GStreamer
  backend, the Jellyfin client and DeviceProfile, the home screen and the
  failure screens, and (2026-09-13) the Films grid, Genres view, item detail,
  the subtitles & audio sheet and the player screen - each with a golden.
  Since then: Discover (Seerr) with request, cancel and search, Continue
  Watching and Recently added rails, and the audio/visual fixes below.
  **Not built yet:** first-run enrolment (the server config is still baked into
  dev images with `MIRA_DEV_CONFIG`) and the rpi4 target. Discover shows a
  "not connected" screen when `overseerrApiKey` is missing from the config.

  **The request server is Seerr 3.4.1**, not classic Overseerr - the merged
  successor, API-compatible (`/api/v1/...`, `X-Api-Key` header), at
  `http://192.168.100.34:5055`, verified read-only on 2026-09-13. Config keys
  stay `overseerrUrl` / `overseerrApiKey`. The dev key is an **admin** key
  (permissions=2), so requests made with it auto-approve - a household member's
  key would not. Discover returns ~20,000 films; every result carries
  `mediaInfo.status` when the title is known to Seerr (3 = processing, 5 =
  available), so the UI can show "Requested" / "In your library" without an
  extra call per title. Never POST a request from a probe.

  **Discover artwork goes through Seerr's image proxy**,
  `<overseerrUrl>/imageproxy/tmdb/t/p/<size><path>` (plain http, no API key,
  same bytes as TMDB, cached by Seerr) - not `image.tmdb.org`. Found in the VM:
  direct TMDB URLs rendered every poster as a placeholder because the image had
  **no CA certificates**, so every HTTPS request failed silently while
  Jellyfin's plain-http artwork loaded. `BR2_PACKAGE_CA_CERTIFICATES` is now in
  the VM defconfig anyway, and the rpi4 target needs it too.

  **Seerr's search rejects reserved characters in the query** with a 400
  ("must be url encoded"): `the+odyssey` fails, `the%20odyssey` works, and a
  bare apostrophe fails too. Dart's `Uri` query encoding produces both `+` and
  bare `'`, so `OverseerrClient.strictEncode` percent-encodes everything but
  `A-Za-z0-9-._~`. Search (Discover -> Search chip) has an on-screen keyboard
  for the d-pad and also accepts a physical keyboard.

  **Playback and subtitle decisions (2026-09-13):**
  - Playback is flutter-pi's GStreamer video player plugin via `video_player` +
    `flutterpi_gstreamer_video_player`, which only `lib/player/` may import.
    Its default pipeline has **no audio**, so `GstreamerMiraPlayer` passes a
    custom pipeline with an audio branch. That pipeline uses `uridecodebin`,
    which is acceptable **only in the VM** - the rpi4 pipeline must pin the
    V4L2 decoders (see *Known trap* above).
  - Subtitles are drawn by the shell from Jellyfin's WebVTT
    (`lib/player/webvtt.dart`) against the player's position, so they survive a
    backend swap. Bitmap subtitles are burned in by the server instead.
  - The "OpenSubtitles wrapper" goes **through Jellyfin's Open Subtitles
    plugin** (RemoteSearch/Subtitles), not opensubtitles.com directly: no key on
    the TV, and a downloaded subtitle attaches to the film for every client.
    Downloads cost daily quota, so they only happen on an explicit OK - never
    in probes or on focus.
  - A non-default audio track or burned-in subtitle is a different server
    stream: the player restarts at the same position once, when the sheet
    closes. Text subtitles switch live.
  - Genres are aggregated client-side from paged Items, not `/Genres`.
  - Player remote model: the overlay auto-hides after 5 s of playback; the
    first key on a hidden overlay only wakes it (Back always stops); left/right
    on the scrub bar seek 10 s, 30 s when held, debounced into one seek.
    Down from the scrub bar goes **explicitly** to Play/Pause: the bar spans the
    screen, so Flutter's directional policy picked the button nearest its
    centre - Stop - which was found in the VM, not in tests. Widget tests only
    exercise traversal if their harness has `WidgetsApp.defaultShortcuts` and
    `defaultActions`; without them arrow keys silently go nowhere.
  - Archivo has no arrow glyphs; on-screen key hints use ASCII.
  - VM sound needs `-audiodev pipewire` (or `pa`); `run-vm.sh` picks one and
    warns when neither QEMU audio backend is installed.
  **Packaged and in the image:** `sd-event-shim`, `flutter-engine-bin`,
  `flutterpi` and `mira-shell`, plus mesa/libdrm/libinput/libxkbcommon and
  eudev (libinput enumerates through udev, which BusyBox mdev does not provide).
  Build the bundle with `./scripts/build-shell.sh` before building the image.
  **Rendering against the real server**, verified 2026-09-12: the shell runs in
  the VM under flutter-pi and shows the real Jellyfin library - titles,
  artwork, resume positions, direct-play badges - reached over NetBird from
  192.168.100.34:8096.
  Getting there needed two patches to flutter-pi, both in
  `buildroot-external/package/flutterpi/`, because virtio-gpu does not
  advertise `DRM_CAP_ADDFB2_MODIFIERS`: 0001 falls back to `drmModeAddFB2`,
  0002 stops plane selection matching on modifiers. `USE_LEGACY_KMS` is a trap
  here - it does not fix the plane problem and crashes on virtio-gpu's missing
  `drmCrtcGetSequence`.

  **The d-pad works**, verified by injecting arrow keys with QEMU's
  `sendkey`: focus moves along the rail and the hero follows. Two things were
  needed, and the second is the non-obvious one:
  - `xkeyboard-config` for the keymap database (`BR2_PACKAGE_XKEYBOARD_CONFIG`,
    under `package/x11r7/`). Needed on the rpi4 target too.
  - **flutter-pi patch 0003**: it treated a missing *compose table* as fatal
    for all keyboard input, and a minimal image has no X11 locale data, so
    there is no compose file for locale `C`. A dead-key feature no TV needs was
    costing the entire d-pad.

  **Remaining rough edges:**
  - The console still warns `The system has no configured locale`. Harmless now
    that compose is optional, but a locale would silence it.
  - Some titles show as raw filenames (`Dune.2021.1080p.BluR...`) - unmatched
    items in the library, not a shell bug.
- **Real data works.** `shell/tool/probe_jellyfin.dart` and
  `probe_envelope.dart` run as plain Dart (the client depends only on
  `dart:io`) and exercise the real server without building the UI. Config comes
  from `/var/lib/mira/config.json` or `~/.config/mira/dev-server.json`;
  `MIRA_DEV_CONFIG=... ./scripts/build.sh vm` bakes one into a VM image, which
  puts credentials in the ISO and is therefore dev-only.
- **A layout bug that only real data finds:** every demo title is short, so the
  hero never overflowed until a real one wrapped ("The Lord of the Rings: The
  Fellowship of the Ring Extended"). The hero now drops synopsis lines as the
  title grows, and a golden test uses that exact title. Prefer real titles in
  UI tests over invented short ones.
- Visual design lives in `design/` as Claude Design artboards (Cinema
  direction) - the source of truth for anything not yet built.
- Phase 0 hardware validation on the real Pi **has not been run**. Until it has,
  treat every claim in *Hardware reality* as researched-but-unproven.

## When building the Shell UI

Use **Claude Design** (the `design` skill) for the launcher's visual design
before implementing screens.

Shell code lives in `shell/` and follows a few rules that are cheap now and
expensive later:

- Every control is a `MiraFocusable`. Nothing rolls its own focus handling.
- No colour or size literals in widgets - they live in `core/tokens.dart`.
- The focus ring is **stroked, not a BoxShadow**. A shadow paints the whole box
  shape including underneath, so on anything with a transparent interior it
  comes out as a solid gold slab instead of a ring. This was found by rendering,
  not by reading.
- Fonts are bundled. A Buildroot rootfs has none, so this is load-bearing, not
  styling.
- **Poster grids use `GridFocus`** (`lib/ui/widgets/grid_focus.dart`): the
  focused row snaps to the top of the grid, the last rows get enough bottom
  padding to reach the top too, and Right at the end of a row moves to the next
  row's first tile (Left mirrors it, except beside the search keyboard).
  Flutter's own traversal only scrolls until the tile's edge meets the
  viewport's, which clipped the focus ring and left rows creeping at the bottom.
- **Horizontal rails use `MiraFocusable.revealMargin`** so the focused poster
  keeps its ring and a glimpse of the next poster in view, and Right on a
  rail's last poster continues into the next rail. Don't set `revealMargin` on
  tiles inside a `GridFocus` grid - its reveal and the row snap would fight.

**The d-pad is the primary input.** Mira is a TV app first: every screen must be
fully operable with up/down/left/right and OK alone, and the box must stay
completely usable with the gyro cursor **switched off**. That is a user-facing
setting, not a debug flag.

The gyro **pointer is an option layered on top**. When it is on it *moves focus*
rather than drawing its own competing hover state — so there is exactly one
focus at all times, and the two inputs can never disagree about what is
selected.

This is a hard rule, not a preference. It is the thing most often retrofitted
badly, and retrofitting it means rewriting the navigation model. What it implies
in practice: explicit orthogonal focus traversal everywhere; focus that
remembers its column when moving between rows; on-screen hints naming what OK
and Back do for the focused item; and no control that needs a drag — the player
scrub bar is driven with left/right, never dragged.
