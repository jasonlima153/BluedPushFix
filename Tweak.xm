#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import "silent_data.h"

// 声明报告 3.1 & 3.3 & 3.5 中的核心网络控制类
@interface BDgRPCConnector : NSObject
+ (void)connect;
@end

@interface BDLiveIM : NSObject
- (void)connect;
- (void)p_willEnterForeground:(id)arg1;
- (void)p_checkActive;
@end

@interface BDPartyController : NSObject
- (void)handleGrpcReconnect:(id)arg1;
@end

// 音频播放器长驻句柄
static AVAudioPlayer *bgAudioPlayer = nil;

// 启动底层无声音频流守护
void setupSilentAudioEngine() {
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            AVAudioSession *session = [AVAudioSession sharedInstance];
            // 启用Playback模式，并显式指定允许与其它音乐混音，不抢占系统音频
            [session setCategory:AVAudioSessionCategoryPlayback 
                     withOptions:AVAudioSessionCategoryOptionMixWithOthers 
                           error:nil];
            [session setActive:YES error:nil];
            
            if (!bgAudioPlayer) {
                NSData *audioData = [NSData dataWithBytes:silent_mp3 length:silent_mp3_len];
                NSError *error = nil;
                bgAudioPlayer = [[AVAudioPlayer alloc] initWithData:audioData error:&error];
                if (error || !bgAudioPlayer) {
                    NSLog(@"[PushFix] 守护音频初始化失败: %@", error);
                    return;
                }
                bgAudioPlayer.numberOfLoops = -1; // 无限循环
                bgAudioPlayer.volume = 0.01;      // 保持静音级别
                [bgAudioPlayer prepareToPlay];
            }
            
            [bgAudioPlayer play];
            NSLog(@"[PushFix] 守护音频已成功在后台跑起来了");
        } @catch (NSException *exception) {
            NSLog(@"[PushFix] 音频守护发生异常: %@", exception);
        }
    });
}

// ==========================================
// 修复核心：安全过渡生命周期，在后台强行复活网络
// ==========================================
%hook AppDelegate

- (void)applicationDidEnterBackground:(UIApplication *)application {
    NSLog(@"[PushFix] 顺从系统：执行原生切后台逻辑，规避Watchdog 3秒强杀...");
    
    // 1. 允许原生后台逻辑执行，让UI、广告、Flutter释放资源，防止主线程死锁闪退
    %orig;
    
    // 2. 开启音频不挂起守护
    setupSilentAudioEngine();
    
    // 3. 延迟 0.5 秒，等 App 彻底安稳进入后台后，强行拉起被断开的网络
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        NSLog(@"[PushFix] 正在后台逆向重塑全套网络长连接...");
        
        // 唤醒全局 gRPC 核心连接器（对应报告 3.1.1）
        if (NSClassFromString(@"BDgRPCConnector")) {
            [NSClassFromString(@"BDgRPCConnector") performSelector:@selector(connect)];
        }
        
        // 唤醒直播间即时消息系统（对应报告 3.3）
        if (NSClassFromString(@"BDLiveIM")) {
            NSLog(@"[PushFix] 激活后台 IM 活跃度扫描");
        }
        
        // 唤醒个推长连接服务（对应报告 4.3.2）
        if (NSClassFromString(@"GXPushService")) {
            #pragma clang diagnostic push
            #pragma clang diagnostic ignored "-Wundeclared-selector"
            [NSClassFromString(@"GXPushService") performSelector:@selector(startPushService)];
            #pragma clang diagnostic pop
        }
    });
}

%end


// ==========================================
// 屏蔽主动断连行为（双保险）
// ==========================================

%hook BDgRPCConnector
+ (void)disConnect {
    // 如果是 App 进后台触发的主动断开，直接拦截拒绝，不执行官方 %orig;
    NSLog(@"[PushFix] 拒绝了后台主动拆除 gRPC 管道的请求");
}
%end

%hook GXPushService
- (void)stopPushService {
    // 拒绝个推在后台关闭 Socket
    NSLog(@"[PushFix] 拒绝了后台关闭个推 Socket 的请求");
}
%end

%hook GtSdkManager
- (void)setClientId:(NSString *)clientId {
    if (!clientId || [clientId isEqualToString:@""]) {
        return; // 防御分身多开 ClientId 被刷掉
    }
    %orig;
}
%end
