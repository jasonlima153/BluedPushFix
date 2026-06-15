// BluedPushFix — 底层核心网络守护版
// Target: Blued极速版2 (com.danlan.xiaolAn)

#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <UserNotifications/UserNotifications.h>
#import <dispatch/dispatch.h>
#import <CFNetwork/CFNetwork.h>
#import <sys/socket.h>
#import "silent_data.h"

// ==========================================
// 全局单例/活体实例追踪器（修复报告原代码的致命错误）
// ==========================================
static id g_activeWatchdog = nil;
static id g_activeLiveIM = nil;
static id g_activeGRPCConnector = nil;

// 状态控制
static BOOL g_isBackground = NO;
static AVAudioPlayer *bgAudioPlayer = nil;
static dispatch_source_t g_heartbeatTimer = NULL;
static dispatch_queue_t g_heartbeatQueue = NULL;

// ==========================================
// 策略三：VoIP 底层 Socket 标记 (PushKit 滥用)
// 赋予 C 底层 Socket 最高级别的后台网络存活优先级
// ==========================================
void markSocketAsVoIP(int socketFD) {
    CFReadStreamRef readStream = NULL;
    CFWriteStreamRef writeStream = NULL;
    CFStreamCreatePairWithSocket(kCFAllocatorDefault, socketFD, &readStream, &writeStream);
    
    if (readStream) {
        CFReadStreamSetProperty(readStream, kCFStreamNetworkServiceType, kCFStreamNetworkServiceTypeVoIP);
        CFReadStreamOpen(readStream);
        CFRelease(readStream); // 修复报告遗漏的内存泄露
    }
    if (writeStream) {
        CFWriteStreamSetProperty(writeStream, kCFStreamNetworkServiceType, kCFStreamNetworkServiceTypeVoIP);
        CFWriteStreamOpen(writeStream);
        CFRelease(writeStream); // 修复报告遗漏的内存泄露
    }
}

// 拦截系统底层的 connect 函数
%hookf(int, connect, int sockfd, const struct sockaddr *addr, socklen_t addrlen) {
    int result = %orig(sockfd, addr, addrlen);
    if (result == 0) {
        markSocketAsVoIP(sockfd);
    }
    return result;
}

// ==========================================
// 策略二：GCD 定时器强力心跳 (无视 NSTimer 冻结)
// ==========================================
void setupGCDHeartbeat() {
    if (!g_heartbeatQueue) {
        g_heartbeatQueue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0);
    }
    if (!g_heartbeatTimer) {
        g_heartbeatTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, g_heartbeatQueue);
        // 设置每 5 秒一次高频心跳冲击
        dispatch_source_set_timer(g_heartbeatTimer, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC), 5 * NSEC_PER_SEC, 1 * NSEC_PER_SEC);
        
        dispatch_source_set_event_handler(g_heartbeatTimer, ^{
            @try {
                // 1. 电击个推底层 Socket
                if (g_activeWatchdog) {
                    #pragma clang diagnostic push
                    #pragma clang diagnostic ignored "-Wundeclared-selector"
                    [g_activeWatchdog performSelector:@selector(watchdogNeedHeartBeat)];
                    #pragma clang diagnostic pop
                }
                
                // 2. 电击 BDLiveIM 活跃度检测
                if (g_activeLiveIM) {
                    #pragma clang diagnostic push
                    #pragma clang diagnostic ignored "-Wundeclared-selector"
                    [g_activeLiveIM performSelector:@selector(p_checkActive)];
                    #pragma clang diagnostic pop
                }
                
                // 3. 电击全局 gRPC Ping 服务器
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
// 策略一：实例捕获与底层阻断
// ==========================================

// 1. 个推看门狗拦截
%hook GXWatchdog
- (instancetype)init {
    id obj = %orig;
    g_activeWatchdog = obj; // 捕获真实活体句柄
    return obj;
}
- (void)watchdogNeedHeartBeat {
    // 强制接管心跳，拒绝执行 %orig 以避开底层 NSTimer 的挂起限制
    #pragma clang diagnostic push
    #pragma clang diagnostic ignored "-Wundeclared-selector"
    id channel = [g_activeWatchdog performSelector:@selector(channel)];
    if (channel) {
        [channel performSelector:@selector(sendHeartbeatData)];
    }
    #pragma clang diagnostic pop
}
%end

// 2. 阻断个推核心 Socket 主动断开
%hook GXSocketConnectModule
- (void)disConnect { }
- (void)closeSocket { }
%end
%hook GXPushService
- (void)stopPushService { }
%end

// 3. 捕获 BDLiveIM 引擎并阻止后台休眠
%hook BDLiveIM
- (instancetype)init {
    id obj = %orig;
    g_activeLiveIM = obj; // 捕获真实活体句柄
    return obj;
}
- (void)disConnect {
    if (g_isBackground) return; // 后台模式下死锁保护
    %orig;
}
- (void)p_didEnterBackground:(id)notification {
    // 不执行 %orig，彻底阻止 IM 断联休眠
}
%end

// 4. 捕获全局 gRPC 连接器
%hook BDgRPCConnector
- (instancetype)init {
    id obj = %orig;
    g_activeGRPCConnector = obj; // 捕获真实活体句柄
    return obj;
}
+ (void)disConnect { }
%end

// ==========================================
// 内存音频兜底：防 Jetsam 杀后台 (P2级别)
// ==========================================
void setupSilentAudioEngine() {
    dispatch_async(dispatch_get_main_queue(), ^{
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
// 顺从 AppDelegate 生命周期 (防 Watchdog)
// ==========================================
%hook AppDelegate
- (void)applicationDidEnterBackground:(UIApplication *)application {
    g_isBackground = YES;
    %orig; // 必须调用，让 UI 正常卸载，躲避 Watchdog 的 3 秒强杀机制
    
    setupSilentAudioEngine();
    setupGCDHeartbeat();
}
- (void)applicationWillEnterForeground:(UIApplication *)application {
    g_isBackground = NO;
    %orig;
}
%end

// ==========================================
// 策略四：底层消息拦截与本地横幅伪造 (无视 APNs 证书)
// ==========================================

// 封装发送本地通知的方法
void fireLocalBannerNotification(NSString *title, NSString *body) {
    // 只有在后台才弹横幅，前台聊天时不弹
    if (!g_isBackground) return; 
    
    dispatch_async(dispatch_get_main_queue(), ^{
        UNMutableNotificationContent *content = [[UNMutableNotificationContent alloc] init];
        content.title = title;
        content.body = body;
        content.sound = [UNNotificationSound defaultSound]; // 触发系统默认提示音
        
        // 0.1秒后立刻弹出
        UNTimeIntervalNotificationTrigger *trigger = [UNTimeIntervalNotificationTrigger triggerWithTimeInterval:0.1 repeats:NO];
        NSString *reqId = [NSString stringWithFormat:@"PushFix_%f", [[NSDate date] timeIntervalSince1970]];
        UNNotificationRequest *request = [UNNotificationRequest requestWithIdentifier:reqId content:content trigger:trigger];
        
        [[UNUserNotificationCenter currentNotificationCenter] addNotificationRequest:request withCompletionHandler:nil];
        NSLog(@"[PushFix] 拦截到新消息，已强行触发本地横幅通知！");
    });
}

// 1. 拦截普通聊天消息包 (对应报告中的 GJIMSessionService)
%hook GJIMSessionService
- (void)p_handlePushPackage:(id)arg1 {
    %orig; // 让 App 正常处理聊天数据
    
    // 我们不知道具体是谁发来的，统一弹出一个安全的提示
    fireLocalBannerNotification(@"新消息", @"您收到了一条新的聊天消息");
}
%end

// 2. 拦截直播间/派对/gRPC 推送包 (对应报告中的 BDLiveIM)
%hook BDLiveIM
- (void)didReceiveProtoMessage:(id)message {
    %orig;
    fireLocalBannerNotification(@"互动通知", @"直播间或派对有新的动态");
}
%end

// 3. 拦截个推底层直接下发的 Payload 数据
%hook GXPushManager
- (void)GXPushManagerDidReceivePayloadData:(NSData *)data 
                                    taskId:(NSString *)taskId 
                                     msgId:(NSString *)msgId 
                                   offLine:(BOOL)offLine 
                                     appId:(NSString *)appId {
    %orig;
    fireLocalBannerNotification(@"系统通知", @"您有新的系统推送消息");
}
%end
