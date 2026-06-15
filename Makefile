TARGET = iphone:clang:latest:10.0
ARCHS = arm64

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = BluedPushFix
BluedPushFix_FILES = Tweak.xm
BluedPushFix_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
BluedPushFix_FRAMEWORKS = UIKit AVFoundation UserNotifications CoreLocation

include $(THEOS)/makefiles/tweak.mk

after-install::
	install.exec "killall -9 Blued"
