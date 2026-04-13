#import "../LiquidGlass.h"
#import <objc/runtime.h>

static const NSInteger kWidgetTintTag       = 0x71D0;
static CFStringRef const kLGPrefsChangedNotification = CFSTR("dylv.liquidassprefs/Reload");

static void LGStartWidgetDisplayLink(void);
static void LGStopWidgetDisplayLink(void);
static void LGWidgetsRefreshAllHosts(void);
static void *kWidgetAttachedKey = &kWidgetAttachedKey;
static void *kWidgetGlassKey = &kWidgetGlassKey;
static void *kWidgetTintKey = &kWidgetTintKey;
static void *kWidgetOriginalAlphaKey = &kWidgetOriginalAlphaKey;
static void *kWidgetOriginalCornerRadiusKey = &kWidgetOriginalCornerRadiusKey;
static void *kWidgetOriginalClipsKey = &kWidgetOriginalClipsKey;
static void *kWidgetOriginalCornerCurveKey = &kWidgetOriginalCornerCurveKey;

@interface LGWidgetTicker : NSObject
- (void)tick:(CADisplayLink *)dl;
@end

@implementation LGWidgetTicker
- (void)tick:(CADisplayLink *)dl {
    LG_updateRegisteredGlassViews(LGUpdateGroupWidgets);
}
@end

static CADisplayLink *sWidgetLink = nil;
static LGWidgetTicker *sWidgetTicker = nil;
static NSInteger sWidgetCount = 0;

static BOOL LGWidgetEnabled(void) { return LG_globalEnabled() && LG_prefBool(@"Widgets.Enabled", NO); }
static CGFloat LGWidgetCornerRadius(void) { return LG_prefFloat(@"Widgets.CornerRadius", 20.2); }
static CGFloat LGWidgetBezelWidth(void) { return LG_prefFloat(@"Widgets.BezelWidth", 18.0); }
static CGFloat LGWidgetGlassThickness(void) { return LG_prefFloat(@"Widgets.GlassThickness", 150.0); }
static CGFloat LGWidgetRefractionScale(void) { return LG_prefFloat(@"Widgets.RefractionScale", 1.8); }
static CGFloat LGWidgetRefractiveIndex(void) { return LG_prefFloat(@"Widgets.RefractiveIndex", 1.2); }
static CGFloat LGWidgetSpecularOpacity(void) { return LG_prefFloat(@"Widgets.SpecularOpacity", 0.8); }
static CGFloat LGWidgetBlur(void) { return LG_prefFloat(@"Widgets.Blur", 8.0); }
static CGFloat LGWidgetWallpaperScale(void) { return LG_prefFloat(@"Widgets.WallpaperScale", 0.5); }
static CGFloat LGWidgetLightTintAlpha(void) { return LG_prefFloat(@"Widgets.LightTintAlpha", 0.1); }
static CGFloat LGWidgetDarkTintAlpha(void) { return LG_prefFloat(@"Widgets.DarkTintAlpha", 0.3); }

static NSInteger LGWidgetPreferredFPS(void) {
    NSInteger maxFPS = UIScreen.mainScreen.maximumFramesPerSecond > 0
        ? UIScreen.mainScreen.maximumFramesPerSecond
        : 60;
    NSInteger fps = LG_prefInteger(@"Homescreen.FPS", maxFPS >= 120 ? 120 : 60);
    if (fps < 30) fps = 30;
    if (fps > maxFPS) fps = maxFPS;
    return fps;
}

static BOOL LGViewBelongsToWidgetStack(UIView *view) {
    if (!view) return NO;

    NSString *selfClassName = NSStringFromClass([view class]);
    if ([selfClassName containsString:@"Widget"] || [selfClassName containsString:@"WG"]) {
        return YES;
    }

    UIView *ancestor = view.superview;
    while (ancestor) {
        NSString *className = NSStringFromClass([ancestor class]);
        if ([className containsString:@"Widget"] || [className containsString:@"WG"])
            return YES;
        ancestor = ancestor.superview;
    }
    return NO;
}

static BOOL LGHasAncestorClassNamed(UIView *view, NSString *className) {
    UIView *ancestor = view.superview;
    while (ancestor) {
        if ([NSStringFromClass([ancestor class]) isEqualToString:className]) return YES;
        ancestor = ancestor.superview;
    }
    return NO;
}

static BOOL LGResponderChainContainsClassNamed(UIResponder *responder, NSString *className) {
    UIResponder *current = responder;
    while (current) {
        if ([NSStringFromClass([current class]) isEqualToString:className]) return YES;
        current = current.nextResponder;
    }
    return NO;
}

static void LGStartWidgetDisplayLink(void) {
    if (sWidgetLink) return;
    sWidgetTicker = [LGWidgetTicker new];
    sWidgetLink = [CADisplayLink displayLinkWithTarget:sWidgetTicker selector:@selector(tick:)];
    if ([sWidgetLink respondsToSelector:@selector(setPreferredFramesPerSecond:)])
        sWidgetLink.preferredFramesPerSecond = LGWidgetPreferredFPS();
    [sWidgetLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
}

static void LGStopWidgetDisplayLink(void) {
    [sWidgetLink invalidate];
    sWidgetLink = nil;
    sWidgetTicker = nil;
}

static UIColor *widgetTintColorForView(UIView *view) {
    if (@available(iOS 12.0, *)) {
        UITraitCollection *traits = view.traitCollection ?: UIScreen.mainScreen.traitCollection;
        if (traits.userInterfaceStyle == UIUserInterfaceStyleDark)
            return [UIColor colorWithWhite:0.0 alpha:LGWidgetDarkTintAlpha()];
    }
    return [UIColor colorWithWhite:1.0 alpha:LGWidgetLightTintAlpha()];
}

static void removeWidgetOverlays(UIView *view) {
    UIView *tint = objc_getAssociatedObject(view, kWidgetTintKey);
    if (tint) [tint removeFromSuperview];
    objc_setAssociatedObject(view, kWidgetTintKey, nil, OBJC_ASSOCIATION_ASSIGN);
    LiquidGlassView *glass = objc_getAssociatedObject(view, kWidgetGlassKey);
    if (glass) [glass removeFromSuperview];
    objc_setAssociatedObject(view, kWidgetGlassKey, nil, OBJC_ASSOCIATION_ASSIGN);
}

static void LGRememberWidgetOriginalState(UIView *view) {
    if (!objc_getAssociatedObject(view, kWidgetOriginalAlphaKey))
        objc_setAssociatedObject(view, kWidgetOriginalAlphaKey, @(view.alpha), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (!objc_getAssociatedObject(view, kWidgetOriginalCornerRadiusKey))
        objc_setAssociatedObject(view, kWidgetOriginalCornerRadiusKey, @(view.layer.cornerRadius), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (!objc_getAssociatedObject(view, kWidgetOriginalClipsKey))
        objc_setAssociatedObject(view, kWidgetOriginalClipsKey, @(view.clipsToBounds), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (!objc_getAssociatedObject(view, kWidgetOriginalCornerCurveKey)) {
        NSString *curve = nil;
        if (@available(iOS 13.0, *))
            curve = view.layer.cornerCurve;
        if (curve)
            objc_setAssociatedObject(view, kWidgetOriginalCornerCurveKey, curve, OBJC_ASSOCIATION_COPY_NONATOMIC);
    }
}

static void LGRestoreWidgetOriginalState(UIView *view) {
    NSNumber *alpha = objc_getAssociatedObject(view, kWidgetOriginalAlphaKey);
    if (alpha) view.alpha = [alpha doubleValue];
    NSNumber *radius = objc_getAssociatedObject(view, kWidgetOriginalCornerRadiusKey);
    if (radius) view.layer.cornerRadius = [radius doubleValue];
    NSNumber *clips = objc_getAssociatedObject(view, kWidgetOriginalClipsKey);
    if (clips) view.clipsToBounds = [clips boolValue];
    NSString *curve = objc_getAssociatedObject(view, kWidgetOriginalCornerCurveKey);
    if (@available(iOS 13.0, *)) {
        if (curve) view.layer.cornerCurve = curve;
    }
}

static void ensureWidgetTintOverlay(UIView *view) {
    UIView *tint = objc_getAssociatedObject(view, kWidgetTintKey);
    if (!tint) {
        tint = [[UIView alloc] initWithFrame:view.bounds];
        tint.tag = kWidgetTintTag;
        tint.userInteractionEnabled = NO;
        tint.autoresizingMask = UIViewAutoresizingFlexibleWidth |
                                UIViewAutoresizingFlexibleHeight;
        [view addSubview:tint];
        objc_setAssociatedObject(view, kWidgetTintKey, tint, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    tint.frame = view.bounds;
    tint.backgroundColor = widgetTintColorForView(view);
    tint.layer.cornerRadius = view.layer.cornerRadius;
    if (@available(iOS 13.0, *))
        tint.layer.cornerCurve = view.layer.cornerCurve;
    [view bringSubviewToFront:tint];
}

static BOOL LGIsWidgetMaterialView(UIView *view) {
    if (!view.window) return NO;
    if (![NSStringFromClass([view class]) isEqualToString:@"MTMaterialView"]) return NO;
    if (!LGResponderChainContainsClassNamed(view, @"SBHWidgetStackViewController")) return NO;

    // Keep this scoped to the large widget material background, not auxiliary controls.
    if (LGHasAncestorClassNamed(view, @"WGShortLookStyleButton")) return NO;
    if ([view isKindOfClass:[UIControl class]]) return NO;
    if ([view isKindOfClass:[UILabel class]]) return NO;
    if ([view isKindOfClass:[UIImageView class]]) return NO;
    if ([view isKindOfClass:[UIScrollView class]]) return NO;
    if (view.bounds.size.width < 120.0 || view.bounds.size.height < 120.0) return NO;

    return YES;
}

static void LGPrepareWidgetMaterialView(UIView *view) {
    LGRememberWidgetOriginalState(view);
    view.layer.cornerRadius = LGWidgetCornerRadius();
    if (@available(iOS 13.0, *))
        view.layer.cornerCurve = kCACornerCurveContinuous;
    view.clipsToBounds = YES;
}

static void LGInjectIntoWidgetMaterialView(UIView *view) {
    if (!LGWidgetEnabled()) {
        removeWidgetOverlays(view);
        LGRestoreWidgetOriginalState(view);
        return;
    }
    LiquidGlassView *glass = objc_getAssociatedObject(view, kWidgetGlassKey);

    CGPoint wallpaperOrigin = CGPointZero;
    UIImage *wallpaper = LG_getWallpaperImage(&wallpaperOrigin);
    if (!wallpaper) {
        removeWidgetOverlays(view);
        LGRestoreWidgetOriginalState(view);
        return;
    }

    LGPrepareWidgetMaterialView(view);

    if (!glass) {
        glass = [[LiquidGlassView alloc]
            initWithFrame:view.bounds wallpaper:wallpaper wallpaperOrigin:wallpaperOrigin];
        glass.autoresizingMask       = UIViewAutoresizingFlexibleWidth |
                                       UIViewAutoresizingFlexibleHeight;
        glass.userInteractionEnabled = NO;
        glass.cornerRadius           = LGWidgetCornerRadius();
        glass.bezelWidth             = LGWidgetBezelWidth();
        glass.glassThickness         = LGWidgetGlassThickness();
        glass.refractionScale        = LGWidgetRefractionScale();
        glass.refractiveIndex        = LGWidgetRefractiveIndex();
        glass.specularOpacity        = LGWidgetSpecularOpacity();
        glass.blur                   = LGWidgetBlur();
        glass.wallpaperScale         = LGWidgetWallpaperScale();
        glass.updateGroup            = LGUpdateGroupWidgets;
        [view insertSubview:glass atIndex:0];
        objc_setAssociatedObject(view, kWidgetGlassKey, glass, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    glass.cornerRadius = LGWidgetCornerRadius();
    glass.bezelWidth = LGWidgetBezelWidth();
    glass.glassThickness = LGWidgetGlassThickness();
    glass.refractionScale = LGWidgetRefractionScale();
    glass.refractiveIndex = LGWidgetRefractiveIndex();
    glass.specularOpacity = LGWidgetSpecularOpacity();
    glass.blur = LGWidgetBlur();
    glass.wallpaperScale = LGWidgetWallpaperScale();
    [glass updateOrigin];
    ensureWidgetTintOverlay(view);
    dispatch_async(dispatch_get_main_queue(), ^{
        if (view.window) ensureWidgetTintOverlay(view);
    });
}

static void LGWidgetsTraverseViews(UIView *root, void (^block)(UIView *view)) {
    if (!root) return;
    block(root);
    for (UIView *sub in root.subviews) LGWidgetsTraverseViews(sub, block);
}

static void LGWidgetsRefreshAllHosts(void) {
    UIApplication *app = UIApplication.sharedApplication;
    void (^refreshWindow)(UIWindow *) = ^(UIWindow *window) {
        LGWidgetsTraverseViews(window, ^(UIView *view) {
            if (!LGIsWidgetMaterialView(view)) return;
            LGPrepareWidgetMaterialView(view);
            LGInjectIntoWidgetMaterialView(view);
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

static void LGWidgetsPrefsChanged(CFNotificationCenterRef center,
                                  void *observer,
                                  CFStringRef name,
                                  const void *object,
                                  CFDictionaryRef userInfo) {
    dispatch_async(dispatch_get_main_queue(), ^{
        LGWidgetsRefreshAllHosts();
    });
}

%hook MTMaterialView

- (void)didMoveToWindow {
    %orig;
    UIView *self_ = (UIView *)self;

    if (!self_.window) {
        removeWidgetOverlays(self_);
        LGRestoreWidgetOriginalState(self_);
        if ([objc_getAssociatedObject(self_, kWidgetAttachedKey) boolValue]) {
            objc_setAssociatedObject(self_, kWidgetAttachedKey, nil, OBJC_ASSOCIATION_ASSIGN);
            sWidgetCount = MAX(0, sWidgetCount - 1);
            if (sWidgetCount == 0) LGStopWidgetDisplayLink();
        }
        return;
    }

    if (!LGIsWidgetMaterialView(self_)) return;
    LGInjectIntoWidgetMaterialView(self_);
    if (![objc_getAssociatedObject(self_, kWidgetAttachedKey) boolValue]) {
        objc_setAssociatedObject(self_, kWidgetAttachedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        sWidgetCount++;
        LGStartWidgetDisplayLink();
    }
}

- (void)layoutSubviews {
    %orig;
    UIView *self_ = (UIView *)self;
    if (!LGIsWidgetMaterialView(self_)) return;
    if (!LGWidgetEnabled()) {
        removeWidgetOverlays(self_);
        LGRestoreWidgetOriginalState(self_);
        return;
    }
    ensureWidgetTintOverlay(self_);
    LiquidGlassView *glass = objc_getAssociatedObject(self_, kWidgetGlassKey);
    [glass updateOrigin];
}

%end

%ctor {
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                    NULL,
                                    LGWidgetsPrefsChanged,
                                    kLGPrefsChangedNotification,
                                    NULL,
                                    CFNotificationSuspensionBehaviorDeliverImmediately);
}

%hook UIScrollView

- (void)setContentOffset:(CGPoint)offset {
    %orig;
    if (!LGViewBelongsToWidgetStack((UIView *)self)) return;
    if (!sWidgetLink) LG_updateRegisteredGlassViews(LGUpdateGroupWidgets);
}

- (void)setContentOffset:(CGPoint)offset animated:(BOOL)animated {
    %orig;
    if (!LGViewBelongsToWidgetStack((UIView *)self)) return;
    if (!sWidgetLink) LG_updateRegisteredGlassViews(LGUpdateGroupWidgets);
}

%end
