DEBUG = 0
FINALPACKAGE = 1

ARCHS = arm64 arm64e

include BigTime2_Build.mk
include $(THEOS)/makefiles/common.mk

TWEAK_NAME = BigTime2
BigTime2_FILES = $(wildcard Hooks/*.xm)
BigTime2_CFLAGS = -fobjc-arc
BigTime2_FRAMEWORKS = UIKit Foundation CoreFoundation CoreText QuartzCore
BigTime2_LIBRARIES = substrate

include $(THEOS_MAKE_PATH)/tweak.mk
