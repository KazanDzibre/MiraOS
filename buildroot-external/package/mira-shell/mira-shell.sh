#!/bin/sh
#
# Launch Mira Shell under flutter-pi.
#
# mirad execs this and restarts it with backoff, so anything that goes wrong
# here must fail loudly on the console rather than exit silently - a black
# screen with no explanation is the one outcome the box must never produce.

# The exit status must be flutter-pi's, not the logging pipe's: mirad decides
# whether to back off from it, and tee always succeeds.
set -o pipefail 2>/dev/null || true

BUNDLE=/usr/share/mira-shell
LOG=/var/log/mira-shell.log

if [ ! -f "${BUNDLE}/kernel_blob.bin" ]; then
	echo "mira-shell: no asset bundle at ${BUNDLE}" >&2
	exit 1
fi

# --release would need an AOT build; the pinned engine is the JIT one, so the
# bundle's kernel_blob is what runs.
# Tells the shell it is on the appliance, so it registers the GStreamer player.
# A desktop run or a test has no such variable and gets a fake player instead -
# there is nothing on the far side of the platform channel to talk to.
export MIRA_PLATFORM=flutter-pi

# GStreamer warnings and errors, not just flutter-pi's one-line summary: a film
# that never starts otherwise leaves nothing to go on.
export GST_DEBUG="${GST_DEBUG:-2}"

# Prefer the Pi's hardware decoders, explicitly.
#
# The stateless ones (v4l2slh265dec, the HEVC path) register with rank NONE, so
# autoplugging ignores them and quietly picks a software decoder instead -
# exactly the trap in CLAUDE.md, seen as a pegged CPU core and a stuttering
# film. Ranking them MAX is how GStreamer lets you say "use the hardware".
export GST_PLUGIN_FEATURE_RANK="${GST_PLUGIN_FEATURE_RANK:-v4l2slh265dec:MAX,v4l2h264dec:MAX}"

# Bring-up only, and temporary: draws what the remote sends in the corner of
# the screen. A TV box has no serial adapter here and no ssh yet, and remotes
# disagree about which key OK is - the first one tried moved focus but did
# nothing on OK. Remove this once the real remote's keys are known.
export MIRA_DEBUG_KEYS="${MIRA_DEBUG_KEYS:-0}"

# The UI is a 1080p layout, always - video output can mode-switch for content,
# the interface does not. flutter-pi takes the panel's preferred mode and
# derives Flutter's scale from the display's physical size, which on a TV comes
# out at 1. So on a 4K set the UI gets 3840x2160 logical pixels and every size
# in the design renders half as big (seen on the real TV, 2026-10-05).
#
# Ask for 1920x1080 when the panel lists it, which every 4K TV does. If it is
# not listed, take the panel's own mode: a small UI beats a black screen.
MODE_ARGS=""
if [ -z "${MIRA_VIDEOMODE:-}" ]; then
	if grep -qxh "1920x1080" /sys/class/drm/card*/modes 2>/dev/null; then
		MIRA_VIDEOMODE=1920x1080
	fi
fi
[ -n "${MIRA_VIDEOMODE:-}" ] && MODE_ARGS="--videomode ${MIRA_VIDEOMODE}"

# Say what we are starting with. When flutter-pi fails, these lines are usually
# enough to tell a missing DRM device from a missing bundle.
DRI="$(ls /dev/dri 2>/dev/null | tr '\n' ' ')"
echo "mira-shell: $(cat /proc/device-tree/model 2>/dev/null || echo 'unknown board'), dri: ${DRI:-none}${MODE_ARGS:+, mode ${MIRA_VIDEOMODE}}"

# No display device is the one failure worth explaining on the spot: flutter-pi
# will only say it cannot query the DRM device list, and the reason is always
# further back - a driver that never loaded, or one that found nothing to bind.
if [ -z "${DRI}" ]; then
	echo "mira-shell: modules loaded: $(lsmod 2>/dev/null | tail -n +2 | wc -l), vc4: $(lsmod 2>/dev/null | grep -c '^vc4')"
	modprobe vc4 2>&1 | sed 's/^/mira-shell: modprobe vc4: /'
	dmesg 2>/dev/null | grep -iE 'vc4|v3d|drm|cma' | tail -8 | sed 's/^/mira-shell: dmesg: /'
	DRI="$(ls /dev/dri 2>/dev/null | tr '\n' ' ')"
	echo "mira-shell: dri after modprobe: ${DRI:-none}"
fi

# Output goes three ways on purpose. tty1 is where mirad's restart messages
# already are, so on a box with no serial adapter the failure is readable on
# the TV itself; the log file is what an ssh session reads after the fact; and
# ttyS0 stays the serial diagnostic path. Once flutter-pi takes DRM master the
# console is hidden behind the UI, so this scrolls on a working box only while
# it is still starting.
run() {
	if [ -c /dev/ttyS0 ]; then
		/usr/bin/flutter-pi "$@" "${BUNDLE}" 2>&1 | tee -a "${LOG}" /dev/ttyS0
	else
		/usr/bin/flutter-pi "$@" "${BUNDLE}" 2>&1 | tee -a "${LOG}"
	fi
}

started="$(date +%s)"
# shellcheck disable=SC2086  # MODE_ARGS is deliberately word-split
run ${MODE_ARGS}
status=$?

# A mode the panel will not take makes flutter-pi exit at once. Retry on the
# display's own terms rather than leaving the TV black while mirad backs off.
if [ "${status}" != 0 ] && [ -n "${MODE_ARGS}" ] && [ "$(( $(date +%s) - started ))" -lt 10 ]; then
	echo "mira-shell: ${MIRA_VIDEOMODE} was refused; retrying with the display's preferred mode"
	run
	status=$?
fi

exit "${status}"
