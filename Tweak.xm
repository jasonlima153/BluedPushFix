// BluedPushFix — 终极防冻结 (修复音频初始化 10秒必死 Bug)
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <UserNotifications/UserNotifications.h>

// ✨ 修复核心：生成绝对合法的 1秒静音 WAV 音频数据
NSData* generateSilentWAV() {
    unsigned char wavHeader[] = {
        0x52, 0x49, 0x46, 0x46, 0x26, 0x00, 0x00, 0x00, // RIFF Chunk
        0x57, 0x41, 0x56, 0x45, 0x66, 0x6d, 0x74, 0x20, // WAVE fmt
        0x10, 0x00, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00, // Format (PCM, Mono)
        0x44, 0xAC, 0x00, 0x00, 0x88, 0x58, 0x01, 0x00, // 44100 Hz
        0x02, 0x00, 0x10, 0x00, 0x64, 0x61, 0x74, 0x61, // data chunk
        0x02, 0x00, 0x00, 0x00, 0x00, 0x00              // 1 sample of silence
    };
    return [NSData dataWithBytes:wavHeader length:sizeof(wavHeader)];
}

static UIBackgroundTaskIdentifier bgTask = UIBackgroundTaskInvalid;
static AVAudioPlayer *audioPlayer = nil;
static BOOL isAppActuallyBackground = NO;

// 实例捕获
static id g_activeGRPCConnector = nil;
static id g_activeWatchdog = nil;
static dispatch_source_t g_heartbeatTimer = NULL;

// ==========================================
// 1. 本地横幅通知引擎
// ==========================================
void fireLocalBannerNotification() {
    if (!isAppActuallyBackground) return;

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        UNMutableNotificationContent *content = [[UNMutableNotificationContent alloc] init];
        content.title = @"新消息";
        content.body = @"您收到了一条新的聊天消息";
        content.sound = [UNNotificationSound defaultSound];

        UNTimeIntervalNotificationTrigger *trigger = [UNTimeIntervalNotificationTrigger triggerWithTimeInterval:0.1 repeats:NO];
        UNNotificationRequest *request = [UNNotificationRequest requestWithIdentifier:@"PushNotify_Msg" content:content trigger:trigger];
        [[UNUserNotificationCenter currentNotificationCenter] addNotificationRequest:request withCompletionHandler:nil];
    });
}

// ==========================================
// 2. 拦截与切断网络层后台感知
// ==========================================
%hook BDLiveIM
- (void)didReceiveProtoMessage:(id)message {
    if (message) { %orig(message); fireLocalBannerNotification(); } else { %orig; }
}
- (void)p_didEnterBackground:(id)arg { /* 彻底吞掉 */ }
- (void)disConnect { if (isAppActuallyBackground) return; %orig; }
%end

%hook BDgRPCConnector
- (instancetype)init { id obj = %orig; g_activeGRPCConnector = obj; return obj; }
- (void)p_appDidEnterBackground:(id)notification { /* 彻底吞掉 */ }
+ (void)disConnect { }
%end

%hook GXPushManager
- (void)GXPushManagerDidReceivePayloadData:(NSData *)d taskId:(NSString *)t msgId:(NSString *)m offLine:(BOOL)o appId:(NSString *)a {
    %orig; fireLocalBannerNotification();
}
%end

%hook GXSocketConnectModule
- (void)disConnect { if (isAppActuallyBackground) return; %orig; }
- (void)closeSocket { if (isAppActuallyBackground) return; %orig; }
%end

%hook GXWatchdog
- (instancetype)init { id obj = %orig; g_activeWatchdog = obj; return obj; }
%end

// ==========================================
// 3. 拦截音频总闸 (防止原生代码关声音)
// ==========================================
%hook AVAudioSession
- (BOOL)setActive:(BOOL)active error:(NSError **)outError {
    if (!active && isAppActuallyBackground) return YES;
    return %orig;
}
- (BOOL)setActive:(BOOL)active withOptions:(AVAudioSessionSetActiveOptions)options error:(NSError **)outError {
    if (!active && isAppActuallyBackground) return YES;
    return %orig;
}
%end

// ==========================================
// 4. ✨ 核心保活与起搏器 (修复崩溃点)
// ==========================================
void startSyncKeepAlive() {
    if (bgTask == UIBackgroundTaskInvalid) {
        bgTask = [[UIApplication sharedApplication] beginBackgroundTaskWithExpirationHandler:^{
            [[UIApplication sharedApplication] endBackgroundTask:bgTask];
            bgTask = UIBackgroundTaskInvalid;
        }];
    }

    // 1. 拉起合法音频锁住进程
    @try {
        [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryPlayback withOptions:AVAudioSessionCategoryOptionMixWithOthers error:nil];
        [[AVAudioSession sharedInstance] setActive:YES error:nil];

        if (!audioPlayer) {
            NSError *err = nil;
            // ✨ 这里使用了绝对合法的 WAV 文件流，解决 10秒挂掉的根本原因
            audioPlayer = [[AVAudioPlayer alloc] initWithData:generateSilentWAV() error:&err];
            if (audioPlayer) {
                audioPlayer.numberOfLoops = -1;
                audioPlayer.volume = 0.01;
                [audioPlayer prepareToPlay];
            } else {
                NSLog(@"[PushFix] 音频初始化失败: %@", err);
            }
        }
        if (audioPlayer && !audioPlayer.isPlaying) {
            [audioPlayer play];
        }
    } @catch (NSException *e) {}

    // 2. GCD 起搏器：防服务器踢人
    if (!g_heartbeatTimer) {
        g_heartbeatTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0));
        dispatch_source_set_timer(g_heartbeatTimer, dispatch_time(DISPATCH_TIME_NOW, 20 * NSEC_PER_SEC), 20 * NSEC_PER_SEC, 1 * NSEC_PER_SEC);
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
// 5. 生命周期调度与通知授权
// ==========================================
%hook AppDelegate
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    [[UNUserNotificationCenter currentNotificationCenter] requestAuthorizationWithOptions:(UNAuthorizationOptionAlert | UNAuthorizationOptionSound | UNAuthorizationOptionBadge) completionHandler:^(BOOL granted, NSError * _Nullable error) {}];
    return %orig;
}

- (void)applicationWillResignActive:(UIApplication *)application {
    isAppActuallyBackground = YES;
    startSyncKeepAlive();
    %orig;
}

- (void)applicationDidEnterBackground:(UIApplication *)application {
    isAppActuallyBackground = YES;
    %orig;
}

- (void)applicationWillEnterForeground:(UIApplication *)application {
    isAppActuallyBackground = NO;
    %orig;
}
%end
