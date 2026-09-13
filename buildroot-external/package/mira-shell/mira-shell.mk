################################################################################
#
# mira-shell - the Flutter launcher bundle
#
################################################################################

MIRA_SHELL_VERSION = 0.1.0
MIRA_SHELL_SITE = $(BR2_EXTERNAL_MIRA_PATH)/../shell
MIRA_SHELL_SITE_METHOD = local
MIRA_SHELL_LICENSE = MIT
MIRA_SHELL_DEPENDENCIES = flutterpi

MIRA_SHELL_BUNDLE = $(@D)/build/flutter_assets

# The bundle is built by the pinned SDK in .toolchain/, not by Buildroot: the
# Flutter toolchain is a host tool with its own pinning, and dragging it into
# the image build would make every distro rebuild depend on it.
define MIRA_SHELL_BUILD_CMDS
	test -f $(MIRA_SHELL_BUNDLE)/kernel_blob.bin || { \
		echo ""; \
		echo "error: no Flutter bundle at shell/build/flutter_assets"; \
		echo "  build it first:  ./scripts/build-shell.sh"; \
		echo ""; \
		exit 1; \
	}
endef

define MIRA_SHELL_INSTALL_TARGET_CMDS
	mkdir -p $(TARGET_DIR)/usr/share/mira-shell
	cp -a $(MIRA_SHELL_BUNDLE)/. $(TARGET_DIR)/usr/share/mira-shell/
	$(INSTALL) -D -m 0755 $(BR2_EXTERNAL_MIRA_PATH)/package/mira-shell/mira-shell.sh \
		$(TARGET_DIR)/usr/bin/mira-shell
endef

$(eval $(generic-package))
