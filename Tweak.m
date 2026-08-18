#import <UIKit/UIKit.h>
#import <AudioToolbox/AudioToolbox.h>
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>
#import <objc/message.h>

// MARK: - 1. BIẾN TRẠNG THÁI
static BOOL isMasterLoopRunning  = NO;
static BOOL isFoodEnabled        = YES;
static BOOL isDeliveryEnabled    = YES;
static BOOL isRideEnabled        = YES;

static dispatch_queue_t chainedQueue = nil;

static dispatch_queue_t getChainedQueue(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        chainedQueue = dispatch_queue_create("com.driver.native.queue", DISPATCH_QUEUE_SERIAL);
    });
    return chainedQueue;
}

// MARK: - 2. CÁC HÀM QUÉT DỮ LIỆU ĐƠN HÀNG
static void scanFoodOrders(void (^done)(void)) {
    @autoreleasepool {
        Class foodClass = objc_getClass("FoodOrderManager");
        if (foodClass) {
            id mgr = ((id (*)(id, SEL))objc_msgSend)(foodClass, NSSelectorFromString(@"sharedInstance"));
            SEL scanSel = NSSelectorFromString(@"fetchAvailableFoodOrders");
            if ([mgr respondsToSelector:scanSel]) {
                ((void (*)(id, SEL))objc_msgSend)(mgr, scanSel);
            }
        }
        if (done) done();
    }
}

static void scanDeliveryOrders(void (^done)(void)) {
    @autoreleasepool {
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
                if (isMasterLoopRunning) {
                    startChainedEngine();
                }
            });
        }
    });
}

// MARK: - 3. QUẢN LÝ GIAO DIỆN NÚT NỔI
@interface DriverFloatingMenu : NSObject
@property (nonatomic, strong) UIButton *btn;
+ (instancetype)shared;
- (void)attachButton;
@end

@implementation DriverFloatingMenu

+ (instancetype)shared {
    static DriverFloatingMenu *inst;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        inst = [[DriverFloatingMenu alloc] init];
    });
    return inst;
}

- (void)attachButton {
    UIWindow *window = [UIApplication sharedApplication].keyWindow;
    if (!window) {
        if (@available(iOS 13.0, *)) {
            for (UIWindowScene *scene in [UIApplication sharedApplication].connectedScenes) {
                if ([scene isKindOfClass:[UIWindowScene class]]) {
                    for (UIWindow *w in scene.windows) {
                        if (w.isKeyWindow) { window = w; break; }
                    }
                }
            }
        }
    }
    if (!window || self.btn.superview) return;

    self.btn = [UIButton buttonWithType:UIButtonTypeCustom];
    self.btn.frame = CGRectMake(15, 180, 50, 50);
    self.btn.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.8];
    self.btn.layer.cornerRadius = 25;
    self.btn.layer.borderWidth = 1.5;
    self.btn.layer.borderColor = [UIColor systemGreenColor].CGColor;
    [self.btn setTitle:@"⚡" forState:UIControlStateNormal];
    self.btn.titleLabel.font = [UIFont systemFontOfSize:22];

    [self.btn addTarget:self action:@selector(openMenu) forControlEvents:UIControlEventTouchUpInside];

    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
    [self.btn addGestureRecognizer:pan];

    [window addSubview:self.btn];
}

- (void)handlePan:(UIPanGestureRecognizer *)pan {
    UIView *parent = self.btn.superview;
    if (!parent) return;
    CGPoint trans = [pan translationInView:parent];
    self.btn.center = CGPointMake(self.btn.center.x + trans.x, self.btn.center.y + trans.y);
    [pan setTranslation:CGPointZero inView:parent];
}

- (void)openMenu {
    UIViewController *rootVC = [UIApplication sharedApplication].keyWindow.rootViewController;
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"MENU SĂN ĐƠN"
                                                                   message:nil
                                                            preferredStyle:UIAlertControllerStyleActionSheet];

    NSString *mTitle = isMasterLoopRunning ? @"⚡ Vòng lặp: [ĐANG BẬT] 🟢" : @"⚪ Vòng lặp: [ĐANG TẮT] 🔴";
    [sheet addAction:[UIAlertAction actionWithTitle:mTitle style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        isMasterLoopRunning = !isMasterLoopRunning;
        if (isMasterLoopRunning) startChainedEngine();
    }]];

    NSString *fTitle = [NSString stringWithFormat:@"%@ Đồ ăn", isFoodEnabled ? @"[BẬT] 🟢" : @"[TẮT] 🔴"];
    [sheet addAction:[UIAlertAction actionWithTitle:fTitle style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        isFoodEnabled = !isFoodEnabled;
    }]];

    NSString *dTitle = [NSString stringWithFormat:@"%@ Giao hàng", isDeliveryEnabled ? @"[BẬT] 🟢" : @"[TẮT] 🔴"];
    [sheet addAction:[UIAlertAction actionWithTitle:dTitle style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        isDeliveryEnabled = !isDeliveryEnabled;
    }]];

    NSString *rTitle = [NSString stringWithFormat:@"%@ Xe ôm", isRideEnabled ? @"[BẬT] 🟢" : @"[TẮT] 🔴"];
    [sheet addAction:[UIAlertAction actionWithTitle:rTitle style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        isRideEnabled = !isRideEnabled;
    }]];

    [sheet addAction:[UIAlertAction actionWithTitle:@"Đóng" style:UIAlertActionStyleCancel handler:nil]];
    [rootVC presentViewController:sheet animated:YES completion:nil];
}

@end

// MARK: - 4. METHOD SWIZZLING THUẦN (KHÔNG CẦN CYDIASUBSTRATE)
static void (*orig_viewDidAppear)(id, SEL, BOOL);

static void custom_viewDidAppear(id self, SEL _cmd, BOOL animated) {
    orig_viewDidAppear(self, _cmd, animated);

    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [[DriverFloatingMenu shared] attachButton];
        });
    });
}

// Khởi tạo Swizzling an toàn khi thư viện được load
__attribute__((constructor)) static void initNativeLibrary(void) {
    Class vcClass = [UIViewController class];
    SEL sel = @selector(viewDidAppear:);
    Method originalMethod = class_getInstanceMethod(vcClass, sel);
    
    if (originalMethod) {
        orig_viewDidAppear = (void (*)(id, SEL, BOOL))method_getImplementation(originalMethod);
        method_setImplementation(originalMethod, (IMP)custom_viewDidAppear);
    }
}
