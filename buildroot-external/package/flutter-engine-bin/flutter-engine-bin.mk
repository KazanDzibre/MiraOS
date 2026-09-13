################################################################################
#
# flutter-engine-bin - prebuilt Flutter engine matching .toolchain/
#
################################################################################

# MUST match the engine revision of the Flutter SDK pinned in
# scripts/setup-flutter.sh. Check with:  flutter --version
FLUTTER_ENGINE_BIN_VERSION = 0e228ec8c8d2abc9fcf1d053e8a40665bb859ec7
FLUTTER_ENGINE_BIN_SITE = https://storage.googleapis.com/flutter_infra_release/flutter/$(FLUTTER_ENGINE_BIN_VERSION)/linux-x64
FLUTTER_ENGINE_BIN_SOURCE = linux-x64-embedder.zip
FLUTTER_ENGINE_BIN_LICENSE = BSD-3-Clause
FLUTTER_ENGINE_BIN_LICENSE_FILES = LICENSE.embedder-archive.md
FLUTTER_ENGINE_BIN_INSTALL_STAGING = YES

# The engine also needs ICU data, which ships in a different archive from the
# embedder. Without it flutter-pi exits at startup with "icudtl file not found"
# and never reaches GL init.
FLUTTER_ENGINE_BIN_EXTRA_DOWNLOADS = $(FLUTTER_ENGINE_BIN_SITE)/artifacts.zip

define FLUTTER_ENGINE_BIN_EXTRACT_CMDS
	$(UNZIP) -d $(@D) $(FLUTTER_ENGINE_BIN_DL_DIR)/$(FLUTTER_ENGINE_BIN_SOURCE)
	$(UNZIP) -j -o -d $(@D) $(FLUTTER_ENGINE_BIN_DL_DIR)/artifacts.zip icudtl.dat
endef

define FLUTTER_ENGINE_BIN_INSTALL_STAGING_CMDS
	$(INSTALL) -D -m 0644 $(@D)/flutter_embedder.h \
		$(STAGING_DIR)/usr/include/flutter_embedder.h
	$(INSTALL) -D -m 0755 $(@D)/libflutter_engine.so \
		$(STAGING_DIR)/usr/lib/libflutter_engine.so
endef

define FLUTTER_ENGINE_BIN_INSTALL_TARGET_CMDS
	$(INSTALL) -D -m 0755 $(@D)/libflutter_engine.so \
		$(TARGET_DIR)/usr/lib/libflutter_engine.so
	# /usr/lib/icudtl.dat is one of the paths flutter-pi searches.
	$(INSTALL) -D -m 0644 $(@D)/icudtl.dat \
		$(TARGET_DIR)/usr/lib/icudtl.dat
endef

$(eval $(generic-package))
