// BluedPushFix — 稳健后台守护与数据同步修复版
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
// 1. 本地横幅通知 (修复弹窗堆叠)
// ==========================================
void fireLocalBannerNotification(NSString *title, NSString *body) {
    if (!g_isBackground) return; 
    
    dispatch_async(dispatch_get_main_queue(), ^{
        UNMutableNotificationContent *content = [[UNMutableNotificationContent alloc] init];
        content.title = title;
        content.body = body;
        content.sound = [UNNotificationSound defaultSound];
        
        // 使用固定的 Identifier，这样新消息会覆盖老横幅，不会满屏堆叠
        UNTimeIntervalNotificationTrigger *trigger = [UNTimeIntervalNotificationTrigger triggerWithTimeInterval:0.1 repeats:NO];
        UNNotificationRequest *request = [UNNotificationRequest requestWithIdentifier:@"BluedClone_Push" content:content trigger:trigger];
        [[UNUserNotificationCenter currentNotificationCenter] addNotificationRequest:request withCompletionHandler:nil];
    });
}

// ==========================================
// 2. 合法后台申请与音频守护 (防闪退核心)
// ==========================================
void applyLegalBackgroundPrivilege() {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIApplication *app = [UIApplication sharedApplication];
        // 向 iOS 申请合法的后台运行时间
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

// ==========================================
// 3. 柔性心跳 (20秒一次，防系统电量制裁)
// ==========================================
void startGentleHeartbeat() {
    if (!g_heartbeatTimer) {
        g_heartbeatTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0));
        // 将高频 5秒 改为安全的 20秒，大幅降低被系统强杀的概率
        dispatch_source_set_timer(g_heartbeatTimer, dispatch_time(DISPATCH_TIME_NOW, 20 * NSEC_PER_SEC), 20 * NSEC_PER_SEC, 2 * NSEC_PER_SEC);
        dispatch_source_set_event_handler(g_heartbeatTimer, ^{
            @try {
                if (g_activeWatchdog) {
                    #pragma clang diagnostic push
                    #pragma clang diagnostic ignored "-Wundeclared-selector"
                    [g_activeWatchdog performSelector:@selector(watchdogNeedHeartBeat)];
                    #pragma clang diagnostic pop
                }
                if (g_activeGRPCConnector) {
                    #pragma clang diagnostic push
                    #pragma clang diagnostic ignored "-Wundeclared-selector"
                    [g_activeGRPCConnector performSelector:@selector(p_pingServer)];
                    #pragma clang diagnostic pop
                }
            } @catch (NSException *e) {}
        });
        dispatch_resume(g_heartbeatTimer);
    }
}

// ==========================================
// 4. 实例捕获与消息横幅拦截
// ==========================================
%hook GXWatchdog
- (instancetype)init { id obj = %orig; g_activeWatchdog = obj; return obj; }
%end

%hook BDLiveIM
- (instancetype)init { id obj = %orig; g_activeLiveIM = obj; return obj; }
- (void)didReceiveProtoMessage:(id)message {
    %orig;
    fireLocalBannerNotification(@"互动通知", @"直播间或派对有新的动态");
}
%end

%hook BDgRPCConnector
- (instancetype)init { id obj = %orig; g_activeGRPCConnector = obj; return obj; }
%end

%hook GJIMSessionService
- (void)p_handlePushPackage:(id)arg1 {
    %orig;
    fireLocalBannerNotification(@"新消息", @"您收到了一条新的聊天消息");
}
%end

// ==========================================
// 5. 状态机修复：允许断开，前台强刷！
// ==========================================
%hook AppDelegate

- (void)applicationDidEnterBackground:(UIApplication *)application {
    g_isBackground = YES;
    
    // 允许 App 执行原生的后台处理（这会让它的数据库安全存盘，解决记录丢失问题）
    %orig; 
    
    // 然后我们再用合法手段拉起后台权限
    applyLegalBackgroundPrivilege();
    startGentleHeartbeat();
}

- (void)applicationWillEnterForeground:(UIApplication *)application {
    g_isBackground = NO;
    %orig;
    
    // 核心修复：回到前台时，主动掐断原有的 Socket 并强制 App 重新连接！
    // 这将逼迫 App 重新握手服务器，完美拉取你离线期间的所有最新聊天记录！
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (g_activeGRPCConnector) {
            #pragma clang diagnostic push
            #pragma clang diagnostic ignored "-Wundeclared-selector"
            // 先断开
            if ([g_activeGRPCConnector respondsToSelector:@selector(disConnect)]) {
                [g_activeGRPCConnector performSelector:@selector(disConnect)];
            }
            // 逼迫重连拉取数据
            if ([g_activeGRPCConnector respondsToSelector:@selector(connect)]) {
                [g_activeGRPCConnector performSelector:@selector(connect)];
            }
            #pragma clang diagnostic pop
        }
    });
}
%end
