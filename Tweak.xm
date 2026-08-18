#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
#pragma clang diagnostic ignored "-Wunused-variable"

#import <UIKit/UIKit.h>
#import <AudioToolbox/AudioToolbox.h>
#import <AVFoundation/AVFoundation.h>
#import <mach-o/dyld.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <substrate.h>

// MARK: - 1. BIẾN CẤU HÌNH & TRẠNG THÁI
static BOOL isMasterLoopRunning     = NO;
static BOOL isFoodEnabled           = YES;
static BOOL isDeliveryEnabled       = YES;
static BOOL isRideEnabled           = YES;
static BOOL isSoundHapticEnabled    = YES;
static BOOL useCustomSound          = YES;

// Cấu hình Auto-Accept & Bộ lọc
static BOOL isAutoAcceptEnabled     = YES;
static double minOrderPriceSetting  = 40000.0;  // Giá tối thiểu (VNĐ)
static double maxPickupDistSetting  = 2.5;      // Khoảng cách tối đa (km)

// Thống kê thời gian thực
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

// MARK: - 2. KHỞI TẠO ÂM THANH & RUNG PHẢN HỒI
static void setupCustomAudioPlayer(void) {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *documentsDirectory = [paths firstObject];
    NSString *soundFilePath = [documentsDirectory stringByAppendingPathComponent:@"custom_alert.mp3"];
    
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

// MARK: - 3. THỰC THI AUTO-ACCEPT KÈM BỘ LỌC
static void executeAcceptOrder(NSString *orderId, double price, double distance) {
    if (!orderId || orderId.length == 0) return;

    // Human delay ngẫu nhiên (80ms - 180ms)
    uint32_t delayMs = 80 + arc4random_uniform(100);

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delayMs * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
        Class orderMgrClass = objc_getClass("FoodOrderManager");
        if (orderMgrClass) {
            id mgr = ((id (*)(id, SEL))objc_msgSend)(orderMgrClass, NSSelectorFromString(@"sharedInstance"));
            SEL acceptSelector = NSSelectorFromString(@"acceptOrderById:completion:");
            
            if ([mgr respondsToSelector:acceptSelector]) {
                void (^callback)(BOOL success, id error) = ^(BOOL success, id error) {
                    if (success) {
                        NSLog(@"[DriverTweak] ✅ Nhận đơn thành công!");
                    }
                };
                
                // Dùng objc_msgSend trực tiếp thay cho NSInvocation để tránh lỗi cast pointer C++
                ((void (*)(id, SEL, NSString *, id))objc_msgSend)(mgr, acceptSelector, orderId, callback);
            }
        }
    });
}

static void filterAndProcessIncomingOrder(NSDictionary *orderData) {
    if (!isAutoAcceptEnabled || !orderData) return;

    NSString *orderId = orderData[@"order_id"] ?: orderData[@"id"];
    double orderPrice = [orderData[@"driver_fee"] doubleValue] ?: [orderData[@"price"] doubleValue];
    double distanceKm = [orderData[@"pickup_distance_km"] doubleValue] ?: [orderData[@"distance"] doubleValue];

    if (orderPrice < minOrderPriceSetting) return;
    if (distanceKm > maxPickupDistSetting && distanceKm > 0) return;

    executeAcceptOrder(orderId, orderPrice, distanceKm);
}

// MARK: - 4. CÁC HÀM QUÉT DỮ LIỆU ĐƠN HÀNG (CHAINED MODULES)
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

// MARK: - 5. HOOK CHUYỂN "VUỐT ĐỂ NHẬN ĐƠN" THÀNH "NHẤN 1 CHẠM"
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

// MARK: - 6. GIAO DIỆN NÚT NỔI & MENU ĐIỀU KHIỂN
@implementation MasterControlMenu

+ (instancetype)shared {
    static MasterControlMenu *inst;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        inst = [[MasterControlMenu alloc] initWithFrame:[UIScreen mainScreen].bounds];
        inst.windowLevel = UIWindowLevelAlert + 100;
        inst.backgroundColor = [UIColor clearColor];
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

- (void)openMinPricePicker:(UIViewController *)rootVC {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"💰 CHỌN GIÁ CƯỚC TỐI THIỂU"
                                                                   message:@"Chỉ tự nhận đơn có giá lớn hơn hoặc bằng:"
                                                            preferredStyle:UIAlertControllerStyleActionSheet];

    NSArray *pricePresets = @[
        @{@"label": @"Tất cả giá (Không lọc)", @"val": @(0.0)},
        @{@"label": @"Từ 25.000 đ", @"val": @(25000.0)},
        @{@"label": @"Từ 35.000 đ", @"val": @(35000.0)},
        @{@"label": @"Từ 50.000 đ", @"val": @(50000.0)},
        @{@"label": @"Từ 80.000 đ", @"val": @(80000.0)}
    ];

    for (NSDictionary *item in pricePresets) {
        double val = [item[@"val"] doubleValue];
        NSString *checkMark = (minOrderPriceSetting == val) ? @"✅ " : @"⚪ ";
        [alert addAction:[UIAlertAction actionWithTitle:[checkMark stringByAppendingString:item[@"label"]] style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
            minOrderPriceSetting = val;
            [[NSUserDefaults standardUserDefaults] setDouble:val forKey:@"Saved_MinPrice"];
        }]];
    }

    [alert addAction:[UIAlertAction actionWithTitle:@"Đóng" style:UIAlertActionStyleCancel handler:nil]];
    [rootVC presentViewController:alert animated:YES completion:nil];
}

- (void)openMaxDistancePicker:(UIViewController *)rootVC {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"📍 CHỌN BÁN KÍNH ĐÓN TỐI ĐA"
                                                                   message:@"Chỉ nhận đơn có khoảng cách đón gần hơn:"
                                                            preferredStyle:UIAlertControllerStyleActionSheet];

    NSArray *distPresets = @[
        @{@"label": @"Dưới 1.0 km", @"val": @(1.0)},
        @{@"label": @"Dưới 1.5 km", @"val": @(1.5)},
        @{@"label": @"Dưới 2.5 km (Chuẩn)", @"val": @(2.5)},
        @{@"label": @"Dưới 4.0 km", @"val": @(4.0)},
        @{@"label": @"Không giới hạn", @"val": @(99.0)}
    ];

    for (NSDictionary *item in distPresets) {
        double val = [item[@"val"] doubleValue];
        NSString *checkMark = (maxPickupDistSetting == val) ? @"✅ " : @"⚪ ";
        [alert addAction:[UIAlertAction actionWithTitle:[checkMark stringByAppendingString:item[@"label"]] style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
            maxPickupDistSetting = val;
            [[NSUserDefaults standardUserDefaults] setDouble:val forKey:@"Saved_MaxDist"];
        }]];
    }

    [alert addAction:[UIAlertAction actionWithTitle:@"Đóng" style:UIAlertActionStyleCancel handler:nil]];
    [rootVC presentViewController:alert animated:YES completion:nil];
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
    NSString *fTitle = [NSString stringWithFormat:@"%@ Đơn Đồ ăn (Food)", isFoodEnabled ? @"[BẬT] 🟢" : @"[TẮT] 🔴"];
    [sheet addAction:[UIAlertAction actionWithTitle:fTitle style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        isFoodEnabled = !isFoodEnabled;
        [[NSUserDefaults standardUserDefaults] setBool:isFoodEnabled forKey:@"Saved_Food"];
    }]];

    NSString *dTitle = [NSString stringWithFormat:@"%@ Đơn Giao hàng (Delivery)", isDeliveryEnabled ? @"[BẬT] 🟢" : @"[TẮT] 🔴"];
    [sheet addAction:[UIAlertAction actionWithTitle:dTitle style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        isDeliveryEnabled = !isDeliveryEnabled;
        [[NSUserDefaults standardUserDefaults] setBool:isDeliveryEnabled forKey:@"Saved_Delivery"];
    }]];

    NSString *rTitle = [NSString stringWithFormat:@"%@ Cuốc Xe ôm (Ride)", isRideEnabled ? @"[BẬT] 🟢" : @"[TẮT] 🔴"];
    [sheet addAction:[UIAlertAction actionWithTitle:rTitle style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        isRideEnabled = !isRideEnabled;
        [[NSUserDefaults standardUserDefaults] setBool:isRideEnabled forKey:@"Saved_Ride"];
    }]];

    // 3. Auto-Accept & Lọc
    NSString *autoTitle = [NSString stringWithFormat:@"%@ Tự Động Nhận Đơn (Auto-Accept)", isAutoAcceptEnabled ? @"[BẬT] 🎯" : @"[TẮT] ⏸️"];
    [sheet addAction:[UIAlertAction actionWithTitle:autoTitle style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        isAutoAcceptEnabled = !isAutoAcceptEnabled;
        [[NSUserDefaults standardUserDefaults] setBool:isAutoAcceptEnabled forKey:@"Saved_AutoAccept"];
    }]];

    NSString *priceTitle = [NSString stringWithFormat:@"💰 Lọc giá tối thiểu: [%.0f đ] ❯", minOrderPriceSetting];
    [sheet addAction:[UIAlertAction actionWithTitle:priceTitle style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        [self openMinPricePicker:rootVC];
    }]];

    NSString *distTitle = [NSString stringWithFormat:@"📍 Lọc khoảng cách: [≤ %.1f km] ❯", maxPickupDistSetting];
    [sheet addAction:[UIAlertAction actionWithTitle:distTitle style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        [self openMaxDistancePicker:rootVC];
    }]];

    // 4. Chuông & Rung
    NSString *sndTitle = [NSString stringWithFormat:@"%@ Chuông & Rung báo đơn", isSoundHapticEnabled ? @"[BẬT] 🔔" : @"[TẮT] 🔕"];
    [sheet addAction:[UIAlertAction actionWithTitle:sndTitle style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        isSoundHapticEnabled = !isSoundHapticEnabled;
        [[NSUserDefaults standardUserDefaults] setBool:isSoundHapticEnabled forKey:@"Saved_Sound"];
    }]];

    // 5. Tiện ích
    [sheet addAction:[UIAlertAction actionWithTitle:@"🔄 Reset bộ đếm thống kê" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        totalScannedCount = 0;
        newOrdersFound = 0;
        [self updateLiveStatsUI];
    }]];

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

// MARK: - 7. CHỐNG PHÁT HIỆN DYLIB (ANTI-DETECTION)
static const char *(*orig_dyld_get_image_name)(uint32_t image_index);
static const char *hooked_dyld_get_image_name(uint32_t image_index) {
    const char *name = orig_dyld_get_image_name(image_index);
    if (name != NULL) {
        if (strstr(name, "dylib") || strstr(name, "Substrate") || strstr(name, "TweakInject") || strstr(name, "Shadow")) {
            return "/System/Library/Frameworks/UIKit.framework/UIKit";
        }
    }
    return name;
}

static void applyAntiDetection(void) {
    MSHookFunction((void *)_dyld_get_image_name, (void *)hooked_dyld_get_image_name, (void **)&orig_dyld_get_image_name);
}

// MARK: - 8. CỬ CHỈ BÍ MẬT & CONSTRUCTOR
%hook UIWindow
- (void)makeKeyAndVisible {
    %orig;
    if (self.windowLevel == UIWindowLevelNormal) {
        UITapGestureRecognizer *secretGesture = [[UITapGestureRecognizer alloc] initWithTarget:[MasterControlMenu shared] action:@selector(toggleMenuVisibility)];
        secretGesture.numberOfTouchesRequired = 3;
        secretGesture.numberOfTapsRequired = 2;
        [self addGestureRecognizer:secretGesture];
    }
}
%end

__attribute__((constructor)) static void initTweak(void) {
    applyAntiDetection();
    setupCustomAudioPlayer();

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        NSUserDefaults *defs = [NSUserDefaults standardUserDefaults];
        if ([defs objectForKey:@"Saved_Food"])       isFoodEnabled        = [defs boolForKey:@"Saved_Food"];
        if ([defs objectForKey:@"Saved_Delivery"])   isDeliveryEnabled    = [defs boolForKey:@"Saved_Delivery"];
        if ([defs objectForKey:@"Saved_Ride"])       isRideEnabled        = [defs boolForKey:@"Saved_Ride"];
        if ([defs objectForKey:@"Saved_Sound"])      isSoundHapticEnabled = [defs boolForKey:@"Saved_Sound"];
        if ([defs objectForKey:@"Saved_Master"])     isMasterLoopRunning  = [defs boolForKey:@"Saved_Master"];
        if ([defs objectForKey:@"Saved_AutoAccept"]) isAutoAcceptEnabled  = [defs boolForKey:@"Saved_AutoAccept"];
        if ([defs objectForKey:@"Saved_MinPrice"])   minOrderPriceSetting = [defs doubleForKey:@"Saved_MinPrice"];
        if ([defs objectForKey:@"Saved_MaxDist"])    maxPickupDistSetting = [defs doubleForKey:@"Saved_MaxDist"];

        [MasterControlMenu shared];
        if (isMasterLoopRunning) {
            startChainedEngine();
        }
    });
}

#pragma clang diagnostic pop
