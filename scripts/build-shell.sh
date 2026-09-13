#!/usr/bin/env bash
#
# Build the Mira Shell asset bundle with the pinned Flutter SDK.
#
# Kept out of the Buildroot build deliberately: the Flutter toolchain has its
# own pinning under .toolchain/, and making every image rebuild depend on it
# would drag a 2.5 GB SDK into the distro's critical path.
set -euo pipefail

MIRA_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FLUTTER="${MIRA_ROOT}/.toolchain/flutter/bin/flutter"

if [ ! -x "${FLUTTER}" ]; then
	echo "error: no pinned Flutter SDK - run ./scripts/setup-flutter.sh first" >&2
	exit 1
fi

cd "${MIRA_ROOT}/shell"
echo ">> flutter pub get"
"${FLUTTER}" pub get

echo ">> analyzing"
"${FLUTTER}" analyze

echo ">> building asset bundle"
"${FLUTTER}" build bundle

BUNDLE="${MIRA_ROOT}/shell/build/flutter_assets"
if [ ! -f "${BUNDLE}/kernel_blob.bin" ]; then
	echo "error: bundle built but ${BUNDLE}/kernel_blob.bin is missing" >&2
	exit 1
fi

# Buildroot will not notice that the bundle changed: mira-shell is a local
# package, and once its stamps exist `make` skips it entirely - so the next
# image build would silently ship the previous bundle. That failure is
# invisible (the shell runs, just the old one), so invalidate the stamps here
# rather than relying on anyone remembering `make mira-shell-rebuild`.
# Removing .stamp_built/.stamp_target_installed is NOT enough: a local package
# also has .stamp_rsynced, so Buildroot would rebuild from its previous copy of
# shell/ and still ship the old bundle. Drop the whole package build directory.
shopt -s nullglob
for pkgdir in "${MIRA_ROOT}"/build/*/build/mira-shell-*; do
	rm -rf "${pkgdir}"
	echo ">> cleared $(basename "$(dirname "$(dirname "${pkgdir}")")")/$(basename "${pkgdir}")"
done
shopt -u nullglob

echo ">> bundle ready: ${BUNDLE} ($(du -sh "${BUNDLE}" | cut -f1))"
