// BluedPushFix — 终极冻结免疫版 (AVAudioSession 霸权)
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <UserNotifications/UserNotifications.h>

unsigned char silent_mp3[] = {
  0xFF, 0xFB, 0x90, 0x44, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
};
unsigned int silent_mp3_len = 16;

static UIBackgroundTaskIdentifier bgTask = UIBackgroundTaskInvalid;
static AVAudioPlayer *audioPlayer = nil;
static BOOL isAppActuallyBackground = NO;

// ==========================================
// 1. 核心反制：没收原生 App 关闭音频的权限
// ==========================================
%hook AVAudioSession
- (BOOL)setActive:(BOOL)active error:(NSError **)outError {
    // 如果 App 在后台，且原生代码试图关闭音频 (active == NO)
    if (!active && isAppActuallyBackground) {
        NSLog(@"[PushFix] 警告：拦截到原生代码试图关闭音频总闸，已强行驳回！");
        return YES; // 欺骗原生代码，假装关闭成功，实际上没关
    }
    return %orig;
}

- (BOOL)setActive:(BOOL)active withOptions:(AVAudioSessionSetActiveOptions)options error:(NSError **)outError {
    if (!active && isAppActuallyBackground) {
        NSLog(@"[PushFix] 警告：拦截到原生代码试图关闭音频总闸(带参数)，已强行驳回！");
        return YES; 
    }
    return %orig;
}
%end

// ==========================================
// 2. 横幅通知引擎
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
// 3. 神经切断：网络层瞎子模式
// ==========================================
%hook BDLiveIM
- (void)didReceiveProtoMessage:(id)message {
    if (message) { %orig(message); fireLocalBannerNotification(); } else { %orig; }
}
- (void)p_didEnterBackground:(id)arg { /* 吞掉 */ }
- (void)disConnect { if (isAppActuallyBackground) return; %orig; }
%end

%hook BDgRPCConnector
- (void)p_appDidEnterBackground:(id)notification { /* 吞掉 */ }
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

// ==========================================
// 4. 同步保活引擎 (提前启动)
// ==========================================
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
            audioPlayer = [[AVAudioPlayer alloc] initWithData:[NSData dataWithBytes:silent_mp3 length:silent_mp3_len] error:nil];
            audioPlayer.numberOfLoops = -1;
            audioPlayer.volume = 0.01;
            [audioPlayer prepareToPlay];
        }
        if (!audioPlayer.isPlaying) {
            [audioPlayer play];
        }
    } @catch (NSException *e) {}
}

// ==========================================
// 5. 生命周期调度
// ==========================================
%hook AppDelegate
// 优化：在 App 刚准备失去焦点（还没完全进后台）时，就提前抢占音频总闸
- (void)applicationWillResignActive:(UIApplication *)application {
    isAppActuallyBackground = YES;
    startSyncKeepAlive();
    %orig;
}

- (void)applicationDidEnterBackground:(UIApplication *)application {
    isAppActuallyBackground = YES;
    // 此时原生 %orig 里面如果有停音乐的代码，会被上面的 AVAudioSession Hook 拦死
    %orig; 
}

- (void)applicationWillEnterForeground:(UIApplication *)application {
    isAppActuallyBackground = NO;
    %orig;
}
%end
