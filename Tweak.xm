// BluedPushFix — 终极防闪退与业务层拦截版
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <UserNotifications/UserNotifications.h>
#import <AudioToolbox/AudioToolbox.h>

NSData* generateStandardSilentWAV() {
    int sampleRate = 16000;
    int duration = 2; 
    int numSamples = sampleRate * duration;
    int dataSize = numSamples * 2; 
    int fileSize = 36 + dataSize;
    
    NSMutableData *wav = [NSMutableData dataWithCapacity:fileSize + 8];
    [wav appendBytes:"RIFF" length:4];
    [wav appendBytes:&fileSize length:4];
    [wav appendBytes:"WAVE" length:4];
    [wav appendBytes:"fmt " length:4];
    int fmtSize = 16; [wav appendBytes:&fmtSize length:4];
    short audioFormat = 1; [wav appendBytes:&audioFormat length:2];
    short numChannels = 1; [wav appendBytes:&numChannels length:2];
    [wav appendBytes:&sampleRate length:4];
    int byteRate = sampleRate * 2; [wav appendBytes:&byteRate length:4];
    short blockAlign = 2; [wav appendBytes:&blockAlign length:2];
    short bitsPerSample = 16; [wav appendBytes:&bitsPerSample length:2];
    [wav appendBytes:"data" length:4];
    [wav appendBytes:&dataSize length:4];
    
    NSMutableData *zeros = [NSMutableData dataWithLength:dataSize];
    [wav appendData:zeros];
    return wav;
}

static UIBackgroundTaskIdentifier bgTask = UIBackgroundTaskInvalid;
static AVAudioPlayer *audioPlayer = nil;
static BOOL isAppActuallyBackground = NO;
static NSTimeInterval lastNotifyTime = 0;

static id g_activeWatchdog = nil;
static id g_activeGRPCConnector = nil;
static dispatch_source_t g_heartbeatTimer = NULL;

// ==========================================
// 1. 横幅通知与震动 (安全触发)
// ==========================================
void fireLocalBannerNotification(NSString *title, NSString *body) {
    if (!isAppActuallyBackground) return; 
    
    // 防刷屏
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    if (now - lastNotifyTime < 2.0) return;
    lastNotifyTime = now;
    
    // 安全地请求一次通知权限，不碰启动生命周期
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        [[UNUserNotificationCenter currentNotificationCenter] requestAuthorizationWithOptions:(UNAuthorizationOptionAlert | UNAuthorizationOptionSound | UNAuthorizationOptionBadge) completionHandler:^(BOOL granted, NSError * _Nullable error) {}];
    });
    
    dispatch_async(dispatch_get_main_queue(), ^{
        UNMutableNotificationContent *content = [[UNMutableNotificationContent alloc] init];
        content.title = title;
        content.body = body;
        content.sound = [UNNotificationSound defaultSound];
        
        NSString *notifyId = [NSString stringWithFormat:@"Push_%f", now];
        UNTimeIntervalNotificationTrigger *trigger = [UNTimeIntervalNotificationTrigger triggerWithTimeInterval:0.1 repeats:NO];
        UNNotificationRequest *request = [UNNotificationRequest requestWithIdentifier:notifyId content:content trigger:trigger];
        [[UNUserNotificationCenter currentNotificationCenter] addNotificationRequest:request withCompletionHandler:nil];
        
        if (@available(iOS 10.0, *)) {
            UIImpactFeedbackGenerator *feedback = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleHeavy];
            [feedback prepare];
            [feedback impactOccurred];
        } else {
            AudioServicesPlaySystemSound(kSystemSoundID_Vibrate);
        }
    });
}

// ==========================================
// 2. 业务层私聊拦截 (绝对精准，不弹自己)
// ==========================================
%hook GJIMSessionService
- (void)p_handlePushPackage:(id)arg1 {
    %orig; // 极简调用，防止参数解析导致闪退
    fireLocalBannerNotification(@"新消息", @"您收到了一条新的聊天消息");
}
%end

%hook GXPushManager
- (void)GXPushManagerDidReceivePayloadData:(NSData *)d taskId:(NSString *)t msgId:(NSString *)m offLine:(BOOL)o appId:(NSString *)a {
    %orig; 
    fireLocalBannerNotification(@"系统通知", @"您收到了一条系统消息");
}
%end

// ==========================================
// 3. 网络瞎子模式 (只断感知，不碰业务)
// ==========================================
%hook BDLiveIM
- (void)p_didEnterBackground:(id)arg { /* 吞掉 */ }
- (void)disConnect { if (isAppActuallyBackground) return; %orig; }
%end

%hook GXSocketConnectModule
- (void)disConnect { if (isAppActuallyBackground) return; %orig; }
- (void)closeSocket { if (isAppActuallyBackground) return; %orig; }
%end

// ==========================================
// 4. 起搏器与音频霸权
// ==========================================
%hook GXWatchdog
- (instancetype)init { id obj = %orig; g_activeWatchdog = obj; return obj; }
%end

%hook BDgRPCConnector
- (instancetype)init { id obj = %orig; g_activeGRPCConnector = obj; return obj; }
- (void)p_appDidEnterBackground:(id)notification { /* 吞掉 */ }
+ (void)disConnect { }
%end

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

void startSyncKeepAlive() {
    if (bgTask == UIBackgroundTaskInvalid) {
        bgTask = [[UIApplication sharedApplication] beginBackgroundTaskWithExpirationHandler:^{
            [[UIApplication sharedApplication] endBackgroundTask:bgTask];
            bgTask = UIBackgroundTaskInvalid;
        }];
    }
    
    @try {
        [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryPlayback withOptions:AVAudioSessionCategoryOptionMixWithOthers error:nil];
        [[AVAudioSession sharedInstance] setActive:YES error:nil];
        
        if (!audioPlayer) {
            NSError *err = nil;
            audioPlayer = [[AVAudioPlayer alloc] initWithData:generateStandardSilentWAV() error:&err];
            if (audioPlayer) {
                audioPlayer.numberOfLoops = -1;
                audioPlayer.volume = 0.01;
                [audioPlayer prepareToPlay];
            }
        }
        if (audioPlayer && !audioPlayer.isPlaying) [audioPlayer play];
    } @catch (NSException *e) {}
    
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
// 5. 生命周期 (回归最稳定的三个钩子，杜绝闪退)
// ==========================================
%hook AppDelegate
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
