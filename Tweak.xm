// BluedPushFix — V5 防冲突与异步解耦终极版
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
// 1. 本地横幅通知 (异步安全队列)
// ==========================================
void fireLocalBannerNotification(NSString *title, NSString *body) {
    if (!g_isBackground) return; 
    
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
// 2. 实例捕获与底层解耦拦截 (避开 BluedHook 冲突区域)
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
    if (message) {
        %orig(message);
        fireLocalBannerNotification(@"互动通知", @"直播间或派对有新的动态");
    } else {
        %orig;
    }
}
%end

// 【核心修复】：彻底废弃 GJIMSessionService 的双重 Hook！
// 转而在个推底层接口拦截 Payload 数据，这里 BluedHook 触碰不到，绝对安全
%hook GXPushManager
- (void)GXPushManagerDidReceivePayloadData:(NSData *)data 
                                    taskId:(NSString *)taskId 
                                     msgId:(NSString *)msgId 
                                   offLine:(BOOL)offLine 
                                     appId:(NSString *)appId {
    %orig; // 让个推原生服务正常消化数据
    // 触发安全横幅
    fireLocalBannerNotification(@"新消息", @"您收到了一条新的聊天消息");
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
// 4. 生命周期平滑过渡防 ANR
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
    
    // 留出 1.5 秒的安全缓冲带，让被冻结的 UI 层彻底苏醒，防止网络重连冲垮主线程
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (g_activeGRPCConnector) {
            #pragma clang diagnostic push
            #pragma clang diagnostic ignored "-Wundeclared-selector"
            if ([g_activeGRPCConnector respondsToSelector:@selector(disConnect)]) {
                [g_activeGRPCConnector performSelector:@selector(disConnect)];
            }
            if ([g_activeGRPCConnector respondsToSelector:@selector(connect)]) {
                [g_activeGRPCConnector performSelector:@selector(connect)];
            }
            #pragma clang diagnostic pop
        }
    });
}
%end
