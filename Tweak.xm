#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>

// ==========================================
// 1. 引入由 GitHub 自动化工具生成的 C 数组头文件
// ==========================================
#import "silent_data.h"

// 声明应用内核心 gRPC 与 IM 类（对接报告 3.1 & 3.3 & 3.5 节）
@interface BDgRPCConnector : NSObject
+ (void)disConnect;
@end

@interface BDLiveIM : NSObject
- (void)connect;
- (void)disConnect;
- (void)p_checkActive;
@end

@interface BDPartyController : NSObject
- (void)handleGrpcReconnect:(id)arg1;
- (void)handleGrpcDisconnect:(id)arg1;
@end

@interface GXPushService : NSObject
- (void)stopPushService;
- (void)startPushService;
@end

@interface GtSdkManager : NSObject
- (void)setClientId:(NSString *)clientId;
@end


// ==========================================
// 2. 内存音频保活核心逻辑（C 数组内存加载方案）
// ==========================================
static AVAudioPlayer *globalAudioPlayer = nil;

void triggerAudioKeepAlive() {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSError *sessionError = nil;
        AVAudioSession *session = [AVAudioSession sharedInstance];
        
        // 强制设置为后台播放模式，允许与其他应用混音（不打扰用户）
        [session setCategory:AVAudioSessionCategoryPlayback 
                 withOptions:AVAudioSessionCategoryOptionMixWithOthers 
                       error:&sessionError];
        [session setActive:YES error:&sessionError];
        
        if (sessionError) {
            NSLog(@"[PushFix] AVAudioSession 配置失败: %@", sessionError);
            return;
        }

        // 100% 纯内存加载，避开 iOS 文件系统权限与多开路径变化雷区
        NSData *audioData = [NSData dataWithBytes:silent_mp3 length:silent_mp3_len];
        NSError *audioError = nil;
        
        globalAudioPlayer = [[AVAudioPlayer alloc] initWithData:audioData error:&audioError];
        if (!audioError && globalAudioPlayer) {
            globalAudioPlayer.numberOfLoops = -1; // 无限循环
            globalAudioPlayer.volume = 0.02;      // 保持极低音量
            [globalAudioPlayer prepareToPlay];
            [globalAudioPlayer play];
            NSLog(@"[PushFix] 纯内存无声音频长驻守护启动成功！");
        } else {
            NSLog(@"[PushFix] 内存音频初始化失败: %@", audioError);
        }
    });
}


// ==========================================
// 3. 业务长连接深度 Hook 守护
// ==========================================

// 拦截全局 gRPC 进后台主动断开
%hook BDgRPCConnector
+ (void)disConnect {
    NSLog(@"[PushFix] 拦截到全局 gRPC [disConnect] 行为，强制保持连接。");
    // 拒绝执行 %orig; 维持连接不中断
}
%end

// 拦截直播间即时消息断连
%hook BDLiveIM
- (void)p_didEnterBackground:(id)arg1 {
    NSLog(@"[PushFix] 拦截 BDLiveIM 进入后台的主动断连");
    // 不调用 %orig; 阻止其执行内部的断开逻辑
    [self p_checkActive]; // 保持活跃检测
}

- (void)disConnect {
    NSLog(@"[PushFix] 拦截到 BDLiveIM 异常断开，正在强制触发重连...");
    [self connect]; 
}
%end

// 拦截派对/群组即时消息断连
%hook BDPartyController
- (void)handleGrpcDisconnect:(id)arg1 {
    NSLog(@"[PushFix] 拦截到派对系统断开，强制转回重连：handleGrpcReconnect");
    [self handleGrpcReconnect:arg1]; 
}
%end

// 拦截个推 SDK 停止行为（对应报告 4.3.2 节）
%hook GXPushService
- (void)stopPushService {
    NSLog(@"[PushFix] 拦截个推 [stopPushService]，拒绝关闭 Socket 隧道");
    // 拒绝执行原生停止
}
%end

// 防止个推多开分身时 ClientId 被置空丢失（对应报告 4.3.3 节）
%hook GtSdkManager
- (void)setClientId:(NSString *)clientId {
    if (!clientId || [clientId isEqualToString:@""]) {
        NSLog(@"[PushFix] 拦截到 GtSdkManager 试图置空 ClientId 的异常行为");
        return; 
    }
    %orig;
}
%end

// 生命周期切入点
%hook AppDelegate
- (void)applicationDidEnterBackground:(UIApplication *)application {
    %orig;
    NSLog(@"[PushFix] 监听到 App 切后台，正在将长连接网络注入内存守护状态...");
    triggerAudioKeepAlive();
}
%end
