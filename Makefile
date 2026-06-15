TARGET = iphone:clang:latest:10.0
ARCHS = arm64

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = BluedPushFix
# 编译时会自动寻找同级目录下的 silent_data.h
BluedPushFix_FILES = Tweak.xm
BluedPushFix_CFLAGS = -fobjc-arc
BluedPushFix_FRAMEWORKS = UIKit AVFoundation

include $(THEOS)/makefiles/tweak.mk

after-install::
	install.exec "killall -9 Blued"
