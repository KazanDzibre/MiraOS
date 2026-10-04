#!/usr/bin/env bash
#
# Assemble the SD card image, then publish it into the repo's out/ directory
# under a versioned name - the rpi4 counterpart of the VM target's post-image.
set -euo pipefail

BINARIES_DIR="${BINARIES_DIR:-$1}"
BOARD_DIR="$(dirname "$0")"
MIRA_ROOT="${BR2_EXTERNAL_MIRA_PATH}/.."
OUT_DIR="${MIRA_ROOT}/out"
VERSION="$(cat "${MIRA_ROOT}/VERSION" 2>/dev/null || echo 0.0.0)"

GENIMAGE_CFG="${BINARIES_DIR}/genimage.cfg"
GENIMAGE_TMP="${BUILD_DIR}/genimage.tmp"

# The boot partition holds whatever the build produced: the kernel named by
# config.txt, every DTB, and the firmware's files and overlays.
FILES=()
for i in "${BINARIES_DIR}"/*.dtb "${BINARIES_DIR}"/rpi-firmware/*; do
	[ -e "$i" ] || continue
	FILES+=( "${i#"${BINARIES_DIR}"/}" )
done
KERNEL="$(sed -n 's/^kernel=//p' "${BINARIES_DIR}/rpi-firmware/config.txt")"
FILES+=( "${KERNEL}" )

BOOT_FILES="$(printf '\t\t\t"%s",\n' "${FILES[@]}")"
# The list is multi-line, so hand it to sed as a file rather than a pattern.
awk -v repl="${BOOT_FILES}" '{ sub(/#BOOT_FILES#/, repl); print }' \
	"${BOARD_DIR}/genimage.cfg.in" > "${GENIMAGE_CFG}"

# genimage copies the rootpath wholesale, and the ext4 image is already built,
# so give it an empty directory rather than TARGET_DIR.
trap 'rm -rf "${ROOTPATH_TMP}"' EXIT
ROOTPATH_TMP="$(mktemp -d)"
rm -rf "${GENIMAGE_TMP}"

genimage \
	--rootpath "${ROOTPATH_TMP}" \
	--tmppath "${GENIMAGE_TMP}" \
	--inputpath "${BINARIES_DIR}" \
	--outputpath "${BINARIES_DIR}" \
	--config "${GENIMAGE_CFG}"

mkdir -p "${OUT_DIR}"
dest="${OUT_DIR}/mira-rpi4-${VERSION}-arm64.img"
cp -f "${BINARIES_DIR}/sdcard.img" "${dest}"
ln -sf "$(basename "${dest}")" "${OUT_DIR}/mira-rpi4-latest.img"

size="$(du -h "${dest}" | cut -f1)"
echo
echo "  Mira SD card image ready: ${dest} (${size})"
echo "  Write it to a card with:  sudo dd if=${dest} of=/dev/sdX bs=4M conv=fsync status=progress"
echo
