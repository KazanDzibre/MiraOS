#!/usr/bin/env bash
#
# Build a Mira image.
#
#   ./scripts/build.sh vm      -> out/mira-vm-<ver>-x86_64.iso   (local VM testing)
#   ./scripts/build.sh rpi4    -> out/mira-rpi4-<ver>-arm64.img  (the real appliance)
#
# Flags:
#   --menuconfig   open Buildroot's config UI instead of building
#   --clean        discard the build tree for this target first
#   -j N           parallelism (default: nproc)
set -euo pipefail

MIRA_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILDROOT_DIR="${MIRA_ROOT}/buildroot"
EXTERNAL_DIR="${MIRA_ROOT}/buildroot-external"

TARGET="${1:-}"; shift || true
MENUCONFIG=0
CLEAN=0
JOBS="$(nproc)"

while [ $# -gt 0 ]; do
	case "$1" in
		--menuconfig) MENUCONFIG=1 ;;
		--clean)      CLEAN=1 ;;
		-j)           JOBS="$2"; shift ;;
		-j*)          JOBS="${1#-j}" ;;
		*)            echo "unknown flag: $1" >&2; exit 2 ;;
	esac
	shift
done

case "${TARGET}" in
	vm)   DEFCONFIG=mira_vm_x86_64_defconfig ;;
	rpi4) DEFCONFIG=mira_rpi4_defconfig ;;
	*)    echo "usage: $0 {vm|rpi4} [--menuconfig] [--clean] [-j N]" >&2; exit 2 ;;
esac

if [ ! -f "${EXTERNAL_DIR}/configs/${DEFCONFIG}" ]; then
	echo "error: ${DEFCONFIG} does not exist yet" >&2
	exit 1
fi

# Buildroot checks host tools too, but only after several minutes of setup.
# Fail in one second with something actionable instead.
missing=()
for tool in bc gcc g++ perl python3 rsync wget cpio unzip file which sed; do
	command -v "${tool}" >/dev/null 2>&1 || missing+=("${tool}")
done
if [ ${#missing[@]} -gt 0 ]; then
	echo "error: missing host build tools: ${missing[*]}" >&2
	echo "  Arch:   sudo pacman -S --needed base-devel bc rsync wget cpio unzip python perl" >&2
	echo "  Debian: sudo apt install build-essential bc rsync wget cpio unzip python3 perl file" >&2
	exit 1
fi

if [ ! -d "${BUILDROOT_DIR}" ]; then
	echo "error: buildroot/ missing - run ./scripts/setup.sh first" >&2
	exit 1
fi

BUILD_DIR="${MIRA_ROOT}/build/${TARGET}"

if [ "${CLEAN}" = 1 ]; then
	echo ">> removing ${BUILD_DIR}"
	rm -rf "${BUILD_DIR}"
fi

# (Re)generate the config whenever the defconfig is newer than the build's
# .config, so edits to the defconfig are never silently ignored.
if [ ! -f "${BUILD_DIR}/.config" ] || \
   [ "${EXTERNAL_DIR}/configs/${DEFCONFIG}" -nt "${BUILD_DIR}/.config" ]; then
	echo ">> configuring ${TARGET} from ${DEFCONFIG}"
	mkdir -p "${BUILD_DIR}"
	make -C "${BUILDROOT_DIR}" O="${BUILD_DIR}" BR2_EXTERNAL="${EXTERNAL_DIR}" "${DEFCONFIG}"
fi

if [ "${MENUCONFIG}" = 1 ]; then
	exec make -C "${BUILD_DIR}" menuconfig
fi

echo ">> building ${TARGET} with -j${JOBS} (first build takes a while)"
time make -C "${BUILD_DIR}" -j"${JOBS}"
