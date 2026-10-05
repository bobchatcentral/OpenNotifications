export ARCHS = armv7
export TARGET = iphone:clang:5.0:5.0

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = OpenNotifications
OpenNotifications_FILES = Tweak.x
OpenNotifications_FRAMEWORKS = UIKit Foundation AudioToolbox AVFoundation QuartzCore

include $(THEOS_MAKE_PATH)/tweak.mk

SUBPROJECTS += onprefs
include $(THEOS_MAKE_PATH)/aggregate.mk
