// BluedPushFix — 终极神经切断与静默保活版
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <UserNotifications/UserNotifications.h>

// 1. 无声音频字节码 (绝对防系统底层 5 秒强杀)
unsigned char silent_mp3[] = {
  0xFF, 0xFB, 0x90, 0x44, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
};
unsigned int silent_mp3_len = 16;

static UIBackgroundTaskIdentifier bgTask = UIBackgroundTaskInvalid;
static AVAudioPlayer *audioPlayer = nil;
static BOOL isAppActuallyBackground = NO;

// ==========================================
// 1. 统一横幅通知引擎
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
// 2. 核心手术：切断网络层的后台感知
// ==========================================
%hook BDLiveIM
- (void)didReceiveProtoMessage:(id)message {
    if (message) { 
        %orig(message); 
        fireLocalBannerNotification(); 
    } else { 
        %orig; 
    }
}
// 【阻断一】：不让 IM 知道进后台了，防止它主动断开 Socket
- (void)p_didEnterBackground:(id)arg {
    // 吞掉！不执行 %orig
}
// 【阻断二】：如果它强行想断开，直接拦住
- (void)disConnect {
    if (isAppActuallyBackground) return; 
    %orig;
}
%end

%hook BDgRPCConnector
// 【阻断三】：不让全局 gRPC 连接器知道进后台了（对应报告发现）
- (void)p_appDidEnterBackground:(id)notification {
    // 吞掉！不执行 %orig
}
+ (void)disConnect {
    // 阻止全局静态断开
}
%end

// 个推底层拦截
%hook GXPushManager
- (void)GXPushManagerDidReceivePayloadData:(NSData *)d taskId:(NSString *)t msgId:(NSString *)m offLine:(BOOL)o appId:(NSString *)a {
    %orig; 
    fireLocalBannerNotification();
}
%end

%hook GXSocketConnectModule
// 【阻断四】：拦截个推底层的强制断连
- (void)disConnect { if (isAppActuallyBackground) return; %orig; }
- (void)closeSocket { if (isAppActuallyBackground) return; %orig; }
%end

// ==========================================
// 3. 绝对同步保活引擎 (防系统强杀)
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
// 4. 生命周期调度 (去掉恶心的重连)
// ==========================================
%hook AppDelegate
- (void)applicationDidEnterBackground:(UIApplication *)application {
    isAppActuallyBackground = YES;
    startSyncKeepAlive(); 
    %orig; // 允许UI和数据库进后台，但网络层已经被我们上面切断了感知
}

- (void)applicationWillEnterForeground:(UIApplication *)application {
    isAppActuallyBackground = NO;
    %orig;
    // 删除了所有强制断开和重连的代码！
    // 只要系统没把 App 杀掉，网络就是一直连着的，进去瞬间秒开，再也不会有“收取中...”
}
%end
