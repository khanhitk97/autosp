#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
#pragma clang diagnostic ignored "-Wunused-variable"

#import <UIKit/UIKit.h>
#import <AudioToolbox/AudioToolbox.h>
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>
#import <objc/message.h>

// MARK: - 1. BIẾN CẤU HÌNH & TRẠNG THÁI
static BOOL isMasterLoopRunning     = NO;
static BOOL isFoodEnabled           = YES;
static BOOL isDeliveryEnabled       = YES;
static BOOL isRideEnabled           = YES;
static BOOL isSoundHapticEnabled    = YES;
static BOOL useCustomSound          = YES;

static BOOL isAutoAcceptEnabled     = YES;
static double minOrderPriceSetting  = 40000.0;
static double maxPickupDistSetting  = 2.5;

static NSUInteger totalScannedCount = 0;
static NSUInteger newOrdersFound    = 0;

static dispatch_queue_t chainedQueue = nil;
static AVAudioPlayer *customAudioPlayer = nil;

static dispatch_queue_t getChainedQueue(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        chainedQueue = dispatch_queue_create("com.driver.chained.queue", DISPATCH_QUEUE_SERIAL);
    });
    return chainedQueue;
}

@interface MasterControlMenu : UIWindow
@property (nonatomic, strong) UIButton *btn;
@property (nonatomic, strong) UILabel *badgeLabel;
+ (instancetype)shared;
- (void)updateLiveStatsUI;
- (void)toggleMenuVisibility;
@end

// MARK: - 2. ÂM THANH & RUNG
static void setupCustomAudioPlayer(void) {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *soundFilePath = [[paths firstObject] stringByAppendingPathComponent:@"custom_alert.mp3"];
    
    if (![[NSFileManager defaultManager] fileExistsAtPath:soundFilePath]) {
        soundFilePath = [[NSBundle mainBundle] pathForResource:@"custom_alert" ofType:@"mp3"];
    }

    if ([[NSFileManager defaultManager] fileExistsAtPath:soundFilePath]) {
        NSURL *soundURL = [NSURL fileURLWithPath:soundFilePath];
        [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryPlayback 
                                         withOptions:AVAudioSessionCategoryOptionMixWithOthers 
                                               error:nil];
        [[AVAudioSession sharedInstance] setActive:YES error:nil];

        customAudioPlayer = [[AVAudioPlayer alloc] initWithContentsOfURL:soundURL error:nil];
        [customAudioPlayer prepareToPlay];
        customAudioPlayer.volume = 1.0;
    }
}

static void triggerOrderAlert(void) {
    if (!isSoundHapticEnabled) return;

    dispatch_async(dispatch_get_main_queue(), ^{
        UIImpactFeedbackGenerator *feedback = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleHeavy];
        [feedback prepare];
        [feedback impactOccurred];

        if (useCustomSound && customAudioPlayer) {
            if ([customAudioPlayer isPlaying]) {
                [customAudioPlayer stop];
                customAudioPlayer.currentTime = 0;
            }
            [customAudioPlayer play];
        } else {
            AudioServicesPlaySystemSound(1007);
        }
    });
}

// MARK: - 3. THỰC THI AUTO-ACCEPT
static void executeAcceptOrder(NSString *orderId, double price, double distance) {
    if (!orderId || orderId.length == 0) return;

    uint32_t delayMs = 80 + arc4random_uniform(100);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delayMs * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
        Class orderMgrClass = objc_getClass("FoodOrderManager");
        if (orderMgrClass) {
            id mgr = ((id (*)(id, SEL))objc_msgSend)(orderMgrClass, NSSelectorFromString(@"sharedInstance"));
            SEL acceptSelector = NSSelectorFromString(@"acceptOrderById:completion:");
            
            if ([mgr respondsToSelector:acceptSelector]) {
                void (^callback)(BOOL success, id error) = ^(BOOL success, id error) {
                    if (success) NSLog(@"[DriverTweak] ✅ Nhận đơn thành công!");
                };
                ((void (*)(id, SEL, NSString *, id))objc_msgSend)(mgr, acceptSelector, orderId, callback);
            }
        }
    });
}

// MARK: - 4. QUÉT NỐI TIẾP
static void scanFoodOrders(void (^done)(void)) {
    @autoreleasepool {
        totalScannedCount++;
        Class foodClass = objc_getClass("FoodOrderManager");
        if (foodClass) {
            id mgr = ((id (*)(id, SEL))objc_msgSend)(foodClass, NSSelectorFromString(@"sharedInstance"));
            SEL scanSel = NSSelectorFromString(@"fetchAvailableFoodOrders");
            if ([mgr respondsToSelector:scanSel]) {
                id result = ((id (*)(id, SEL))objc_msgSend)(mgr, scanSel);
                if (result) {
                    newOrdersFound++;
                    triggerOrderAlert();
                }
            }
        }
        if (done) done();
    }
}

static void scanDeliveryOrders(void (^done)(void)) {
    @autoreleasepool {
        totalScannedCount++;
        Class delClass = objc_getClass("ExpressOrderManager");
        if (delClass) {
            id mgr = ((id (*)(id, SEL))objc_msgSend)(delClass, NSSelectorFromString(@"sharedInstance"));
            SEL scanSel = NSSelectorFromString(@"refreshOrderList");
            if ([mgr respondsToSelector:scanSel]) {
                ((void (*)(id, SEL))objc_msgSend)(mgr, scanSel);
            }
        }
        if (done) done();
    }
}

static void scanRideOrders(void (^done)(void)) {
    @autoreleasepool {
        totalScannedCount++;
        Class rideClass = objc_getClass("RideOrderManager");
        if (rideClass) {
            id mgr = ((id (*)(id, SEL))objc_msgSend)(rideClass, NSSelectorFromString(@"sharedInstance"));
            SEL scanSel = NSSelectorFromString(@"syncNearbyDriverAndOrders");
            if ([mgr respondsToSelector:scanSel]) {
                ((void (*)(id, SEL))objc_msgSend)(mgr, scanSel);
            }
        }
        if (done) done();
    }
}

static void startChainedEngine(void) {
    if (!isMasterLoopRunning) return;

    dispatch_async(getChainedQueue(), ^{
        @autoreleasepool {
            dispatch_group_t group = dispatch_group_create();

            if (isFoodEnabled) {
                dispatch_group_enter(group);
                scanFoodOrders(^{ dispatch_group_leave(group); });
            }

            if (isDeliveryEnabled) {
                dispatch_group_enter(group);
                scanDeliveryOrders(^{ dispatch_group_leave(group); });
            }

            if (isRideEnabled) {
                dispatch_group_enter(group);
                scanRideOrders(^{ dispatch_group_leave(group); });
            }

            dispatch_group_notify(group, getChainedQueue(), ^{
                dispatch_async(dispatch_get_main_queue(), ^{
                    [[MasterControlMenu shared] updateLiveStatsUI];
                });

                if (isMasterLoopRunning) {
                    startChainedEngine();
                }
            });
        }
    });
}

// MARK: - 5. HOOK CHUYỂN "VUỐT" THÀNH "NHẤN"
%hook UIView

- (void)didMoveToWindow {
    %orig;
    for (UIView *subview in self.subviews) {
        if ([subview isKindOfClass:[UILabel class]]) {
            UILabel *lbl = (UILabel *)subview;
            if ([lbl.text containsString:@"Vuốt để nhận đơn"]) {
                lbl.text = @"⚡ Nhấn để nhận đơn";
                self.userInteractionEnabled = YES;
                
                BOOL hasTap = NO;
                for (UIGestureRecognizer *g in self.gestureRecognizers) {
                    if ([g isKindOfClass:[UITapGestureRecognizer class]]) {
                        hasTap = YES;
                        break;
                    }
                }
                
                if (!hasTap) {
                    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleInstantTapAccept:)];
                    [self addGestureRecognizer:tap];
                }
            }
        }
    }
}

%new
- (void)handleInstantTapAccept:(UITapGestureRecognizer *)gesture {
    NSArray *methods = @[@"onSwipeCompleted", @"finishSwipe", @"actionTriggered", @"didFinishSliding", @"acceptOrderAction:"];
    for (NSString *selName in methods) {
        SEL sel = NSSelectorFromString(selName);
        if ([self respondsToSelector:sel]) {
            ((void (*)(id, SEL, id))objc_msgSend)(self, sel, self);
            return;
        }
    }
    
    if ([self isKindOfClass:[UIControl class]]) {
        UIControl *ctrl = (UIControl *)self;
        [ctrl sendActionsForControlEvents:UIControlEventValueChanged];
        [ctrl sendActionsForControlEvents:UIControlEventTouchUpInside];
    }
}

%end

// MARK: - 6. GIAO DIỆN NÚT NỔI
@implementation MasterControlMenu

+ (instancetype)shared {
    static MasterControlMenu *inst;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        inst = [[MasterControlMenu alloc] initWithFrame:[UIScreen mainScreen].bounds];
        inst.windowLevel = UIWindowLevelAlert + 100;
        inst.backgroundColor = [UIColor clearColor];
        
        // Hỗ trợ iOS 13+ SceneDelegate
        if (@available(iOS 13.0, *)) {
            for (UIWindowScene *scene in [UIApplication sharedApplication].connectedScenes) {
                if (scene.activationState == UISceneActivationStateForegroundActive && [scene isKindOfClass:[UIWindowScene class]]) {
                    inst.windowScene = scene;
                    break;
                }
            }
        }
        
        inst.hidden = NO;
        [inst setupUI];
    });
    return inst;
}

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hitView = [super hitTest:point withEvent:event];
    return (hitView == self) ? nil : hitView;
}

- (void)setupUI {
    CGFloat x = [[NSUserDefaults standardUserDefaults] floatForKey:@"BtnSavedX"];
    CGFloat y = [[NSUserDefaults standardUserDefaults] floatForKey:@"BtnSavedY"];
    if (x == 0 && y == 0) { x = 15; y = 180; }

    self.btn = [UIButton buttonWithType:UIButtonTypeCustom];
    self.btn.frame = CGRectMake(x, y, 52, 52);
    self.btn.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.85];
    self.btn.layer.cornerRadius = 26;
    self.btn.layer.borderWidth = 1.5;
    
    self.badgeLabel = [[UILabel alloc] initWithFrame:CGRectMake(32, -4, 24, 18)];
    self.badgeLabel.backgroundColor = [UIColor systemRedColor];
    self.badgeLabel.textColor = [UIColor whiteColor];
    self.badgeLabel.font = [UIFont boldSystemFontOfSize:10];
    self.badgeLabel.textAlignment = NSTextAlignmentCenter;
    self.badgeLabel.layer.cornerRadius = 9;
    self.badgeLabel.clipsToBounds = YES;
    self.badgeLabel.hidden = YES;
    [self.btn addSubview:self.badgeLabel];

    [self syncButtonAppearance];
    [self.btn addTarget:self action:@selector(showMenuSheet) forControlEvents:UIControlEventTouchUpInside];

    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
    [self.btn addGestureRecognizer:pan];

    [self addSubview:self.btn];
}

- (void)syncButtonAppearance {
    if (isMasterLoopRunning) {
        [self.btn setTitle:@"⚡" forState:UIControlStateNormal];
        self.btn.titleLabel.font = [UIFont systemFontOfSize:20];
        self.btn.layer.borderColor = [UIColor systemGreenColor].CGColor;
    } else {
        [self.btn setTitle:@"⚙️" forState:UIControlStateNormal];
        self.btn.titleLabel.font = [UIFont systemFontOfSize:20];
        self.btn.layer.borderColor = [[UIColor whiteColor] colorWithAlphaComponent:0.4].CGColor;
    }
}

- (void)updateLiveStatsUI {
    if (newOrdersFound > 0) {
        self.badgeLabel.hidden = NO;
        self.badgeLabel.text = [NSString stringWithFormat:@"%lu", (unsigned long)newOrdersFound];
    } else {
        self.badgeLabel.hidden = YES;
    }
}

- (void)handlePan:(UIPanGestureRecognizer *)pan {
    CGPoint trans = [pan translationInView:self];
    self.btn.center = CGPointMake(self.btn.center.x + trans.x, self.btn.center.y + trans.y);
    [pan setTranslation:CGPointZero inView:self];

    if (pan.state == UIGestureRecognizerStateEnded) {
        CGSize sz = [UIScreen mainScreen].bounds.size;
        CGFloat targetX = (self.btn.center.x < sz.width / 2.0) ? 15 : (sz.width - 67);
        CGFloat targetY = MIN(MAX(self.btn.frame.origin.y, 60), sz.height - 100);

        [UIView animateWithDuration:0.25 delay:0 usingSpringWithDamping:0.75 initialSpringVelocity:0.5 options:UIViewAnimationOptionCurveEaseOut animations:^{
            self.btn.frame = CGRectMake(targetX, targetY, 52, 52);
        } completion:^(BOOL finished) {
            [[NSUserDefaults standardUserDefaults] setFloat:targetX forKey:@"BtnSavedX"];
            [[NSUserDefaults standardUserDefaults] setFloat:targetY forKey:@"BtnSavedY"];
        }];
    }
}

- (void)toggleMenuVisibility {
    self.btn.hidden = !self.btn.hidden;
}

- (void)showMenuSheet {
    UIViewController *rootVC = [UIApplication sharedApplication].keyWindow.rootViewController;
    NSString *statsMsg = [NSString stringWithFormat:@"Đã quét: %lu lượt  |  Bắt được: %lu đơn mới", 
                          (unsigned long)totalScannedCount, (unsigned long)newOrdersFound];
                          
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"BẢNG ĐIỀU KHIỂN SĂN ĐƠN"
                                                                   message:statsMsg
                                                            preferredStyle:UIAlertControllerStyleActionSheet];

    // 1. Công tắc chính
    NSString *mTitle = isMasterLoopRunning ? @"⚡ Vòng lặp: [ĐANG BẬT] 🟢" : @"⚪ Vòng lặp: [ĐANG TẮT] 🔴";
    [sheet addAction:[UIAlertAction actionWithTitle:mTitle style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        isMasterLoopRunning = !isMasterLoopRunning;
        [[NSUserDefaults standardUserDefaults] setBool:isMasterLoopRunning forKey:@"Saved_Master"];
        [self syncButtonAppearance];
        if (isMasterLoopRunning) startChainedEngine();
    }]];

    // 2. Từng module
    NSString *fTitle = [NSString stringWithFormat:@"%@ Đơn Đồ ăn", isFoodEnabled ? @"[BẬT] 🟢" : @"[TẮT] 🔴"];
    [sheet addAction:[UIAlertAction actionWithTitle:fTitle style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        isFoodEnabled = !isFoodEnabled;
        [[NSUserDefaults standardUserDefaults] setBool:isFoodEnabled forKey:@"Saved_Food"];
    }]];

    NSString *dTitle = [NSString stringWithFormat:@"%@ Đơn Giao hàng", isDeliveryEnabled ? @"[BẬT] 🟢" : @"[TẮT] 🔴"];
    [sheet addAction:[UIAlertAction actionWithTitle:dTitle style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        isDeliveryEnabled = !isDeliveryEnabled;
        [[NSUserDefaults standardUserDefaults] setBool:isDeliveryEnabled forKey:@"Saved_Delivery"];
    }]];

    NSString *rTitle = [NSString stringWithFormat:@"%@ Cuốc Xe ôm", isRideEnabled ? @"[BẬT] 🟢" : @"[TẮT] 🔴"];
    [sheet addAction:[UIAlertAction actionWithTitle:rTitle style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        isRideEnabled = !isRideEnabled;
        [[NSUserDefaults standardUserDefaults] setBool:isRideEnabled forKey:@"Saved_Ride"];
    }]];

    // 3. Chuông & Rung
    NSString *sndTitle = [NSString stringWithFormat:@"%@ Chuông & Rung", isSoundHapticEnabled ? @"[BẬT] 🔔" : @"[TẮT] 🔕"];
    [sheet addAction:[UIAlertAction actionWithTitle:sndTitle style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        isSoundHapticEnabled = !isSoundHapticEnabled;
        [[NSUserDefaults standardUserDefaults] setBool:isSoundHapticEnabled forKey:@"Saved_Sound"];
    }]];

    // 4. Xả RAM & Ẩn nút
    [sheet addAction:[UIAlertAction actionWithTitle:@"🧹 Xả RAM & Cache" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        [[NSURLCache sharedURLCache] removeAllCachedResponses];
    }]];

    [sheet addAction:[UIAlertAction actionWithTitle:@"👁️ Ẩn nút nổi (Chạm 3 ngón x2 để mở)" style:UIAlertActionStyleDestructive handler:^(UIAlertAction * _Nonnull action) {
        [self toggleMenuVisibility];
    }]];

    [sheet addAction:[UIAlertAction actionWithTitle:@"Đóng" style:UIAlertActionStyleCancel handler:nil]];
    [rootVC presentViewController:sheet animated:YES completion:nil];
}

@end

// MARK: - 7. KHỞI TẠO AN TOÀN TRÁNH CRASH TRÊN NON-JAILBREAK
static void onAppDidBecomeActive(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            NSUserDefaults *defs = [NSUserDefaults standardUserDefaults];
            if ([defs objectForKey:@"Saved_Food"])       isFoodEnabled        = [defs boolForKey:@"Saved_Food"];
            if ([defs objectForKey:@"Saved_Delivery"])   isDeliveryEnabled    = [defs boolForKey:@"Saved_Delivery"];
            if ([defs objectForKey:@"Saved_Ride"])       isRideEnabled        = [defs boolForKey:@"Saved_Ride"];
            if ([defs objectForKey:@"Saved_Sound"])      isSoundHapticEnabled = [defs boolForKey:@"Saved_Sound"];
            if ([defs objectForKey:@"Saved_Master"])     isMasterLoopRunning  = [defs boolForKey:@"Saved_Master"];

            [MasterControlMenu shared];
            if (isMasterLoopRunning) {
                startChainedEngine();
            }
        });
    });
}

__attribute__((constructor)) static void initSafeTweak(void) {
    setupCustomAudioPlayer();
    
    // Lắng nghe khi App chuyển sang trạng thái Active hoàn toàn mới kích hoạt Menu
    CFNotificationCenterAddObserver(
        CFNotificationCenterGetLocalCenter(),
        NULL,
        &onAppDidBecomeActive,
        (CFStringRef)UIApplicationDidBecomeActiveNotification,
        NULL,
        CFNotificationSuspensionBehaviorDeliverImmediately
    );
}

#pragma clang diagnostic pop
