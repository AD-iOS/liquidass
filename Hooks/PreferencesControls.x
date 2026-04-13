#import "../LiquidAssPrefs/LGPrefsLiquidSlider.h"
#import "../LiquidAssPrefs/LGPrefsLiquidSwitch.h"

static __thread void *sLGCurrentSliderSpecifier = NULL;
static NSString * const kLGPrefsDomain = @"dylv.liquidassprefs";

static BOOL LGIsPreferencesApp(void) {
    return [NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.apple.Preferences"];
}

static BOOL LGSettingsControlsEnabled(void) {
    CFPropertyListRef value = CFPreferencesCopyAppValue((__bridge CFStringRef)@"SettingsControls.Enabled",
                                                        (__bridge CFStringRef)kLGPrefsDomain);
    if (!value) return NO;
    BOOL enabled = CFGetTypeID(value) == CFBooleanGetTypeID() ? CFBooleanGetValue(value) : [(__bridge id)value boolValue];
    CFRelease(value);
    return enabled;
}

static id LGCellSpecifier(id cell) {
    if (!cell) return nil;
    SEL selector = NSSelectorFromString(@"specifier");
    if ([cell respondsToSelector:selector]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        id specifier = [cell performSelector:selector];
#pragma clang diagnostic pop
        if (specifier) return specifier;
    }
    @try {
        return [cell valueForKey:@"specifier"];
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static BOOL LGSpecifierBoolProperty(id specifier, NSString *key) {
    if (!specifier || !key.length) return NO;
    id value = nil;
    @try {
        value = [specifier propertyForKey:key];
    } @catch (__unused NSException *exception) {
        value = nil;
    }
    return value ? [value boolValue] : NO;
}

static BOOL LGShouldUseLiquidSliderForSpecifier(id specifier) {
    if (!specifier) return YES;
    if (LGSpecifierBoolProperty(specifier, @"isSegmented")) return NO;
    if (LGSpecifierBoolProperty(specifier, @"locksToSegment")) return NO;
    if (LGSpecifierBoolProperty(specifier, @"snapsToSegment")) return NO;
    return YES;
}

static BOOL LGShouldUseLiquidSliderForCell(id cell) {
    id specifier = (__bridge id)sLGCurrentSliderSpecifier ?: LGCellSpecifier(cell);
    return LGShouldUseLiquidSliderForSpecifier(specifier);
}

@interface LGPrefsLiquidSlider (PreferencesCompat)
- (void)setSegmented:(BOOL)segmented;
- (void)setLocksToSegment:(BOOL)locksToSegment;
- (void)setSnapsToSegment:(BOOL)snapsToSegment;
- (void)setSegmentCount:(NSUInteger)segmentCount;
- (void)setShowValue:(BOOL)showValue;
@end

@implementation LGPrefsLiquidSlider (PreferencesCompat)

- (void)setSegmented:(BOOL)segmented {
    (void)segmented;
}

- (void)setLocksToSegment:(BOOL)locksToSegment {
    (void)locksToSegment;
}

- (void)setSnapsToSegment:(BOOL)snapsToSegment {
    (void)snapsToSegment;
}

- (void)setSegmentCount:(NSUInteger)segmentCount {
    (void)segmentCount;
}

- (void)setShowValue:(BOOL)showValue {
    (void)showValue;
}

@end

%group LiquidAssPreferencesControls

%hook PSSwitchTableCell

- (id)newControl {
    return [[LGPrefsLiquidSwitch alloc] initWithFrame:CGRectZero];
}

%end

%hook PSSliderTableCell

- (id)initWithStyle:(long long)style reuseIdentifier:(id)identifier specifier:(id)specifier {
    void *previousSpecifier = sLGCurrentSliderSpecifier;
    sLGCurrentSliderSpecifier = (__bridge void *)specifier;
    id result = %orig;
    sLGCurrentSliderSpecifier = previousSpecifier;
    return result;
}

- (id)newControl {
    if (!LGShouldUseLiquidSliderForCell(self)) {
        return %orig;
    }
    return [[LGPrefsLiquidSlider alloc] initWithFrame:CGRectZero];
}

%end

%end

%ctor {
    if (!LGIsPreferencesApp()) return;
    if (!LGSettingsControlsEnabled()) return;
    %init(LiquidAssPreferencesControls);
}
