TARGET := iphone:clang:latest:14.0
ARCHS := arm64 arm64e

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = DriverAssistantPro

DriverAssistantPro_FILES = Tweak.xm
DriverAssistantPro_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -Wno-arc-performSelector-leaks -Wno-unused-variable -Wno-unused-function
DriverAssistantPro_FRAMEWORKS = UIKit Foundation AudioToolbox AVFoundation

include $(THEOS_MAKE_PATH)/tweak.mk
