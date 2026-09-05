TARGET := iphone:clang:latest:14.0

# arm64e is not optional for a release: A12 and newer devices run arm64e system
# processes, and an arm64-only dylib cannot be injected into them. Building
# arm64 alone would work on the development iPhone 8 Plus (A11) and fail on most
# users' phones.
ARCHS = arm64 arm64e

# Rootless (/var/jb) unless HP_ROOTFUL=1 asks for a rootful package.
# Deliberately not `?=`: with that, merely unsetting THEOS_PACKAGE_SCHEME still
# left the default in place, so the "rootful" build quietly produced a second
# rootless package that overwrote the first.
ifneq ($(HP_ROOTFUL),1)
THEOS_PACKAGE_SCHEME = rootless
endif

include $(THEOS)/makefiles/common.mk

# One package, two products: the tweak that injects into SpringBoard and
# Preferences, and the CLI probe that shares its collector sources. Keeping the
# CLI in the package means the same code that counts the bytes can always be
# run by hand to see what it sees.
TWEAK_NAME = HotspotPro

HotspotPro_FILES = Tweak.x Collector.m Prefs.m Tracker.m
HotspotPro_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
HotspotPro_FRAMEWORKS = UIKit Foundation

# The tip-jar link is NOT passed as a -D define. A donate URL contains '&',
# which unquoted reaches the shell as a background operator and truncates the
# compile command; quoting it instead confuses Theos's own makefile parsing
# (it ended up reading Prefix.pch as a makefile). The build scripts generate
# DonateURL.h instead, which Tweak.x picks up with __has_include.
# PSSpecifier/PSListController live here; the SDK ships the stub.
HotspotPro_PRIVATE_FRAMEWORKS = Preferences

include $(THEOS_MAKE_PATH)/tweak.mk

TOOL_NAME = hotspotpro hotspotprod

hotspotpro_FILES = main.m Collector.m Prefs.m Tracker.m
hotspotpro_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
hotspotpro_FRAMEWORKS = Foundation
hotspotpro_CODESIGN_FLAGS = -S

# The per-device counter. Runs as root from a LaunchDaemon, so it installs to
# libexec rather than bin — it is not meant to be run by hand.
hotspotprod_FILES = Daemon.m Collector.m Prefs.m
hotspotprod_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
hotspotprod_FRAMEWORKS = Foundation
hotspotprod_CODESIGN_FLAGS = -S
hotspotprod_INSTALL_PATH = /usr/libexec

include $(THEOS_MAKE_PATH)/tool.mk
