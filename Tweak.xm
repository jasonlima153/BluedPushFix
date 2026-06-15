// BluedPushFix — 务实派：定位唤醒 + 轻量通知探测版
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <UserNotifications/UserNotifications.h>
#import <CoreLocation/CoreLocation.h>

// 1. 极小体积的无声音频数据 (替换原 silent_data.h)
unsigned char silent_mp3[] = {
  0xFF, 0xFB, 0x90, 0x44, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
};
unsigned int silent_mp3_len = 16;

static BOOL g_isBackground = NO;
static NSTimeInterval g_lastWakeupTime = 0;
static id g_activeGRPCConnector = nil;

// ==========================================
// 1. 本地横幅通知引擎
// ==========================================
void fireLocalBannerNotification(NSString *title, NSString *body, NSString *identifier) {
    if (!g_isBackground) return; 
    
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        UNMutableNotificationContent *content = [[UNMutableNotificationContent alloc] init];
        content.title = title;
        content.body = body;
        content.sound = [UNNotificationSound defaultSound];
        
        UNTimeIntervalNotificationTrigger *trigger = [UNTimeIntervalNotificationTrigger triggerWithTimeInterval:0.1 repeats:NO];
        UNNotificationRequest *request = [UNNotificationRequest requestWithIdentifier:identifier content:content trigger:trigger];
        [[UNUserNotificationCenter currentNotificationCenter] addNotificationRequest:request withCompletionHandler:nil];
    });
}

// ==========================================
// 2. 定位哨兵引擎 (基站级极低耗电)
// ==========================================
@interface PragmaticSentinel : NSObject <CLLocationManagerDelegate>
@property (nonatomic, strong) CLLocationManager *locManager;
@property (nonatomic, strong) AVAudioPlayer *audioPlayer;
+ (instancetype)shared;
- (void)setupSentinel;
@end

@implementation PragmaticSentinel
+ (instancetype)shared {
    static PragmaticSentinel *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[self alloc] init];
    });
    return instance;
}

- (void)setupSentinel {
    // 启动音频做第一级缓冲（扛住刚切后台的头10分钟）
    @try {
        [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryPlayback withOptions:AVAudioSessionCategoryOptionMixWithOthers error:nil];
        [[AVAudioSession sharedInstance] setActive:YES error:nil];
        if (!self.audioPlayer) {
            self.audioPlayer = [[AVAudioPlayer alloc] initWithData:[NSData dataWithBytes:silent_mp3 length:silent_mp3_len] error:nil];
            self.audioPlayer.numberOfLoops = -1;
            self.audioPlayer.volume = 0.01;
            [self.audioPlayer prepareToPlay];
        }
        [self.audioPlayer play];
    } @catch (NSException *e) {}

    // 启动定位做第二级长效唤醒
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!self.locManager) {
            self.locManager = [[CLLocationManager alloc] init];
            self.locManager.delegate = self;
            self.locManager.desiredAccuracy = kCLLocationAccuracyThreeKilometers; // 3公里基站级精度，省电
            if ([self.locManager respondsToSelector:@selector(setAllowsBackgroundLocationUpdates:)]) {
                self.locManager.allowsBackgroundLocationUpdates = YES;
            }
            self.locManager.pausesLocationUpdatesAutomatically = NO;
        }
        
        if ([CLLocationManager authorizationStatus] == kCLAuthorizationStatusNotDetermined) {
            [self.locManager requestAlwaysAuthorization];
        }
        [self.locManager startUpdatingLocation];
    });
}

// 系统分配的黄金唤醒时刻（每次约存活 10-30 秒）
- (void)locationManager:(CLLocationManager *)manager didUpdateLocations:(NSArray<CLLocation *> *)locations {
    if (!g_isBackground) return;
    
    // 防抖机制：限制至少 10 分钟（600秒）才允许弹一次通知，防止用户觉得太烦
    NSTimeInterval currentTime = [[NSDate date] timeIntervalSince1970];
    if (currentTime - g_lastWakeupTime < 600) return;
    g_lastWakeupTime = currentTime;

    // --- 可选升级：如果你抓包拿到了未读消息 API，把下面注释放开 ---
    /*
    NSURL *url = [NSURL URLWithString:@"https://api.blued.com/xxx/unread"]; // 替换为真实的未读接口
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    // 需要带上你的 Token 等 Header
    // [req setValue:@"Bearer xxx" forHTTPHeaderField:@"Authorization"];
    
    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (data) {
            // 解析 JSON，判断是否有未读
            // 假设有未读：
            fireLocalBannerNotification(@"新消息提醒", @"您有新的未读消息，请打开App查看", @"Wakeup_Notify");
        }
    }];
    [task resume];
    */

    // --- 默认盲弹机制 ---
    fireLocalBannerNotification(@"分身活跃守护", @"正在为您守护后台连接，如有未读请点此查看", @"Wakeup_Notify");
    
    // 刺激系统刷新机制
    [[UIApplication sharedApplication] setMinimumBackgroundFetchInterval:UIApplicationBackgroundFetchIntervalMinimum];
}
@end

// ==========================================
// 3. 前台精准通知拦截 (依然保留)
// ==========================================
%hook BDLiveIM
- (void)didReceiveProtoMessage:(id)message {
    if (message) { 
        %orig(message); 
        fireLocalBannerNotification(@"互动通知", @"直播间或派对有新的动态", @"IM_Notify"); 
    } else { 
        %orig; 
    }
}
%end

%hook GXPushManager
- (void)GXPushManagerDidReceivePayloadData:(NSData *)d taskId:(NSString *)t msgId:(NSString *)m offLine:(BOOL)o appId:(NSString *)a {
    %orig; 
    fireLocalBannerNotification(@"新消息", @"您收到了一条新的聊天消息", @"Push_Notify");
}
%end

%hook BDgRPCConnector
- (instancetype)init { id obj = %orig; g_activeGRPCConnector = obj; return obj; }
%end

// ==========================================
// 4. 生命周期平滑过渡
// ==========================================
%hook AppDelegate
- (void)applicationDidEnterBackground:(UIApplication *)application {
    g_isBackground = YES;
    %orig; 
    [[PragmaticSentinel shared] setupSentinel];
}

- (void)applicationWillEnterForeground:(UIApplication *)application {
    g_isBackground = NO;
    %orig;
    
    // 切回前台，强制踹一脚 gRPC 让它去同步最新数据
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (g_activeGRPCConnector) {
            #pragma clang diagnostic push
            #pragma clang diagnostic ignored "-Wundeclared-selector"
            if ([g_activeGRPCConnector respondsToSelector:@selector(disConnect)]) [g_activeGRPCConnector performSelector:@selector(disConnect)];
            if ([g_activeGRPCConnector respondsToSelector:@selector(connect)]) [g_activeGRPCConnector performSelector:@selector(connect)];
            #pragma clang diagnostic pop
        }
    });
}
%end
