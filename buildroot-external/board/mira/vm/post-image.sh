#!/usr/bin/env bash
#
# Publish the built ISO into the repo's out/ directory under a versioned,
# predictable name so scripts/run-vm.sh and humans can both find it.
set -euo pipefail

BINARIES_DIR="${BINARIES_DIR:-$1}"
MIRA_ROOT="${BR2_EXTERNAL_MIRA_PATH}/.."
OUT_DIR="${MIRA_ROOT}/out"
VERSION="$(cat "${MIRA_ROOT}/VERSION" 2>/dev/null || echo 0.0.0)"

src="${BINARIES_DIR}/rootfs.iso9660"
if [ ! -f "${src}" ]; then
	echo "post-image: expected ISO at ${src} but it is missing" >&2
	exit 1
fi

mkdir -p "${OUT_DIR}"
dest="${OUT_DIR}/mira-vm-${VERSION}-x86_64.iso"
cp -f "${src}" "${dest}"
ln -sf "$(basename "${dest}")" "${OUT_DIR}/mira-vm-latest.iso"

size="$(du -h "${dest}" | cut -f1)"
echo
echo "  Mira ISO ready: ${dest} (${size})"
echo "  Boot it with:   ./scripts/run-vm.sh"
echo
