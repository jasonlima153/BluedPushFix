#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import "silent_data.h"

// 声明报告中提到的核心组件状态方法，以便进行强制状态重置
@interface BDLiveIM : NSObject
- (void)connect;
- (void)p_willEnterForeground:(id)arg1;
- (void)p_checkActive;
@end

@interface BDPartyController : NSObject
- (void)handleGrpcReconnect:(id)arg1;
@end

// 音频长驻实例
static AVAudioPlayer *globalAudioPlayer = nil;

// 纯内存音频拉起逻辑，确保进程级别不被 iOS 系统 Suspend
void forceAudioActive() {
    dispatch_async(dispatch_get_main_queue(), ^{
        AVAudioSession *session = [AVAudioSession sharedInstance];
        [session setCategory:AVAudioSessionCategoryPlayback 
                 withOptions:AVAudioSessionCategoryOptionMixWithOthers 
                       error:nil];
        [session setActive:YES error:nil];
        
        NSData *audioData = [NSData dataWithBytes:silent_mp3 length:silent_mp3_len];
        globalAudioPlayer = [[AVAudioPlayer alloc] initWithData:audioData error:nil];
        if (globalAudioPlayer) {
            globalAudioPlayer.numberOfLoops = -1;
            globalAudioPlayer.volume = 0.02;
            [globalAudioPlayer prepareToPlay];
            [globalAudioPlayer play];
            NSLog(@"[PushFix] 内存守护音频已强制长驻。");
        }
    });
}

// ==========================================
// 核心大招：切断 App 的"后台感知"能力
// ==========================================
%hook AppDelegate

- (void)applicationDidEnterBackground:(UIApplication *)application {
    NSLog(@"[PushFix] 警告：系统试图让 App 进后台。执行欺骗防御，阻止后台状态广播！");
    
    // 1. 拒绝调用 %orig; 
    // 彻底掐断系统通知链，App 底层所有的组件（gRPC/Socket）都不会收到断开信号！
    
    // 2. 现场拉起无声音频，确保当前进程在系统层面获得长驻权限
    forceAudioActive();
    
    // 3. 针对报告 3.3 / 3.5 节的核心网络层进行主动保活和状态同步刷新
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        // 强行拉起个推服务（对应报告 4.3.2 节）
        if (NSClassFromString(@"GXPushService")) {
            #pragma clang diagnostic push
            #pragma clang diagnostic ignored "-Wundeclared-selector"
            [NSClassFromString(@"GXPushService") performSelector:@selector(startPushService)];
            #pragma clang diagnostic pop
            NSLog(@"[PushFix] 强制重塑个推 Socket 活跃状态");
        }
    });
}

%end


// ==========================================
// 辅助守护：拦截可能漏网的主动断开行为
// ==========================================

// 拦截报告 3.1 节的全局 gRPC 断开
%hook BDgRPCConnector
+ (void)disConnect {
    NSLog(@"[PushFix] 拦截到漏网的全局 gRPC [disConnect] 行为，予以拒绝。");
    // 拒绝断开
}
%end

// 拦截报告 3.3 节的直播间 IM 后台主动断开行为
%hook BDLiveIM
- (void)p_didEnterBackground:(id)arg1 {
    NSLog(@"[PushFix] 拦截 BDLiveIM 主动认输切后台行为，强制转换其为前台活跃检测");
    [self p_willEnterForeground:arg1]; // 欺骗其转化为前台初始化逻辑
    [self p_checkActive];             // 触发活跃检测
}

- (void)disConnect {
    NSLog(@"[PushFix] 检测到 BDLiveIM 试图释放连接，强行执行重连 connect");
    [self connect];
}
%end

// 拦截报告 3.5 节的群组群控断开
%hook BDPartyController
- (void)handleGrpcDisconnect:(id)arg1 {
    NSLog(@"[PushFix] 检测到派对 gRPC 异常断开，立即调用 handleGrpcReconnect 重连");
    [self handleGrpcReconnect:arg1];
}
%end

// 拦截报告 4.3.2 节个推服务被主动停止
%hook GXPushService
- (void)stopPushService {
    NSLog(@"[PushFix] 拦截个推主动退出请求，保持长连接 Socket 通道");
}
%end
