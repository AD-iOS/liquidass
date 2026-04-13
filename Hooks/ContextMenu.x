#import "../LiquidGlass.h"
#import <objc/runtime.h>

static const NSInteger kContextMenuGlassTag     = 0xBEEF;
static const NSInteger kContextMenuTintTag      = 0xDEAD;
static const NSInteger kContextMenuDividerTag   = 0xD171;
static CFStringRef const kLGPrefsChangedNotification = CFSTR("dylv.liquidassprefs/Reload");

static BOOL LGContextMenuEnabled(void) { return LG_globalEnabled() && LG_prefBool(@"ContextMenu.Enabled", YES); }
static CGFloat LGContextMenuCornerRadius(void) { return LG_prefFloat(@"ContextMenu.CornerRadius", 22.0); }
static CGFloat LGContextMenuBezelWidth(void) { return LG_prefFloat(@"ContextMenu.BezelWidth", 18.0); }
static CGFloat LGContextMenuGlassThickness(void) { return LG_prefFloat(@"ContextMenu.GlassThickness", 100.0); }
static CGFloat LGContextMenuRefraction(void) { return LG_prefFloat(@"ContextMenu.RefractionScale", 1.8); }
static CGFloat LGContextMenuRefractiveIndex(void) { return LG_prefFloat(@"ContextMenu.RefractiveIndex", 1.2); }
static CGFloat LGContextMenuSpecular(void) { return LG_prefFloat(@"ContextMenu.SpecularOpacity", 1.0); }
static CGFloat LGContextMenuBlur(void) { return LG_prefFloat(@"ContextMenu.Blur", 10.0); }
static CGFloat LGContextMenuLightTintAlpha(void) { return LG_prefFloat(@"ContextMenu.LightTintAlpha", 0.8); }
static CGFloat LGContextMenuDarkTintAlpha(void) { return LG_prefFloat(@"ContextMenu.DarkTintAlpha", 0.6); }
static CGFloat LGContextMenuWallpaperScale(void) { return LG_prefFloat(@"ContextMenu.WallpaperScale", 0.1); }
static CGFloat LGContextMenuRowInset(void) { return LG_prefFloat(@"ContextMenu.RowInset", 16.0); }
static CGFloat LGContextMenuIconSpacing(void) { return LG_prefFloat(@"ContextMenu.IconSpacing", 12.0); }

static NSInteger LGContextMenuPreferredFPS(void) {
    NSInteger maxFPS = UIScreen.mainScreen.maximumFramesPerSecond > 0
        ? UIScreen.mainScreen.maximumFramesPerSecond
        : 60;
    NSInteger fps = LG_prefInteger(@"Homescreen.FPS", maxFPS >= 120 ? 120 : 60);
    if (fps < 30) fps = 30;
    if (fps > maxFPS) fps = maxFPS;
    return fps;
}

static void stopContextMenuLink(void);
static void LGContextMenuRefreshAllHosts(void);

@interface LGContextMenuTicker : NSObject
- (void)tick:(CADisplayLink *)dl;
@end

@implementation LGContextMenuTicker
- (void)tick:(CADisplayLink *)dl {
    LG_updateRegisteredGlassViews(LGUpdateGroupContextMenu);
}
@end

static CADisplayLink       *sCtxLink   = nil;
static LGContextMenuTicker *sCtxTicker = nil;
static NSInteger            sCtxCount  = 0;
static void *kCtxContainerAttachedKey  = &kCtxContainerAttachedKey;
static void *kContextMenuBackdropAlphaKey = &kContextMenuBackdropAlphaKey;

static void startContextMenuLink(void) {
    if (sCtxLink) return;
    sCtxTicker = [LGContextMenuTicker new];
    sCtxLink   = [CADisplayLink displayLinkWithTarget:sCtxTicker
                                             selector:@selector(tick:)];
    if ([sCtxLink respondsToSelector:@selector(setPreferredFramesPerSecond:)])
        sCtxLink.preferredFramesPerSecond = LGContextMenuPreferredFPS();
    // common modes keeps it alive during the menu animation
    [sCtxLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
}

static void stopContextMenuLink(void) {
    [sCtxLink invalidate];
    sCtxLink   = nil;
    sCtxTicker = nil;
}

static BOOL hasAncestorClass(UIView *view, Class cls) {
    UIView *v = view.superview;
    while (v) {
        if ([v isKindOfClass:cls]) return YES;
        v = v.superview;
    }
    return NO;
}

static UIView *findDescendantMatching(UIView *root, BOOL (^match)(UIView *view)) {
    if (!root) return nil;
    for (UIView *sub in root.subviews) {
        if (match(sub)) return sub;
        UIView *found = findDescendantMatching(sub, match);
        if (found) return found;
    }
    return nil;
}

static BOOL shouldRoundContextMenuSubview(UIView *view) {
    CGSize size = view.bounds.size;
    if (size.width < 20.0 || size.height < 20.0) return NO;
    if (size.width <= 2.0 || size.height <= 2.0) return NO;
    return YES;
}

static BOOL shouldHideContextMenuSeparatorView(UIView *view) {
    if (!view || [view isKindOfClass:[LiquidGlassView class]]) return NO;
    if (view.tag == kContextMenuTintTag || view.tag == kContextMenuGlassTag || view.tag == kContextMenuDividerTag) return NO;
    if ([view isKindOfClass:[UIVisualEffectView class]]) return NO;

    NSString *clsName = NSStringFromClass(view.class);
    if ([clsName isEqualToString:@"_UIContextMenuReusableSeparatorView"]) return YES;
    if ([clsName containsString:@"Separator"]) {
        return YES;
    }

    CGSize size = view.bounds.size;
    BOOL thinHorizontal = size.height > 0.0 && size.height <= 2.0 && size.width >= 24.0;
    BOOL thinVertical = size.width > 0.0 && size.width <= 2.0 && size.height >= 24.0;
    if (thinHorizontal || thinVertical) {
        if (view.backgroundColor || view.layer.backgroundColor) return YES;
    }
    return NO;
}

static BOOL isContextMenuReusableGapView(UIView *view) {
    if (!view) return NO;
    return [NSStringFromClass(view.class) isEqualToString:@"UICollectionReusableView"];
}

static UIColor *contextMenuDividerColorForView(UIView *view) {
    if (@available(iOS 12.0, *)) {
        UITraitCollection *traits = view.traitCollection ?: UIScreen.mainScreen.traitCollection;
        if (traits.userInterfaceStyle == UIUserInterfaceStyleDark)
            return [UIColor colorWithWhite:1.0 alpha:0.16];
    }
    return [UIColor colorWithWhite:0.0 alpha:0.10];
}

static void styleContextMenuReusableGapView(UIView *view) {
    if (!view) return;
    view.hidden = NO;
    view.alpha = 1.0;
    view.backgroundColor = UIColor.clearColor;

    UIView *divider = [view viewWithTag:kContextMenuDividerTag];
    if (!divider) {
        divider = [[UIView alloc] initWithFrame:CGRectZero];
        divider.tag = kContextMenuDividerTag;
        divider.userInteractionEnabled = NO;
        [view addSubview:divider];
    }

    CGFloat inset = MAX(18.0, LGContextMenuRowInset());
    CGFloat lineHeight = 2.0;
    CGFloat width = MAX(0.0, view.bounds.size.width - inset * 2.0);
    CGFloat y = round((view.bounds.size.height - lineHeight) * 0.5);
    divider.frame = CGRectMake(inset, y, width, lineHeight);
    divider.backgroundColor = contextMenuDividerColorForView(view);
    divider.layer.cornerRadius = lineHeight * 0.5;
    divider.layer.masksToBounds = YES;

    for (UIView *inner in view.subviews) {
        if (inner == divider) continue;
        inner.hidden = YES;
        inner.alpha = 0.0;
    }
}

static BOOL LGIsContextMenuCollectionView(UICollectionView *collectionView) {
    if (!collectionView) return NO;
    static Class menuListCls;
    if (!menuListCls) menuListCls = NSClassFromString(@"_UIContextMenuListView");
    UIView *view = collectionView;
    while (view) {
        if (menuListCls && [view isKindOfClass:menuListCls]) return YES;
        view = view.superview;
    }
    return NO;
}

static void hideContextMenuSeparators(UIView *root) {
    for (UIView *sub in root.subviews) {
        if (shouldHideContextMenuSeparatorView(sub)) {
            sub.hidden = YES;
            sub.alpha = 0.0;
        } else if (isContextMenuReusableGapView(sub)) {
            styleContextMenuReusableGapView(sub);
        }
        hideContextMenuSeparators(sub);
    }
}

static UIColor *contextMenuTintColorForView(UIView *view) {
    if (@available(iOS 12.0, *)) {
        UITraitCollection *traits = view.traitCollection ?: UIScreen.mainScreen.traitCollection;
        if (traits.userInterfaceStyle == UIUserInterfaceStyleDark)
            return [UIColor colorWithWhite:0.0 alpha:LGContextMenuDarkTintAlpha()];
    }
    return [UIColor colorWithWhite:1.0 alpha:LGContextMenuLightTintAlpha()];
}

static void refreshContextMenuTint(UIView *root) {
    for (UIView *sub in root.subviews) {
        if (sub.tag == kContextMenuTintTag)
            sub.backgroundColor = contextMenuTintColorForView(root);
        refreshContextMenuTint(sub);
    }
}

static void relayoutContextMenuCellContent(UIView *contentView) {
    if (!LGContextMenuEnabled()) return;
    if (contentView.bounds.size.width < 40.0 || contentView.bounds.size.height < 20.0) return;

    UIImageView *iconView = (UIImageView *)findDescendantMatching(contentView, ^BOOL(UIView *view) {
        if (![view isKindOfClass:[UIImageView class]]) return NO;
        UIImageView *imageView = (UIImageView *)view;
        return imageView.image && imageView.bounds.size.width > 8.0 && imageView.bounds.size.height > 8.0;
    });
    if (!iconView) return;

    UIView *textView = findDescendantMatching(contentView, ^BOOL(UIView *view) {
        if ([view isKindOfClass:[UIStackView class]]) {
            for (UIView *sub in view.subviews)
                if ([sub isKindOfClass:[UILabel class]]) return YES;
        }
        return [view isKindOfClass:[UILabel class]];
    });
    if (!textView || textView == iconView) return;

    CGSize iconSize = iconView.bounds.size;
    if (iconSize.width <= 0.0 || iconSize.height <= 0.0)
        iconSize = CGSizeMake(18.0, 18.0);

    CGFloat iconX = LGContextMenuRowInset();
    CGFloat iconY = round((contentView.bounds.size.height - iconSize.height) * 0.5);
    iconView.frame = CGRectMake(iconX, iconY, iconSize.width, iconSize.height);

    CGRect textFrame = textView.frame;
    CGFloat textX = CGRectGetMaxX(iconView.frame) + LGContextMenuIconSpacing();
    CGFloat maxWidth = contentView.bounds.size.width - textX - LGContextMenuRowInset();
    if (maxWidth < 20.0) return;
    textFrame.origin.x = textX;
    textFrame.size.width = maxWidth;
    textView.frame = CGRectIntegral(textFrame);
}

static void setBackdropHiddenInEffectView(UIView *effectView, BOOL hidden) {
    static Class backdropCls;
    for (UIView *sub in effectView.subviews) {
        if (!backdropCls && [NSStringFromClass(sub.class) containsString:@"Backdrop"])
            backdropCls = sub.class;
        if (backdropCls && [sub isKindOfClass:backdropCls]) {
            if (!objc_getAssociatedObject(sub, kContextMenuBackdropAlphaKey))
                objc_setAssociatedObject(sub, kContextMenuBackdropAlphaKey, @(sub.alpha), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            NSNumber *originalAlpha = objc_getAssociatedObject(sub, kContextMenuBackdropAlphaKey);
            sub.alpha = hidden ? 0.0 : (originalAlpha ? [originalAlpha doubleValue] : 1.0);
            return;
        }
        for (UIView *inner in sub.subviews) {
            if (!backdropCls && [NSStringFromClass(inner.class) containsString:@"Backdrop"])
                backdropCls = inner.class;
            if (backdropCls && [inner isKindOfClass:backdropCls]) {
                if (!objc_getAssociatedObject(inner, kContextMenuBackdropAlphaKey))
                    objc_setAssociatedObject(inner, kContextMenuBackdropAlphaKey, @(inner.alpha), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                NSNumber *originalAlpha = objc_getAssociatedObject(inner, kContextMenuBackdropAlphaKey);
                inner.alpha = hidden ? 0.0 : (originalAlpha ? [originalAlpha doubleValue] : 1.0);
                return;
            }
        }
    }
}

static void injectGlassIntoEffectView(UIVisualEffectView *fxView, int attempt) {
    UIView *container = fxView.contentView;

    for (NSInteger i = container.subviews.count - 1; i >= 0; i--) {
        UIView *sub = container.subviews[i];
        if ([sub isKindOfClass:[LiquidGlassView class]] || sub.tag == kContextMenuTintTag)
            [sub removeFromSuperview];
    }

    if (!LGContextMenuEnabled()) return;

    if (container.bounds.size.width < 10 || container.bounds.size.height < 10) {
        // springboard sometimes gives us zero-ish bounds for a bit
        if (attempt >= 10) return;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if (fxView.window) injectGlassIntoEffectView(fxView, attempt + 1);
        });
        return;
    }

    UIImage *wallpaper = LG_getCachedContextMenuSnapshot();
    if (!wallpaper) return;

    LiquidGlassView *glass = [[LiquidGlassView alloc]
        initWithFrame:container.bounds wallpaper:wallpaper wallpaperOrigin:CGPointZero];
    glass.autoresizingMask = UIViewAutoresizingFlexibleWidth |
                             UIViewAutoresizingFlexibleHeight;
    glass.cornerRadius    = LGContextMenuCornerRadius();
    glass.blur            = LGContextMenuBlur();
    glass.refractionScale = LGContextMenuRefraction();
    glass.refractiveIndex = LGContextMenuRefractiveIndex();
    glass.bezelWidth      = LGContextMenuBezelWidth();
    glass.glassThickness  = LGContextMenuGlassThickness();
    glass.specularOpacity = LGContextMenuSpecular();
    glass.releasesWallpaperAfterUpload = YES;
    glass.wallpaperScale  = LGContextMenuWallpaperScale();
    glass.updateGroup     = LGUpdateGroupContextMenu;
    [container insertSubview:glass atIndex:0];
    [glass updateOrigin];

    UIView *tint = [[UIView alloc] initWithFrame:container.bounds];
    tint.tag                    = kContextMenuTintTag;
    tint.backgroundColor        = contextMenuTintColorForView(container);
    tint.autoresizingMask       = UIViewAutoresizingFlexibleWidth |
                                  UIViewAutoresizingFlexibleHeight;
    tint.userInteractionEnabled = NO;
    [container insertSubview:tint aboveSubview:glass];

}

static void LGContextMenuTraverseViews(UIView *root, void (^block)(UIView *view)) {
    if (!root) return;
    block(root);
    for (UIView *sub in root.subviews) LGContextMenuTraverseViews(sub, block);
}

static void LGContextMenuRefreshAllHosts(void) {
    UIApplication *app = UIApplication.sharedApplication;
    void (^refreshWindow)(UIWindow *) = ^(UIWindow *window) {
        LGContextMenuTraverseViews(window, ^(UIView *view) {
            if (![view isKindOfClass:[UIVisualEffectView class]]) return;
            UIVisualEffectView *fx = (UIVisualEffectView *)view;
            static Class listCls;
            if (!listCls) listCls = NSClassFromString(@"_UIContextMenuListView");
            if (!(fx.tag == kContextMenuGlassTag || hasAncestorClass(fx, listCls))) return;
            injectGlassIntoEffectView(fx, 0);
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

static void LGContextMenuPrefsChanged(CFNotificationCenterRef center,
                                      void *observer,
                                      CFStringRef name,
                                      const void *object,
                                      CFDictionaryRef userInfo) {
    dispatch_async(dispatch_get_main_queue(), ^{
        LGContextMenuRefreshAllHosts();
    });
}

%hook UIVisualEffectView

- (void)didMoveToWindow {
    %orig;
    UIView *self_ = (UIView *)self;

    if (!self_.window) {
        if (self_.tag == kContextMenuGlassTag) self_.tag = 0;
        return;
    }

    static Class listCls;
    if (!listCls) listCls = NSClassFromString(@"_UIContextMenuListView");
    if (!hasAncestorClass(self_, listCls)) return;
    if (self_.tag == kContextMenuGlassTag) return;
    self_.tag = kContextMenuGlassTag;
    setBackdropHiddenInEffectView(self_, LGContextMenuEnabled());
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (self_.window) injectGlassIntoEffectView((UIVisualEffectView *)self_, 0);
    });
}

%end

%hook UICollectionReusableView

- (void)didMoveToWindow {
    %orig;
    UIView *self_ = (UIView *)self;
    static Class menuListCls;
    if (!menuListCls) menuListCls = NSClassFromString(@"_UIContextMenuListView");
    if (!isContextMenuReusableGapView(self_)) return;
    if (![self_ isDescendantOfView:(UIView *)self_.superview] && !hasAncestorClass(self_, menuListCls)) return;
    if (!hasAncestorClass(self_, menuListCls)) return;
    styleContextMenuReusableGapView(self_);
}

- (void)layoutSubviews {
    %orig;
    UIView *self_ = (UIView *)self;
    static Class menuListCls;
    if (!menuListCls) menuListCls = NSClassFromString(@"_UIContextMenuListView");
    if (!isContextMenuReusableGapView(self_)) return;
    if (!hasAncestorClass(self_, menuListCls)) return;
    styleContextMenuReusableGapView(self_);
}

- (id)preferredLayoutAttributesFittingAttributes:(id)attributes {
    return %orig;
}

%end

%hook UICollectionView

- (void)layoutSubviews {
    %orig;
    if (!LGIsContextMenuCollectionView(self)) return;
    hideContextMenuSeparators(self);
}

%end

%ctor {
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                    NULL,
                                    LGContextMenuPrefsChanged,
                                    kLGPrefsChangedNotification,
                                    NULL,
                                    CFNotificationSuspensionBehaviorDeliverImmediately);
}

%hook UIView

- (void)didMoveToWindow {
    %orig;
    static Class containerCls;
    if (!containerCls) containerCls = NSClassFromString(@"_UIContextMenuContainerView");
    if (![self isKindOfClass:containerCls]) return;

    if (self.window) {
        if (![objc_getAssociatedObject(self, kCtxContainerAttachedKey) boolValue]) {
            objc_setAssociatedObject(self, kCtxContainerAttachedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            LG_cacheContextMenuSnapshot();
            sCtxCount++;
            startContextMenuLink();
        }
    } else {
        if ([objc_getAssociatedObject(self, kCtxContainerAttachedKey) boolValue]) {
            objc_setAssociatedObject(self, kCtxContainerAttachedKey, nil, OBJC_ASSOCIATION_ASSIGN);
            sCtxCount = MAX(0, sCtxCount - 1);
            if (sCtxCount == 0) stopContextMenuLink();
            LG_invalidateContextMenuSnapshot();
        }
    }
}

- (void)didAddSubview:(UIView *)subview {
    %orig;
    static Class fxCls, listCls, backdropCls;
    if (!fxCls)   fxCls   = [UIVisualEffectView class];
    if (!listCls) listCls = NSClassFromString(@"_UIContextMenuListView");

    if ([self isKindOfClass:fxCls]) {
        if (!backdropCls) {
            NSString *subClsName = NSStringFromClass(subview.class);
            if ([subClsName containsString:@"Backdrop"]) backdropCls = subview.class;
        }
        if (backdropCls && [subview isKindOfClass:backdropCls]
            && (hasAncestorClass(self, NSClassFromString(@"_UIContextMenuContainerView"))
             || hasAncestorClass(self, listCls))) {
            if (!objc_getAssociatedObject(subview, kContextMenuBackdropAlphaKey))
                objc_setAssociatedObject(subview, kContextMenuBackdropAlphaKey, @(subview.alpha), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            NSNumber *originalAlpha = objc_getAssociatedObject(subview, kContextMenuBackdropAlphaKey);
            subview.alpha = LGContextMenuEnabled() ? 0.0 : (originalAlpha ? [originalAlpha doubleValue] : 1.0);
            return;
        }
    }

    static Class menuListCls;
    if (!menuListCls) menuListCls = NSClassFromString(@"_UIContextMenuListView");
    if ([self isKindOfClass:menuListCls] && [subview isKindOfClass:[UIView class]]
        && ![subview isKindOfClass:[UIVisualEffectView class]]
        && shouldRoundContextMenuSubview(subview)) {
        subview.layer.cornerRadius = LGContextMenuCornerRadius();
        if (@available(iOS 13.0, *))
            subview.layer.cornerCurve = kCACornerCurveContinuous;
    }
    if ([self isKindOfClass:menuListCls] || hasAncestorClass(self, menuListCls)) {
        hideContextMenuSeparators(self);
        if (subview != self) hideContextMenuSeparators(subview);
    }
}

- (void)layoutSubviews {
    %orig;
    refreshContextMenuTint(self);
    static Class cellContentCls;
    if (!cellContentCls) cellContentCls = NSClassFromString(@"_UIContextMenuCellContentView");
    if (cellContentCls && [self isKindOfClass:cellContentCls]) {
        relayoutContextMenuCellContent(self);
        return;
    }
    static Class menuListCls;
    if (!menuListCls) menuListCls = NSClassFromString(@"_UIContextMenuListView");
    if (!shouldRoundContextMenuSubview(self)) return;
    if (self.layer.cornerRadius == LGContextMenuCornerRadius()) return;
    if (!hasAncestorClass(self, menuListCls)) return;
    hideContextMenuSeparators(self);
    self.layer.cornerRadius = LGContextMenuCornerRadius();
    if (@available(iOS 13.0, *))
        self.layer.cornerCurve = kCACornerCurveContinuous;
}

%end
