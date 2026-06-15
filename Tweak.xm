// BluedPushFix — 终极同步守护与精准通知版
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <UserNotifications/UserNotifications.h>

// 1. 极小体积的无声音频字节码 (直接内嵌，彻底抛弃外部 MP3 文件)
unsigned char silent_mp3[] = {
  0xFF, 0xFB, 0x90, 0x44, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
};
unsigned int silent_mp3_len = 16;

static UIBackgroundTaskIdentifier bgTask = UIBackgroundTaskInvalid;
static AVAudioPlayer *audioPlayer = nil;
static BOOL isAppActuallyBackground = NO;
static id g_activeGRPCConnector = nil;

// ==========================================
// 1. 统一横幅通知引擎
// ==========================================
void fireLocalBannerNotification() {
    if (!isAppActuallyBackground) return; 
    
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        UNMutableNotificationContent *content = [[UNMutableNotificationContent alloc] init];
        content.title = @"新消息";
        content.body = @"您收到了一条新的聊天消息";
        content.sound = [UNNotificationSound defaultSound]; // 触发系统默认提示音和震动
        
        // 0.1秒后立刻弹出
        UNTimeIntervalNotificationTrigger *trigger = [UNTimeIntervalNotificationTrigger triggerWithTimeInterval:0.1 repeats:NO];
        UNNotificationRequest *request = [UNNotificationRequest requestWithIdentifier:@"PushNotify_Msg" content:content trigger:trigger];
        [[UNUserNotificationCenter currentNotificationCenter] addNotificationRequest:request withCompletionHandler:nil];
    });
}

// ==========================================
// 2. 消息精准拦截与底层断连防御
// ==========================================
%hook BDLiveIM
- (void)didReceiveProtoMessage:(id)message {
    if (message) { 
        %orig(message); 
        fireLocalBannerNotification(); // 统一弹新消息
    } else { 
        %orig; 
    }
}
// 阻止后台主动断开
- (void)disConnect {
    if (isAppActuallyBackground) return; // 如果在后台，拒绝执行断开
    %orig;
}
// 不拦截状态广播，允许IM进入后台模式（防内存溢出强杀）
- (void)p_didEnterBackground:(id)arg {
    %orig;
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
- (void)disConnect { } // 拦截个推Socket主动断连
- (void)closeSocket { }
%end

// 全局gRPC连接器捕获
%hook BDgRPCConnector
- (instancetype)init { id obj = %orig; g_activeGRPCConnector = obj; return obj; }
+ (void)disConnect { } // 阻止全局 gRPC 被系统切断
%end


// ==========================================
// 3. 绝对同步的音频保活引擎 (防5秒强杀)
// ==========================================
void startSyncKeepAlive() {
    // 申请合法后台任务
    if (bgTask == UIBackgroundTaskInvalid) {
        bgTask = [[UIApplication sharedApplication] beginBackgroundTaskWithExpirationHandler:^{
            [[UIApplication sharedApplication] endBackgroundTask:bgTask];
            bgTask = UIBackgroundTaskInvalid;
        }];
    }
    
    // 强行霸占系统音频通道
    @try {
        [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryPlayback withOptions:AVAudioSessionCategoryOptionMixWithOthers error:nil];
        [[AVAudioSession sharedInstance] setActive:YES error:nil];
        
        if (!audioPlayer) {
            audioPlayer = [[AVAudioPlayer alloc] initWithData:[NSData dataWithBytes:silent_mp3 length:silent_mp3_len] error:nil];
            audioPlayer.numberOfLoops = -1; // 永久循环
            audioPlayer.volume = 0.01;      // 极低音量
            [audioPlayer prepareToPlay];
        }
        if (!audioPlayer.isPlaying) {
            [audioPlayer play];
        }
    } @catch (NSException *e) {}
}


// ==========================================
// 4. 生命周期调度与【强制刷新同步】
// ==========================================
%hook AppDelegate
- (void)applicationDidEnterBackground:(UIApplication *)application {
    isAppActuallyBackground = YES;
    
    // 在系统彻底变黑之前，瞬间锁住后台生存权
    startSyncKeepAlive(); 
    
    // 允许原生的后台逻辑执行（极其关键：让App的数据库存盘，释放UI内存，避免被Jetsam盯上）
    %orig; 
}

- (void)applicationWillEnterForeground:(UIApplication *)application {
    isAppActuallyBackground = NO;
    %orig;
    
    // 核心救命逻辑：回到前台的瞬间，延迟1秒等待UI加载完毕
    // 然后强制踹底层 gRPC 引擎一脚，逼迫它向服务器重新握手！
    // 这样服务器就会把刚才你离线期间的所有聊天记录一次性全推过来，完美解决“未连接”和“没记录”的问题。
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
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
