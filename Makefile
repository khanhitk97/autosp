TARGET := iphone:clang:latest:14.0
ARCHS := arm64

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = DriverAssistantPro

# Biên dịch thuần file .m (không qua bộ tiền xử lý Logos/Substrate)
DriverAssistantPro_FILES = Tweak.m
DriverAssistantPro_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -Wno-arc-performSelector-leaks
DriverAssistantPro_FRAMEWORKS = UIKit Foundation AudioToolbox AVFoundation

include $(THEOS_MAKE_PATH)/tweak.mk
