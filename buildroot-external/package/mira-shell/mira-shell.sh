#!/bin/sh
#
# Launch Mira Shell under flutter-pi.
#
# mirad execs this and restarts it with backoff, so anything that goes wrong
# here must fail loudly on the console rather than exit silently - a black
# screen with no explanation is the one outcome the box must never produce.

BUNDLE=/usr/share/mira-shell

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

# Shell output goes to the serial console, not tty1. tty1 sits behind the UI
# and is part of the product, so nothing may scroll on it - while the serial
# port is the diagnostic way in (CLAUDE.md, "Diagnosability is a feature").
if [ -c /dev/ttyS0 ]; then
	exec >/dev/ttyS0 2>&1
fi

exec /usr/bin/flutter-pi \
	--videomode 1920x1080 \
	"${BUNDLE}" "$@"
