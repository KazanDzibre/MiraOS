################################################################################
#
# mirad - Mira system supervisor
#
################################################################################

MIRAD_VERSION = 0.1.0
MIRAD_SITE = $(BR2_EXTERNAL_MIRA_PATH)/../services/mirad
MIRAD_SITE_METHOD = local
MIRAD_LICENSE = MIT

define MIRAD_BUILD_CMDS
	$(TARGET_CC) $(TARGET_CFLAGS) $(TARGET_LDFLAGS) -Wall -Wextra -O2 \
		-o $(@D)/mirad $(@D)/mirad.c
endef

define MIRAD_INSTALL_TARGET_CMDS
	$(INSTALL) -D -m 0755 $(@D)/mirad $(TARGET_DIR)/usr/bin/mirad
endef

$(eval $(generic-package))
