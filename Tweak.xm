// BluedPushFix — 异步解耦防闪退完美版
// Target: Blued极速版2 (com.danlan.xiaolAn)

#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <UserNotifications/UserNotifications.h>
#import "silent_data.h"

static AVAudioPlayer *bgAudioPlayer = nil;
static UIBackgroundTaskIdentifier bgTask = UIBackgroundTaskInvalid;

static id g_activeLiveIM = nil;
static id g_activeGRPCConnector = nil;
static id g_activeWatchdog = nil;
static dispatch_source_t g_heartbeatTimer = NULL;
static BOOL g_isBackground = NO;

// ==========================================
// 1. 本地横幅通知 (增加异步安全保护)
// ==========================================
void fireLocalBannerNotification(NSString *title, NSString *body) {
    if (!g_isBackground) return; 
    
    // 强制丢到后台默认队列处理，绝对不占用或阻塞主线程的 UI 渲染
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        UNMutableNotificationContent *content = [[UNMutableNotificationContent alloc] init];
        content.title = title;
        content.body = body;
        content.sound = [UNNotificationSound defaultSound];
        
        UNTimeIntervalNotificationTrigger *trigger = [UNTimeIntervalNotificationTrigger triggerWithTimeInterval:0.1 repeats:NO];
        UNNotificationRequest *request = [UNNotificationRequest requestWithIdentifier:@"BluedClone_Push" content:content trigger:trigger];
        [[UNUserNotificationCenter currentNotificationCenter] addNotificationRequest:request withCompletionHandler:nil];
    });
}

// ==========================================
// 2. 实例捕获与防崩溃安全拦截
// ==========================================
%hook GXWatchdog
- (instancetype)init { id obj = %orig; g_activeWatchdog = obj; return obj; }
%end

%hook BDgRPCConnector
- (instancetype)init { id obj = %orig; g_activeGRPCConnector = obj; return obj; }
%end

%hook BDLiveIM
- (instancetype)init { id obj = %orig; g_activeLiveIM = obj; return obj; }
- (void)didReceiveProtoMessage:(id)message {
    // 严格的安全检查：防止空指针引发崩溃
    if (message) {
        %orig(message);
        fireLocalBannerNotification(@"互动通知", @"直播间或派对有新的动态");
    } else {
        %orig;
    }
}
%end

%hook GJIMSessionService
- (void)p_handlePushPackage:(id)arg1 {
    // 严格的安全检查：防止个推后台数据包损坏导致 UI 闪退
    if (arg1) {
        %orig(arg1);
        fireLocalBannerNotification(@"新消息", @"您收到了一条新的聊天消息");
    } else {
        %orig;
    }
}
%end

// ==========================================
// 3. 合法后台申请与音频保活
// ==========================================
void applyLegalBackgroundPrivilege() {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIApplication *app = [UIApplication sharedApplication];
        bgTask = [app beginBackgroundTaskWithExpirationHandler:^{
            [app endBackgroundTask:bgTask];
            bgTask = UIBackgroundTaskInvalid;
        }];
        
        @try {
            AVAudioSession *session = [AVAudioSession sharedInstance];
            [session setCategory:AVAudioSessionCategoryPlayback withOptions:AVAudioSessionCategoryOptionMixWithOthers error:nil];
            [session setActive:YES error:nil];
            
            if (!bgAudioPlayer) {
                NSData *audioData = [NSData dataWithBytes:silent_mp3 length:silent_mp3_len];
                bgAudioPlayer = [[AVAudioPlayer alloc] initWithData:audioData error:nil];
                bgAudioPlayer.numberOfLoops = -1;
                bgAudioPlayer.volume = 0.01;
                [bgAudioPlayer prepareToPlay];
            }
            [bgAudioPlayer play];
        } @catch (NSException *e) {}
    });
}

void startGentleHeartbeat() {
    if (!g_heartbeatTimer) {
        g_heartbeatTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0));
        dispatch_source_set_timer(g_heartbeatTimer, dispatch_time(DISPATCH_TIME_NOW, 20 * NSEC_PER_SEC), 20 * NSEC_PER_SEC, 2 * NSEC_PER_SEC);
        dispatch_source_set_event_handler(g_heartbeatTimer, ^{
            @try {
                if (g_activeWatchdog && [g_activeWatchdog respondsToSelector:@selector(watchdogNeedHeartBeat)]) {
                    [g_activeWatchdog performSelector:@selector(watchdogNeedHeartBeat)];
                }
                if (g_activeGRPCConnector && [g_activeGRPCConnector respondsToSelector:@selector(p_pingServer)]) {
                    [g_activeGRPCConnector performSelector:@selector(p_pingServer)];
                }
            } @catch (NSException *e) {}
        });
        dispatch_resume(g_heartbeatTimer);
    }
}

// ==========================================
// 4. 生命周期缓冲修复 (解决进入前台闪退)
// ==========================================
%hook AppDelegate

- (void)applicationDidEnterBackground:(UIApplication *)application {
    g_isBackground = YES;
    %orig; 
    applyLegalBackgroundPrivilege();
    startGentleHeartbeat();
}

- (void)applicationWillEnterForeground:(UIApplication *)application {
    g_isBackground = NO;
    %orig;
    
    // 【闪退修复核心】将延迟提高到 1.5 秒，留出绝对充足的时间让 UI 和广告 SDK 恢复上下文
    // 避免网络重连和界面渲染撞车导致的内存崩溃
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (g_activeGRPCConnector) {
            #pragma clang diagnostic push
            #pragma clang diagnostic ignored "-Wundeclared-selector"
            if ([g_activeGRPCConnector respondsToSelector:@selector(disConnect)]) {
                [g_activeGRPCConnector performSelector:@selector(disConnect)];
            }
            // 重新平滑握手，同步最新聊天记录
            if ([g_activeGRPCConnector respondsToSelector:@selector(connect)]) {
                [g_activeGRPCConnector performSelector:@selector(connect)];
            }
            #pragma clang diagnostic pop
        }
    });
}
%end
