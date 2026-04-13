#import "../LiquidGlass.h"
#import <objc/runtime.h>

static const NSInteger kFolderIconTintTag      = 0xF01D;
static CFStringRef const kLGPrefsChangedNotification = CFSTR("dylv.liquidassprefs/Reload");
static NSUInteger sFolderSnapshotGeneration = 0;

static BOOL isInsideFolderIcon(UIView *view) {
    static Class folderIconCls, iconViewCls;
    if (!folderIconCls) folderIconCls = NSClassFromString(@"SBFolderIconImageView");
    if (!iconViewCls)   iconViewCls   = NSClassFromString(@"SBIconView");
    UIView *v = view.superview;
    while (v) {
        if ([v isKindOfClass:folderIconCls]) return YES;
        if ([v isKindOfClass:iconViewCls])   break;
        v = v.superview;
    }
    return NO;
}

static void *kFolderIconRetryKey = &kFolderIconRetryKey;
static void *kFolderIconGlassKey = &kFolderIconGlassKey;
static void *kFolderIconTintKey = &kFolderIconTintKey;
static void *kFolderIconLastPageKey = &kFolderIconLastPageKey;

static void LGScheduleFolderSnapshotWarmup(NSTimeInterval delay) {
    if (LG_getFolderSnapshot()) return;
    NSUInteger generation = ++sFolderSnapshotGeneration;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (generation != sFolderSnapshotGeneration) return;
        if (LG_getFolderSnapshot()) return;
        LG_cacheFolderSnapshot();
    });
}

static BOOL LGFolderScrollIsSettled(UIScrollView *scrollView) {
    if (!scrollView) return NO;
    if (scrollView.dragging || scrollView.decelerating || scrollView.tracking) return NO;
    CGFloat pageWidth = CGRectGetWidth(scrollView.bounds);
    if (pageWidth <= 1.0) return YES;
    CGFloat page = scrollView.contentOffset.x / pageWidth;
    return fabs(page - round(page)) < 0.02;
}

static void LGScheduleFolderSnapshotWarmupForScroll(UIScrollView *scrollView, NSTimeInterval delay) {
    if (!scrollView) return;
    if (LG_getFolderSnapshot()) return;
    NSUInteger generation = ++sFolderSnapshotGeneration;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (generation != sFolderSnapshotGeneration) return;
        if (LG_getFolderSnapshot()) return;
        if (!LGFolderScrollIsSettled(scrollView)) {
            LGScheduleFolderSnapshotWarmupForScroll(scrollView, 0.12);
            return;
        }
        LG_cacheFolderSnapshot();
    });
}

static BOOL LGFolderIconEnabled(void) { return LG_globalEnabled() && LG_prefBool(@"FolderIcon.Enabled", YES); }
static CGFloat LGFolderIconCornerRadius(CGFloat fallback) { return LG_prefFloat(@"FolderIcon.CornerRadius", fallback); }
static CGFloat LGFolderIconBezelWidth(void) { return LG_prefFloat(@"FolderIcon.BezelWidth", 12.0); }
static CGFloat LGFolderIconGlassThickness(void) { return LG_prefFloat(@"FolderIcon.GlassThickness", 90.0); }
static CGFloat LGFolderIconRefractionScale(void) { return LG_prefFloat(@"FolderIcon.RefractionScale", 2.0); }
static CGFloat LGFolderIconRefractiveIndex(void) { return LG_prefFloat(@"FolderIcon.RefractiveIndex", 2.0); }
static CGFloat LGFolderIconSpecularOpacity(void) { return LG_prefFloat(@"FolderIcon.SpecularOpacity", 0.8); }
static CGFloat LGFolderIconBlur(void) { return LG_prefFloat(@"FolderIcon.Blur", 3.0); }
static CGFloat LGFolderIconWallpaperScale(void) { return LG_prefFloat(@"FolderIcon.WallpaperScale", 0.5); }
static CGFloat LGFolderIconLightTintAlpha(void) { return LG_prefFloat(@"FolderIcon.LightTintAlpha", 0.1); }
static CGFloat LGFolderIconDarkTintAlpha(void) { return LG_prefFloat(@"FolderIcon.DarkTintAlpha", 0.0); }

static UIColor *folderIconTintColorForView(UIView *view) {
    if (@available(iOS 12.0, *)) {
        UITraitCollection *traits = view.traitCollection ?: UIScreen.mainScreen.traitCollection;
        if (traits.userInterfaceStyle == UIUserInterfaceStyleDark)
            return [UIColor colorWithWhite:0.0 alpha:LGFolderIconDarkTintAlpha()];
    }
    return [UIColor colorWithWhite:1.0 alpha:LGFolderIconLightTintAlpha()];
}

static void removeFolderIconOverlays(UIView *self_) {
    UIView *tint = objc_getAssociatedObject(self_, kFolderIconTintKey);
    if (tint) [tint removeFromSuperview];
    objc_setAssociatedObject(self_, kFolderIconTintKey, nil, OBJC_ASSOCIATION_ASSIGN);
    LiquidGlassView *glass = objc_getAssociatedObject(self_, kFolderIconGlassKey);
    if (glass) [glass removeFromSuperview];
    objc_setAssociatedObject(self_, kFolderIconGlassKey, nil, OBJC_ASSOCIATION_ASSIGN);
}

static void ensureFolderIconTintOverlay(UIView *self_) {
    UIView *tint = objc_getAssociatedObject(self_, kFolderIconTintKey);
    if (!tint) {
        tint = [[UIView alloc] initWithFrame:self_.bounds];
        tint.tag = kFolderIconTintTag;
        tint.userInteractionEnabled = NO;
        tint.autoresizingMask = UIViewAutoresizingFlexibleWidth |
                                UIViewAutoresizingFlexibleHeight;
        [self_ addSubview:tint];
        objc_setAssociatedObject(self_, kFolderIconTintKey, tint, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    tint.frame = self_.bounds;
    tint.backgroundColor = folderIconTintColorForView(self_);
    tint.layer.cornerRadius = LGFolderIconCornerRadius(self_.layer.cornerRadius);
    if (@available(iOS 13.0, *))
        tint.layer.cornerCurve = self_.layer.cornerCurve;
    [self_ bringSubviewToFront:tint];
}

static void injectIntoFolderIcon(UIView *self_) {
    if (!LGFolderIconEnabled()) {
        removeFolderIconOverlays(self_);
        return;
    }
    LiquidGlassView *glass = objc_getAssociatedObject(self_, kFolderIconGlassKey);

    CGPoint wallpaperOrigin = CGPointZero;
    UIImage *wallpaper = LG_getHomescreenSnapshot(&wallpaperOrigin);
    if (!wallpaper) {
        if ([objc_getAssociatedObject(self_, kFolderIconRetryKey) boolValue]) return;
        objc_setAssociatedObject(self_, kFolderIconRetryKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            objc_setAssociatedObject(self_, kFolderIconRetryKey, nil, OBJC_ASSOCIATION_ASSIGN);
            injectIntoFolderIcon(self_);
        });
        return;
    }

    if (!glass) {
        glass = [[LiquidGlassView alloc]
            initWithFrame:self_.bounds wallpaper:wallpaper wallpaperOrigin:wallpaperOrigin];
        glass.autoresizingMask = UIViewAutoresizingFlexibleWidth |
                                 UIViewAutoresizingFlexibleHeight;
        glass.cornerRadius = LGFolderIconCornerRadius(self_.layer.cornerRadius);
        glass.bezelWidth = LGFolderIconBezelWidth();
        glass.glassThickness = LGFolderIconGlassThickness();
        glass.refractionScale = LGFolderIconRefractionScale();
        glass.refractiveIndex = LGFolderIconRefractiveIndex();
        glass.specularOpacity = LGFolderIconSpecularOpacity();
        glass.blur = LGFolderIconBlur();
        glass.wallpaperScale = LGFolderIconWallpaperScale();
        glass.updateGroup = LGUpdateGroupFolderIcon;
        [self_ addSubview:glass];
        objc_setAssociatedObject(self_, kFolderIconGlassKey, glass, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    glass.cornerRadius = LGFolderIconCornerRadius(self_.layer.cornerRadius);
    glass.bezelWidth = LGFolderIconBezelWidth();
    glass.glassThickness = LGFolderIconGlassThickness();
    glass.refractionScale = LGFolderIconRefractionScale();
    glass.refractiveIndex = LGFolderIconRefractiveIndex();
    glass.specularOpacity = LGFolderIconSpecularOpacity();
    glass.blur = LGFolderIconBlur();
    glass.wallpaperScale = LGFolderIconWallpaperScale();
    [glass updateOrigin];
    ensureFolderIconTintOverlay(self_);
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self_.window) ensureFolderIconTintOverlay(self_);
    });
    objc_setAssociatedObject(self_, kFolderIconRetryKey, nil, OBJC_ASSOCIATION_ASSIGN);
}

static void LGFolderIconTraverseViews(UIView *root, void (^block)(UIView *view)) {
    if (!root) return;
    block(root);
    for (UIView *sub in root.subviews) LGFolderIconTraverseViews(sub, block);
}

static void LGFolderIconRefreshAllHosts(void) {
    UIWindow *window = LG_getHomescreenWindow();
    if (!window) return;
    LGFolderIconTraverseViews(window, ^(UIView *view) {
        if (![view isKindOfClass:NSClassFromString(@"MTMaterialView")]) return;
        if (!isInsideFolderIcon(view)) return;
        injectIntoFolderIcon(view);
    });
}

static NSInteger LGFolderScrollPageForOffset(UIScrollView *scrollView, CGPoint offset) {
    CGFloat pageWidth = CGRectGetWidth(scrollView.bounds);
    if (pageWidth <= 1.0) return 0;
    return (NSInteger)llround(offset.x / pageWidth);
}

static void LGHandleFolderSnapshotForScroll(UIScrollView *scrollView, CGPoint offset) {
    NSInteger page = LGFolderScrollPageForOffset(scrollView, offset);
    NSNumber *lastPageNumber = objc_getAssociatedObject(scrollView, kFolderIconLastPageKey);
    NSInteger lastPage = lastPageNumber ? lastPageNumber.integerValue : page;
    if (!lastPageNumber) {
        objc_setAssociatedObject(scrollView, kFolderIconLastPageKey, @(page), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    } else if (lastPage != page) {
        objc_setAssociatedObject(scrollView, kFolderIconLastPageKey, @(page), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        LG_invalidateFolderSnapshot();
        LGScheduleFolderSnapshotWarmupForScroll(scrollView, 0.18);
    }
    LG_updateRegisteredGlassViews(LGUpdateGroupFolderIcon);
}

static void LGFolderIconPrefsChanged(CFNotificationCenterRef center,
                                     void *observer,
                                     CFStringRef name,
                                     const void *object,
                                     CFDictionaryRef userInfo) {
    dispatch_async(dispatch_get_main_queue(), ^{
        LGFolderIconRefreshAllHosts();
    });
}

%hook MTMaterialView

- (void)didMoveToWindow {
    %orig;
    UIView *self_ = (UIView *)self;
    if (!self_.window) return;
    if (!isInsideFolderIcon(self_)) return;
    LGScheduleFolderSnapshotWarmup(0.18);
    injectIntoFolderIcon(self_);
}

- (void)layoutSubviews {
    %orig;
    UIView *self_ = (UIView *)self;
    if (!isInsideFolderIcon(self_)) return;
    if (!LGFolderIconEnabled()) {
        removeFolderIconOverlays(self_);
        return;
    }
    ensureFolderIconTintOverlay(self_);
    LiquidGlassView *glass = objc_getAssociatedObject(self_, kFolderIconGlassKey);
    glass.cornerRadius = LGFolderIconCornerRadius(self_.layer.cornerRadius);
    glass.bezelWidth = LGFolderIconBezelWidth();
    glass.glassThickness = LGFolderIconGlassThickness();
    glass.refractionScale = LGFolderIconRefractionScale();
    glass.refractiveIndex = LGFolderIconRefractiveIndex();
    glass.specularOpacity = LGFolderIconSpecularOpacity();
    glass.blur = LGFolderIconBlur();
    glass.wallpaperScale = LGFolderIconWallpaperScale();
    [glass updateOrigin];
}

%end

%ctor {
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                    NULL,
                                    LGFolderIconPrefsChanged,
                                    kLGPrefsChangedNotification,
                                    NULL,
                                    CFNotificationSuspensionBehaviorDeliverImmediately);
}

%hook SBIconScrollView

- (void)setContentOffset:(CGPoint)offset {
    %orig;
    LGHandleFolderSnapshotForScroll((UIScrollView *)self, offset);
}

- (void)setContentOffset:(CGPoint)offset animated:(BOOL)animated {
    %orig;
    LGHandleFolderSnapshotForScroll((UIScrollView *)self, offset);
}

%end
