#import "LGPRootListController.h"
#import "LGPrefsLiquidSlider.h"
#import "LGPrefsLiquidSwitch.h"
#import <notify.h>
#import <objc/runtime.h>

@interface LGTopFadeView : UIView
@end

static NSString * const kLGPrefsDomain = @"dylv.liquidassprefs";
static const char *kLGPrefsChangedNotification = "dylv.liquidassprefs/Reload";
static const char *kLGPrefsRespringNotification = "dylv.liquidassprefs/Respring";
static NSString * const kLGPrefsUIRefreshNotification = @"LGPrefsUIRefreshNotification";
static NSString * const kLGPrefsRespringChangedNotification = @"LGPrefsRespringChangedNotification";
static NSString * const kLGLastSurfaceKey = @"LGPrefsLastSurface";
static NSString * const kLGNeedsRespringKey = @"LGPrefsNeedsRespring";
static NSString * const kLGRespringBarDismissedKey = @"LGPrefsRespringBarDismissed";
static NSString *LGLocalized(NSString *key);
static NSString *LGFormatSliderValue(CGFloat value, NSInteger decimals);
static NSDictionary *LGSectionSetting(NSString *title, NSString *subtitle);
static UIView *LGMakeNavCardGlyphView(NSString *symbolName, UIColor *tintColor);
static UIColor *LGSubpageCardBackgroundColor(void);
static UIView *LGMakeSectionDivider(void);
static UIView *LGMakeRespringBar(id target, SEL respringAction, SEL laterAction);
static void LGWritePreference(NSString *key, NSNumber *value);
static void *kLGDefaultValueKey = &kLGDefaultValueKey;
static void *kLGValueLabelKey = &kLGValueLabelKey;
static void *kLGDecimalsKey = &kLGDecimalsKey;
static void *kLGSliderAnimatorKey = &kLGSliderAnimatorKey;
static void *kLGSliderKey = &kLGSliderKey;
static void *kLGPreferenceKeyKey = &kLGPreferenceKeyKey;
static void *kLGMinValueKey = &kLGMinValueKey;
static void *kLGMaxValueKey = &kLGMaxValueKey;
static void *kLGControlTitleKey = &kLGControlTitleKey;
static void *kLGControlSubtitleKey = &kLGControlSubtitleKey;
static void *kLGControlledByEnabledKey = &kLGControlledByEnabledKey;

static Class LGPrefsSwitchClass(void) {
    return NSClassFromString(@"LGPrefsLiquidSwitch") ?: [UISwitch class];
}

static Class LGPrefsSliderClass(void) {
    return NSClassFromString(@"LGPrefsLiquidSlider") ?: [UISlider class];
}

static NSUserDefaults *LGStandardDefaults(void) {
    return [NSUserDefaults standardUserDefaults];
}

static void LGSynchronizeSurfaceStateDefaults(void) {
    [LGStandardDefaults() synchronize];
}

static NSString *LGLastSurfaceIdentifier(void) {
    return [LGStandardDefaults() stringForKey:kLGLastSurfaceKey];
}

static void LGSetLastSurfaceIdentifier(NSString *identifier) {
    NSUserDefaults *defaults = LGStandardDefaults();
    if (identifier.length) {
        [defaults setObject:identifier forKey:kLGLastSurfaceKey];
    } else {
        [defaults removeObjectForKey:kLGLastSurfaceKey];
    }
    LGSynchronizeSurfaceStateDefaults();
}

static void LGClearLastSurfaceIdentifierIfMatching(NSString *identifier) {
    if (!identifier.length) return;
    NSString *current = LGLastSurfaceIdentifier();
    if ([current isEqualToString:identifier]) {
        LGSetLastSurfaceIdentifier(nil);
    }
}

static void LGObservePrefsNotifications(id target) {
    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    [center addObserver:target
               selector:@selector(handlePrefsUIRefresh:)
                   name:kLGPrefsUIRefreshNotification
                 object:nil];
    [center addObserver:target
               selector:@selector(handleRespringStateChanged:)
                   name:kLGPrefsRespringChangedNotification
                 object:nil];
}

static void LGApplyNavigationBarAppearance(UINavigationItem *navigationItem) {
    UINavigationBarAppearance *appearance = [[UINavigationBarAppearance alloc] init];
    [appearance configureWithTransparentBackground];
    appearance.backgroundColor = UIColor.clearColor;
    appearance.shadowColor = UIColor.clearColor;
    navigationItem.standardAppearance = appearance;
    navigationItem.scrollEdgeAppearance = appearance;
    navigationItem.compactAppearance = appearance;
    if (@available(iOS 15.0, *)) {
        navigationItem.compactScrollEdgeAppearance = appearance;
    }
}

static void LGInstallScrollableStack(UIViewController *controller,
                                     CGFloat topInset,
                                     CGFloat stackSpacing,
                                     UIScrollView *__strong *scrollViewOut,
                                     UIStackView *__strong *stackViewOut) {
    UIScrollView *scrollView = [[UIScrollView alloc] initWithFrame:controller.view.bounds];
    scrollView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [controller.view addSubview:scrollView];

    LGTopFadeView *fadeView = [[LGTopFadeView alloc] initWithFrame:CGRectZero];
    fadeView.translatesAutoresizingMaskIntoConstraints = NO;
    [controller.view addSubview:fadeView];

    UIStackView *stackView = [[UIStackView alloc] initWithFrame:CGRectZero];
    stackView.axis = UILayoutConstraintAxisVertical;
    stackView.spacing = stackSpacing;
    stackView.translatesAutoresizingMaskIntoConstraints = NO;
    [scrollView addSubview:stackView];

    [NSLayoutConstraint activateConstraints:@[
        [stackView.topAnchor constraintEqualToAnchor:scrollView.contentLayoutGuide.topAnchor constant:topInset],
        [stackView.leadingAnchor constraintEqualToAnchor:scrollView.frameLayoutGuide.leadingAnchor constant:16.0],
        [stackView.trailingAnchor constraintEqualToAnchor:scrollView.frameLayoutGuide.trailingAnchor constant:-16.0],
        [stackView.bottomAnchor constraintEqualToAnchor:scrollView.contentLayoutGuide.bottomAnchor constant:-112.0],
        [fadeView.topAnchor constraintEqualToAnchor:controller.view.topAnchor],
        [fadeView.leadingAnchor constraintEqualToAnchor:controller.view.leadingAnchor],
        [fadeView.trailingAnchor constraintEqualToAnchor:controller.view.trailingAnchor],
        [fadeView.heightAnchor constraintEqualToConstant:150.0],
    ]];

    if (scrollViewOut) *scrollViewOut = scrollView;
    if (stackViewOut) *stackViewOut = stackView;
}

static void LGInstallBottomRespringBar(UIViewController *controller, UIView *__strong *respringBarOut) {
    UIView *respringBar = LGMakeRespringBar(controller, @selector(handleRespringPressed), @selector(handleLaterPressed));
    [controller.view addSubview:respringBar];
    UILayoutGuide *guide = controller.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [respringBar.leadingAnchor constraintEqualToAnchor:guide.leadingAnchor constant:16.0],
        [respringBar.trailingAnchor constraintEqualToAnchor:guide.trailingAnchor constant:-16.0],
        [respringBar.bottomAnchor constraintEqualToAnchor:guide.bottomAnchor constant:-12.0],
    ]];
    if (respringBarOut) *respringBarOut = respringBar;
}

static NSNumber *LGParseLocalizedDecimalString(NSString *rawText) {
    NSString *trimmed = [rawText stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!trimmed.length) return nil;

    NSNumberFormatter *formatter = [[NSNumberFormatter alloc] init];
    formatter.locale = [NSLocale currentLocale];
    NSNumber *parsedNumber = [formatter numberFromString:trimmed];
    if (parsedNumber) return parsedNumber;

    NSString *normalized = [trimmed stringByReplacingOccurrencesOfString:@"," withString:@"."];
    return @([normalized doubleValue]);
}

static void LGPresentSliderValuePrompt(UIViewController *controller, UILabel *valueLabel) {
    if (![valueLabel isKindOfClass:[UILabel class]]) return;

    UISlider *slider = objc_getAssociatedObject(valueLabel, kLGSliderKey);
    NSString *preferenceKey = objc_getAssociatedObject(valueLabel, kLGPreferenceKeyKey);
    NSNumber *minNumber = objc_getAssociatedObject(valueLabel, kLGMinValueKey);
    NSNumber *maxNumber = objc_getAssociatedObject(valueLabel, kLGMaxValueKey);
    NSNumber *decimalsNumber = objc_getAssociatedObject(valueLabel, kLGDecimalsKey);
    NSString *controlTitle = objc_getAssociatedObject(valueLabel, kLGControlTitleKey);
    if (!slider || !preferenceKey.length || !minNumber || !maxNumber || !decimalsNumber) return;

    NSInteger decimals = decimalsNumber.integerValue;
    CGFloat minValue = minNumber.doubleValue;
    CGFloat maxValue = maxNumber.doubleValue;
    NSString *message = [NSString stringWithFormat:LGLocalized(@"prefs.value_prompt.message"),
                         LGFormatSliderValue(minValue, decimals),
                         LGFormatSliderValue(maxValue, decimals)];

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:(controlTitle.length ? controlTitle : LGLocalized(@"prefs.value_prompt.title"))
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField * _Nonnull textField) {
        textField.keyboardType = UIKeyboardTypeDecimalPad;
        textField.placeholder = LGFormatSliderValue(slider.value, decimals);
        textField.text = LGFormatSliderValue(slider.value, decimals);
        textField.clearButtonMode = UITextFieldViewModeWhileEditing;
    }];

    [alert addAction:[UIAlertAction actionWithTitle:LGLocalized(@"prefs.button.cancel")
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:LGLocalized(@"prefs.button.apply")
                                              style:UIAlertActionStyleDefault
                                            handler:^(__unused UIAlertAction * _Nonnull action) {
        UITextField *textField = alert.textFields.firstObject;
        NSNumber *parsedNumber = LGParseLocalizedDecimalString(textField.text ?: @"");
        if (!parsedNumber) return;

        CGFloat value = MIN(MAX(parsedNumber.doubleValue, minValue), maxValue);
        slider.value = value;
        valueLabel.text = LGFormatSliderValue(value, decimals);
        LGWritePreference(preferenceKey, @(value));
    }]];

    [controller presentViewController:alert animated:YES completion:nil];
}

static NSString *LGLocalized(NSString *key) {
    NSBundle *bundle = [NSBundle bundleForClass:[LGPRootListController class]];
    return [bundle localizedStringForKey:key value:key table:nil];
}

static NSString *LGPrefsAppName(void) {
    return LGLocalized(@"prefs.app_name");
}

@interface LGSliderResetAnimator : NSObject
@property (nonatomic, weak) UISlider *slider;
@property (nonatomic, weak) UILabel *valueLabel;
@property (nonatomic, strong) CADisplayLink *displayLink;
@property (nonatomic, assign) CFTimeInterval startTime;
@property (nonatomic, assign) CGFloat startValue;
@property (nonatomic, assign) CGFloat targetValue;
@property (nonatomic, assign) NSInteger decimals;
@end

@implementation LGSliderResetAnimator

- (void)tick:(CADisplayLink *)link {
    if (!self.slider) {
        [self.displayLink invalidate];
        self.displayLink = nil;
        return;
    }
    CFTimeInterval elapsed = CACurrentMediaTime() - self.startTime;
    CGFloat t = MIN(MAX(elapsed / 0.42, 0.0), 1.0);
    CGFloat eased = 1.0 - pow(1.0 - t, 3.0);
    CGFloat value = self.startValue + ((self.targetValue - self.startValue) * eased);
    self.slider.value = value;
    if (self.valueLabel) {
        self.valueLabel.text = LGFormatSliderValue(value, self.decimals);
    }
    if (t >= 1.0) {
        [self.displayLink invalidate];
        self.displayLink = nil;
        objc_setAssociatedObject(self.slider, kLGSliderAnimatorKey, nil, OBJC_ASSOCIATION_ASSIGN);
    }
}

@end

@interface LGPrefsSpringBackButton : UIButton
@property (nonatomic, weak) UIView *animatedView;
@property (nonatomic, strong) CADisplayLink *displayLink;
@property (nonatomic, assign) CFTimeInterval lastTimestamp;
@property (nonatomic, assign) CGFloat springValue;
@property (nonatomic, assign) CGFloat springTarget;
@property (nonatomic, assign) CGFloat springVelocity;
@end

@implementation LGPrefsSpringBackButton

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    _springValue = 1.0;
    _springTarget = 1.0;
    _springVelocity = 0.0;
    return self;
}

- (void)dealloc {
    [_displayLink invalidate];
}

- (void)setHighlighted:(BOOL)highlighted {
    BOOL changed = (self.highlighted != highlighted);
    [super setHighlighted:highlighted];
    if (!changed) return;
    self.springTarget = highlighted ? 0.86 : 1.0;
    [self lg_startSpringIfNeeded];
}

- (void)lg_startSpringIfNeeded {
    if (self.displayLink) return;
    self.lastTimestamp = 0.0;
    self.displayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(lg_tick:)];
    [self.displayLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
}

- (void)lg_tick:(CADisplayLink *)link {
    UIView *targetView = self.animatedView ?: self;
    if (!targetView.superview) {
        [self.displayLink invalidate];
        self.displayLink = nil;
        return;
    }

    if (self.lastTimestamp <= 0.0) {
        self.lastTimestamp = link.timestamp;
        return;
    }

    CFTimeInterval dt = MIN(MAX(link.timestamp - self.lastTimestamp, 1.0 / 240.0), 1.0 / 30.0);
    self.lastTimestamp = link.timestamp;

    CGFloat stiffness = 300.0;
    CGFloat damping = 20.0;
    CGFloat force = (self.springTarget - self.springValue) * stiffness;
    CGFloat dampingForce = self.springVelocity * damping;
    self.springVelocity += (force - dampingForce) * dt;
    self.springValue += self.springVelocity * dt;

    if (fabs(self.springTarget - self.springValue) < 0.0005 &&
        fabs(self.springVelocity) < 0.001) {
        self.springValue = self.springTarget;
        self.springVelocity = 0.0;
    }

    targetView.transform = CGAffineTransformMakeScale(self.springValue, self.springValue);

    if (self.springValue == self.springTarget && self.springVelocity == 0.0) {
        [self.displayLink invalidate];
        self.displayLink = nil;
    }
}

@end

static void LGAnimateSliderToDefault(UISlider *slider, CGFloat targetValue, UILabel *valueLabel, NSInteger decimals) {
    LGSliderResetAnimator *existing = objc_getAssociatedObject(slider, kLGSliderAnimatorKey);
    if (existing.displayLink) {
        [existing.displayLink invalidate];
        existing.displayLink = nil;
    }

    LGSliderResetAnimator *animator = [LGSliderResetAnimator new];
    animator.slider = slider;
    animator.valueLabel = valueLabel;
    animator.startValue = slider.value;
    animator.targetValue = targetValue;
    animator.decimals = decimals;
    animator.startTime = CACurrentMediaTime();
    animator.displayLink = [CADisplayLink displayLinkWithTarget:animator selector:@selector(tick:)];
    [animator.displayLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
    objc_setAssociatedObject(slider, kLGSliderAnimatorKey, animator, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static BOOL LGPreferenceRequiresRespring(NSString *key) {
    if (!key.length) return NO;
    return [key isEqualToString:@"Global.Enabled"] || [key hasSuffix:@".Enabled"];
}

static BOOL LGNeedsRespring(void) {
    return [LGStandardDefaults() boolForKey:kLGNeedsRespringKey];
}

static BOOL LGRespringBarDismissed(void) {
    return [LGStandardDefaults() boolForKey:kLGRespringBarDismissedKey];
}

static void LGSetRespringBarDismissed(BOOL dismissed) {
    NSUserDefaults *defaults = LGStandardDefaults();
    [defaults setBool:dismissed forKey:kLGRespringBarDismissedKey];
    LGSynchronizeSurfaceStateDefaults();
}

static void LGSetNeedsRespring(BOOL needsRespring) {
    NSUserDefaults *defaults = LGStandardDefaults();
    [defaults setBool:needsRespring forKey:kLGNeedsRespringKey];
    if (!needsRespring) {
        [defaults setBool:NO forKey:kLGRespringBarDismissedKey];
    }
    LGSynchronizeSurfaceStateDefaults();
    [[NSNotificationCenter defaultCenter] postNotificationName:kLGPrefsRespringChangedNotification object:nil];
}

static NSNumber *LGReadPreference(NSString *key, NSNumber *fallback) {
    CFPropertyListRef value = CFPreferencesCopyAppValue((__bridge CFStringRef)key,
                                                        (__bridge CFStringRef)kLGPrefsDomain);
    id obj = CFBridgingRelease(value);
    return [obj isKindOfClass:[NSNumber class]] ? obj : fallback;
}

static void LGWritePreference(NSString *key, NSNumber *value) {
    CFPreferencesSetAppValue((__bridge CFStringRef)key,
                             (__bridge CFPropertyListRef)value,
                             (__bridge CFStringRef)kLGPrefsDomain);
    CFPreferencesAppSynchronize((__bridge CFStringRef)kLGPrefsDomain);
    notify_post(kLGPrefsChangedNotification);
}

static void LGWritePreferenceAndMaybeRequireRespring(NSString *key, NSNumber *value) {
    LGWritePreference(key, value);
    if (LGPreferenceRequiresRespring(key)) {
        LGSetRespringBarDismissed(NO);
        LGSetNeedsRespring(YES);
    }
}

static void LGRemovePreference(NSString *key) {
    CFPreferencesSetAppValue((__bridge CFStringRef)key,
                             NULL,
                             (__bridge CFStringRef)kLGPrefsDomain);
}

static NSDictionary *LGSwitchSetting(NSString *key, NSString *title, NSString *subtitle, BOOL fallback) {
    return @{
        @"type": @"switch",
        @"key": key,
        @"title": title,
        @"subtitle": subtitle ?: @"",
        @"default": @(fallback)
    };
}

static NSDictionary *LGSectionSetting(NSString *title, NSString *subtitle) {
    return @{
        @"type": @"section",
        @"title": title ?: @"",
        @"subtitle": subtitle ?: @""
    };
}

static NSDictionary *LGSliderSetting(NSString *key, NSString *title, NSString *subtitle,
                                     CGFloat fallback, CGFloat min, CGFloat max, NSInteger decimals) {
    return @{
        @"type": @"slider",
        @"key": key,
        @"title": title,
        @"subtitle": subtitle ?: @"",
        @"default": @(fallback),
        @"min": @(min),
        @"max": @(max),
        @"decimals": @(decimals)
    };
}

static NSDictionary *LGGlassEnabledSetting(NSString *key, BOOL fallback) {
    return LGSwitchSetting(key, LGLocalized(@"prefs.control.enabled"), LGLocalized(@"prefs.subtitle.enabled"), fallback);
}

static NSDictionary *LGGlassBezelSetting(NSString *key, CGFloat fallback, CGFloat min, CGFloat max, NSInteger decimals) {
    return LGSliderSetting(key, LGLocalized(@"prefs.control.bezel_width"), LGLocalized(@"prefs.subtitle.bezel_width"), fallback, min, max, decimals);
}

static NSDictionary *LGGlassBlurSetting(NSString *key, CGFloat fallback, CGFloat min, CGFloat max, NSInteger decimals) {
    return LGSliderSetting(key, LGLocalized(@"prefs.control.blur"), LGLocalized(@"prefs.subtitle.blur"), fallback, min, max, decimals);
}

static NSDictionary *LGGlassCornerRadiusSetting(NSString *key, CGFloat fallback, CGFloat min, CGFloat max, NSInteger decimals) {
    return LGSliderSetting(key, LGLocalized(@"prefs.control.corner_radius"), LGLocalized(@"prefs.subtitle.corner_radius"), fallback, min, max, decimals);
}

static NSDictionary *LGGlassThicknessSetting(NSString *key, CGFloat fallback, CGFloat min, CGFloat max, NSInteger decimals) {
    return LGSliderSetting(key, LGLocalized(@"prefs.control.glass_thickness"), LGLocalized(@"prefs.subtitle.glass_thickness"), fallback, min, max, decimals);
}

static NSDictionary *LGGlassLightTintSetting(NSString *key, CGFloat fallback, CGFloat min, CGFloat max, NSInteger decimals) {
    return LGSliderSetting(key, LGLocalized(@"prefs.control.light_tint_alpha"), LGLocalized(@"prefs.subtitle.light_tint_alpha"), fallback, min, max, decimals);
}

static NSDictionary *LGGlassDarkTintSetting(NSString *key, CGFloat fallback, CGFloat min, CGFloat max, NSInteger decimals) {
    return LGSliderSetting(key, LGLocalized(@"prefs.control.dark_tint_alpha"), LGLocalized(@"prefs.subtitle.dark_tint_alpha"), fallback, min, max, decimals);
}

static NSDictionary *LGGlassRefractiveIndexSetting(NSString *key, CGFloat fallback, CGFloat min, CGFloat max, NSInteger decimals) {
    return LGSliderSetting(key, LGLocalized(@"prefs.control.refractive_index"), LGLocalized(@"prefs.subtitle.refractive_index"), fallback, min, max, decimals);
}

static NSDictionary *LGGlassRefractionSetting(NSString *key, CGFloat fallback, CGFloat min, CGFloat max, NSInteger decimals) {
    return LGSliderSetting(key, LGLocalized(@"prefs.control.refraction"), LGLocalized(@"prefs.subtitle.refraction"), fallback, min, max, decimals);
}

static NSDictionary *LGGlassSpecularSetting(NSString *key, CGFloat fallback, CGFloat min, CGFloat max, NSInteger decimals) {
    return LGSliderSetting(key, LGLocalized(@"prefs.control.specular"), LGLocalized(@"prefs.subtitle.specular"), fallback, min, max, decimals);
}

static NSDictionary *LGGlassQualitySetting(NSString *key, CGFloat fallback, CGFloat min, CGFloat max, NSInteger decimals) {
    return LGSliderSetting(key, LGLocalized(@"prefs.control.quality"), LGLocalized(@"prefs.subtitle.quality"), fallback, min, max, decimals);
}

static NSInteger LGMaximumSupportedFPS(void) {
    NSInteger maxFPS = UIScreen.mainScreen.maximumFramesPerSecond;
    if (maxFPS <= 0) maxFPS = 60;
    return maxFPS >= 120 ? 120 : 60;
}

static NSDictionary *LGScopedFPSSliderSetting(NSString *key) {
    NSInteger maxFPS = LGMaximumSupportedFPS();
    NSInteger defaultFPS = (30 + maxFPS) / 2;
    NSString *subtitle = maxFPS >= 120
        ? LGLocalized(@"prefs.subtitle.fps_limit_120")
        : LGLocalized(@"prefs.subtitle.fps_limit_60");
    return LGSliderSetting(key, LGLocalized(@"prefs.control.fps_limit"), subtitle, defaultFPS, 30.0, (CGFloat)maxFPS, 0);
}

static NSString *LGFormatSliderValue(CGFloat value, NSInteger decimals) {
    return [NSString stringWithFormat:[NSString stringWithFormat:@"%%.%ldf", (long)decimals], value];
}

static UIView *LGMakeNavCardGlyphView(NSString *symbolName, UIColor *tintColor) {
    UIView *container = [[UIView alloc] initWithFrame:CGRectZero];
    container.translatesAutoresizingMaskIntoConstraints = NO;
    [NSLayoutConstraint activateConstraints:@[
        [container.widthAnchor constraintEqualToConstant:20.0],
        [container.heightAnchor constraintEqualToConstant:20.0],
    ]];

    if ([symbolName isEqualToString:@"lg.lockscreen.stacked"]) {
        UIImageSymbolConfiguration *phoneConfig =
            [UIImageSymbolConfiguration configurationWithPointSize:17.0 weight:UIImageSymbolWeightSemibold];
        UIImageView *phoneGlyph = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"iphone" withConfiguration:phoneConfig]];
        phoneGlyph.translatesAutoresizingMaskIntoConstraints = NO;
        phoneGlyph.tintColor = tintColor;
        phoneGlyph.contentMode = UIViewContentModeScaleAspectFit;

        UIView *lockBadge = [[UIView alloc] initWithFrame:CGRectZero];
        lockBadge.translatesAutoresizingMaskIntoConstraints = NO;
        lockBadge.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
        lockBadge.layer.cornerRadius = 7.0;
        lockBadge.layer.cornerCurve = kCACornerCurveContinuous;

        UIImageSymbolConfiguration *lockConfig =
            [UIImageSymbolConfiguration configurationWithPointSize:8.0 weight:UIImageSymbolWeightBold];
        UIImageView *lockGlyph = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"lock.fill" withConfiguration:lockConfig]];
        lockGlyph.translatesAutoresizingMaskIntoConstraints = NO;
        lockGlyph.tintColor = tintColor;
        lockGlyph.contentMode = UIViewContentModeScaleAspectFit;

        [container addSubview:phoneGlyph];
        [container addSubview:lockBadge];
        [lockBadge addSubview:lockGlyph];
        [NSLayoutConstraint activateConstraints:@[
            [phoneGlyph.centerXAnchor constraintEqualToAnchor:container.centerXAnchor constant:-1.0],
            [phoneGlyph.centerYAnchor constraintEqualToAnchor:container.centerYAnchor],
            [phoneGlyph.widthAnchor constraintEqualToConstant:15.0],
            [phoneGlyph.heightAnchor constraintEqualToConstant:15.0],
            [lockBadge.widthAnchor constraintEqualToConstant:14.0],
            [lockBadge.heightAnchor constraintEqualToConstant:14.0],
            [lockBadge.trailingAnchor constraintEqualToAnchor:container.trailingAnchor],
            [lockBadge.bottomAnchor constraintEqualToAnchor:container.bottomAnchor],
            [lockGlyph.centerXAnchor constraintEqualToAnchor:lockBadge.centerXAnchor],
            [lockGlyph.centerYAnchor constraintEqualToAnchor:lockBadge.centerYAnchor],
        ]];
        return container;
    }

    UIImageSymbolConfiguration *symbolConfig =
        [UIImageSymbolConfiguration configurationWithPointSize:16.0 weight:UIImageSymbolWeightSemibold];
    UIImageView *glyph = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:symbolName withConfiguration:symbolConfig]];
    glyph.translatesAutoresizingMaskIntoConstraints = NO;
    glyph.tintColor = tintColor;
    glyph.contentMode = UIViewContentModeScaleAspectFit;
    [container addSubview:glyph];
    [NSLayoutConstraint activateConstraints:@[
        [glyph.centerXAnchor constraintEqualToAnchor:container.centerXAnchor],
        [glyph.centerYAnchor constraintEqualToAnchor:container.centerYAnchor],
    ]];
    return container;
}

static UIColor *LGSubpageCardBackgroundColor(void) {
    return [UIColor colorWithDynamicProvider:^UIColor * _Nonnull(UITraitCollection * _Nonnull trait) {
        if (trait.userInterfaceStyle == UIUserInterfaceStyleDark) {
            return [[UIColor whiteColor] colorWithAlphaComponent:0.07];
        }
        return [[UIColor whiteColor] colorWithAlphaComponent:0.76];
    }];
}

static UIView *LGMakeSectionDivider(void) {
    UIView *divider = [[UIView alloc] initWithFrame:CGRectZero];
    divider.translatesAutoresizingMaskIntoConstraints = NO;
    divider.backgroundColor = [UIColor colorWithDynamicProvider:^UIColor * _Nonnull(UITraitCollection * _Nonnull trait) {
        if (trait.userInterfaceStyle == UIUserInterfaceStyleDark) {
            return [[UIColor whiteColor] colorWithAlphaComponent:0.08];
        }
        return [[UIColor blackColor] colorWithAlphaComponent:0.08];
    }];
    divider.layer.cornerRadius = 0.5;
    [NSLayoutConstraint activateConstraints:@[
        [divider.heightAnchor constraintEqualToConstant:1.0]
    ]];
    return divider;
}

static UIBarButtonItem *LGMakeCircularBackItem(id target, SEL action) {
    LGPrefsSpringBackButton *button = [LGPrefsSpringBackButton buttonWithType:UIButtonTypeSystem];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    UIImageSymbolConfiguration *config =
        [UIImageSymbolConfiguration configurationWithPointSize:16.0 weight:UIImageSymbolWeightSemibold];
    UIImage *image = [UIImage systemImageNamed:@"chevron.left" withConfiguration:config];
    [button setImage:image forState:UIControlStateNormal];
    [button setTintColor:[UIColor labelColor]];
    button.imageView.contentMode = UIViewContentModeCenter;
    [button addTarget:target action:action forControlEvents:UIControlEventTouchUpInside];

    UIView *container = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 38, 38)];
    UIVisualEffectView *blurView =
        [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemChromeMaterial]];
    blurView.translatesAutoresizingMaskIntoConstraints = NO;
    blurView.layer.cornerRadius = 19.0;
    blurView.layer.cornerCurve = kCACornerCurveContinuous;
    blurView.layer.masksToBounds = YES;
    blurView.layer.borderWidth = 0.75;
    blurView.layer.borderColor = [[UIColor separatorColor] colorWithAlphaComponent:0.22].CGColor;
    [container addSubview:blurView];
    [blurView.contentView addSubview:button];
    button.animatedView = container;
    [NSLayoutConstraint activateConstraints:@[
        [blurView.topAnchor constraintEqualToAnchor:container.topAnchor],
        [blurView.leadingAnchor constraintEqualToAnchor:container.leadingAnchor],
        [blurView.trailingAnchor constraintEqualToAnchor:container.trailingAnchor],
        [blurView.bottomAnchor constraintEqualToAnchor:container.bottomAnchor],
        [button.topAnchor constraintEqualToAnchor:blurView.contentView.topAnchor],
        [button.leadingAnchor constraintEqualToAnchor:blurView.contentView.leadingAnchor],
        [button.trailingAnchor constraintEqualToAnchor:blurView.contentView.trailingAnchor],
        [button.bottomAnchor constraintEqualToAnchor:blurView.contentView.bottomAnchor],
        [button.widthAnchor constraintEqualToConstant:38.0],
        [button.heightAnchor constraintEqualToConstant:38.0],
    ]];
    return [[UIBarButtonItem alloc] initWithCustomView:container];
}

static NSArray<NSDictionary *> *LGAllSurfaceItems(void);
static void LGPresentResetConfirmation(UIViewController *controller);
static void LGPresentRespringConfirmation(UIViewController *controller);
static void LGPresentReopenSettingsConfirmation(UIViewController *controller);
static void LGPresentInfoSheet(UIViewController *controller, NSString *title, NSString *message);

static void LGResetAllPreferences(void) {
    for (NSDictionary *item in LGAllSurfaceItems()) {
        NSString *key = item[@"key"];
        if (!key.length) continue;
        if ([key isEqualToString:@"Global.Enabled"]) continue;
        LGRemovePreference(key);
    }
    CFPreferencesAppSynchronize((__bridge CFStringRef)kLGPrefsDomain);
    LGSetRespringBarDismissed(NO);
    LGSetNeedsRespring(YES);
    [[NSNotificationCenter defaultCenter] postNotificationName:kLGPrefsUIRefreshNotification object:nil];
    notify_post(kLGPrefsChangedNotification);
}

static UIBarButtonItem *LGMakeResetTextItem(id target, SEL action) {
    UIBarButtonItem *item = [[UIBarButtonItem alloc] initWithTitle:LGLocalized(@"prefs.button.reset")
                                                             style:UIBarButtonItemStylePlain
                                                            target:target
                                                            action:action];
    return item;
}

static NSArray<NSDictionary *> *LGDockItems(void) {
    return @[
        LGGlassEnabledSetting(@"Dock.Enabled", YES),
        LGGlassBezelSetting(@"Dock.BezelWidth", 30.0, 0.0, 50.0, 1),
        LGGlassBlurSetting(@"Dock.Blur", 10.0, 0.0, 30.0, 1),
        LGSliderSetting(@"Dock.CornerRadiusFloating", LGLocalized(@"prefs.control.floating_radius"), LGLocalized(@"prefs.subtitle.floating_radius"), 30.5, 0.0, 50.0, 1),
        LGSliderSetting(@"Dock.CornerRadiusFullScreen", LGLocalized(@"prefs.control.full_screen_radius"), LGLocalized(@"prefs.subtitle.full_screen_radius"), 34.0, 0.0, 50.0, 1),
        LGGlassThicknessSetting(@"Dock.GlassThickness", 150.0, 0.0, 220.0, 1),
        LGGlassDarkTintSetting(@"Dock.DarkTintAlpha", 0.0, 0.0, 1.0, 2),
        LGSliderSetting(@"Dock.CornerRadiusHomeButton", LGLocalized(@"prefs.control.home_button_radius"), LGLocalized(@"prefs.subtitle.home_button_radius"), 0.0, 0.0, 40.0, 1),
        LGGlassLightTintSetting(@"Dock.LightTintAlpha", 0.1, 0.0, 0.3, 2),
        LGGlassRefractiveIndexSetting(@"Dock.RefractiveIndex", 1.5, 1.0, 2.0, 2),
        LGGlassRefractionSetting(@"Dock.RefractionScale", 1.5, 0.5, 3.0, 2),
        LGGlassSpecularSetting(@"Dock.SpecularOpacity", 0.5, 0.0, 1.0, 2),
        LGGlassQualitySetting(@"Dock.WallpaperScale", 0.25, 0.1, 1.0, 2),
    ];
}

static NSArray<NSDictionary *> *LGFolderItems(void) {
    return @[
        LGSectionSetting(LGLocalized(@"prefs.section.folder_icons.title"), LGLocalized(@"prefs.section.folder_icons.subtitle")),
        LGGlassEnabledSetting(@"FolderIcon.Enabled", YES),
        LGGlassBezelSetting(@"FolderIcon.BezelWidth", 12.0, 0.0, 30.0, 1),
        LGGlassBlurSetting(@"FolderIcon.Blur", 3.0, 0.0, 20.0, 1),
        LGGlassCornerRadiusSetting(@"FolderIcon.CornerRadius", 13.5, 0.0, 24.0, 1),
        LGGlassThicknessSetting(@"FolderIcon.GlassThickness", 90.0, 0.0, 160.0, 1),
        LGGlassDarkTintSetting(@"FolderIcon.DarkTintAlpha", 0.0, 0.0, 1.0, 2),
        LGGlassLightTintSetting(@"FolderIcon.LightTintAlpha", 0.1, 0.0, 0.3, 2),
        LGGlassRefractiveIndexSetting(@"FolderIcon.RefractiveIndex", 2.0, 1.0, 2.0, 2),
        LGGlassRefractionSetting(@"FolderIcon.RefractionScale", 2.0, 0.5, 3.0, 2),
        LGGlassSpecularSetting(@"FolderIcon.SpecularOpacity", 0.8, 0.0, 1.0, 2),
        LGGlassQualitySetting(@"FolderIcon.WallpaperScale", 0.5, 0.1, 1.0, 2),
        LGSectionSetting(LGLocalized(@"prefs.section.folder_open.title"), LGLocalized(@"prefs.section.folder_open.subtitle")),
        LGGlassEnabledSetting(@"FolderOpen.Enabled", YES),
        LGGlassBezelSetting(@"FolderOpen.BezelWidth", 24.0, 0.0, 50.0, 1),
        LGGlassBlurSetting(@"FolderOpen.Blur", 25.0, 0.0, 40.0, 1),
        LGGlassCornerRadiusSetting(@"FolderOpen.CornerRadius", 38.0, 0.0, 60.0, 1),
        LGGlassDarkTintSetting(@"FolderOpen.DarkTintAlpha", 0.0, 0.0, 1.0, 2),
        LGGlassThicknessSetting(@"FolderOpen.GlassThickness", 100.0, 0.0, 200.0, 1),
        LGGlassLightTintSetting(@"FolderOpen.LightTintAlpha", 0.1, 0.0, 0.3, 2),
        LGGlassRefractiveIndexSetting(@"FolderOpen.RefractiveIndex", 1.2, 1.0, 2.0, 2),
        LGGlassRefractionSetting(@"FolderOpen.RefractionScale", 1.8, 0.5, 3.0, 2),
        LGGlassSpecularSetting(@"FolderOpen.SpecularOpacity", 0.8, 0.0, 1.0, 2),
        LGGlassQualitySetting(@"FolderOpen.WallpaperScale", 0.1, 0.1, 1.0, 2),
    ];
}

static NSArray<NSDictionary *> *LGAppIconItems(void) {
    return @[
        LGSectionSetting(LGLocalized(@"prefs.section.app_icons.title"), LGLocalized(@"prefs.section.app_icons.subtitle")),
        LGGlassEnabledSetting(@"AppIcons.Enabled", NO),
        LGGlassBezelSetting(@"AppIcons.BezelWidth", 14.0, 0.0, 30.0, 1),
        LGGlassBlurSetting(@"AppIcons.Blur", 8.0, 0.0, 20.0, 1),
        LGGlassCornerRadiusSetting(@"AppIcons.CornerRadius", 13.5, 0.0, 24.0, 1),
        LGGlassThicknessSetting(@"AppIcons.GlassThickness", 80.0, 0.0, 160.0, 1),
        LGGlassDarkTintSetting(@"AppIcons.DarkTintAlpha", 0.0, 0.0, 1.0, 2),
        LGGlassLightTintSetting(@"AppIcons.LightTintAlpha", 0.1, 0.0, 0.3, 2),
        LGGlassRefractiveIndexSetting(@"AppIcons.RefractiveIndex", 1.0, 1.0, 2.0, 2),
        LGGlassRefractionSetting(@"AppIcons.RefractionScale", 1.2, 0.5, 3.0, 2),
        LGGlassSpecularSetting(@"AppIcons.SpecularOpacity", 0.8, 0.0, 1.0, 2),
        LGGlassQualitySetting(@"AppIcons.WallpaperScale", 0.5, 0.1, 1.0, 2),
    ];
}

static NSArray<NSDictionary *> *LGContextMenuItems(void) {
    return @[
        LGGlassEnabledSetting(@"ContextMenu.Enabled", YES),
        LGGlassBezelSetting(@"ContextMenu.BezelWidth", 18.0, 0.0, 40.0, 1),
        LGGlassBlurSetting(@"ContextMenu.Blur", 10.0, 0.0, 25.0, 1),
        LGGlassCornerRadiusSetting(@"ContextMenu.CornerRadius", 22.0, 0.0, 40.0, 1),
        LGGlassDarkTintSetting(@"ContextMenu.DarkTintAlpha", 0.6, 0.0, 1.0, 2),
        LGGlassThicknessSetting(@"ContextMenu.GlassThickness", 100.0, 0.0, 200.0, 1),
        LGSliderSetting(@"ContextMenu.IconSpacing", LGLocalized(@"prefs.control.icon_spacing"), LGLocalized(@"prefs.subtitle.icon_spacing"), 12.0, 0.0, 24.0, 1),
        LGGlassLightTintSetting(@"ContextMenu.LightTintAlpha", 0.8, 0.0, 1.0, 2),
        LGGlassRefractiveIndexSetting(@"ContextMenu.RefractiveIndex", 1.2, 1.0, 2.0, 2),
        LGGlassRefractionSetting(@"ContextMenu.RefractionScale", 1.8, 0.5, 3.0, 2),
        LGSliderSetting(@"ContextMenu.RowInset", LGLocalized(@"prefs.control.row_inset"), LGLocalized(@"prefs.subtitle.row_inset"), 16.0, 0.0, 30.0, 1),
        LGGlassSpecularSetting(@"ContextMenu.SpecularOpacity", 1.0, 0.0, 1.0, 2),
        LGGlassQualitySetting(@"ContextMenu.WallpaperScale", 0.1, 0.1, 1.0, 2),
    ];
}

static NSArray<NSDictionary *> *LGLockscreenItems(void) {
    return @[
        LGScopedFPSSliderSetting(@"Lockscreen.FPS"),
        LGSectionSetting(LGLocalized(@"prefs.section.lockscreen_notifications.title"), LGLocalized(@"prefs.section.lockscreen_notifications.subtitle")),
        LGGlassEnabledSetting(@"Lockscreen.Enabled", YES),
        LGGlassBezelSetting(@"Lockscreen.BezelWidth", 12.0, 0.0, 30.0, 1),
        LGGlassBlurSetting(@"Lockscreen.Blur", 8.0, 0.0, 20.0, 1),
        LGGlassCornerRadiusSetting(@"Lockscreen.CornerRadius", 18.5, 0.0, 40.0, 1),
        LGGlassDarkTintSetting(@"Lockscreen.DarkTintAlpha", 0.0, 0.0, 1.0, 2),
        LGGlassThicknessSetting(@"Lockscreen.GlassThickness", 80.0, 0.0, 160.0, 1),
        LGGlassLightTintSetting(@"Lockscreen.LightTintAlpha", 0.1, 0.0, 0.3, 2),
        LGGlassRefractiveIndexSetting(@"Lockscreen.RefractiveIndex", 1.0, 1.0, 2.0, 2),
        LGGlassRefractionSetting(@"Lockscreen.RefractionScale", 1.2, 0.5, 2.5, 2),
        LGGlassSpecularSetting(@"Lockscreen.SpecularOpacity", 0.8, 0.0, 1.0, 2),
        LGGlassQualitySetting(@"Lockscreen.WallpaperScale", 0.5, 0.1, 1.0, 2),
        LGSectionSetting(LGLocalized(@"prefs.section.lockscreen_quick_actions.title"), LGLocalized(@"prefs.section.lockscreen_quick_actions.subtitle")),
        LGGlassEnabledSetting(@"LockscreenQuickActions.Enabled", YES),
        LGGlassBezelSetting(@"LockscreenQuickActions.BezelWidth", 12.0, 0.0, 30.0, 1),
        LGGlassBlurSetting(@"LockscreenQuickActions.Blur", 8.0, 0.0, 20.0, 1),
        LGGlassCornerRadiusSetting(@"LockscreenQuickActions.CornerRadius", 25.0, 0.0, 40.0, 1),
        LGGlassDarkTintSetting(@"LockscreenQuickActions.DarkTintAlpha", 0.0, 0.0, 1.0, 2),
        LGGlassThicknessSetting(@"LockscreenQuickActions.GlassThickness", 80.0, 0.0, 160.0, 1),
        LGGlassLightTintSetting(@"LockscreenQuickActions.LightTintAlpha", 0.1, 0.0, 0.3, 2),
        LGGlassRefractiveIndexSetting(@"LockscreenQuickActions.RefractiveIndex", 1.0, 1.0, 2.0, 2),
        LGGlassRefractionSetting(@"LockscreenQuickActions.RefractionScale", 1.2, 0.5, 2.5, 2),
        LGGlassSpecularSetting(@"LockscreenQuickActions.SpecularOpacity", 0.8, 0.0, 1.0, 2),
        LGGlassQualitySetting(@"LockscreenQuickActions.WallpaperScale", 0.5, 0.1, 1.0, 2),
    ];
}

static NSArray<NSDictionary *> *LGAppLibraryItems(void) {
    return @[
        LGScopedFPSSliderSetting(@"AppLibrary.FPS"),
        LGSectionSetting(LGLocalized(@"prefs.section.category_pods.title"), LGLocalized(@"prefs.section.category_pods.subtitle")),
        LGGlassEnabledSetting(@"AppLibrary.Enabled", YES),
        LGGlassBlurSetting(@"AppLibrary.Blur", 25.0, 0.0, 40.0, 1),
        LGGlassBezelSetting(@"AppLibrary.BezelWidth", 18.0, 0.0, 40.0, 1),
        LGGlassCornerRadiusSetting(@"AppLibrary.CornerRadius", 20.2, 0.0, 40.0, 1),
        LGGlassDarkTintSetting(@"AppLibrary.DarkTintAlpha", 0.0, 0.0, 1.0, 2),
        LGGlassThicknessSetting(@"AppLibrary.GlassThickness", 150.0, 0.0, 220.0, 1),
        LGGlassLightTintSetting(@"AppLibrary.LightTintAlpha", 0.1, 0.0, 0.3, 2),
        LGGlassRefractiveIndexSetting(@"AppLibrary.RefractiveIndex", 1.2, 1.0, 2.0, 2),
        LGGlassRefractionSetting(@"AppLibrary.RefractionScale", 1.8, 0.5, 3.0, 2),
        LGGlassSpecularSetting(@"AppLibrary.SpecularOpacity", 0.8, 0.0, 1.0, 2),
        LGGlassQualitySetting(@"AppLibrary.WallpaperScale", 0.1, 0.1, 1.0, 2),
        LGSectionSetting(LGLocalized(@"prefs.section.search_field.title"), LGLocalized(@"prefs.section.search_field.subtitle")),
        LGGlassEnabledSetting(@"AppLibrary.Enabled", YES),
        LGGlassBezelSetting(@"AppLibrary.SearchBezelWidth", 16.0, 0.0, 40.0, 1),
        LGGlassBlurSetting(@"AppLibrary.SearchBlur", 25.0, 0.0, 40.0, 1),
        LGGlassCornerRadiusSetting(@"AppLibrary.SearchCornerRadius", 24.0, 0.0, 40.0, 1),
        LGGlassDarkTintSetting(@"AppLibrary.SearchDarkTintAlpha", 0.0, 0.0, 1.0, 2),
        LGGlassThicknessSetting(@"AppLibrary.SearchGlassThickness", 100.0, 0.0, 180.0, 1),
        LGGlassLightTintSetting(@"AppLibrary.SearchLightTintAlpha", 0.1, 0.0, 0.3, 2),
        LGGlassRefractiveIndexSetting(@"AppLibrary.SearchRefractiveIndex", 1.5, 1.0, 2.0, 2),
        LGGlassRefractionSetting(@"AppLibrary.SearchRefractionScale", 1.5, 0.5, 3.0, 2),
        LGGlassSpecularSetting(@"AppLibrary.SearchSpecularOpacity", 0.8, 0.0, 1.0, 2),
        LGGlassQualitySetting(@"AppLibrary.SearchWallpaperScale", 0.1, 0.1, 1.0, 2),
    ];
}

static NSArray<NSDictionary *> *LGWidgetItems(void) {
    return @[
        LGGlassEnabledSetting(@"Widgets.Enabled", NO),
        LGGlassBezelSetting(@"Widgets.BezelWidth", 18.0, 0.0, 40.0, 1),
        LGGlassBlurSetting(@"Widgets.Blur", 8.0, 0.0, 20.0, 1),
        LGGlassCornerRadiusSetting(@"Widgets.CornerRadius", 20.2, 0.0, 40.0, 1),
        LGGlassDarkTintSetting(@"Widgets.DarkTintAlpha", 0.3, 0.0, 1.0, 2),
        LGGlassThicknessSetting(@"Widgets.GlassThickness", 150.0, 0.0, 220.0, 1),
        LGGlassLightTintSetting(@"Widgets.LightTintAlpha", 0.1, 0.0, 0.3, 2),
        LGGlassRefractiveIndexSetting(@"Widgets.RefractiveIndex", 1.2, 1.0, 2.0, 2),
        LGGlassRefractionSetting(@"Widgets.RefractionScale", 1.8, 0.5, 3.0, 2),
        LGGlassSpecularSetting(@"Widgets.SpecularOpacity", 0.8, 0.0, 1.0, 2),
        LGGlassQualitySetting(@"Widgets.WallpaperScale", 0.5, 0.1, 1.0, 2),
    ];
}

static NSArray<NSDictionary *> *LGHomescreenItems(void) {
    NSMutableArray<NSDictionary *> *items = [NSMutableArray array];
    [items addObject:LGScopedFPSSliderSetting(@"Homescreen.FPS")];
    [items addObject:LGSectionSetting(LGLocalized(@"prefs.section.dock.title"), LGLocalized(@"prefs.section.dock.subtitle"))];
    [items addObjectsFromArray:LGDockItems()];
    [items addObjectsFromArray:LGFolderItems()];
    [items addObject:LGSectionSetting(LGLocalized(@"prefs.section.context_menu.title"), LGLocalized(@"prefs.section.context_menu.subtitle"))];
    [items addObjectsFromArray:LGContextMenuItems()];
    [items addObject:LGSectionSetting(LGLocalized(@"prefs.section.widgets.title"), LGLocalized(@"prefs.section.widgets.subtitle"))];
    [items addObjectsFromArray:LGWidgetItems()];
    [items addObjectsFromArray:LGAppIconItems()];
    return [items copy];
}

static NSArray<NSDictionary *> *LGAllSurfaceItems(void) {
    static NSArray<NSDictionary *> *items = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSMutableArray<NSDictionary *> *all = [NSMutableArray array];
        [all addObject:LGSwitchSetting(@"Global.Enabled", LGLocalized(@"prefs.control.enabled"), LGLocalized(@"prefs.subtitle.global_enabled"), NO)];
        [all addObjectsFromArray:LGHomescreenItems()];
        [all addObjectsFromArray:LGLockscreenItems()];
        [all addObjectsFromArray:LGAppLibraryItems()];
        items = [all copy];
    });
    return items;
}

static NSArray<NSDictionary *> *LGMoreOptionsItems(void) {
    return @[
        LGSwitchSetting(@"SettingsControls.Enabled",
                        LGLocalized(@"prefs.misc.settings_controls.title"),
                        LGLocalized(@"prefs.misc.settings_controls.subtitle"),
                        NO),
    ];
}

static void LGDismissResetConfirmation(UIView *overlay, UIView *panel) {
    [UIView animateWithDuration:0.22 animations:^{
        overlay.alpha = 0.0;
        panel.transform = CGAffineTransformMakeScale(0.96, 0.96);
    } completion:^(__unused BOOL finished) {
        [overlay removeFromSuperview];
    }];
}

static void LGPresentResetConfirmation(UIViewController *controller) {
    if (!controller.view.window) return;
    UIView *existing = [controller.view viewWithTag:0x1ACE];
    if (existing) [existing removeFromSuperview];

    UIView *overlay = [[UIView alloc] initWithFrame:controller.view.bounds];
    overlay.tag = 0x1ACE;
    overlay.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    overlay.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.24];
    overlay.alpha = 0.0;

    UIControl *dismissControl = [[UIControl alloc] initWithFrame:overlay.bounds];
    dismissControl.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [overlay addSubview:dismissControl];

    UIVisualEffectView *panel =
        [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterial]];
    panel.translatesAutoresizingMaskIntoConstraints = NO;
    panel.layer.cornerRadius = 32.0;
    panel.layer.cornerCurve = kCACornerCurveContinuous;
    panel.layer.masksToBounds = YES;
    panel.transform = CGAffineTransformMakeScale(0.96, 0.96);

    UILabel *titleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    titleLabel.text = LGLocalized(@"prefs.reset_confirm.title");
    titleLabel.font = [UIFont systemFontOfSize:24.0 weight:UIFontWeightBold];
    titleLabel.numberOfLines = 0;

    UILabel *bodyLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    bodyLabel.translatesAutoresizingMaskIntoConstraints = NO;
    bodyLabel.text = LGLocalized(@"prefs.reset_confirm.body");
    bodyLabel.font = [UIFont systemFontOfSize:15.0 weight:UIFontWeightMedium];
    bodyLabel.textColor = [UIColor secondaryLabelColor];
    bodyLabel.numberOfLines = 0;

    UIButton *cancelButton = [UIButton buttonWithType:UIButtonTypeSystem];
    cancelButton.translatesAutoresizingMaskIntoConstraints = NO;
    [cancelButton setTitle:LGLocalized(@"prefs.button.cancel") forState:UIControlStateNormal];
    [cancelButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    cancelButton.titleLabel.font = [UIFont systemFontOfSize:17.0 weight:UIFontWeightSemibold];
    cancelButton.backgroundColor = [UIColor systemBlueColor];
    cancelButton.layer.cornerRadius = 23.0;
    cancelButton.layer.cornerCurve = kCACornerCurveContinuous;
    cancelButton.layer.masksToBounds = YES;

    UIButton *resetButton = [UIButton buttonWithType:UIButtonTypeSystem];
    resetButton.translatesAutoresizingMaskIntoConstraints = NO;
    [resetButton setTitle:LGLocalized(@"prefs.button.reset") forState:UIControlStateNormal];
    [resetButton setTitleColor:[UIColor systemRedColor] forState:UIControlStateNormal];
    resetButton.titleLabel.font = [UIFont systemFontOfSize:17.0 weight:UIFontWeightSemibold];
    resetButton.backgroundColor = [UIColor tertiarySystemFillColor];
    resetButton.layer.cornerRadius = 23.0;
    resetButton.layer.cornerCurve = kCACornerCurveContinuous;
    resetButton.layer.masksToBounds = YES;

    UIStackView *buttonRow = [[UIStackView alloc] initWithArrangedSubviews:@[cancelButton, resetButton]];
    buttonRow.translatesAutoresizingMaskIntoConstraints = NO;
    buttonRow.axis = UILayoutConstraintAxisHorizontal;
    buttonRow.spacing = 12.0;
    buttonRow.distribution = UIStackViewDistributionFillEqually;

    [overlay addSubview:panel];
    [panel.contentView addSubview:titleLabel];
    [panel.contentView addSubview:bodyLabel];
    [panel.contentView addSubview:buttonRow];

    [NSLayoutConstraint activateConstraints:@[
        [panel.centerXAnchor constraintEqualToAnchor:overlay.centerXAnchor],
        [panel.centerYAnchor constraintEqualToAnchor:overlay.centerYAnchor],
        [panel.leadingAnchor constraintGreaterThanOrEqualToAnchor:overlay.leadingAnchor constant:20.0],
        [panel.trailingAnchor constraintLessThanOrEqualToAnchor:overlay.trailingAnchor constant:-20.0],
        [panel.widthAnchor constraintEqualToConstant:320.0],

        [titleLabel.topAnchor constraintEqualToAnchor:panel.contentView.topAnchor constant:22.0],
        [titleLabel.leadingAnchor constraintEqualToAnchor:panel.contentView.leadingAnchor constant:18.0],
        [titleLabel.trailingAnchor constraintEqualToAnchor:panel.contentView.trailingAnchor constant:-18.0],

        [bodyLabel.topAnchor constraintEqualToAnchor:titleLabel.bottomAnchor constant:10.0],
        [bodyLabel.leadingAnchor constraintEqualToAnchor:panel.contentView.leadingAnchor constant:18.0],
        [bodyLabel.trailingAnchor constraintEqualToAnchor:panel.contentView.trailingAnchor constant:-18.0],

        [buttonRow.topAnchor constraintEqualToAnchor:bodyLabel.bottomAnchor constant:20.0],
        [buttonRow.leadingAnchor constraintEqualToAnchor:panel.contentView.leadingAnchor constant:16.0],
        [buttonRow.trailingAnchor constraintEqualToAnchor:panel.contentView.trailingAnchor constant:-16.0],
        [buttonRow.bottomAnchor constraintEqualToAnchor:panel.contentView.bottomAnchor constant:-16.0],
        [cancelButton.heightAnchor constraintEqualToConstant:46.0],
        [resetButton.heightAnchor constraintEqualToConstant:46.0],
    ]];

    [dismissControl addAction:[UIAction actionWithHandler:^(__kindof UIAction * _Nonnull _) {
        LGDismissResetConfirmation(overlay, panel);
    }] forControlEvents:UIControlEventTouchUpInside];

    [cancelButton addAction:[UIAction actionWithHandler:^(__kindof UIAction * _Nonnull _) {
        LGDismissResetConfirmation(overlay, panel);
    }] forControlEvents:UIControlEventTouchUpInside];

    [resetButton addAction:[UIAction actionWithHandler:^(__kindof UIAction * _Nonnull _) {
        LGResetAllPreferences();
        LGDismissResetConfirmation(overlay, panel);
    }] forControlEvents:UIControlEventTouchUpInside];

    [controller.view addSubview:overlay];
    [UIView animateWithDuration:0.22 animations:^{
        overlay.alpha = 1.0;
        panel.transform = CGAffineTransformIdentity;
    }];
}

static void LGPresentRespringConfirmation(UIViewController *controller) {
    if (!controller.view.window) return;
    UIView *existing = [controller.view viewWithTag:0x1ACF];
    if (existing) [existing removeFromSuperview];

    UIView *overlay = [[UIView alloc] initWithFrame:controller.view.bounds];
    overlay.tag = 0x1ACF;
    overlay.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    overlay.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.24];
    overlay.alpha = 0.0;

    UIControl *dismissControl = [[UIControl alloc] initWithFrame:overlay.bounds];
    dismissControl.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [overlay addSubview:dismissControl];

    UIVisualEffectView *panel =
        [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterial]];
    panel.translatesAutoresizingMaskIntoConstraints = NO;
    panel.layer.cornerRadius = 32.0;
    panel.layer.cornerCurve = kCACornerCurveContinuous;
    panel.layer.masksToBounds = YES;
    panel.transform = CGAffineTransformMakeScale(0.96, 0.96);

    UILabel *titleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    titleLabel.text = LGLocalized(@"prefs.respring_confirm.title");
    titleLabel.font = [UIFont systemFontOfSize:24.0 weight:UIFontWeightBold];
    titleLabel.numberOfLines = 0;

    UILabel *bodyLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    bodyLabel.translatesAutoresizingMaskIntoConstraints = NO;
    bodyLabel.text = LGLocalized(@"prefs.respring_confirm.body");
    bodyLabel.font = [UIFont systemFontOfSize:15.0 weight:UIFontWeightMedium];
    bodyLabel.textColor = [UIColor secondaryLabelColor];
    bodyLabel.numberOfLines = 0;

    UIButton *laterButton = [UIButton buttonWithType:UIButtonTypeSystem];
    laterButton.translatesAutoresizingMaskIntoConstraints = NO;
    [laterButton setTitle:LGLocalized(@"prefs.button.later") forState:UIControlStateNormal];
    [laterButton setTitleColor:[UIColor secondaryLabelColor] forState:UIControlStateNormal];
    laterButton.titleLabel.font = [UIFont systemFontOfSize:17.0 weight:UIFontWeightSemibold];
    laterButton.backgroundColor = [UIColor tertiarySystemFillColor];
    laterButton.layer.cornerRadius = 23.0;
    laterButton.layer.cornerCurve = kCACornerCurveContinuous;
    laterButton.layer.masksToBounds = YES;

    UIButton *respringButton = [UIButton buttonWithType:UIButtonTypeSystem];
    respringButton.translatesAutoresizingMaskIntoConstraints = NO;
    [respringButton setTitle:LGLocalized(@"prefs.button.respring") forState:UIControlStateNormal];
    [respringButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    respringButton.titleLabel.font = [UIFont systemFontOfSize:17.0 weight:UIFontWeightSemibold];
    respringButton.backgroundColor = [UIColor systemBlueColor];
    respringButton.layer.cornerRadius = 23.0;
    respringButton.layer.cornerCurve = kCACornerCurveContinuous;
    respringButton.layer.masksToBounds = YES;

    UIStackView *buttonRow = [[UIStackView alloc] initWithArrangedSubviews:@[laterButton, respringButton]];
    buttonRow.translatesAutoresizingMaskIntoConstraints = NO;
    buttonRow.axis = UILayoutConstraintAxisHorizontal;
    buttonRow.spacing = 12.0;
    buttonRow.distribution = UIStackViewDistributionFillEqually;

    [overlay addSubview:panel];
    [panel.contentView addSubview:titleLabel];
    [panel.contentView addSubview:bodyLabel];
    [panel.contentView addSubview:buttonRow];

    [NSLayoutConstraint activateConstraints:@[
        [panel.centerXAnchor constraintEqualToAnchor:overlay.centerXAnchor],
        [panel.centerYAnchor constraintEqualToAnchor:overlay.centerYAnchor],
        [panel.leadingAnchor constraintGreaterThanOrEqualToAnchor:overlay.leadingAnchor constant:20.0],
        [panel.trailingAnchor constraintLessThanOrEqualToAnchor:overlay.trailingAnchor constant:-20.0],
        [panel.widthAnchor constraintEqualToConstant:320.0],

        [titleLabel.topAnchor constraintEqualToAnchor:panel.contentView.topAnchor constant:22.0],
        [titleLabel.leadingAnchor constraintEqualToAnchor:panel.contentView.leadingAnchor constant:18.0],
        [titleLabel.trailingAnchor constraintEqualToAnchor:panel.contentView.trailingAnchor constant:-18.0],

        [bodyLabel.topAnchor constraintEqualToAnchor:titleLabel.bottomAnchor constant:10.0],
        [bodyLabel.leadingAnchor constraintEqualToAnchor:panel.contentView.leadingAnchor constant:18.0],
        [bodyLabel.trailingAnchor constraintEqualToAnchor:panel.contentView.trailingAnchor constant:-18.0],

        [buttonRow.topAnchor constraintEqualToAnchor:bodyLabel.bottomAnchor constant:20.0],
        [buttonRow.leadingAnchor constraintEqualToAnchor:panel.contentView.leadingAnchor constant:16.0],
        [buttonRow.trailingAnchor constraintEqualToAnchor:panel.contentView.trailingAnchor constant:-16.0],
        [buttonRow.bottomAnchor constraintEqualToAnchor:panel.contentView.bottomAnchor constant:-16.0],
        [laterButton.heightAnchor constraintEqualToConstant:46.0],
        [respringButton.heightAnchor constraintEqualToConstant:46.0],
    ]];

    [dismissControl addAction:[UIAction actionWithHandler:^(__kindof UIAction * _Nonnull _) {
        LGDismissResetConfirmation(overlay, panel);
    }] forControlEvents:UIControlEventTouchUpInside];

    [laterButton addAction:[UIAction actionWithHandler:^(__kindof UIAction * _Nonnull _) {
        LGDismissResetConfirmation(overlay, panel);
    }] forControlEvents:UIControlEventTouchUpInside];

    [respringButton addAction:[UIAction actionWithHandler:^(__kindof UIAction * _Nonnull _) {
        LGSetNeedsRespring(NO);
        notify_post(kLGPrefsRespringNotification);
        LGDismissResetConfirmation(overlay, panel);
    }] forControlEvents:UIControlEventTouchUpInside];

    [controller.view addSubview:overlay];
    [UIView animateWithDuration:0.22 animations:^{
        overlay.alpha = 1.0;
        panel.transform = CGAffineTransformIdentity;
    }];
}

static void LGPresentReopenSettingsConfirmation(UIViewController *controller) {
    if (!controller.view.window) return;
    UIView *existing = [controller.view viewWithTag:0x1AD2];
    if (existing) [existing removeFromSuperview];

    UIView *overlay = [[UIView alloc] initWithFrame:controller.view.bounds];
    overlay.tag = 0x1AD2;
    overlay.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    overlay.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.24];
    overlay.alpha = 0.0;

    UIControl *dismissControl = [[UIControl alloc] initWithFrame:overlay.bounds];
    dismissControl.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [overlay addSubview:dismissControl];

    UIVisualEffectView *panel =
        [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterial]];
    panel.translatesAutoresizingMaskIntoConstraints = NO;
    panel.layer.cornerRadius = 32.0;
    panel.layer.cornerCurve = kCACornerCurveContinuous;
    panel.layer.masksToBounds = YES;
    panel.transform = CGAffineTransformMakeScale(0.96, 0.96);

    UILabel *titleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    titleLabel.text = LGLocalized(@"prefs.reopen_settings.title");
    titleLabel.font = [UIFont systemFontOfSize:24.0 weight:UIFontWeightBold];
    titleLabel.numberOfLines = 0;

    UILabel *bodyLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    bodyLabel.translatesAutoresizingMaskIntoConstraints = NO;
    bodyLabel.text = LGLocalized(@"prefs.reopen_settings.body");
    bodyLabel.font = [UIFont systemFontOfSize:15.0 weight:UIFontWeightMedium];
    bodyLabel.textColor = [UIColor secondaryLabelColor];
    bodyLabel.numberOfLines = 0;

    UIButton *laterButton = [UIButton buttonWithType:UIButtonTypeSystem];
    laterButton.translatesAutoresizingMaskIntoConstraints = NO;
    [laterButton setTitle:LGLocalized(@"prefs.button.later") forState:UIControlStateNormal];
    [laterButton setTitleColor:[UIColor secondaryLabelColor] forState:UIControlStateNormal];
    laterButton.titleLabel.font = [UIFont systemFontOfSize:17.0 weight:UIFontWeightSemibold];
    laterButton.backgroundColor = [UIColor tertiarySystemFillColor];
    laterButton.layer.cornerRadius = 23.0;
    laterButton.layer.cornerCurve = kCACornerCurveContinuous;
    laterButton.layer.masksToBounds = YES;

    UIButton *reopenButton = [UIButton buttonWithType:UIButtonTypeSystem];
    reopenButton.translatesAutoresizingMaskIntoConstraints = NO;
    [reopenButton setTitle:LGLocalized(@"prefs.button.reopen_settings") forState:UIControlStateNormal];
    [reopenButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    reopenButton.titleLabel.font = [UIFont systemFontOfSize:17.0 weight:UIFontWeightSemibold];
    reopenButton.backgroundColor = [UIColor systemBlueColor];
    reopenButton.layer.cornerRadius = 23.0;
    reopenButton.layer.cornerCurve = kCACornerCurveContinuous;
    reopenButton.layer.masksToBounds = YES;

    UIStackView *buttonRow = [[UIStackView alloc] initWithArrangedSubviews:@[laterButton, reopenButton]];
    buttonRow.translatesAutoresizingMaskIntoConstraints = NO;
    buttonRow.axis = UILayoutConstraintAxisHorizontal;
    buttonRow.spacing = 12.0;
    buttonRow.distribution = UIStackViewDistributionFillEqually;

    [overlay addSubview:panel];
    [panel.contentView addSubview:titleLabel];
    [panel.contentView addSubview:bodyLabel];
    [panel.contentView addSubview:buttonRow];

    [NSLayoutConstraint activateConstraints:@[
        [panel.centerXAnchor constraintEqualToAnchor:overlay.centerXAnchor],
        [panel.centerYAnchor constraintEqualToAnchor:overlay.centerYAnchor],
        [panel.leadingAnchor constraintGreaterThanOrEqualToAnchor:overlay.leadingAnchor constant:20.0],
        [panel.trailingAnchor constraintLessThanOrEqualToAnchor:overlay.trailingAnchor constant:-20.0],
        [panel.widthAnchor constraintEqualToConstant:320.0],

        [titleLabel.topAnchor constraintEqualToAnchor:panel.contentView.topAnchor constant:22.0],
        [titleLabel.leadingAnchor constraintEqualToAnchor:panel.contentView.leadingAnchor constant:18.0],
        [titleLabel.trailingAnchor constraintEqualToAnchor:panel.contentView.trailingAnchor constant:-18.0],

        [bodyLabel.topAnchor constraintEqualToAnchor:titleLabel.bottomAnchor constant:10.0],
        [bodyLabel.leadingAnchor constraintEqualToAnchor:panel.contentView.leadingAnchor constant:18.0],
        [bodyLabel.trailingAnchor constraintEqualToAnchor:panel.contentView.trailingAnchor constant:-18.0],

        [buttonRow.topAnchor constraintEqualToAnchor:bodyLabel.bottomAnchor constant:20.0],
        [buttonRow.leadingAnchor constraintEqualToAnchor:panel.contentView.leadingAnchor constant:16.0],
        [buttonRow.trailingAnchor constraintEqualToAnchor:panel.contentView.trailingAnchor constant:-16.0],
        [buttonRow.bottomAnchor constraintEqualToAnchor:panel.contentView.bottomAnchor constant:-16.0],
        [laterButton.heightAnchor constraintEqualToConstant:46.0],
        [reopenButton.heightAnchor constraintEqualToConstant:46.0],
    ]];

    [dismissControl addAction:[UIAction actionWithHandler:^(__kindof UIAction * _Nonnull _) {
        LGDismissResetConfirmation(overlay, panel);
    }] forControlEvents:UIControlEventTouchUpInside];

    [laterButton addAction:[UIAction actionWithHandler:^(__kindof UIAction * _Nonnull _) {
        LGDismissResetConfirmation(overlay, panel);
    }] forControlEvents:UIControlEventTouchUpInside];

    [reopenButton addAction:[UIAction actionWithHandler:^(__kindof UIAction * _Nonnull _) {
        LGDismissResetConfirmation(overlay, panel);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.18 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            exit(0);
        });
    }] forControlEvents:UIControlEventTouchUpInside];

    [controller.view addSubview:overlay];
    [UIView animateWithDuration:0.22 animations:^{
        overlay.alpha = 1.0;
        panel.transform = CGAffineTransformIdentity;
    }];
}

static void LGPresentInfoSheet(UIViewController *controller, NSString *title, NSString *message) {
    if (!controller.view.window) return;
    UIView *existing = [controller.view viewWithTag:0x1AD0];
    if (existing) [existing removeFromSuperview];

    UIView *overlay = [[UIView alloc] initWithFrame:controller.view.bounds];
    overlay.tag = 0x1AD0;
    overlay.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    overlay.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.24];
    overlay.alpha = 0.0;

    UIControl *dismissControl = [[UIControl alloc] initWithFrame:overlay.bounds];
    dismissControl.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [overlay addSubview:dismissControl];

    UIVisualEffectView *panel =
        [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterial]];
    panel.translatesAutoresizingMaskIntoConstraints = NO;
    panel.layer.cornerRadius = 32.0;
    panel.layer.cornerCurve = kCACornerCurveContinuous;
    panel.layer.masksToBounds = YES;
    panel.transform = CGAffineTransformMakeScale(0.96, 0.96);

    UILabel *titleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    titleLabel.text = title.length ? title : LGLocalized(@"prefs.info.title");
    titleLabel.font = [UIFont systemFontOfSize:24.0 weight:UIFontWeightBold];
    titleLabel.numberOfLines = 0;

    UILabel *bodyLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    bodyLabel.translatesAutoresizingMaskIntoConstraints = NO;
    bodyLabel.text = message.length ? message : @"";
    bodyLabel.font = [UIFont systemFontOfSize:15.0 weight:UIFontWeightMedium];
    bodyLabel.textColor = [UIColor secondaryLabelColor];
    bodyLabel.numberOfLines = 0;

    UIButton *okButton = [UIButton buttonWithType:UIButtonTypeSystem];
    okButton.translatesAutoresizingMaskIntoConstraints = NO;
    [okButton setTitle:LGLocalized(@"prefs.button.ok") forState:UIControlStateNormal];
    [okButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    okButton.titleLabel.font = [UIFont systemFontOfSize:17.0 weight:UIFontWeightSemibold];
    okButton.backgroundColor = [UIColor systemBlueColor];
    okButton.layer.cornerRadius = 23.0;
    okButton.layer.cornerCurve = kCACornerCurveContinuous;
    okButton.layer.masksToBounds = YES;

    [overlay addSubview:panel];
    [panel.contentView addSubview:titleLabel];
    [panel.contentView addSubview:bodyLabel];
    [panel.contentView addSubview:okButton];

    [NSLayoutConstraint activateConstraints:@[
        [panel.centerXAnchor constraintEqualToAnchor:overlay.centerXAnchor],
        [panel.centerYAnchor constraintEqualToAnchor:overlay.centerYAnchor],
        [panel.leadingAnchor constraintGreaterThanOrEqualToAnchor:overlay.leadingAnchor constant:20.0],
        [panel.trailingAnchor constraintLessThanOrEqualToAnchor:overlay.trailingAnchor constant:-20.0],
        [panel.widthAnchor constraintEqualToConstant:320.0],

        [titleLabel.topAnchor constraintEqualToAnchor:panel.contentView.topAnchor constant:22.0],
        [titleLabel.leadingAnchor constraintEqualToAnchor:panel.contentView.leadingAnchor constant:18.0],
        [titleLabel.trailingAnchor constraintEqualToAnchor:panel.contentView.trailingAnchor constant:-18.0],

        [bodyLabel.topAnchor constraintEqualToAnchor:titleLabel.bottomAnchor constant:10.0],
        [bodyLabel.leadingAnchor constraintEqualToAnchor:panel.contentView.leadingAnchor constant:18.0],
        [bodyLabel.trailingAnchor constraintEqualToAnchor:panel.contentView.trailingAnchor constant:-18.0],

        [okButton.topAnchor constraintEqualToAnchor:bodyLabel.bottomAnchor constant:20.0],
        [okButton.leadingAnchor constraintEqualToAnchor:panel.contentView.leadingAnchor constant:16.0],
        [okButton.trailingAnchor constraintEqualToAnchor:panel.contentView.trailingAnchor constant:-16.0],
        [okButton.bottomAnchor constraintEqualToAnchor:panel.contentView.bottomAnchor constant:-16.0],
        [okButton.heightAnchor constraintEqualToConstant:46.0],
    ]];

    [dismissControl addAction:[UIAction actionWithHandler:^(__kindof UIAction * _Nonnull _) {
        LGDismissResetConfirmation(overlay, panel);
    }] forControlEvents:UIControlEventTouchUpInside];

    [okButton addAction:[UIAction actionWithHandler:^(__kindof UIAction * _Nonnull _) {
        LGDismissResetConfirmation(overlay, panel);
    }] forControlEvents:UIControlEventTouchUpInside];

    [controller.view addSubview:overlay];
    [UIView animateWithDuration:0.22 animations:^{
        overlay.alpha = 1.0;
        panel.transform = CGAffineTransformIdentity;
    }];
}

@interface LGPSurfaceController : UIViewController <UIScrollViewDelegate>
- (instancetype)initWithTitle:(NSString *)title
                     subtitle:(NSString *)subtitle
                    tintColor:(UIColor *)tintColor
                   identifier:(NSString *)identifier
                        items:(NSArray<NSDictionary *> *)items;
@end

static UIView *LGMakeRespringBar(id target, SEL respringAction, SEL laterAction) {
    UIView *card = [[UIView alloc] initWithFrame:CGRectZero];
    card.translatesAutoresizingMaskIntoConstraints = NO;
    card.layer.cornerRadius = 26.0;
    card.layer.cornerCurve = kCACornerCurveContinuous;
    card.layer.masksToBounds = YES;
    card.alpha = 0.0;
    card.hidden = YES;
    card.transform = CGAffineTransformMakeTranslation(0.0, 10.0);

    UIBlurEffectStyle blurStyle = UIBlurEffectStyleSystemThinMaterial;
    UIVisualEffectView *blurView = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:blurStyle]];
    blurView.translatesAutoresizingMaskIntoConstraints = NO;
    blurView.userInteractionEnabled = NO;
    [card addSubview:blurView];

    UIView *tintView = [[UIView alloc] initWithFrame:CGRectZero];
    tintView.translatesAutoresizingMaskIntoConstraints = NO;
    tintView.userInteractionEnabled = NO;
    tintView.backgroundColor = [UIColor colorWithDynamicProvider:^UIColor * _Nonnull(UITraitCollection * _Nonnull trait) {
        if (trait.userInterfaceStyle == UIUserInterfaceStyleDark) {
            return [[UIColor whiteColor] colorWithAlphaComponent:0.04];
        }
        return [[UIColor blackColor] colorWithAlphaComponent:0.01];
    }];
    [card addSubview:tintView];

    UILabel *titleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    titleLabel.text = LGLocalized(@"prefs.respring_bar.title");
    titleLabel.font = [UIFont systemFontOfSize:16.0 weight:UIFontWeightSemibold];

    UILabel *subtitleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    subtitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    subtitleLabel.text = LGLocalized(@"prefs.respring_bar.subtitle");
    subtitleLabel.textColor = [UIColor secondaryLabelColor];
    subtitleLabel.font = [UIFont systemFontOfSize:13.0 weight:UIFontWeightRegular];
    subtitleLabel.numberOfLines = 2;

    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    [button setTitle:LGLocalized(@"prefs.button.respring") forState:UIControlStateNormal];
    [button setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    button.titleLabel.font = [UIFont systemFontOfSize:15.0 weight:UIFontWeightSemibold];
    button.backgroundColor = [UIColor systemBlueColor];
    button.layer.cornerRadius = 14.0;
    button.layer.cornerCurve = kCACornerCurveContinuous;
    [button addTarget:target action:respringAction forControlEvents:UIControlEventTouchUpInside];

    UIButton *laterButton = [UIButton buttonWithType:UIButtonTypeSystem];
    laterButton.translatesAutoresizingMaskIntoConstraints = NO;
    [laterButton setTitle:LGLocalized(@"prefs.button.later") forState:UIControlStateNormal];
    [laterButton setTitleColor:[UIColor secondaryLabelColor] forState:UIControlStateNormal];
    laterButton.titleLabel.font = [UIFont systemFontOfSize:15.0 weight:UIFontWeightSemibold];
    laterButton.backgroundColor = [UIColor colorWithDynamicProvider:^UIColor * _Nonnull(UITraitCollection * _Nonnull trait) {
        if (trait.userInterfaceStyle == UIUserInterfaceStyleDark) {
            return [[UIColor whiteColor] colorWithAlphaComponent:0.10];
        }
        return [[UIColor blackColor] colorWithAlphaComponent:0.06];
    }];
    laterButton.layer.cornerRadius = 14.0;
    laterButton.layer.cornerCurve = kCACornerCurveContinuous;
    [laterButton addTarget:target action:laterAction forControlEvents:UIControlEventTouchUpInside];

    [NSLayoutConstraint activateConstraints:@[
        [blurView.topAnchor constraintEqualToAnchor:card.topAnchor],
        [blurView.leadingAnchor constraintEqualToAnchor:card.leadingAnchor],
        [blurView.trailingAnchor constraintEqualToAnchor:card.trailingAnchor],
        [blurView.bottomAnchor constraintEqualToAnchor:card.bottomAnchor],
        [tintView.topAnchor constraintEqualToAnchor:card.topAnchor],
        [tintView.leadingAnchor constraintEqualToAnchor:card.leadingAnchor],
        [tintView.trailingAnchor constraintEqualToAnchor:card.trailingAnchor],
        [tintView.bottomAnchor constraintEqualToAnchor:card.bottomAnchor],
    ]];

    UIStackView *buttonStack = [[UIStackView alloc] initWithFrame:CGRectZero];
    buttonStack.translatesAutoresizingMaskIntoConstraints = NO;
    buttonStack.axis = UILayoutConstraintAxisVertical;
    buttonStack.spacing = 7.0;
    [buttonStack addArrangedSubview:button];
    [buttonStack addArrangedSubview:laterButton];

    [card addSubview:titleLabel];
    [card addSubview:subtitleLabel];
    [card addSubview:buttonStack];
    [NSLayoutConstraint activateConstraints:@[
        [titleLabel.topAnchor constraintEqualToAnchor:card.topAnchor constant:14.0],
        [titleLabel.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:16.0],
        [titleLabel.trailingAnchor constraintLessThanOrEqualToAnchor:buttonStack.leadingAnchor constant:-12.0],
        [subtitleLabel.topAnchor constraintEqualToAnchor:titleLabel.bottomAnchor constant:4.0],
        [subtitleLabel.leadingAnchor constraintEqualToAnchor:titleLabel.leadingAnchor],
        [subtitleLabel.trailingAnchor constraintLessThanOrEqualToAnchor:buttonStack.leadingAnchor constant:-12.0],
        [subtitleLabel.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-14.0],
        [buttonStack.centerYAnchor constraintEqualToAnchor:card.centerYAnchor],
        [buttonStack.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-16.0],
        [buttonStack.widthAnchor constraintEqualToConstant:96.0],
        [button.widthAnchor constraintEqualToConstant:82.0],
        [button.heightAnchor constraintEqualToConstant:28.0],
        [laterButton.widthAnchor constraintEqualToConstant:82.0],
        [laterButton.heightAnchor constraintEqualToConstant:28.0],
    ]];
    return card;
}

@implementation LGTopFadeView {
    CAGradientLayer *_gradientLayer;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    self.userInteractionEnabled = NO;
    self.backgroundColor = UIColor.clearColor;
    _gradientLayer = [CAGradientLayer layer];
    _gradientLayer.startPoint = CGPointMake(0.5, 0.0);
    _gradientLayer.endPoint = CGPointMake(0.5, 1.0);
    [self.layer addSublayer:_gradientLayer];
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    _gradientLayer.frame = self.bounds;
    UIColor *baseColor = [UIColor systemBackgroundColor];
    _gradientLayer.colors = @[
        (__bridge id)[baseColor colorWithAlphaComponent:0.98].CGColor,
        (__bridge id)[baseColor colorWithAlphaComponent:0.55].CGColor,
        (__bridge id)[baseColor colorWithAlphaComponent:0.0].CGColor
    ];
    _gradientLayer.locations = @[ @0.0, @0.45, @1.0 ];
}

@end

@implementation LGPSurfaceController {
    NSString *_screenTitle;
    NSString *_screenSubtitle;
    NSString *_screenIdentifier;
    UIColor *_accentColor;
    NSArray<NSDictionary *> *_items;
    UIScrollView *_scrollView;
    UIStackView *_contentStack;
    UIScrollView *_jumpScrollView;
    UIStackView *_jumpStack;
    NSMutableDictionary<NSString *, UIView *> *_sectionViews;
    UIView *_respringBar;
    UIView *_scrollTopButton;
    NSLayoutConstraint *_scrollTopBottomConstraint;
    BOOL _scrollTopButtonVisible;
}

- (instancetype)initWithTitle:(NSString *)title
                     subtitle:(NSString *)subtitle
                    tintColor:(UIColor *)tintColor
                   identifier:(NSString *)identifier
                        items:(NSArray<NSDictionary *> *)items {
    self = [super init];
    if (!self) return nil;
    _screenTitle = [title copy];
    _screenSubtitle = [subtitle copy];
    _screenIdentifier = [identifier copy];
    _accentColor = tintColor ?: [UIColor systemBlueColor];
    _items = [items copy];
    self.title = title;
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];
    [self configureCustomBackButton];
    self.navigationItem.rightBarButtonItem = LGMakeResetTextItem(self, @selector(handleResetPressed));
    [self applyNavigationBarStyle];
    LGInstallScrollableStack(self, 24.0, 12.0, &_scrollView, &_contentStack);
    _scrollView.delegate = self;
    LGInstallBottomRespringBar(self, &_respringBar);
    _scrollTopButton = [self makeScrollTopButton];
    [self.view addSubview:_scrollTopButton];
    UILayoutGuide *guide = self.view.safeAreaLayoutGuide;
    _scrollTopBottomConstraint = [_scrollTopButton.bottomAnchor constraintEqualToAnchor:guide.bottomAnchor constant:-12.0];
    [NSLayoutConstraint activateConstraints:@[
        [_scrollTopButton.trailingAnchor constraintEqualToAnchor:guide.trailingAnchor constant:-16.0],
        _scrollTopBottomConstraint,
    ]];

    [self reloadVisibleSettings];
    LGObservePrefsNotifications(self);
    [self updateRespringBarAnimated:NO];
    _scrollTopButtonVisible = NO;
    [self updateScrollTopButtonAnimated:NO];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self applyNavigationBarStyle];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    if (_screenIdentifier.length) {
        LGSetLastSurfaceIdentifier(_screenIdentifier);
    }
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
}

- (void)configureCustomBackButton {
    self.navigationItem.hidesBackButton = YES;
    self.navigationItem.leftBarButtonItem = LGMakeCircularBackItem(self, @selector(handleBackPressed));
}

- (void)applyNavigationBarStyle {
    LGApplyNavigationBarAppearance(self.navigationItem);
}

- (void)handleBackPressed {
    LGClearLastSurfaceIdentifierIfMatching(_screenIdentifier);
    [self.navigationController popViewControllerAnimated:YES];
}

- (void)handleResetPressed {
    LGPresentResetConfirmation(self);
}

- (void)handleRespringPressed {
    LGSetRespringBarDismissed(YES);
    [self updateRespringBarAnimated:YES];
    LGPresentRespringConfirmation(self);
}

- (void)handleLaterPressed {
    LGSetRespringBarDismissed(YES);
    [self updateRespringBarAnimated:YES];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)handlePrefsUIRefresh:(NSNotification *)notification {
    (void)notification;
    if (!self.isViewLoaded) return;
    [self animateVisibleControlsToDefaults];
}

- (void)handleRespringStateChanged:(NSNotification *)notification {
    (void)notification;
    [self updateRespringBarAnimated:YES];
}

- (void)updateRespringBarAnimated:(BOOL)animated {
    BOOL shouldShow = LGNeedsRespring() && !LGRespringBarDismissed();
    if (!_respringBar) return;
    _scrollTopBottomConstraint.constant = shouldShow ? -108.0 : -12.0;
    if (shouldShow == !_respringBar.hidden) {
        if (animated && !_scrollTopButton.hidden) {
            [UIView animateWithDuration:0.22 animations:^{
                [self.view layoutIfNeeded];
            }];
        } else {
            [self.view layoutIfNeeded];
        }
        return;
    }
    if (shouldShow) {
        _respringBar.hidden = NO;
        if (animated) {
            [UIView animateWithDuration:0.22 animations:^{
                _respringBar.alpha = 1.0;
                _respringBar.transform = CGAffineTransformIdentity;
                [self.view layoutIfNeeded];
            }];
        } else {
            _respringBar.alpha = 1.0;
            _respringBar.transform = CGAffineTransformIdentity;
            [self.view layoutIfNeeded];
        }
    } else {
        void (^hideBlock)(void) = ^{
            _respringBar.alpha = 0.0;
            _respringBar.transform = CGAffineTransformMakeTranslation(0.0, 10.0);
            [self.view layoutIfNeeded];
        };
        void (^completion)(BOOL) = ^(BOOL finished) {
            (void)finished;
            _respringBar.hidden = YES;
        };
        if (animated) {
            [UIView animateWithDuration:0.18 animations:hideBlock completion:completion];
        } else {
            hideBlock();
            completion(YES);
        }
    }
}

- (UIView *)makeScrollTopButton {
    UIView *container = [[UIView alloc] initWithFrame:CGRectZero];
    container.translatesAutoresizingMaskIntoConstraints = NO;
    container.hidden = YES;
    container.alpha = 0.0;
    container.transform = CGAffineTransformMakeTranslation(0.0, 10.0);

    UIVisualEffectView *blurView =
        [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemChromeMaterial]];
    blurView.translatesAutoresizingMaskIntoConstraints = NO;
    blurView.layer.cornerRadius = 19.0;
    blurView.layer.cornerCurve = kCACornerCurveContinuous;
    blurView.layer.masksToBounds = YES;
    blurView.layer.borderWidth = 0.75;
    blurView.layer.borderColor = [[UIColor separatorColor] colorWithAlphaComponent:0.20].CGColor;
    [container addSubview:blurView];

    UIImageSymbolConfiguration *config =
        [UIImageSymbolConfiguration configurationWithPointSize:13.0 weight:UIImageSymbolWeightSemibold];
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    [button setTitle:LGLocalized(@"prefs.button.go_to_top") forState:UIControlStateNormal];
    [button setTitleColor:[UIColor labelColor] forState:UIControlStateNormal];
    button.titleLabel.font = [UIFont systemFontOfSize:14.0 weight:UIFontWeightSemibold];
    [button setImage:[UIImage systemImageNamed:@"chevron.up" withConfiguration:config] forState:UIControlStateNormal];
    button.tintColor = [UIColor labelColor];
    button.semanticContentAttribute = UISemanticContentAttributeForceRightToLeft;
    button.contentEdgeInsets = UIEdgeInsetsMake(0.0, 12.0, 0.0, 12.0);
    button.imageEdgeInsets = UIEdgeInsetsMake(0.0, 6.0, 0.0, -6.0);
    [button addTarget:self action:@selector(handleScrollTopPressed) forControlEvents:UIControlEventTouchUpInside];
    [blurView.contentView addSubview:button];

    [NSLayoutConstraint activateConstraints:@[
        [container.widthAnchor constraintEqualToConstant:116.0],
        [container.heightAnchor constraintEqualToConstant:38.0],
        [blurView.topAnchor constraintEqualToAnchor:container.topAnchor],
        [blurView.leadingAnchor constraintEqualToAnchor:container.leadingAnchor],
        [blurView.trailingAnchor constraintEqualToAnchor:container.trailingAnchor],
        [blurView.bottomAnchor constraintEqualToAnchor:container.bottomAnchor],
        [button.topAnchor constraintEqualToAnchor:blurView.contentView.topAnchor],
        [button.leadingAnchor constraintEqualToAnchor:blurView.contentView.leadingAnchor],
        [button.trailingAnchor constraintEqualToAnchor:blurView.contentView.trailingAnchor],
        [button.bottomAnchor constraintEqualToAnchor:blurView.contentView.bottomAnchor],
    ]];
    return container;
}

- (CGFloat)scrollTopRevealThreshold {
    UIView *targetSection = _sectionViews[LGLocalized(@"prefs.section.folder_icons.title")];
    if (!targetSection) {
        NSArray<NSDictionary *> *sections = [self sectionItems];
        NSString *fallbackTitle = sections.count > 1 ? sections[1][@"title"] : sections.firstObject[@"title"];
        if (fallbackTitle.length) {
            targetSection = _sectionViews[fallbackTitle];
        }
    }
    if (targetSection) {
        CGRect targetRect = [_contentStack convertRect:targetSection.frame toView:_scrollView];
        CGFloat topInset = _scrollView.adjustedContentInset.top;
        return MAX(120.0, CGRectGetMinY(targetRect) - topInset - 24.0);
    }
    return 220.0;
}

- (void)updateScrollTopButtonAnimated:(BOOL)animated {
    if (!_scrollTopButton || !_scrollView) return;
    BOOL shouldShow = _scrollView.contentOffset.y >= [self scrollTopRevealThreshold];
    if (shouldShow == _scrollTopButtonVisible) return;
    _scrollTopButtonVisible = shouldShow;
    if (shouldShow) {
        _scrollTopButton.hidden = NO;
        void (^showBlock)(void) = ^{
            _scrollTopButton.alpha = 1.0;
            _scrollTopButton.transform = CGAffineTransformIdentity;
            [self.view layoutIfNeeded];
        };
        if (animated) {
            _scrollTopButton.transform = CGAffineTransformMakeTranslation(0.0, 8.0);
            [UIView animateWithDuration:0.22
                                  delay:0.0
                                options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionCurveEaseOut
                             animations:showBlock
                             completion:nil];
        } else {
            showBlock();
        }
    } else {
        void (^hideBlock)(void) = ^{
            _scrollTopButton.alpha = 0.0;
            _scrollTopButton.transform = CGAffineTransformMakeTranslation(0.0, 8.0);
            [self.view layoutIfNeeded];
        };
        void (^completion)(BOOL) = ^(BOOL finished) {
            if (!_scrollTopButtonVisible) {
                _scrollTopButton.hidden = YES;
            }
        };
        if (animated) {
            [UIView animateWithDuration:0.20
                                  delay:0.0
                                options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionCurveEaseInOut
                             animations:hideBlock
                             completion:completion];
        } else {
            hideBlock();
            completion(YES);
        }
    }
}

- (void)handleScrollTopPressed {
    CGFloat topInset = _scrollView.adjustedContentInset.top;
    [_scrollView setContentOffset:CGPointMake(0.0, -topInset) animated:YES];
}

- (void)reloadVisibleSettings {
    _sectionViews = [NSMutableDictionary dictionary];
    for (UIView *subview in [_contentStack.arrangedSubviews copy]) {
        [_contentStack removeArrangedSubview:subview];
        [subview removeFromSuperview];
    }
    [_contentStack addArrangedSubview:[self heroCard]];
    [_contentStack addArrangedSubview:LGMakeSectionDivider()];
    UIView *jumpView = [self jumpToViewIfNeeded];
    if (jumpView) {
        [_contentStack addArrangedSubview:jumpView];
    }
    NSUInteger index = 0;
    while (index < _items.count) {
        NSDictionary *item = _items[index];
        NSString *type = item[@"type"];
        if ([type isEqualToString:@"section"]) {
            [_contentStack addArrangedSubview:[self sectionViewForItem:item]];
            NSMutableArray<NSDictionary *> *groupItems = [NSMutableArray array];
            index += 1;
            while (index < _items.count && ![_items[index][@"type"] isEqualToString:@"section"]) {
                [groupItems addObject:_items[index]];
                index += 1;
            }
            if (groupItems.count) {
                [self appendSurfaceGroupItems:groupItems];
            }
            continue;
        }

        NSMutableArray<NSDictionary *> *groupItems = [NSMutableArray array];
        while (index < _items.count && ![_items[index][@"type"] isEqualToString:@"section"]) {
            [groupItems addObject:_items[index]];
            index += 1;
        }
        if (groupItems.count) {
            [self appendSurfaceGroupItems:groupItems];
        }
    }
    [self updateScrollTopButtonAnimated:NO];
}

- (void)updatePanelsControlledByEnabledKey:(NSString *)enabledKey enabled:(BOOL)enabled animated:(BOOL)animated {
    if (!enabledKey.length) return;
    for (UIView *panel in _contentStack.arrangedSubviews) {
        NSString *controllerKey = objc_getAssociatedObject(panel, kLGControlledByEnabledKey);
        if (![controllerKey isEqualToString:enabledKey]) continue;
        panel.userInteractionEnabled = enabled;
        void (^changes)(void) = ^{
            panel.alpha = enabled ? 1.0 : 0.42;
        };
        if (animated) {
            [UIView animateWithDuration:0.18
                                  delay:0.0
                                options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction
                             animations:changes
                             completion:nil];
        } else {
            changes();
        }
    }
}

- (void)animateVisibleControlsToDefaults {
    for (UIView *card in _contentStack.arrangedSubviews) {
        for (UIView *subview in [self lg_allSubviewsOfView:card]) {
            if ([subview isKindOfClass:[UISwitch class]]) {
                UISwitch *toggle = (UISwitch *)subview;
                NSNumber *defaultValue = objc_getAssociatedObject(toggle, kLGDefaultValueKey);
                NSString *preferenceKey = objc_getAssociatedObject(toggle, kLGPreferenceKeyKey);
                if ([preferenceKey isEqualToString:@"Global.Enabled"]) {
                    continue;
                }
                if (defaultValue) {
                    BOOL enabled = [defaultValue boolValue];
                    [toggle setOn:enabled animated:YES];
                    if ([preferenceKey hasSuffix:@".Enabled"]) {
                        [self updatePanelsControlledByEnabledKey:preferenceKey enabled:enabled animated:YES];
                    }
                }
            } else if ([subview isKindOfClass:[UISlider class]]) {
                UISlider *slider = (UISlider *)subview;
                NSNumber *defaultValue = objc_getAssociatedObject(slider, kLGDefaultValueKey);
                UILabel *valueLabel = objc_getAssociatedObject(slider, kLGValueLabelKey);
                NSNumber *decimalsNumber = objc_getAssociatedObject(slider, kLGDecimalsKey);
                if (defaultValue) {
                    float targetValue = [defaultValue floatValue];
                    NSInteger decimals = decimalsNumber ? [decimalsNumber integerValue] : 0;
                    LGAnimateSliderToDefault(slider, targetValue, valueLabel, decimals);
                }
            }
        }
    }
}

- (NSArray<UIView *> *)lg_allSubviewsOfView:(UIView *)view {
    NSMutableArray<UIView *> *result = [NSMutableArray array];
    for (UIView *subview in view.subviews) {
        [result addObject:subview];
        [result addObjectsFromArray:[self lg_allSubviewsOfView:subview]];
    }
    return result;
}

- (UIView *)heroCard {
    UIView *card = [[UIView alloc] initWithFrame:CGRectZero];
    card.backgroundColor = UIColor.clearColor;

    UILabel *titleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    titleLabel.text = _screenTitle;
    titleLabel.font = [UIFont systemFontOfSize:30.0 weight:UIFontWeightBold];
    titleLabel.translatesAutoresizingMaskIntoConstraints = NO;

    UILabel *subtitleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    subtitleLabel.text = _screenSubtitle;
    subtitleLabel.numberOfLines = 0;
    subtitleLabel.textColor = [UIColor secondaryLabelColor];
    subtitleLabel.font = [UIFont systemFontOfSize:15.0 weight:UIFontWeightMedium];
    subtitleLabel.translatesAutoresizingMaskIntoConstraints = NO;

    UIView *accentBar = [[UIView alloc] initWithFrame:CGRectZero];
    accentBar.translatesAutoresizingMaskIntoConstraints = NO;
    accentBar.backgroundColor = [_accentColor colorWithAlphaComponent:0.9];
    accentBar.layer.cornerRadius = 2.0;

    [card addSubview:accentBar];
    [card addSubview:titleLabel];
    [card addSubview:subtitleLabel];
    [NSLayoutConstraint activateConstraints:@[
        [accentBar.topAnchor constraintEqualToAnchor:card.topAnchor constant:18.0],
        [accentBar.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:18.0],
        [accentBar.widthAnchor constraintEqualToConstant:36.0],
        [accentBar.heightAnchor constraintEqualToConstant:4.0],
        [titleLabel.topAnchor constraintEqualToAnchor:accentBar.bottomAnchor constant:14.0],
        [titleLabel.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:18.0],
        [titleLabel.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-18.0],
        [subtitleLabel.topAnchor constraintEqualToAnchor:titleLabel.bottomAnchor constant:8.0],
        [subtitleLabel.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:18.0],
        [subtitleLabel.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-18.0],
        [subtitleLabel.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-18.0],
    ]];
    return card;
}

- (NSArray<NSDictionary *> *)sectionItems {
    NSMutableArray<NSDictionary *> *sections = [NSMutableArray array];
    for (NSDictionary *item in _items) {
        if ([item[@"type"] isEqualToString:@"section"] && [item[@"title"] length]) {
            [sections addObject:item];
        }
    }
    return [sections copy];
}

- (UIView *)jumpToViewIfNeeded {
    NSArray<NSDictionary *> *sections = [self sectionItems];
    if (sections.count < 2) return nil;

    UIView *container = [[UIView alloc] initWithFrame:CGRectZero];
    container.backgroundColor = UIColor.clearColor;

    UILabel *titleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    titleLabel.text = LGLocalized(@"prefs.jump_to.title");
    titleLabel.font = [UIFont systemFontOfSize:13.0 weight:UIFontWeightSemibold];
    titleLabel.textColor = [UIColor secondaryLabelColor];

    _jumpScrollView = [[UIScrollView alloc] initWithFrame:CGRectZero];
    _jumpScrollView.translatesAutoresizingMaskIntoConstraints = NO;
    _jumpScrollView.showsHorizontalScrollIndicator = NO;
    _jumpScrollView.alwaysBounceHorizontal = YES;
    _jumpScrollView.backgroundColor = UIColor.clearColor;

    _jumpStack = [[UIStackView alloc] initWithFrame:CGRectZero];
    _jumpStack.translatesAutoresizingMaskIntoConstraints = NO;
    _jumpStack.axis = UILayoutConstraintAxisHorizontal;
    _jumpStack.spacing = 10.0;
    [_jumpScrollView addSubview:_jumpStack];

    [container addSubview:titleLabel];
    [container addSubview:_jumpScrollView];

    [NSLayoutConstraint activateConstraints:@[
        [titleLabel.topAnchor constraintEqualToAnchor:container.topAnchor],
        [titleLabel.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:2.0],
        [titleLabel.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-2.0],
        [_jumpScrollView.topAnchor constraintEqualToAnchor:titleLabel.bottomAnchor constant:10.0],
        [_jumpScrollView.leadingAnchor constraintEqualToAnchor:container.leadingAnchor],
        [_jumpScrollView.trailingAnchor constraintEqualToAnchor:container.trailingAnchor],
        [_jumpScrollView.bottomAnchor constraintEqualToAnchor:container.bottomAnchor],
        [_jumpScrollView.heightAnchor constraintEqualToConstant:38.0],
        [_jumpStack.topAnchor constraintEqualToAnchor:_jumpScrollView.contentLayoutGuide.topAnchor],
        [_jumpStack.leadingAnchor constraintEqualToAnchor:_jumpScrollView.contentLayoutGuide.leadingAnchor],
        [_jumpStack.trailingAnchor constraintEqualToAnchor:_jumpScrollView.contentLayoutGuide.trailingAnchor],
        [_jumpStack.bottomAnchor constraintEqualToAnchor:_jumpScrollView.contentLayoutGuide.bottomAnchor],
        [_jumpStack.heightAnchor constraintEqualToAnchor:_jumpScrollView.frameLayoutGuide.heightAnchor],
    ]];

    for (NSDictionary *section in sections) {
        NSString *title = section[@"title"];
        UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
        button.translatesAutoresizingMaskIntoConstraints = NO;
        [button setTitle:title forState:UIControlStateNormal];
        [button setTitleColor:_accentColor forState:UIControlStateNormal];
        button.titleLabel.font = [UIFont systemFontOfSize:14.0 weight:UIFontWeightSemibold];
        button.backgroundColor = [_accentColor colorWithAlphaComponent:(self.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark ? 0.16 : 0.10)];
        button.layer.cornerRadius = 19.0;
        button.layer.cornerCurve = kCACornerCurveContinuous;
        button.contentEdgeInsets = UIEdgeInsetsMake(0.0, 14.0, 0.0, 14.0);
        [button.heightAnchor constraintEqualToConstant:38.0].active = YES;
        [button addTarget:self action:@selector(handleJumpChipPressed:) forControlEvents:UIControlEventTouchUpInside];
        objc_setAssociatedObject(button, @selector(handleJumpChipPressed:), title, OBJC_ASSOCIATION_COPY_NONATOMIC);
        [_jumpStack addArrangedSubview:button];
    }

    return container;
}

- (void)handleJumpChipPressed:(UIButton *)sender {
    NSString *title = objc_getAssociatedObject(sender, _cmd);
    if (title.length) {
        [self jumpToSectionNamed:title];
    }
}

- (void)handleSliderValueLabelTapped:(UITapGestureRecognizer *)gesture {
    LGPresentSliderValuePrompt(self, (UILabel *)gesture.view);
}

- (void)handleSliderInfoPressed:(UIButton *)sender {
    NSString *controlTitle = objc_getAssociatedObject(sender, kLGControlTitleKey);
    NSString *subtitle = objc_getAssociatedObject(sender, kLGControlSubtitleKey);
    NSNumber *minNumber = objc_getAssociatedObject(sender, kLGMinValueKey);
    NSNumber *maxNumber = objc_getAssociatedObject(sender, kLGMaxValueKey);
    NSNumber *decimalsNumber = objc_getAssociatedObject(sender, kLGDecimalsKey);

    NSInteger decimals = decimalsNumber.integerValue;
    NSString *rangeText = (minNumber && maxNumber)
        ? [NSString stringWithFormat:LGLocalized(@"prefs.range_format"),
           LGFormatSliderValue(minNumber.doubleValue, decimals),
           LGFormatSliderValue(maxNumber.doubleValue, decimals)]
        : nil;

    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    if (subtitle.length) [parts addObject:subtitle];
    if (rangeText.length) [parts addObject:rangeText];
    NSString *message = parts.count ? [parts componentsJoinedByString:@"\n\n"] : nil;
    LGPresentInfoSheet(self, (controlTitle.length ? controlTitle : LGLocalized(@"prefs.info.title")), message);
}

- (void)jumpToSectionNamed:(NSString *)title {
    UIView *sectionView = _sectionViews[title];
    if (!sectionView || !_scrollView) return;
    CGRect targetRect = [_contentStack convertRect:sectionView.frame toView:_scrollView];
    CGFloat topInset = _scrollView.adjustedContentInset.top;
    CGFloat targetY = MAX(-topInset, CGRectGetMinY(targetRect) - 12.0);
    [_scrollView setContentOffset:CGPointMake(0.0, targetY) animated:YES];
}

- (void)scrollViewDidScroll:(UIScrollView *)scrollView {
    if (scrollView == _scrollView) {
        [self updateScrollTopButtonAnimated:YES];
    }
}

- (UIView *)sectionViewForItem:(NSDictionary *)item {
    UIView *sectionView = [[UIView alloc] initWithFrame:CGRectZero];
    sectionView.backgroundColor = UIColor.clearColor;
    NSString *sectionTitleText = item[@"title"];
    if (sectionTitleText.length) {
        _sectionViews[sectionTitleText] = sectionView;
    }

    UIStackView *sectionStack = [[UIStackView alloc] initWithFrame:CGRectZero];
    sectionStack.axis = UILayoutConstraintAxisVertical;
    sectionStack.spacing = 3.0;
    sectionStack.translatesAutoresizingMaskIntoConstraints = NO;

    UILabel *sectionTitle = [[UILabel alloc] initWithFrame:CGRectZero];
    sectionTitle.text = item[@"title"];
    sectionTitle.font = [UIFont systemFontOfSize:22.0 weight:UIFontWeightBold];

    UILabel *sectionSubtitle = [[UILabel alloc] initWithFrame:CGRectZero];
    sectionSubtitle.text = item[@"subtitle"];
    sectionSubtitle.numberOfLines = 0;
    sectionSubtitle.textColor = [UIColor secondaryLabelColor];
    sectionSubtitle.font = [UIFont systemFontOfSize:13.0 weight:UIFontWeightMedium];

    [sectionStack addArrangedSubview:sectionTitle];
    [sectionStack addArrangedSubview:sectionSubtitle];
    [sectionView addSubview:sectionStack];
    [NSLayoutConstraint activateConstraints:@[
        [sectionStack.topAnchor constraintEqualToAnchor:sectionView.topAnchor constant:4.0],
        [sectionStack.leadingAnchor constraintEqualToAnchor:sectionView.leadingAnchor constant:2.0],
        [sectionStack.trailingAnchor constraintEqualToAnchor:sectionView.trailingAnchor constant:-2.0],
        [sectionStack.bottomAnchor constraintEqualToAnchor:sectionView.bottomAnchor constant:-1.0],
    ]];
    return sectionView;
}

- (UILabel *)controlTitleLabelForItem:(NSDictionary *)item {
    UILabel *titleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    titleLabel.text = item[@"title"];
    titleLabel.font = [UIFont systemFontOfSize:17.0 weight:UIFontWeightSemibold];
    return titleLabel;
}

- (UILabel *)controlSubtitleLabelWithText:(NSString *)text {
    UILabel *subtitleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    subtitleLabel.text = text;
    subtitleLabel.numberOfLines = 0;
    subtitleLabel.textColor = [UIColor secondaryLabelColor];
    subtitleLabel.font = [UIFont systemFontOfSize:13.0 weight:UIFontWeightRegular];
    return subtitleLabel;
}

- (UIView *)controlHeaderRowWithTitleLabel:(UILabel *)titleLabel
                            accessoryViews:(NSArray<UIView *> *)accessoryViews
                                   spacing:(CGFloat)spacing {
    UIView *headerRow = [[UIView alloc] initWithFrame:CGRectZero];
    headerRow.translatesAutoresizingMaskIntoConstraints = NO;
    [headerRow addSubview:titleLabel];
    titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [titleLabel.leadingAnchor constraintEqualToAnchor:headerRow.leadingAnchor].active = YES;
    [titleLabel.topAnchor constraintEqualToAnchor:headerRow.topAnchor].active = YES;
    [titleLabel.bottomAnchor constraintEqualToAnchor:headerRow.bottomAnchor].active = YES;

    UIView *rightmostView = nil;
    for (UIView *accessoryView in accessoryViews) {
        [headerRow addSubview:accessoryView];
        accessoryView.translatesAutoresizingMaskIntoConstraints = NO;
        [accessoryView.centerYAnchor constraintEqualToAnchor:titleLabel.centerYAnchor].active = YES;
        if (!rightmostView) {
            [accessoryView.trailingAnchor constraintEqualToAnchor:headerRow.trailingAnchor].active = YES;
        } else {
            [accessoryView.trailingAnchor constraintEqualToAnchor:rightmostView.leadingAnchor constant:-spacing].active = YES;
        }
        rightmostView = accessoryView;
    }

    if (rightmostView) {
        [titleLabel.trailingAnchor constraintLessThanOrEqualToAnchor:rightmostView.leadingAnchor constant:-spacing].active = YES;
        [rightmostView.leadingAnchor constraintGreaterThanOrEqualToAnchor:titleLabel.trailingAnchor constant:spacing].active = YES;
    } else {
        [titleLabel.trailingAnchor constraintEqualToAnchor:headerRow.trailingAnchor].active = YES;
    }

    return headerRow;
}

- (UISwitch *)configuredToggleForItem:(NSDictionary *)item {
    UISwitch *toggle = [[LGPrefsSwitchClass() alloc] initWithFrame:CGRectZero];
    toggle.onTintColor = _accentColor;
    toggle.on = [LGReadPreference(item[@"key"], item[@"default"]) boolValue];
    objc_setAssociatedObject(toggle, kLGDefaultValueKey, item[@"default"], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(toggle, kLGPreferenceKeyKey, item[@"key"], OBJC_ASSOCIATION_COPY_NONATOMIC);
    [toggle addAction:[UIAction actionWithHandler:^(__kindof UIAction * _Nonnull action) {
        UISwitch *sender = (UISwitch *)action.sender;
        if ([item[@"key"] isEqualToString:@"SettingsControls.Enabled"]) {
            LGWritePreference(item[@"key"], @(sender.isOn));
            LGPresentReopenSettingsConfirmation(self);
        } else {
            LGWritePreferenceAndMaybeRequireRespring(item[@"key"], @(sender.isOn));
            [self handleRespringStateChanged:nil];
        }
        if ([item[@"key"] hasSuffix:@".Enabled"]) {
            [self updatePanelsControlledByEnabledKey:item[@"key"] enabled:sender.isOn animated:YES];
        }
    }] forControlEvents:UIControlEventValueChanged];
    return toggle;
}

- (UIButton *)sliderInfoButtonForItem:(NSDictionary *)item
                             subtitle:(NSString *)subtitle
                             minValue:(CGFloat)minValue
                             maxValue:(CGFloat)maxValue
                             decimals:(NSInteger)decimals {
    UIButton *infoButton = [UIButton buttonWithType:UIButtonTypeSystem];
    UIImageSymbolConfiguration *infoConfig =
        [UIImageSymbolConfiguration configurationWithPointSize:14.0 weight:UIImageSymbolWeightSemibold];
    [infoButton setImage:[UIImage systemImageNamed:@"info.circle" withConfiguration:infoConfig] forState:UIControlStateNormal];
    [infoButton setTintColor:[UIColor tertiaryLabelColor]];
    objc_setAssociatedObject(infoButton, kLGControlTitleKey, item[@"title"], OBJC_ASSOCIATION_COPY_NONATOMIC);
    objc_setAssociatedObject(infoButton, kLGControlSubtitleKey, subtitle, OBJC_ASSOCIATION_COPY_NONATOMIC);
    objc_setAssociatedObject(infoButton, kLGMinValueKey, @(minValue), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(infoButton, kLGMaxValueKey, @(maxValue), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(infoButton, kLGDecimalsKey, @(decimals), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [infoButton addTarget:self action:@selector(handleSliderInfoPressed:) forControlEvents:UIControlEventTouchUpInside];
    [infoButton.widthAnchor constraintEqualToConstant:18.0].active = YES;
    [infoButton.heightAnchor constraintEqualToConstant:18.0].active = YES;
    return infoButton;
}

- (UILabel *)sliderValueLabelForStoredValue:(NSNumber *)stored
                                   decimals:(NSInteger)decimals
                                       item:(NSDictionary *)item
                                   subtitle:(NSString *)subtitle
                                   minValue:(CGFloat)minValue
                                   maxValue:(CGFloat)maxValue
                                     slider:(UISlider *)slider {
    UILabel *valueLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    valueLabel.text = LGFormatSliderValue([stored doubleValue], decimals);
    valueLabel.font = [UIFont monospacedDigitSystemFontOfSize:15.0 weight:UIFontWeightSemibold];
    valueLabel.textColor = _accentColor;
    valueLabel.userInteractionEnabled = YES;
    objc_setAssociatedObject(slider, kLGDefaultValueKey, item[@"default"], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(slider, kLGValueLabelKey, valueLabel, OBJC_ASSOCIATION_ASSIGN);
    objc_setAssociatedObject(slider, kLGDecimalsKey, @(decimals), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(valueLabel, kLGSliderKey, slider, OBJC_ASSOCIATION_ASSIGN);
    objc_setAssociatedObject(valueLabel, kLGPreferenceKeyKey, item[@"key"], OBJC_ASSOCIATION_COPY_NONATOMIC);
    objc_setAssociatedObject(valueLabel, kLGMinValueKey, @(minValue), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(valueLabel, kLGMaxValueKey, @(maxValue), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(valueLabel, kLGDecimalsKey, @(decimals), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(valueLabel, kLGControlTitleKey, item[@"title"], OBJC_ASSOCIATION_COPY_NONATOMIC);
    objc_setAssociatedObject(valueLabel, kLGControlSubtitleKey, subtitle, OBJC_ASSOCIATION_COPY_NONATOMIC);
    [valueLabel addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleSliderValueLabelTapped:)]];
    return valueLabel;
}

- (UIView *)switchControlBodyForItem:(NSDictionary *)item titleLabel:(UILabel *)titleLabel {
    UIView *body = [[UIView alloc] initWithFrame:CGRectZero];
    UIStackView *stack = [[UIStackView alloc] initWithFrame:CGRectZero];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 9.0;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [body addSubview:stack];

    UIView *headerRow = [self controlHeaderRowWithTitleLabel:titleLabel
                                              accessoryViews:@[[self configuredToggleForItem:item]]
                                                     spacing:12.0];
    [stack addArrangedSubview:headerRow];
    [stack addArrangedSubview:[self controlSubtitleLabelWithText:item[@"subtitle"]]];
    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:body.topAnchor constant:13.0],
        [stack.leadingAnchor constraintEqualToAnchor:body.leadingAnchor constant:14.0],
        [stack.trailingAnchor constraintEqualToAnchor:body.trailingAnchor constant:-14.0],
        [stack.bottomAnchor constraintEqualToAnchor:body.bottomAnchor constant:-13.0],
    ]];
    return body;
}

- (UIView *)sliderControlBodyForItem:(NSDictionary *)item titleLabel:(UILabel *)titleLabel {
    UIView *body = [[UIView alloc] initWithFrame:CGRectZero];
    UIStackView *stack = [[UIStackView alloc] initWithFrame:CGRectZero];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 9.0;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [body addSubview:stack];

    NSNumber *stored = LGReadPreference(item[@"key"], item[@"default"]);
    CGFloat minValue = [item[@"min"] doubleValue];
    CGFloat maxValue = [item[@"max"] doubleValue];
    NSInteger decimals = [item[@"decimals"] integerValue];
    NSString *subtitle = item[@"subtitle"];

    UISlider *slider = [[LGPrefsSliderClass() alloc] initWithFrame:CGRectZero];
    slider.minimumValue = minValue;
    slider.maximumValue = maxValue;
    slider.value = [stored doubleValue];
    slider.minimumTrackTintColor = _accentColor;

    UILabel *valueLabel = [self sliderValueLabelForStoredValue:stored
                                                      decimals:decimals
                                                          item:item
                                                      subtitle:subtitle
                                                      minValue:minValue
                                                      maxValue:maxValue
                                                        slider:slider];
    UIButton *infoButton = [self sliderInfoButtonForItem:item
                                                subtitle:subtitle
                                                minValue:minValue
                                                maxValue:maxValue
                                                decimals:decimals];
    UIView *headerRow = [self controlHeaderRowWithTitleLabel:titleLabel
                                              accessoryViews:@[valueLabel, infoButton]
                                                     spacing:8.0];

    NSString *preferenceKey = item[@"key"];
    [slider addAction:[UIAction actionWithHandler:^(__kindof UIAction * _Nonnull action) {
        UISlider *sender = (UISlider *)action.sender;
        valueLabel.text = LGFormatSliderValue(sender.value, decimals);
    }] forControlEvents:UIControlEventValueChanged];
    UIControlEvents commitEvents = UIControlEventTouchUpInside | UIControlEventTouchUpOutside | UIControlEventTouchCancel;
    [slider addAction:[UIAction actionWithHandler:^(__kindof UIAction * _Nonnull action) {
        UISlider *sender = (UISlider *)action.sender;
        CGFloat value = sender.value;
        valueLabel.text = LGFormatSliderValue(value, decimals);
        LGWritePreference(preferenceKey, @(value));
    }] forControlEvents:commitEvents];

    [stack addArrangedSubview:headerRow];
    [stack addArrangedSubview:slider];
    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:body.topAnchor constant:13.0],
        [stack.leadingAnchor constraintEqualToAnchor:body.leadingAnchor constant:14.0],
        [stack.trailingAnchor constraintEqualToAnchor:body.trailingAnchor constant:-14.0],
        [stack.bottomAnchor constraintEqualToAnchor:body.bottomAnchor constant:-13.0],
    ]];
    return body;
}

- (UIView *)controlBodyForItem:(NSDictionary *)item {
    UILabel *titleLabel = [self controlTitleLabelForItem:item];
    if ([item[@"type"] isEqualToString:@"switch"]) {
        return [self switchControlBodyForItem:item titleLabel:titleLabel];
    }
    return [self sliderControlBodyForItem:item titleLabel:titleLabel];
}

- (UIView *)groupedPanelForItems:(NSArray<NSDictionary *> *)items {
    UIView *card = [[UIView alloc] initWithFrame:CGRectZero];
    card.backgroundColor = LGSubpageCardBackgroundColor();
    card.layer.cornerRadius = 24.0;
    card.layer.cornerCurve = kCACornerCurveContinuous;
    card.layer.masksToBounds = YES;

    UIStackView *stack = [[UIStackView alloc] initWithFrame:CGRectZero];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 0.0;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:stack];

    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:card.topAnchor],
        [stack.leadingAnchor constraintEqualToAnchor:card.leadingAnchor],
        [stack.trailingAnchor constraintEqualToAnchor:card.trailingAnchor],
        [stack.bottomAnchor constraintEqualToAnchor:card.bottomAnchor],
    ]];

    for (NSUInteger i = 0; i < items.count; i++) {
        [stack addArrangedSubview:[self controlBodyForItem:items[i]]];
        if (i + 1 < items.count) {
            UIView *dividerRow = [[UIView alloc] initWithFrame:CGRectZero];
            dividerRow.translatesAutoresizingMaskIntoConstraints = NO;
            UIView *divider = LGMakeSectionDivider();
            [dividerRow addSubview:divider];
            [NSLayoutConstraint activateConstraints:@[
                [divider.leadingAnchor constraintEqualToAnchor:dividerRow.leadingAnchor constant:14.0],
                [divider.trailingAnchor constraintEqualToAnchor:dividerRow.trailingAnchor constant:-14.0],
                [divider.centerYAnchor constraintEqualToAnchor:dividerRow.centerYAnchor],
            ]];
            [stack addArrangedSubview:dividerRow];
        }
    }

    return card;
}

- (void)appendSurfaceGroupItems:(NSArray<NSDictionary *> *)items {
    if (!items.count) return;
    NSUInteger startIndex = 0;
    NSDictionary *fpsItem = nil;
    NSDictionary *enabledItem = nil;

    if (startIndex < items.count) {
        NSDictionary *candidate = items[startIndex];
        NSString *type = candidate[@"type"];
        NSString *key = candidate[@"key"];
        if ([type isEqualToString:@"slider"] && [key hasSuffix:@".FPS"]) {
            fpsItem = candidate;
            startIndex += 1;
        }
    }

    if (startIndex < items.count) {
        NSDictionary *candidate = items[startIndex];
        NSString *key = candidate[@"key"];
        if ([candidate[@"type"] isEqualToString:@"switch"] && [key hasSuffix:@".Enabled"]) {
            enabledItem = candidate;
            startIndex += 1;
        }
    }

    if (fpsItem) {
        [_contentStack addArrangedSubview:[self groupedPanelForItems:@[fpsItem]]];
    }

    if (enabledItem) {
        [_contentStack addArrangedSubview:[self groupedPanelForItems:@[enabledItem]]];
    }

    if (startIndex >= items.count) return;

    UIView *panel = [self groupedPanelForItems:[items subarrayWithRange:NSMakeRange(startIndex, items.count - startIndex)]];
    BOOL enabled = enabledItem ? [LGReadPreference(enabledItem[@"key"], enabledItem[@"default"]) boolValue] : YES;
    if (enabledItem[@"key"]) {
        objc_setAssociatedObject(panel, kLGControlledByEnabledKey, enabledItem[@"key"], OBJC_ASSOCIATION_COPY_NONATOMIC);
    }
    panel.alpha = enabled ? 1.0 : 0.42;
    panel.userInteractionEnabled = enabled;
    [_contentStack addArrangedSubview:panel];
}

@end

@interface LGPRootListController ()
@property (nonatomic, strong) UIScrollView *lg_scrollView;
@property (nonatomic, strong) UIStackView *lg_stackView;
@property (nonatomic, strong) NSArray<UIButton *> *lg_menuButtons;
@property (nonatomic, strong) UIView *lg_respringBar;
@property (nonatomic, strong) UISwitch *lg_globalToggle;
@end

@implementation LGPRootListController

- (NSArray *)specifiers {
    return @[];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = LGPrefsAppName();
    self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];
    if ([self respondsToSelector:@selector(table)] && self.table) self.table.hidden = YES;
    self.navigationItem.rightBarButtonItem = LGMakeResetTextItem(self, @selector(handleResetPressed));
    [self applyNavigationBarStyle];
    LGInstallScrollableStack(self, 32.0, 14.0, &_lg_scrollView, &_lg_stackView);
    LGInstallBottomRespringBar(self, &_lg_respringBar);

    [self.lg_stackView addArrangedSubview:[self heroCard]];
    [self.lg_stackView addArrangedSubview:LGMakeSectionDivider()];
    UIView *mainSection = [self rootSectionViewWithTitle:LGLocalized(@"prefs.section.main.title")
                                                subtitle:LGLocalized(@"prefs.section.main.subtitle")];
    UIButton *homescreenButton = (UIButton *)[self navCardWithTitle:LGLocalized(@"prefs.surface.homescreen.title") subtitle:LGLocalized(@"prefs.surface.homescreen.subtitle") color:[UIColor systemBlueColor] symbolName:@"apps.iphone" action:@selector(openHomescreen)];
    UIButton *lockscreenButton = (UIButton *)[self navCardWithTitle:LGLocalized(@"prefs.surface.lockscreen.title") subtitle:LGLocalized(@"prefs.surface.lockscreen.subtitle") color:[UIColor systemRedColor] symbolName:@"lg.lockscreen.stacked" action:@selector(openLockscreen)];
    UIButton *appLibraryButton = (UIButton *)[self navCardWithTitle:LGLocalized(@"prefs.surface.app_library.title") subtitle:LGLocalized(@"prefs.surface.app_library.subtitle") color:[UIColor systemGreenColor] symbolName:@"square.grid.2x2.fill" action:@selector(openAppLibrary)];
    UIView *miscSection = [self rootSectionViewWithTitle:LGLocalized(@"prefs.section.misc.title")
                                                subtitle:LGLocalized(@"prefs.section.misc.subtitle")];
    UIButton *respringButton = (UIButton *)[self navCardWithTitle:LGLocalized(@"prefs.misc.respring.title") subtitle:LGLocalized(@"prefs.misc.respring.subtitle") color:[UIColor systemOrangeColor] symbolName:@"arrow.counterclockwise.circle.fill" action:@selector(handleRespringPressed)];
    UIButton *aboutButton = (UIButton *)[self navCardWithTitle:LGLocalized(@"prefs.misc.about.title") subtitle:LGLocalized(@"prefs.misc.about.subtitle") color:[UIColor systemGrayColor] symbolName:@"info.circle.fill" action:@selector(handleAboutPressed)];
    self.lg_menuButtons = @[homescreenButton, lockscreenButton, appLibraryButton];
    [self.lg_stackView addArrangedSubview:mainSection];
    [self.lg_stackView addArrangedSubview:[self globalToggleCard]];
    [self.lg_stackView addArrangedSubview:[self groupedRootNavPanelForButtons:self.lg_menuButtons]];
    [self.lg_stackView addArrangedSubview:miscSection];
    [self.lg_stackView addArrangedSubview:[self groupedRootNavPanelForButtons:@[respringButton, aboutButton]]];
    [self updateMenuAvailability];
    LGObservePrefsNotifications(self);
    [self updateRespringBarAnimated:NO];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self applyNavigationBarStyle];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [self.lg_globalToggle setOn:[self isGlobalEnabled] animated:NO];
    [self updateMenuAvailability];
    [self updateRespringBarAnimated:NO];
    NSString *surface = LGLastSurfaceIdentifier();
    if (self.navigationController.topViewController != self) return;
    if (!surface.length) return;

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.12 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (self.navigationController.topViewController != self) return;
        if ([surface isEqualToString:@"Homescreen"]) [self openHomescreen];
        else if ([surface isEqualToString:@"Lockscreen"]) [self openLockscreen];
        else if ([surface isEqualToString:@"AppLibrary"]) [self openAppLibrary];
    });
}

- (void)handleBackPressed {
    [self.navigationController popViewControllerAnimated:YES];
}

- (BOOL)isGlobalEnabled {
    return [LGReadPreference(@"Global.Enabled", @NO) boolValue];
}

- (void)handleSliderValueLabelTapped:(UITapGestureRecognizer *)gesture {
    LGPresentSliderValuePrompt(self, (UILabel *)gesture.view);
}

- (void)handleSliderInfoPressed:(UIButton *)sender {
    NSString *controlTitle = objc_getAssociatedObject(sender, kLGControlTitleKey);
    NSString *subtitle = objc_getAssociatedObject(sender, kLGControlSubtitleKey);
    NSNumber *minNumber = objc_getAssociatedObject(sender, kLGMinValueKey);
    NSNumber *maxNumber = objc_getAssociatedObject(sender, kLGMaxValueKey);
    NSNumber *decimalsNumber = objc_getAssociatedObject(sender, kLGDecimalsKey);

    NSInteger decimals = decimalsNumber.integerValue;
    NSString *rangeText = (minNumber && maxNumber)
        ? [NSString stringWithFormat:LGLocalized(@"prefs.range_format"),
           LGFormatSliderValue(minNumber.doubleValue, decimals),
           LGFormatSliderValue(maxNumber.doubleValue, decimals)]
        : nil;

    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    if (subtitle.length) [parts addObject:subtitle];
    if (rangeText.length) [parts addObject:rangeText];
    NSString *message = parts.count ? [parts componentsJoinedByString:@"\n\n"] : nil;

    LGPresentInfoSheet(self, (controlTitle.length ? controlTitle : LGLocalized(@"prefs.info.title")), message);
}

- (void)updateMenuAvailability {
    BOOL enabled = [self isGlobalEnabled];
    for (UIButton *button in self.lg_menuButtons) {
        button.alpha = enabled ? 1.0 : 0.42;
        button.userInteractionEnabled = enabled;
    }
}

- (void)handlePrefsUIRefresh:(NSNotification *)notification {
    (void)notification;
    if (!self.isViewLoaded) return;
    BOOL enabled = [self isGlobalEnabled];
    [self.lg_globalToggle setOn:enabled animated:YES];
    [self updateMenuAvailability];
    [self updateRespringBarAnimated:YES];
}

- (void)handleRespringStateChanged:(NSNotification *)notification {
    (void)notification;
    [self updateRespringBarAnimated:YES];
}

- (void)updateRespringBarAnimated:(BOOL)animated {
    BOOL shouldShow = LGNeedsRespring() && !LGRespringBarDismissed();
    if (!self.lg_respringBar) return;
    if (shouldShow == !self.lg_respringBar.hidden) return;
    if (shouldShow) {
        self.lg_respringBar.hidden = NO;
        if (animated) {
            [UIView animateWithDuration:0.22 animations:^{
                self.lg_respringBar.alpha = 1.0;
                self.lg_respringBar.transform = CGAffineTransformIdentity;
            }];
        } else {
            self.lg_respringBar.alpha = 1.0;
            self.lg_respringBar.transform = CGAffineTransformIdentity;
        }
    } else {
        void (^hideBlock)(void) = ^{
            self.lg_respringBar.alpha = 0.0;
            self.lg_respringBar.transform = CGAffineTransformMakeTranslation(0.0, 10.0);
        };
        void (^completion)(BOOL) = ^(BOOL finished) {
            (void)finished;
            self.lg_respringBar.hidden = YES;
        };
        if (animated) {
            [UIView animateWithDuration:0.18 animations:hideBlock completion:completion];
        } else {
            hideBlock();
            completion(YES);
        }
    }
}

- (UIView *)globalToggleCard {
    UIView *card = [[UIView alloc] initWithFrame:CGRectZero];
    card.backgroundColor = LGSubpageCardBackgroundColor();
    card.layer.cornerRadius = 24.0;
    card.layer.cornerCurve = kCACornerCurveContinuous;

    UIStackView *stack = [[UIStackView alloc] initWithFrame:CGRectZero];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 9.0;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:stack];

    UILabel *titleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    titleLabel.text = LGLocalized(@"prefs.control.enabled");
    titleLabel.font = [UIFont systemFontOfSize:17.0 weight:UIFontWeightSemibold];

    UILabel *subtitleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    subtitleLabel.text = LGLocalized(@"prefs.subtitle.global_enabled");
    subtitleLabel.numberOfLines = 0;
    subtitleLabel.textColor = [UIColor secondaryLabelColor];
    subtitleLabel.font = [UIFont systemFontOfSize:13.0 weight:UIFontWeightRegular];

    UISwitch *toggle = [[LGPrefsSwitchClass() alloc] initWithFrame:CGRectZero];
    toggle.onTintColor = [UIColor systemBlueColor];
    toggle.on = [self isGlobalEnabled];
    self.lg_globalToggle = toggle;
    [toggle addAction:[UIAction actionWithHandler:^(__kindof UIAction * _Nonnull action) {
        UISwitch *sender = (UISwitch *)action.sender;
        LGWritePreferenceAndMaybeRequireRespring(@"Global.Enabled", @(sender.isOn));
        [self updateMenuAvailability];
        [self updateRespringBarAnimated:YES];
    }] forControlEvents:UIControlEventValueChanged];

    UIView *headerRow = [[UIView alloc] initWithFrame:CGRectZero];
    headerRow.translatesAutoresizingMaskIntoConstraints = NO;
    [headerRow addSubview:titleLabel];
    [headerRow addSubview:toggle];
    titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    toggle.translatesAutoresizingMaskIntoConstraints = NO;
    [NSLayoutConstraint activateConstraints:@[
        [titleLabel.leadingAnchor constraintEqualToAnchor:headerRow.leadingAnchor],
        [titleLabel.topAnchor constraintEqualToAnchor:headerRow.topAnchor],
        [titleLabel.bottomAnchor constraintEqualToAnchor:headerRow.bottomAnchor],
        [titleLabel.trailingAnchor constraintLessThanOrEqualToAnchor:toggle.leadingAnchor constant:-12.0],
        [toggle.trailingAnchor constraintEqualToAnchor:headerRow.trailingAnchor],
        [toggle.centerYAnchor constraintEqualToAnchor:titleLabel.centerYAnchor],
        [toggle.leadingAnchor constraintGreaterThanOrEqualToAnchor:titleLabel.trailingAnchor constant:12.0]
    ]];
    [stack addArrangedSubview:headerRow];
    [stack addArrangedSubview:subtitleLabel];

    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:card.topAnchor constant:13.0],
        [stack.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:14.0],
        [stack.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-14.0],
        [stack.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-13.0],
    ]];
    return card;
}

- (void)applyNavigationBarStyle {
    LGApplyNavigationBarAppearance(self.navigationItem);
}

- (UIView *)heroCard {
    UIView *card = [[UIView alloc] initWithFrame:CGRectZero];
    card.backgroundColor = UIColor.clearColor;

    UILabel *eyebrow = [[UILabel alloc] initWithFrame:CGRectZero];
    eyebrow.text = LGLocalized(@"prefs.hero.eyebrow");
    eyebrow.font = [UIFont systemFontOfSize:13.0 weight:UIFontWeightSemibold];
    eyebrow.textColor = [UIColor secondaryLabelColor];
    eyebrow.translatesAutoresizingMaskIntoConstraints = NO;

    UILabel *titleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    titleLabel.text = LGPrefsAppName();
    titleLabel.font = [UIFont systemFontOfSize:34.0 weight:UIFontWeightBlack];
    titleLabel.translatesAutoresizingMaskIntoConstraints = NO;

    UILabel *subtitleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    subtitleLabel.text = LGLocalized(@"prefs.hero.subtitle");
    subtitleLabel.numberOfLines = 0;
    subtitleLabel.textColor = [UIColor secondaryLabelColor];
    subtitleLabel.font = [UIFont systemFontOfSize:15.0 weight:UIFontWeightMedium];
    subtitleLabel.translatesAutoresizingMaskIntoConstraints = NO;

    [card addSubview:eyebrow];
    [card addSubview:titleLabel];
    [card addSubview:subtitleLabel];
    [NSLayoutConstraint activateConstraints:@[
        [eyebrow.topAnchor constraintEqualToAnchor:card.topAnchor constant:22.0],
        [eyebrow.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:20.0],
        [eyebrow.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-20.0],
        [titleLabel.topAnchor constraintEqualToAnchor:eyebrow.bottomAnchor constant:10.0],
        [titleLabel.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:20.0],
        [titleLabel.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-20.0],
        [subtitleLabel.topAnchor constraintEqualToAnchor:titleLabel.bottomAnchor constant:12.0],
        [subtitleLabel.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:20.0],
        [subtitleLabel.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-20.0],
        [subtitleLabel.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-22.0],
    ]];
    return card;
}

- (UIView *)rootSectionViewWithTitle:(NSString *)title subtitle:(NSString *)subtitle {
    UIView *sectionView = [[UIView alloc] initWithFrame:CGRectZero];
    sectionView.backgroundColor = UIColor.clearColor;

    UIStackView *sectionStack = [[UIStackView alloc] initWithFrame:CGRectZero];
    sectionStack.axis = UILayoutConstraintAxisVertical;
    sectionStack.spacing = 3.0;
    sectionStack.translatesAutoresizingMaskIntoConstraints = NO;

    UILabel *titleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    titleLabel.text = title;
    titleLabel.font = [UIFont systemFontOfSize:22.0 weight:UIFontWeightBold];

    UILabel *subtitleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    subtitleLabel.text = subtitle;
    subtitleLabel.numberOfLines = 0;
    subtitleLabel.textColor = [UIColor secondaryLabelColor];
    subtitleLabel.font = [UIFont systemFontOfSize:13.0 weight:UIFontWeightMedium];

    [sectionStack addArrangedSubview:titleLabel];
    [sectionStack addArrangedSubview:subtitleLabel];
    [sectionView addSubview:sectionStack];
    [NSLayoutConstraint activateConstraints:@[
        [sectionStack.topAnchor constraintEqualToAnchor:sectionView.topAnchor constant:4.0],
        [sectionStack.leadingAnchor constraintEqualToAnchor:sectionView.leadingAnchor constant:2.0],
        [sectionStack.trailingAnchor constraintEqualToAnchor:sectionView.trailingAnchor constant:-2.0],
        [sectionStack.bottomAnchor constraintEqualToAnchor:sectionView.bottomAnchor constant:-1.0],
    ]];
    return sectionView;
}

- (UIView *)groupedRootNavPanelForButtons:(NSArray<UIButton *> *)buttons {
    UIView *card = [[UIView alloc] initWithFrame:CGRectZero];
    card.backgroundColor = LGSubpageCardBackgroundColor();
    card.layer.cornerRadius = 24.0;
    card.layer.cornerCurve = kCACornerCurveContinuous;
    card.layer.masksToBounds = YES;

    UIStackView *stack = [[UIStackView alloc] initWithFrame:CGRectZero];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 0.0;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:stack];

    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:card.topAnchor],
        [stack.leadingAnchor constraintEqualToAnchor:card.leadingAnchor],
        [stack.trailingAnchor constraintEqualToAnchor:card.trailingAnchor],
        [stack.bottomAnchor constraintEqualToAnchor:card.bottomAnchor],
    ]];

    for (NSUInteger i = 0; i < buttons.count; i++) {
        UIButton *button = buttons[i];
        button.backgroundColor = UIColor.clearColor;
        button.layer.cornerRadius = 0.0;
        [stack addArrangedSubview:button];
        if (i + 1 < buttons.count) {
            UIView *dividerRow = [[UIView alloc] initWithFrame:CGRectZero];
            dividerRow.translatesAutoresizingMaskIntoConstraints = NO;
            UIView *divider = LGMakeSectionDivider();
            [dividerRow addSubview:divider];
            [NSLayoutConstraint activateConstraints:@[
                [divider.leadingAnchor constraintEqualToAnchor:dividerRow.leadingAnchor constant:14.0],
                [divider.trailingAnchor constraintEqualToAnchor:dividerRow.trailingAnchor constant:-14.0],
                [divider.centerYAnchor constraintEqualToAnchor:dividerRow.centerYAnchor],
            ]];
            [stack addArrangedSubview:dividerRow];
        }
    }

    return card;
}

- (UIView *)navCardWithTitle:(NSString *)title subtitle:(NSString *)subtitle color:(UIColor *)color symbolName:(NSString *)symbolName action:(SEL)action {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.backgroundColor = LGSubpageCardBackgroundColor();
    button.layer.cornerRadius = 24.0;
    button.layer.cornerCurve = kCACornerCurveContinuous;
    button.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
    if (action) {
        [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    }

    UIView *chip = [[UIView alloc] initWithFrame:CGRectZero];
    chip.translatesAutoresizingMaskIntoConstraints = NO;
    chip.backgroundColor = [color colorWithAlphaComponent:0.14];
    chip.layer.cornerRadius = 18.0;
    chip.layer.cornerCurve = kCACornerCurveContinuous;

    UIView *glyph = LGMakeNavCardGlyphView(symbolName, color);
    [chip addSubview:glyph];

    UILabel *titleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    titleLabel.text = title;
    titleLabel.font = [UIFont systemFontOfSize:18.0 weight:UIFontWeightSemibold];
    titleLabel.translatesAutoresizingMaskIntoConstraints = NO;

    UILabel *subtitleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    subtitleLabel.text = subtitle;
    subtitleLabel.numberOfLines = 0;
    subtitleLabel.textColor = [UIColor secondaryLabelColor];
    subtitleLabel.font = [UIFont systemFontOfSize:13.0 weight:UIFontWeightRegular];
    subtitleLabel.translatesAutoresizingMaskIntoConstraints = NO;

    UIImageView *chevron = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"chevron.right"]];
    chevron.translatesAutoresizingMaskIntoConstraints = NO;
    chevron.tintColor = [UIColor tertiaryLabelColor];
    chevron.contentMode = UIViewContentModeScaleAspectFit;
    [chevron setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [chevron setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];

    [button addSubview:chip];
    [button addSubview:titleLabel];
    [button addSubview:subtitleLabel];
    [button addSubview:chevron];

    [NSLayoutConstraint activateConstraints:@[
        [button.heightAnchor constraintGreaterThanOrEqualToConstant:82.0],
        [chip.leadingAnchor constraintEqualToAnchor:button.leadingAnchor constant:14.0],
        [chip.centerYAnchor constraintEqualToAnchor:button.centerYAnchor],
        [chip.widthAnchor constraintEqualToConstant:34.0],
        [chip.heightAnchor constraintEqualToConstant:34.0],
        [glyph.centerXAnchor constraintEqualToAnchor:chip.centerXAnchor],
        [glyph.centerYAnchor constraintEqualToAnchor:chip.centerYAnchor],
        [titleLabel.topAnchor constraintEqualToAnchor:button.topAnchor constant:14.0],
        [titleLabel.leadingAnchor constraintEqualToAnchor:chip.trailingAnchor constant:12.0],
        [titleLabel.trailingAnchor constraintLessThanOrEqualToAnchor:chevron.leadingAnchor constant:-10.0],
        [subtitleLabel.topAnchor constraintEqualToAnchor:titleLabel.bottomAnchor constant:3.0],
        [subtitleLabel.leadingAnchor constraintEqualToAnchor:titleLabel.leadingAnchor],
        [subtitleLabel.trailingAnchor constraintLessThanOrEqualToAnchor:chevron.leadingAnchor constant:-10.0],
        [subtitleLabel.bottomAnchor constraintEqualToAnchor:button.bottomAnchor constant:-14.0],
        [chevron.widthAnchor constraintEqualToConstant:12.0],
        [chevron.heightAnchor constraintEqualToConstant:20.0],
        [chevron.trailingAnchor constraintEqualToAnchor:button.trailingAnchor constant:-14.0],
        [chevron.centerYAnchor constraintEqualToAnchor:button.centerYAnchor],
    ]];
    return button;
}

- (void)pushSurfaceTitle:(NSString *)title subtitle:(NSString *)subtitle color:(UIColor *)color items:(NSArray<NSDictionary *> *)items {
    LGPSurfaceController *controller = [[LGPSurfaceController alloc] initWithTitle:title
                                                                          subtitle:subtitle
                                                                         tintColor:color
                                                                        identifier:title
                                                                             items:items];
    [self.navigationController pushViewController:controller animated:YES];
}

- (void)openHomescreen { [self pushSurfaceTitle:LGLocalized(@"prefs.surface.homescreen.title") subtitle:LGLocalized(@"prefs.surface.homescreen.subtitle") color:[UIColor systemBlueColor] items:LGHomescreenItems()]; }
- (void)openLockscreen { [self pushSurfaceTitle:LGLocalized(@"prefs.surface.lockscreen.title") subtitle:LGLocalized(@"prefs.surface.lockscreen.subtitle") color:[UIColor systemRedColor] items:LGLockscreenItems()]; }
- (void)openAppLibrary { [self pushSurfaceTitle:LGLocalized(@"prefs.surface.app_library.title") subtitle:LGLocalized(@"prefs.surface.app_library.subtitle") color:[UIColor systemGreenColor] items:LGAppLibraryItems()]; }
- (void)handleAboutPressed {
    [self pushSurfaceTitle:LGLocalized(@"prefs.misc.about.title")
                  subtitle:LGLocalized(@"prefs.misc.about.subtitle")
                     color:[UIColor systemGrayColor]
                     items:LGMoreOptionsItems()];
}

- (void)handleResetPressed {
    LGPresentResetConfirmation(self);
}

- (void)handleRespringPressed {
    LGSetRespringBarDismissed(YES);
    [self updateRespringBarAnimated:YES];
    LGPresentRespringConfirmation(self);
}

- (void)handleLaterPressed {
    LGSetRespringBarDismissed(YES);
    [self updateRespringBarAnimated:YES];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

@end
