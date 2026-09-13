################################################################################
#
# sd-event-shim - Mira's sd-event subset, installed as libsystemd
#
################################################################################

SD_EVENT_SHIM_VERSION = 0.1.0
SD_EVENT_SHIM_SITE = $(BR2_EXTERNAL_MIRA_PATH)/../services/sd-event-shim
SD_EVENT_SHIM_SITE_METHOD = local
SD_EVENT_SHIM_LICENSE = MIT

# flutter-pi resolves this with pkg-config at configure time, so headers and the
# .pc file have to be in staging, not just on the target.
SD_EVENT_SHIM_INSTALL_STAGING = YES

define SD_EVENT_SHIM_BUILD_CMDS
	$(TARGET_MAKE_ENV) $(MAKE) -C $(@D) \
		CC="$(TARGET_CC)" \
		CFLAGS="$(TARGET_CFLAGS)" \
		LDFLAGS="$(TARGET_LDFLAGS)"
endef

define SD_EVENT_SHIM_INSTALL_STAGING_CMDS
	$(TARGET_MAKE_ENV) $(MAKE) -C $(@D) install DESTDIR=$(STAGING_DIR)
endef

define SD_EVENT_SHIM_INSTALL_TARGET_CMDS
	$(TARGET_MAKE_ENV) $(MAKE) -C $(@D) install DESTDIR=$(TARGET_DIR)
endef

$(eval $(generic-package))
