#import "../LiquidGlass.h"
#import <objc/runtime.h>

static const NSTimeInterval kFolderOpenDisplayLinkGrace = 0.18;
static const NSInteger kFolderOpenTintTag = 0xF0D0;
static void *kFolderOpenOriginalAlphaKey = &kFolderOpenOriginalAlphaKey;
static void *kFolderOpenAttachedKey = &kFolderOpenAttachedKey;
static void *kFolderOpenGlassKey = &kFolderOpenGlassKey;
static void *kFolderOpenTintKey = &kFolderOpenTintKey;
static CFStringRef const kLGPrefsChangedNotification = CFSTR("dylv.liquidassprefs/Reload");

static BOOL isInsideOpenFolder(UIView *view) {
    static Class cls;
    if (!cls) cls = NSClassFromString(@"SBFolderBackgroundView");
    UIView *v = view.superview;
    while (v) {
        if ([v isKindOfClass:cls]) return YES;
        v = v.superview;
    }
    return NO;
}

static UIView *folderOpenContainerForView(UIView *view) {
    static Class cls;
    if (!cls) cls = NSClassFromString(@"SBFolderBackgroundView");
    UIView *v = view;
    while (v) {
        if ([v isKindOfClass:cls]) return v;
        v = v.superview;
    }
    return nil;
}

static void stopFolderDisplayLink(void);
static void scheduleFolderDisplayLinkStopIfIdle(void);
static void LGFolderOpenRefreshAllHosts(void);
static void LGFolderOpenTraverseViews(UIView *root, void (^block)(UIView *view));
static void LGFolderOpenForEachMaterialHost(void (^block)(UIView *view));
static void LGRestoreFolderOpenHost(UIView *view);
static void LGDetachFolderOpenHost(UIView *view);
static void LGHandleFolderOpenMaterialView(UIView *view, BOOL updateOnly);

static NSInteger sFolderCount = 0;
static NSUInteger sFolderStopGeneration = 0;
static BOOL LGFolderOpenEnabled(void) { return LG_globalEnabled() && LG_prefBool(@"FolderOpen.Enabled", YES); }
static CGFloat LGFolderOpenCornerRadius(void) { return LG_prefFloat(@"FolderOpen.CornerRadius", 38.0); }
static CGFloat LGFolderOpenBezelWidth(void) { return LG_prefFloat(@"FolderOpen.BezelWidth", 24.0); }
static CGFloat LGFolderOpenGlassThickness(void) { return LG_prefFloat(@"FolderOpen.GlassThickness", 100.0); }
static CGFloat LGFolderOpenRefractionScale(void) { return LG_prefFloat(@"FolderOpen.RefractionScale", 1.8); }
static CGFloat LGFolderOpenRefractiveIndex(void) { return LG_prefFloat(@"FolderOpen.RefractiveIndex", 1.2); }
static CGFloat LGFolderOpenSpecularOpacity(void) { return LG_prefFloat(@"FolderOpen.SpecularOpacity", 0.8); }
static CGFloat LGFolderOpenBlur(void) { return LG_prefFloat(@"FolderOpen.Blur", 25.0); }
static CGFloat LGFolderOpenWallpaperScale(void) { return LG_prefFloat(@"FolderOpen.WallpaperScale", 0.1); }
static CGFloat LGFolderOpenLightTintAlpha(void) { return LG_prefFloat(@"FolderOpen.LightTintAlpha", 0.1); }
static CGFloat LGFolderOpenDarkTintAlpha(void) { return LG_prefFloat(@"FolderOpen.DarkTintAlpha", 0.0); }

static UIColor *folderOpenTintColorForView(UIView *view) {
    if (@available(iOS 12.0, *)) {
        UITraitCollection *traits = view.traitCollection ?: UIScreen.mainScreen.traitCollection;
        if (traits.userInterfaceStyle == UIUserInterfaceStyleDark)
            return [UIColor colorWithWhite:0.0 alpha:LGFolderOpenDarkTintAlpha()];
    }
    return [UIColor colorWithWhite:1.0 alpha:LGFolderOpenLightTintAlpha()];
}

static void ensureFolderOpenTintOverlay(UIView *view) {
    UIView *tint = objc_getAssociatedObject(view, kFolderOpenTintKey);
    if (!tint) {
        tint = [[UIView alloc] initWithFrame:view.bounds];
        tint.tag = kFolderOpenTintTag;
        tint.userInteractionEnabled = NO;
        tint.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [view addSubview:tint];
        objc_setAssociatedObject(view, kFolderOpenTintKey, tint, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    tint.frame = view.bounds;
    tint.backgroundColor = folderOpenTintColorForView(view);
    tint.layer.cornerRadius = LGFolderOpenCornerRadius();
    if (@available(iOS 13.0, *))
        tint.layer.cornerCurve = view.layer.cornerCurve;
    [view bringSubviewToFront:tint];
}

@interface LGFolderTicker : NSObject
- (void)tick:(CADisplayLink *)dl;
@end

@implementation LGFolderTicker
- (void)tick:(CADisplayLink *)dl {
    LG_updateRegisteredGlassViews(LGUpdateGroupFolderOpen);
}
@end

static CADisplayLink *sFolderLink = nil;
static LGFolderTicker *sFolderTicker = nil;

static void startFolderDisplayLink(void) {
    sFolderStopGeneration++;
    if (sFolderLink) return;
    sFolderTicker = [LGFolderTicker new];
    sFolderLink = [CADisplayLink displayLinkWithTarget:sFolderTicker selector:@selector(tick:)];
    if ([sFolderLink respondsToSelector:@selector(setPreferredFramesPerSecond:)]) {
        sFolderLink.preferredFramesPerSecond = LG_prefInteger(@"Homescreen.FPS", 60);
    }
    [sFolderLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
}

static void stopFolderDisplayLink(void) {
    sFolderStopGeneration++;
    [sFolderLink invalidate];
    sFolderLink = nil;
    sFolderTicker = nil;
}

static void scheduleFolderDisplayLinkStopIfIdle(void) {
    NSUInteger generation = ++sFolderStopGeneration;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kFolderOpenDisplayLinkGrace * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (generation != sFolderStopGeneration) return;
        if (sFolderCount != 0) return;
        stopFolderDisplayLink();
    });
}

static UIView *LGPrimaryFolderOpenHostForContainer(UIView *container) {
    if (!container) return nil;
    __block UIView *bestView = nil;
    __block CGFloat bestArea = 0.0;
    Class materialCls = NSClassFromString(@"MTMaterialView");
    LGFolderOpenTraverseViews(container, ^(UIView *view) {
        if (view == container) return;
        if (!materialCls || ![view isKindOfClass:materialCls]) return;
        if (view.hidden || view.alpha <= 0.01f || view.layer.opacity <= 0.01f) return;
        CGSize size = view.bounds.size;
        if (size.width < 120.0 || size.height < 120.0) return;
        CGFloat area = size.width * size.height;
        if (area > bestArea) {
            bestArea = area;
            bestView = view;
        }
    });
    return bestView;
}

static BOOL LGIsPrimaryFolderOpenHost(UIView *view) {
    UIView *container = folderOpenContainerForView(view);
    if (!container) return NO;
    return LGPrimaryFolderOpenHostForContainer(container) == view;
}

static void LGRestoreFolderOpenHost(UIView *view) {
    UIView *tint = objc_getAssociatedObject(view, kFolderOpenTintKey);
    if (tint) [tint removeFromSuperview];
    objc_setAssociatedObject(view, kFolderOpenTintKey, nil, OBJC_ASSOCIATION_ASSIGN);

    LiquidGlassView *glass = objc_getAssociatedObject(view, kFolderOpenGlassKey);
    if (glass) [glass removeFromSuperview];
    objc_setAssociatedObject(view, kFolderOpenGlassKey, nil, OBJC_ASSOCIATION_ASSIGN);

    NSNumber *originalAlpha = objc_getAssociatedObject(view, kFolderOpenOriginalAlphaKey);
    if (originalAlpha) view.alpha = [originalAlpha doubleValue];
}

static void LGDetachFolderOpenHost(UIView *view) {
    LGRestoreFolderOpenHost(view);
    if (![objc_getAssociatedObject(view, kFolderOpenAttachedKey) boolValue]) return;
    objc_setAssociatedObject(view, kFolderOpenAttachedKey, nil, OBJC_ASSOCIATION_ASSIGN);
    sFolderCount = MAX(0, sFolderCount - 1);
    if (sFolderCount == 0) scheduleFolderDisplayLinkStopIfIdle();
}

static void injectIntoOpenFolder(UIView *host) {
    if (!LGFolderOpenEnabled()) {
        LGDetachFolderOpenHost(host);
        return;
    }
    if (!LGIsPrimaryFolderOpenHost(host)) {
        LGDetachFolderOpenHost(host);
        return;
    }

    UIImage *snapshot = LG_getFolderSnapshot();
    if (LG_imageLooksBlack(snapshot)) snapshot = nil;
    if (!snapshot) {
        snapshot = LG_getStrictCachedContextMenuSnapshot();
        if (LG_imageLooksBlack(snapshot)) snapshot = nil;
    }
    if (!snapshot) {
        NSNumber *originalAlpha = objc_getAssociatedObject(host, kFolderOpenOriginalAlphaKey);
        if (originalAlpha) host.alpha = [originalAlpha doubleValue];
        return;
    }

    if (!objc_getAssociatedObject(host, kFolderOpenOriginalAlphaKey))
        objc_setAssociatedObject(host, kFolderOpenOriginalAlphaKey, @(host.alpha), OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    LiquidGlassView *glass = objc_getAssociatedObject(host, kFolderOpenGlassKey);
    if (!glass) {
        glass = [[LiquidGlassView alloc] initWithFrame:host.bounds
                                             wallpaper:snapshot
                                       wallpaperOrigin:CGPointZero];
        glass.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        glass.userInteractionEnabled = NO;
        glass.updateGroup = LGUpdateGroupFolderOpen;
        [host insertSubview:glass atIndex:0];
        objc_setAssociatedObject(host, kFolderOpenGlassKey, glass, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    } else if (glass.wallpaperImage != snapshot) {
        glass.wallpaperImage = snapshot;
    }

    glass.cornerRadius = LGFolderOpenCornerRadius();
    glass.bezelWidth = LGFolderOpenBezelWidth();
    glass.glassThickness = LGFolderOpenGlassThickness();
    glass.refractionScale = LGFolderOpenRefractionScale();
    glass.refractiveIndex = LGFolderOpenRefractiveIndex();
    glass.specularOpacity = LGFolderOpenSpecularOpacity();
    glass.blur = LGFolderOpenBlur();
    glass.wallpaperScale = LGFolderOpenWallpaperScale();
    ensureFolderOpenTintOverlay(host);
    [glass updateOrigin];

    if (![objc_getAssociatedObject(host, kFolderOpenAttachedKey) boolValue]) {
        objc_setAssociatedObject(host, kFolderOpenAttachedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        sFolderCount++;
    }
    startFolderDisplayLink();
}

static void LGFolderOpenTraverseViews(UIView *root, void (^block)(UIView *view)) {
    if (!root) return;
    block(root);
    for (UIView *sub in root.subviews) LGFolderOpenTraverseViews(sub, block);
}

static void LGFolderOpenForEachMaterialHost(void (^block)(UIView *view)) {
    if (!block) return;
    UIApplication *app = UIApplication.sharedApplication;
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in app.connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            for (UIWindow *window in ((UIWindowScene *)scene).windows) {
                LGFolderOpenTraverseViews(window, ^(UIView *view) {
                    if (![view isKindOfClass:NSClassFromString(@"MTMaterialView")]) return;
                    if (!isInsideOpenFolder(view)) return;
                    block(view);
                });
            }
        }
    } else {
        for (UIWindow *window in [app valueForKey:@"windows"]) {
            LGFolderOpenTraverseViews(window, ^(UIView *view) {
                if (![view isKindOfClass:NSClassFromString(@"MTMaterialView")]) return;
                if (!isInsideOpenFolder(view)) return;
                block(view);
            });
        }
    }
}

static void LGHandleFolderOpenMaterialView(UIView *view, BOOL updateOnly) {
    if (!view) return;
    if (!view.window) {
        LGDetachFolderOpenHost(view);
        return;
    }
    if (!isInsideOpenFolder(view) || !LGIsPrimaryFolderOpenHost(view) || !LGFolderOpenEnabled()) {
        LGDetachFolderOpenHost(view);
        return;
    }
    if (!updateOnly) {
        injectIntoOpenFolder(view);
        return;
    }
    LiquidGlassView *glass = objc_getAssociatedObject(view, kFolderOpenGlassKey);
    ensureFolderOpenTintOverlay(view);
    if (!glass) {
        injectIntoOpenFolder(view);
        return;
    }
    glass.cornerRadius = LGFolderOpenCornerRadius();
    glass.bezelWidth = LGFolderOpenBezelWidth();
    glass.glassThickness = LGFolderOpenGlassThickness();
    glass.refractionScale = LGFolderOpenRefractionScale();
    glass.refractiveIndex = LGFolderOpenRefractiveIndex();
    glass.specularOpacity = LGFolderOpenSpecularOpacity();
    glass.blur = LGFolderOpenBlur();
    glass.wallpaperScale = LGFolderOpenWallpaperScale();
    [glass updateOrigin];
}

static void LGFolderOpenRefreshAllHosts(void) {
    LGFolderOpenForEachMaterialHost(^(UIView *view) {
        LGHandleFolderOpenMaterialView(view, NO);
    });
}

static void LGFolderOpenPrefsChanged(CFNotificationCenterRef center,
                                     void *observer,
                                     CFStringRef name,
                                     const void *object,
                                     CFDictionaryRef userInfo) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!LGFolderOpenEnabled()) {
            LGFolderOpenForEachMaterialHost(^(UIView *view) {
                LGDetachFolderOpenHost(view);
            });
            stopFolderDisplayLink();
            return;
        }
        LGFolderOpenRefreshAllHosts();
    });
}

%hook MTMaterialView

- (void)didMoveToWindow {
    %orig;
    UIView *self_ = (UIView *)self;
    LGHandleFolderOpenMaterialView(self_, NO);
}

- (void)layoutSubviews {
    %orig;
    UIView *self_ = (UIView *)self;
    LGHandleFolderOpenMaterialView(self_, YES);
}

%end

%ctor {
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                    NULL,
                                    LGFolderOpenPrefsChanged,
                                    kLGPrefsChangedNotification,
                                    NULL,
                                    CFNotificationSuspensionBehaviorDeliverImmediately);
}
