################################################################################
#
# flutterpi - the DRM/KMS Flutter embedder, built against Mira's sd-event shim
#
################################################################################

# Same commit Buildroot 2026.02.3 pins, so we inherit its vetting without
# inheriting its systemd dependency.
FLUTTERPI_VERSION = af8c8d66c5f40a6aaf366882bb9ca525be9c600a
FLUTTERPI_SITE = https://github.com/ardera/flutter-pi.git
FLUTTERPI_SITE_METHOD = git
FLUTTERPI_LICENSE = MIT
FLUTTERPI_LICENSE_FILES = LICENSE

FLUTTERPI_DEPENDENCIES = \
	flutter-engine-bin \
	gstreamer1 \
	gst1-plugins-base \
	sd-event-shim \
	libdrm \
	libinput \
	libxkbcommon \
	mesa3d

# USE_LEGACY_KMS stays OFF. It was tried while chasing "Could not find a
# suitable unused DRM plane" and did not help - patch 0002 did. Worse, legacy
# modesetting takes an internally-blocking path that calls drmCrtcGetSequence,
# which virtio-gpu does not implement, and flutter-pi then segfaults.
#
# ENABLE_SOFTWARE is ON, unlike Buildroot's package. It is flutter-pi's own
# software renderer, needing no GBM or EGL - the only way the VM target renders
# on QEMU's stdvga, where mesa cannot create a GBM device. The Pi uses the GL
# path; this is a fallback, not a replacement.
#
# Careful when editing FLUTTERPI_CONF_OPTS: a `#` comment inside a
# backslash-continued assignment comments out the rest of the continuation and
# silently drops every option after it.
# The GStreamer video player plugin is ON: it is how Mira plays video inside the
# flutter-pi process (DRM-master option 1). TRY_BUILD_... is OFF on purpose -
# with it ON, missing GStreamer libraries make CMake quietly build flutter-pi
# *without* the plugin, and the first sign would be a player that never starts.
#
# Its default pipeline (uridecodebin ! video/x-raw ! appsink) has no audio
# branch and gstplayer_set_volume is a stub, so MiraPlayer hands it a full
# pipeline string that includes audio rather than relying on the default.
#
# Everything else optional is off. The video and audio plugins pull in GStreamer,
# and Mira drives playback through its own MiraPlayer channel rather than
# flutter-pi's plugin - see CLAUDE.md on the decodebin trap.
FLUTTERPI_CONF_OPTS = \
	-DBUILD_CHARSET_CONVERTER_PLUGIN=OFF \
	-DBUILD_GSTREAMER_AUDIO_PLAYER_PLUGIN=OFF \
	-DBUILD_GSTREAMER_VIDEO_PLAYER_PLUGIN=ON \
	-DBUILD_RAW_KEYBOARD_PLUGIN=ON \
	-DBUILD_SENTRY_PLUGIN=OFF \
	-DBUILD_TEXT_INPUT_PLUGIN=ON \
	-DDEBUG_DRM_PLANE_ALLOCATIONS=OFF \
	-DDUMP_ENGINE_LAYERS=OFF \
	-DENABLE_ASAN=OFF \
	-DENABLE_MTRACE=OFF \
	-DENABLE_OPENGL=ON \
	-DENABLE_SESSION_SWITCHING=OFF \
	-DENABLE_SOFTWARE=ON \
	-DENABLE_TESTS=OFF \
	-DENABLE_TSAN=OFF \
	-DENABLE_UBSAN=OFF \
	-DENABLE_VULKAN=OFF \
	-DLINT_EGL_HEADERS=OFF \
	-DLTO=OFF \
	-DTRY_BUILD_GSTREAMER_AUDIO_PLAYER_PLUGIN=OFF \
	-DTRY_BUILD_GSTREAMER_VIDEO_PLAYER_PLUGIN=OFF \
	-DTRY_ENABLE_SESSION_SWITCHING=OFF \
	-DTRY_ENABLE_VULKAN=OFF \
	-DUSE_LEGACY_KMS=OFF \
	-DVULKAN_DEBUG=OFF \
	-DWARN_MISSING_FIELD_INITIALIZERS=OFF

$(eval $(cmake-package))
