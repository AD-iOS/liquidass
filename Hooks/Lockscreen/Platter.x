#import "Common.h"
#import <objc/runtime.h>

static CFStringRef const kLGPrefsChangedNotification = CFSTR("dylv.liquidassprefs/Reload");
static void *kLockOriginalTextColorKey = &kLockOriginalTextColorKey;

BOOL LGIsLockscreenQuickActionsHost(UIView *view);
CGFloat LGLockscreenQuickActionsCornerRadius(UIView *view);

static void LG_lockscreenPrefsChanged(CFNotificationCenterRef center,
                                      void *observer,
                                      CFStringRef name,
                                      const void *object,
                                      CFDictionaryRef userInfo) {
    LGInvalidateLockscreenSnapshotCache();
    dispatch_async(dispatch_get_main_queue(), ^{
        LGLockscreenRefreshAllHosts();
    });
}

static BOOL isInsidePlatterView(UIView *view) {
    static Class cls;
    if (!cls) cls = NSClassFromString(@"PLPlatterView");
    UIView *v = view.superview;
    while (v) {
        if ([v isKindOfClass:cls]) return YES;
        v = v.superview;
    }
    return NO;
}

static BOOL isInsideSwitcherSuggestionBanner(UIView *view) {
    static Class cls;
    if (!cls) cls = NSClassFromString(@"SBSwitcherAppSuggestionBannerView");
    UIView *v = view;
    while (v) {
        if ([v isKindOfClass:cls]) return YES;
        v = v.superview;
    }
    return NO;
}

static BOOL hasMaterialAncestorBeforeClass(UIView *view, Class stopClass) {
    static Class materialCls;
    if (!materialCls) materialCls = NSClassFromString(@"MTMaterialView");
    UIView *v = view.superview;
    while (v) {
        if (stopClass && [v isKindOfClass:stopClass]) return NO;
        if (materialCls && [v isKindOfClass:materialCls]) return YES;
        v = v.superview;
    }
    return NO;
}

static BOOL isPrimaryPlatterMaterialHost(UIView *view) {
    static Class platterCls;
    if (!platterCls) platterCls = NSClassFromString(@"PLPlatterView");
    if (isInsideSwitcherSuggestionBanner(view)) return NO;
    if (!isInsidePlatterView(view)) return NO;
    return !hasMaterialAncestorBeforeClass(view, platterCls);
}

static BOOL isInsideActionButton(UIView *view) {
    static Class cls;
    if (!cls) {
        cls = NSClassFromString(LGIsAtLeastiOS16()
            ? @"PLPlatterActionButton"
            : @"NCNotificationListCellActionButton");
    }
    UIView *v = view.superview;
    while (v) {
        if ([v isKindOfClass:cls]) return YES;
        v = v.superview;
    }
    return NO;
}

static BOOL isPrimaryActionButtonMaterialHost(UIView *view) {
    static Class actionCls;
    if (!actionCls) {
        actionCls = NSClassFromString(LGIsAtLeastiOS16()
            ? @"PLPlatterActionButton"
            : @"NCNotificationListCellActionButton");
    }
    if (isInsideSwitcherSuggestionBanner(view)) return NO;
    if (!isInsideActionButton(view)) return NO;
    return !hasMaterialAncestorBeforeClass(view, actionCls);
}

static CGFloat LGNotificationActionButtonCornerRadius(UIView *view) {
    CGFloat fallbackRadius = LGIsAtLeastiOS16() ? 23.5f : 14.0f;
    return LGLockscreenResolvedCornerRadius(view, fallbackRadius);
}

static void updateSeamlessLabelColor(UILabel *label) {
    if (!label.window) return;
    static Class cls;
    if (!cls) cls = NSClassFromString(@"NCNotificationSeamlessContentView");
    UIView *v = label.superview;
    while (v) {
        if ([v isKindOfClass:cls]) {
            if (!objc_getAssociatedObject(label, kLockOriginalTextColorKey) && label.textColor)
                objc_setAssociatedObject(label, kLockOriginalTextColorKey, label.textColor, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            if (LGLockscreenEnabled()) {
                label.textColor = [UIColor whiteColor];
            } else {
                UIColor *original = objc_getAssociatedObject(label, kLockOriginalTextColorKey);
                if (original) label.textColor = original;
            }
            return;
        }
        v = v.superview;
    }
}

static void LGLockscreenTraverseViews(UIView *root, void (^block)(UIView *view)) {
    if (!root) return;
    block(root);
    for (UIView *sub in root.subviews) LGLockscreenTraverseViews(sub, block);
}

void LGLockscreenRefreshAllHosts(void) {
    UIApplication *app = UIApplication.sharedApplication;
    void (^refreshWindow)(UIWindow *) = ^(UIWindow *window) {
        LGLockscreenTraverseViews(window, ^(UIView *view) {
            if ([view isKindOfClass:[UILabel class]]) {
                updateSeamlessLabelColor((UILabel *)view);
                return;
            }
            if ([view isKindOfClass:NSClassFromString(@"MTMaterialView")]) {
                if (isPrimaryPlatterMaterialHost(view)) {
                    LGLockscreenInjectGlass(view, LGLockscreenCornerRadius());
                    LGAttachLockHostIfNeeded(view);
                    return;
                }
                if (isPrimaryActionButtonMaterialHost(view)) {
                    LGLockscreenInjectGlass(view, LGNotificationActionButtonCornerRadius(view));
                    LGAttachLockHostIfNeeded(view);
                    return;
                }
            }
            if (LGIsLockscreenQuickActionsHost(view)) {
                if (LG_prefBool(@"LockscreenQuickActions.Enabled", YES)) {
                    CGFloat cornerRadius = LGLockscreenQuickActionsCornerRadius(view);
                    LGLockscreenInjectGlassWithSettings(view,
                                                        cornerRadius,
                                                        LG_prefFloat(@"LockscreenQuickActions.BezelWidth", 12.0),
                                                        LG_prefFloat(@"LockscreenQuickActions.GlassThickness", 80.0),
                                                        LG_prefFloat(@"LockscreenQuickActions.RefractionScale", 1.2),
                                                        LG_prefFloat(@"LockscreenQuickActions.RefractiveIndex", 1.0),
                                                        LG_prefFloat(@"LockscreenQuickActions.SpecularOpacity", 0.8),
                                                        LG_prefFloat(@"LockscreenQuickActions.Blur", 8.0),
                                                        LG_prefFloat(@"LockscreenQuickActions.WallpaperScale", 0.5),
                                                        LG_prefFloat(@"LockscreenQuickActions.LightTintAlpha", 0.1),
                                                        LG_prefFloat(@"LockscreenQuickActions.DarkTintAlpha", 0.6));
                    LGAttachLockHostIfNeeded(view);
                } else {
                    LGCleanupLockscreenHost(view);
                }
            }
        });
    };
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in app.connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            for (UIWindow *window in ((UIWindowScene *)scene).windows) refreshWindow(window);
        }
    } else {
        for (UIWindow *window in [app valueForKey:@"windows"]) refreshWindow(window);
    }
}

%hook MTMaterialView

- (void)didMoveToWindow {
    %orig;
    UIView *self_ = (UIView *)self;

    if (!self_.window) {
        LGDetachLockHostIfNeeded(self_);
        return;
    }
    if (!LGLockscreenEnabled()) return;

    if (isPrimaryPlatterMaterialHost(self_)) {
        LGLockscreenInjectGlass(self_, LGLockscreenCornerRadius());
    } else if (isPrimaryActionButtonMaterialHost(self_)) {
        LGLockscreenInjectGlass(self_, LGNotificationActionButtonCornerRadius(self_));
    } else {
        return;
    }

    LGAttachLockHostIfNeeded(self_);
}

- (void)layoutSubviews {
    %orig;
    UIView *self_ = (UIView *)self;
    if (!self_.window) return;

    if (isPrimaryPlatterMaterialHost(self_)) {
        LGLockscreenInjectGlass(self_, LGLockscreenCornerRadius());
        LGAttachLockHostIfNeeded(self_);
        return;
    }
    if (isPrimaryActionButtonMaterialHost(self_)) {
        LGLockscreenInjectGlass(self_, LGNotificationActionButtonCornerRadius(self_));
        LGAttachLockHostIfNeeded(self_);
    }
}

%end

%hook UILabel

- (void)didMoveToWindow {
    %orig;
    updateSeamlessLabelColor(self);
}

%end

%hook SBCoverSheetViewController

- (void)viewWillAppear:(BOOL)animated {
    %orig;
    LGRefreshLockSnapshotAfterDelay(0.12);
}

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    LGRefreshLockSnapshotAfterDelay(0.45);
}

- (void)viewDidDisappear:(BOOL)animated {
    %orig;
    LGInvalidateLockscreenSnapshotCache();
}

%end

%hook SBDashBoardViewController

- (void)viewWillAppear:(BOOL)animated {
    %orig;
    LGRefreshLockSnapshotAfterDelay(0.12);
}

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    LGRefreshLockSnapshotAfterDelay(0.45);
}

- (void)viewDidDisappear:(BOOL)animated {
    %orig;
    LGInvalidateLockscreenSnapshotCache();
}

%end

%ctor {
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                    NULL,
                                    LG_lockscreenPrefsChanged,
                                    kLGPrefsChangedNotification,
                                    NULL,
                                    CFNotificationSuspensionBehaviorDeliverImmediately);
}
