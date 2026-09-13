#!/usr/bin/env bash
#
# Runs against the assembled target rootfs, before image packing.
set -euo pipefail

TARGET_DIR="${TARGET_DIR:-$1}"
MIRA_ROOT="${BR2_EXTERNAL_MIRA_PATH}/.."
VERSION="$(cat "${MIRA_ROOT}/VERSION" 2>/dev/null || echo 0.0.0)"
RELEASE_NAME="Algol"

# Identify ourselves properly rather than inheriting Buildroot's defaults.
cat > "${TARGET_DIR}/usr/lib/os-release" <<EOS
NAME="Mira"
PRETTY_NAME="Mira ${VERSION} (${RELEASE_NAME})"
ID=mira
VERSION="${VERSION}"
VERSION_ID=${VERSION}
VERSION_CODENAME=${RELEASE_NAME,,}
HOME_URL="https://github.com/"
EOS
ln -sf ../usr/lib/os-release "${TARGET_DIR}/etc/os-release"

# The console should never look like a generic Linux box.
printf 'Mira %s (%s) \\n \\l\n\n' "${VERSION}" "${RELEASE_NAME}" \
	> "${TARGET_DIR}/etc/issue"

# Persistent state lives on its own partition; make sure the mountpoint exists
# even before that partition is provisioned.
mkdir -p "${TARGET_DIR}/var/lib/mira"

# Optional, opt-in, development only: bake a server config into the image.
#
#   MIRA_DEV_CONFIG=~/.config/mira/dev-server.json ./scripts/build.sh vm
#
# The VM's rootfs is an initrd in RAM, so /var/lib/mira cannot persist across a
# boot and there is nowhere else for a config to come from. On the appliance
# this is never used - first-run enrolment writes the real partition instead.
#
# WARNING: the resulting image contains these credentials in clear text. It is
# for a local VM, not for anything that leaves the machine.
if [ -n "${MIRA_DEV_CONFIG:-}" ]; then
	if [ -r "${MIRA_DEV_CONFIG}" ]; then
		install -D -m 0600 "${MIRA_DEV_CONFIG}" "${TARGET_DIR}/var/lib/mira/config.json"
		echo ">> post-build: baked ${MIRA_DEV_CONFIG} into the image (DEV ONLY - image now holds credentials)"
	else
		echo "error: MIRA_DEV_CONFIG set but ${MIRA_DEV_CONFIG} is not readable" >&2
		exit 1
	fi
fi
