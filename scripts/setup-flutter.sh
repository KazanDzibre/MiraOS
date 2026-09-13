#!/usr/bin/env bash
#
# Install the pinned Flutter SDK into .toolchain/.
#
# Pinned, not system-installed, and verified by checksum: the shell is part of a
# distro image, so "whatever Flutter the developer happened to have" is not a
# reproducible input. Bumping this is a deliberate act - change the three
# variables below together and rebuild the shell from clean.
set -euo pipefail

FLUTTER_VERSION="3.47.4"
FLUTTER_SHA256="5b45f0ceda99b9bebdc873e7e69f6450aeb4c30f454b505e2e62fc9255a907d3"
FLUTTER_URL="https://storage.googleapis.com/flutter_infra_release/releases/stable/linux/flutter_linux_${FLUTTER_VERSION}-stable.tar.xz"

MIRA_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOLCHAIN="${MIRA_ROOT}/.toolchain"
SDK="${TOOLCHAIN}/flutter"
ARCHIVE="${TOOLCHAIN}/flutter_linux_${FLUTTER_VERSION}-stable.tar.xz"

if [ -x "${SDK}/bin/flutter" ]; then
	have="$(cat "${TOOLCHAIN}/FLUTTER_VERSION" 2>/dev/null || echo unknown)"
	if [ "${have}" = "${FLUTTER_VERSION}" ]; then
		echo ">> flutter ${FLUTTER_VERSION} already installed"
		exit 0
	fi
	echo ">> replacing flutter ${have} with ${FLUTTER_VERSION}"
	rm -rf "${SDK}"
fi

mkdir -p "${TOOLCHAIN}"

if [ ! -f "${ARCHIVE}" ]; then
	echo ">> downloading flutter ${FLUTTER_VERSION}"
	curl -fL --retry 3 --progress-bar "${FLUTTER_URL}" -o "${ARCHIVE}.part"
	mv "${ARCHIVE}.part" "${ARCHIVE}"
fi

echo ">> verifying checksum"
echo "${FLUTTER_SHA256}  ${ARCHIVE}" | sha256sum -c - || {
	echo "error: checksum mismatch - refusing to install" >&2
	rm -f "${ARCHIVE}"
	exit 1
}

echo ">> extracting"
tar -xJf "${ARCHIVE}" -C "${TOOLCHAIN}"
echo "${FLUTTER_VERSION}" > "${TOOLCHAIN}/FLUTTER_VERSION"

# Flutter refuses to run from a directory owned by another user, and git-based
# version detection needs the repo it ships with to be considered safe.
git config --global --add safe.directory "${SDK}" 2>/dev/null || true

echo ">> flutter ${FLUTTER_VERSION} installed at ${SDK}"
"${SDK}/bin/flutter" --version || true
