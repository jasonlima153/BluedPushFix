// BluedPushFix — 终极暴力欺骗版 (God Mode)
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <UserNotifications/UserNotifications.h>

// 直接硬编码 0.1秒的无声音频，杜绝任何外部文件找不到的问题
unsigned char silent_mp3[] = {
  0xFF, 0xFB, 0x90, 0x44, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
};
unsigned int silent_mp3_len = 16;

static UIBackgroundTaskIdentifier bgTask = UIBackgroundTaskInvalid;
static AVAudioPlayer *audioPlayer = nil;
static BOOL isAppActuallyBackground = NO;

// ==========================================
// 1. 绝对同步的底层免死金牌
// ==========================================
void startGodModeKeepAlive() {
    // 强制锁住后台运行时间
    if (bgTask == UIBackgroundTaskInvalid) {
        bgTask = [[UIApplication sharedApplication] beginBackgroundTaskWithExpirationHandler:^{
            [[UIApplication sharedApplication] endBackgroundTask:bgTask];
            bgTask = UIBackgroundTaskInvalid;
        }];
    }
    
    // 必须同步执行音频霸占，绝不能用 dispatch_async
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
// 2. 核心黑客手段：瞎子模式 (状态欺骗)
// ==========================================
// 拦截全局系统广播，不让 App 内部的任何 SDK 知道自己进后台了
%hook NSNotificationCenter
- (void)postNotificationName:(NSNotificationName)aName object:(id)anObject userInfo:(NSDictionary *)aUserInfo {
    if ([aName isEqualToString:UIApplicationDidEnterBackgroundNotification] ||
        [aName isEqualToString:UIApplicationWillResignActiveNotification]) {
        // 当系统宣告进后台时，我们把通知吞掉（DROP!）
        // 这样个推、gRPC 就永远不会触发断开连接的逻辑！
        return; 
    }
    %orig;
}
%end

// 欺骗全局状态：谁来问，都告诉它"老子在前台活跃着呢"
%hook UIApplication
- (UIApplicationState)applicationState {
    return UIApplicationStateActive;
}
%end

// ==========================================
// 3. 拦截横幅通知
// ==========================================
void fireLocalBannerNotification(NSString *title, NSString *body) {
    if (!isAppActuallyBackground) return; 
    
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        UNMutableNotificationContent *content = [[UNMutableNotificationContent alloc] init];
        content.title = title;
        content.body = body;
        content.sound = [UNNotificationSound defaultSound];
        
        UNTimeIntervalNotificationTrigger *trigger = [UNTimeIntervalNotificationTrigger triggerWithTimeInterval:0.1 repeats:NO];
        UNNotificationRequest *request = [UNNotificationRequest requestWithIdentifier:@"PushNotify" content:content trigger:trigger];
        [[UNUserNotificationCenter currentNotificationCenter] addNotificationRequest:request withCompletionHandler:nil];
    });
}

%hook BDLiveIM
- (void)didReceiveProtoMessage:(id)message {
    if (message) { %orig(message); fireLocalBannerNotification(@"互动通知", @"直播间或派对有新的动态"); } else { %orig; }
}
%end

%hook GXPushManager
- (void)GXPushManagerDidReceivePayloadData:(NSData *)d taskId:(NSString *)t msgId:(NSString *)m offLine:(BOOL)o appId:(NSString *)a {
    %orig; fireLocalBannerNotification(@"新消息", @"您收到了一条新的聊天消息");
}
%end

// ==========================================
// 4. 生命线的最后把控
// ==========================================
%hook AppDelegate
- (void)applicationDidEnterBackground:(UIApplication *)application {
    isAppActuallyBackground = YES;
    startGodModeKeepAlive(); // 抢在系统前面拉起保护罩
    %orig; 
}
- (void)applicationWillEnterForeground:(UIApplication *)application {
    isAppActuallyBackground = NO;
    %orig;
}
%end
