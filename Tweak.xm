// BluedPushFix — 终极去重、防自收、硬件震动版
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <UserNotifications/UserNotifications.h>
#import <AudioToolbox/AudioToolbox.h>

// ✨ 核心修复 1：生成真实的 2秒钟 静音 WAV，彻底解决底层音频停止导致的断网问题
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

// 防抖动时间戳
static NSTimeInterval lastNotifyTime = 0;

// ==========================================
// 1. 精准横幅 + 强制硬件震动
// ==========================================
void fireLocalBannerNotification() {
    if (!isAppActuallyBackground) return; 
    
    // ✨ 核心修复 2：防抖机制，限制最多每 2 秒只允许弹一次，杜绝疯狂刷屏
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    if (now - lastNotifyTime < 2.0) return;
    lastNotifyTime = now;
    
    dispatch_async(dispatch_get_main_queue(), ^{
        UNMutableNotificationContent *content = [[UNMutableNotificationContent alloc] init];
        content.title = @"新消息";
        content.body = @"您收到了一条新的聊天消息";
        content.sound = [UNNotificationSound defaultSound];
        
        // 使用时间戳作为 ID，避免系统覆盖横幅
        NSString *notifyId = [NSString stringWithFormat:@"Push_%f", now];
        UNTimeIntervalNotificationTrigger *trigger = [UNTimeIntervalNotificationTrigger triggerWithTimeInterval:0.1 repeats:NO];
        UNNotificationRequest *request = [UNNotificationRequest requestWithIdentifier:notifyId content:content trigger:trigger];
        [[UNUserNotificationCenter currentNotificationCenter] addNotificationRequest:request withCompletionHandler:nil];
        
        // ✨ 核心修复 3：强制调用手机硬件震动马达
        AudioServicesPlaySystemSound(kSystemSoundID_Vibrate);
    });
}

// ==========================================
// 2. 网络层瞎子模式 (只断感知，不弹杂音)
// ==========================================
%hook BDLiveIM
// ✨ 核心修复 4：去掉了这里的横幅触发！不再把你发的消息、心跳、已读回执当成新消息！
- (void)didReceiveProtoMessage:(id)message { %orig; }
- (void)p_didEnterBackground:(id)arg { /* 吞掉进后台感知 */ }
- (void)disConnect { if (isAppActuallyBackground) return; %orig; }
%end

%hook BDgRPCConnector
- (void)p_appDidEnterBackground:(id)notification { /* 吞掉进后台感知 */ }
+ (void)disConnect { }
%end

%hook GXSocketConnectModule
- (void)disConnect { if (isAppActuallyBackground) return; %orig; }
- (void)closeSocket { if (isAppActuallyBackground) return; %orig; }
%end

// ==========================================
// 3. ✨ 唯一指定通知源：个推真实推送
// ==========================================
%hook GXPushManager
- (void)GXPushManagerDidReceivePayloadData:(NSData *)d taskId:(NSString *)t msgId:(NSString *)m offLine:(BOOL)o appId:(NSString *)a {
    %orig; 
    // 只有这里（真正的官方离线推送通道）收到数据，才弹横幅和震动！
    fireLocalBannerNotification();
}
%end

// ==========================================
// 4. 音频霸权与后台起搏器
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
        if (audioPlayer && !audioPlayer.isPlaying) {
            [audioPlayer play];
        }
    } @catch (NSException *e) {}
}

// ==========================================
// 5. 生命周期调度
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
