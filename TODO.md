# Mira — what's left

State on 2026-10-05: **the box works.** A Pi 4B boots from SD into the shell,
browses the real Jellyfin library over the LAN, and plays everything in it —
H.264 direct, everything else transcoded by the server — with hardware decode,
sound, subtitles, and the remote. Measured: 8% of four cores while playing, no
dropped frames.

What follows is the gap between *works* and *appliance*. Ordered by what would
hurt most if the box were handed to someone who did not build it.

CLAUDE.md is the context document — the why, the traps, the measurements. This
is the list of open work only.

---

## 1. It is still a dev box, not a product

Every item here is a deliberate bring-up aid that has to come off before anyone
else uses this. None are hard; the risk is forgetting one.

- [ ] **Credentials are baked into the image.** `MIRA_DEV_CONFIG` writes the
      server URL, username and password into the rootfs. This image must not be
      shared with anyone. The fix is first-run enrolment (§2).
- [ ] **Root password is `mira`**, in the defconfig
      (`BR2_TARGET_GENERIC_ROOT_PASSWD`), with dropbear listening on 22 *and*
      2222 (`board/mira/rpi4/rootfs-overlay/etc/default/dropbear`). Decide what
      ships: key-only, no password, and probably no sshd at all by default.
- [ ] **The boot is verbose.** `cmdline.txt` still carries `mira.debug=1` and
      `loglevel=4`. The appliance premise is a silent boot — "anything
      user-visible on the console is part of the product".
- [ ] **`GST_DEBUG=2` on every boot** (`mira-shell.sh`), which is what makes
      the GStreamer warnings legible. Keep it behind the debug flag, not on by
      default.
- [ ] Dev knobs to keep but document as dev-only: `MIRA_PIPELINE`,
      `MIRA_VIDEO_FORMAT`, `MIRA_HWDEC`, `MIRA_DEBUG_KEYS`.
- [ ] **Push to GitHub, as a private repo.** 3 commits are unpushed. CLAUDE.md
      contains the server's IP and username, so public is not an option.

## 2. The appliance layer (none of it exists yet)

This is the biggest block of real work, and it is what the *Boot and storage*
section of CLAUDE.md was designed around but never built.

- [ ] **Read-only root.** Today it is a single read-write ext4 partition. The
      power *will* get pulled mid-write on a TV box — this is the reason the
      design calls for squashfs.
- [ ] **A/B slots + `tryboot`.** Write the inactive slot, update
      `autoboot.txt`, reboot with tryboot, auto-revert if the new slot fails
      its health signal.
- [ ] **`mira-update`** — the OTA updater itself. Nothing written.
- [ ] **First-run enrolment.** A real sign-in screen, so the server config
      stops being baked in. Blocks §1's credential item.
- [ ] **`mira-inputd`** — CEC, so the TV remote drives the box and it powers on
      with the telly. A USB/2.4 GHz remote works meanwhile.
- [ ] **USB SSD boot** — `BOOT_ORDER=0xf14` via `rpi-eeprom-config`, SD kept as
      rescue.

## 3. HEVC direct play — the one real blocker left

Worth its own section because it is a single upstream bug standing between this
box and never transcoding again. 82% of the library is HEVC.

- [ ] **`v4l2codecs` registers zero features.** It enumerates
      `/sys/class/media`; the Pi's stateless decoder nodes are under
      `/sys/bus/media`. `/dev/video19` (`rpi-hevc-dec`) is right there and
      unreachable. Patch the plugin, or find the kernel/plugin version pairing
      that works.
- [ ] Once it decodes: re-widen the DeviceProfile (the HEVC block is kept
      commented in `shell/lib/jellyfin/device_profile.dart` for exactly this),
      add an HEVC branch to `GstreamerMiraPlayer.pipelineFor`, and update
      `likelyDirectPlay` in `models.dart`. Three files, all cross-referenced.
- [ ] Re-measure after. The whole point is removing the server's work, so the
      proof is CPU on *both* ends.

## 4. The hitch: playback degrades over a session (open, half-diagnosed)

The live investigation, written up in CLAUDE.md under *Playback degrades over
a session*. In short: nothing is dropped, nothing is copied, the decoder and
the server are idle - but `flutter-pi`'s CPU climbs 2-3 points a minute while
a film plays, from ~43% of a core to ~88%, and memory with it (295 -> 390 MB)
while fds and fences stay flat.

- [ ] Find what grows. Suspects, in order: EGLImage/texture churn per frame in
      the compositor, V4L2 capture-buffer recycling, GPU memory fragmentation.
- [ ] Watch the `frame.c` counters over a long session: if `copied` becomes
      non-zero after twenty minutes, the V4L2 pool has exhausted and switched
      to the copy path, and the fix is buffer counts rather than anything in
      the renderer.
- [ ] Deploy `MIRA_FRAME_LOG=1` during a real session to confirm the late
      frames are late *presentations* rather than late decodes.
- [ ] Remove the temporary `frame.c` counter patch from the box when done -
      it writes a line a second to a 115200 baud console, which costs ~9 ms of
      main-thread time each time.

## 5. Unverified — claims that have never been exercised

Honest list of things believed but not shown. Each one is a candidate for the
next surprise.

- [ ] **Seeking inside a transcoded (HLS) stream.** The playlist is VOD with
      `ENDLIST` and 2418 segments, so it *should* seek — but no one has pressed
      left/right during a transcode on the box. Most likely next bug.
- [ ] **The H.264 4K ceiling**, still unproven after a month: the library has
      no files above 1080p, so the rule most likely to be wrong has never run.
      Put a 4K H.264 file on the server and watch what the profile does.
- [ ] **Long playback.** Longest verified run is minutes, not a whole film.
      Watch for the transcode folder filling (§5) and for drift between audio
      and subtitles over two hours.
- [ ] **Power-loss behaviour**, which is the entire argument for §2.
- [ ] NetBird from *outside* the LAN. Everything so far was same-subnet; the
      20 Mbps `defaultMaxStreamingBitrate` is the knob that matters remotely.

## 6. Scrub preview (Netflix-style), waiting on the server

Asked for on 2026-10-06 and deferred the same day: the client work is small,
but it cannot show anything until Jellyfin has the images.

- [ ] **Turn on trickplay image extraction.** Dashboard → Libraries → Movies →
      *Enable trickplay image extraction*, then let the task run. Off on all
      four libraries today (Movies, Shows, Anime, Collections); the server's
      own defaults are already sensible - a 320 px tile every 10 s, 10x10 to a
      sheet, BelowNormal priority on one thread. Expect hours of background CPU
      for 359 titles, which is why it was not switched on without asking.
- [ ] **Then the client half:** `MediaItem` carries no trickplay data yet;
      Jellyfin exposes it through the `Trickplay` field on an item and serves
      tiles at `/Videos/{id}/Trickplay/{width}/{index}.jpg`. The player would
      show the tile nearest the pending seek above the scrub bar - which is
      exactly where the new `» ×N` speed readout sits, so the two want
      designing together.
- [ ] There is no fallback worth building: Jellyfin has no "frame at this
      timestamp" endpoint, and decoding a second stream on the Pi to make one
      is not on.

## 7. Server side — done on 2026-10-07

Applied to the real Jellyfin (192.168.100.34, Docker, linuxserver image). The
old values are backed up in `/tmp/claude-*/encoding-backup.json`; the same
three are in Dashboard -> Playback if they ever need putting back.

| setting | was | now | why |
|---|---|---|---|
| Throttling | off | **on**, 180 s ahead | ffmpeg was using **5.45 of 6 cores** racing ~8x ahead of playback. After: 97% idle, load 13.5 -> 4.4. |
| Segment deletion | off | **on**, keep 720 s | one film had left **5.8 GB in 6919 files**. |
| Encoder preset | `veryfast` | **`medium`** | at the ~3-12 Mbps we now ask for, preset is where the picture is won. Measured after: still **222 fps, 9.3x realtime**. |

**Hardware transcoding is impossible here and would not help anyway.** The
Jellyfin box is a KVM guest whose only display adapter is QEMU's Bochs VGA.
The Proxmox host (192.168.100.100) does have a **Radeon RX 5500**, but
`/sys/kernel/iommu_groups/` is *empty* - IOMMU is off in the firmware, so
passthrough needs a BIOS change and a full host reboot, and it would take the
card away from the host's own console. And AMD's VCN encoder looks *worse*
than `x264 medium` at the same bitrate, so it would trade picture quality for
speed that is already surplus. If it is ever wanted, the sane route is running
Jellyfin in a Proxmox **LXC** sharing `/dev/dri`, not passthrough to the VM.

Still optional, and measured:

- [ ] **Throttle transcodes + delete segments** (Dashboard → Playback). Both
      off today, which is why the server converted 37.8% of a 2-hour film while
      7.6 minutes had been watched — roughly 2.8 GB of temp files, heading for
      ~7.5 GB. Low risk, no quality cost.
- [ ] **Hardware acceleration** is `none`. QSV/VAAPI would make transcoding
      nearly free, but needs `ls -l /dev/dri` on the server first (and the
      device passed through if Jellyfin is in Docker/LXC). An optimisation, not
      a fix.
- [ ] Five stale `probe*` sessions in the dashboard from testing; they expire.

## 8. Rough edges

Small, visible, none blocking.

- [ ] `The system has no configured locale` on every boot. Harmless since
      compose became optional, but it is console output, so it counts.
- [ ] ALSA logs `Unknown PCM default:{AES0...}` twice at startup — something
      probing the IEC958 device. Sound works; the noise is untraced.
- [ ] `libinput error: client bug: event processing lagging behind` from the
      AirMouse. Not seen to affect input.
- [ ] Some titles show as raw filenames (`Dune.2021.1080p.BluR...`). Unmatched
      items in Jellyfin, not a shell bug — fix the library metadata.
- [ ] **AC3/DTS passthrough** was in the original plan and is deliberately not
      shipped: vc4-hdmi via ALSA `default` takes 48 kHz S16LE stereo only. Real
      passthrough needs the IEC958 device. A feature, when wanted.
- [ ] 4K video mode-switching (UI stays 1080p). Less urgent now that everything
      arrives as 1080p H.264.

## 9. Deferred on purpose — do not drift into these

- **YouTube** and any second *graphical* process. It forks the architecture
  (DRM master), which is why v1 stops where it does. See *The v2 fork*.
- **Android TV APK** for operator boxes. Considered and declined 2026-09-15.
