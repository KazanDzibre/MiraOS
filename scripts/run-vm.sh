#!/usr/bin/env bash
#
# Boot the Mira ISO in QEMU.
#
#   ./scripts/run-vm.sh           plain virtio-gpu (no 3D) - fine for boot/console
#   ./scripts/run-vm.sh --gl      virgl 3D accel - needed once flutter-pi renders
#   ./scripts/run-vm.sh --serial  console on this terminal instead of a window
#   --monitor PATH                QEMU monitor on a unix socket, for scripted
#                                 remote presses: echo "sendkey right" | socat - UNIX-CONNECT:PATH
#   --serial-log PATH             guest serial console to a file (shell logs)
#   --serial-tcp PORT             guest serial console on 127.0.0.1:PORT, to log in
#                                 and run commands while the window shows the shell
set -euo pipefail

MIRA_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ISO="${MIRA_ROOT}/out/mira-vm-latest.iso"
MEM=2048
CPUS=4
GL=0
SERIAL=0
MONITOR=""
SERIAL_LOG=""
SERIAL_TCP=""

while [ $# -gt 0 ]; do
	case "$1" in
		--gl)     GL=1 ;;
		--serial) SERIAL=1 ;;
		--monitor)    MONITOR="$2"; shift ;;
		--serial-log) SERIAL_LOG="$2"; shift ;;
		--serial-tcp) SERIAL_TCP="$2"; shift ;;
		--iso)    ISO="$2"; shift ;;
		-m)       MEM="$2"; shift ;;
		*)        echo "unknown flag: $1" >&2; exit 2 ;;
	esac
	shift
done

if [ ! -f "${ISO}" ]; then
	echo "error: no ISO at ${ISO} - run ./scripts/build.sh vm" >&2
	exit 1
fi

args=(
	-machine q35
	-m "${MEM}"
	-smp "${CPUS}"
	-cdrom "${ISO}"
	-boot d
	-netdev user,id=net0
	-device virtio-net-pci,netdev=net0
	-device intel-hda
	-usb -device usb-tablet
)

# Sound. Without an -audiodev the guest gets a sound card whose output goes
# nowhere - playback "works" and is silent, which looks like a player bug.
# Like the display models, QEMU's audio backends are separate Arch packages.
audio_backends="$(qemu-system-x86_64 -audiodev help 2>&1)"
if printf '%s' "${audio_backends}" | grep -qw pipewire; then
	args+=(-audiodev pipewire,id=snd0 -device hda-duplex,audiodev=snd0)
elif printf '%s' "${audio_backends}" | grep -qw pa; then
	args+=(-audiodev pa,id=snd0 -device hda-duplex,audiodev=snd0)
else
	echo "warning: this QEMU has no PipeWire or PulseAudio backend - the VM will be silent." >&2
	echo "  Arch/CachyOS: sudo pacman -S qemu-audio-pipewire" >&2
	args+=(-device hda-duplex)
fi

# KVM makes this near-native; without it the UI feel would be misleading.
if [ -w /dev/kvm ]; then
	args+=(-enable-kvm -cpu host)
else
	echo "warning: /dev/kvm not writable - falling back to emulation (slow)" >&2
	args+=(-cpu max)
fi

# Display device availability varies by QEMU packaging: on Arch the virtio-gpu
# models and the UI backends live in separate qemu-* packages, so a perfectly
# working qemu-system-x86 can still have no way to open a window. Pick what
# exists, and when nothing does, say which package is missing.
has_device() {
	qemu-system-x86_64 -device help 2>&1 | grep -q "name \"$1\""
}

has_display() {
	qemu-system-x86_64 -display help 2>&1 | grep -qw "$1"
}

# Arch splits QEMU's display models finely, and the ones that matter on a q35
# (PCI) machine are the *-pci* variants - installing qemu-hw-display-virtio-gpu
# alone gets you virtio-gpu-device on the virtio bus, which a PCI machine cannot
# use. virgl also needs the -gl build and qemu-ui-opengl.
PKGS="sudo pacman -S qemu-ui-gtk qemu-ui-opengl \\
        qemu-hw-display-virtio-gpu qemu-hw-display-virtio-gpu-gl \\
        qemu-hw-display-virtio-gpu-pci qemu-hw-display-virtio-gpu-pci-gl"

# Exactly one display device. Without -vga none QEMU adds the machine's default
# VGA on top of whatever we ask for, and the guest boots with two
# indistinguishable DRM cards - flutter-pi then has to guess which to take DRM
# master on, and guessing wrong looks like a rendering bug rather than a
# configuration mistake.
args+=(-vga none)

if [ "${SERIAL}" = 1 ]; then
	# "Console on this terminal" means no window. Keep a KMS-capable display
	# device anyway so /dev/dri still exists inside the guest.
	args+=(-device bochs-display -display none -serial mon:stdio)
else
	if [ "${GL}" = 1 ]; then
		if has_device virtio-gpu-gl-pci && has_display gtk; then
			args+=(-device virtio-gpu-gl-pci -display gtk,gl=on)
		elif has_device virtio-vga-gl && has_display gtk; then
			args+=(-device virtio-vga-gl -display gtk,gl=on)
		else
			echo "error: --gl needs a PCI virtio-gpu with virgl, and the GTK UI." >&2
			echo "  Looked for virtio-gpu-gl-pci and virtio-vga-gl; neither is present." >&2
			echo "  ${PKGS}" >&2
			exit 1
		fi
	else
		if ! has_display gtk; then
			echo "error: this QEMU has no GTK display backend, so no window can open." >&2
			echo "  QEMU ships its UI and display models as separate packages." >&2
			echo "  Arch/CachyOS:  ${PKGS}" >&2
			echo "  Or boot headless on this terminal:  $0 --serial" >&2
			exit 1
		fi
		if has_device virtio-gpu-pci; then
			args+=(-device virtio-gpu-pci -display gtk)
		else
			args+=(-device bochs-display -display gtk)
		fi
	fi
	if [ -n "${SERIAL_TCP}" ]; then
		args+=(-serial "tcp:127.0.0.1:${SERIAL_TCP},server=on,wait=off")
	elif [ -n "${SERIAL_LOG}" ]; then
		args+=(-serial "file:${SERIAL_LOG}")
	else
		args+=(-serial null)
	fi
fi

if [ -n "${MONITOR}" ]; then
	args+=(-monitor "unix:${MONITOR},server,nowait")
fi

echo ">> booting ${ISO##*/}"
exec qemu-system-x86_64 "${args[@]}"
