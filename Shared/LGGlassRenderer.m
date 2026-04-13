#import "LGGlassRenderer.h"
#import "LGMetalShaderSource.h"
#import <CoreVideo/CoreVideo.h>
#import <MetalPerformanceShaders/MetalPerformanceShaders.h>

typedef struct {
    vector_float2 resolution;
    vector_float2 screenResolution;
    vector_float2 cardOrigin;
    vector_float2 wallpaperResolution;
    float radius;
    float bezelWidth;
    float glassThickness;
    float refractionScale;
    float refractiveIndex;
    float specularOpacity;
    float specularAngle;
    float blur;
    vector_float2 wallpaperOrigin;
    float samplingOrientation;
} LGSharedUniforms;

static id<MTLDevice> sLGDevice;
static id<MTLRenderPipelineState> sLGPipeline;
static id<MTLCommandQueue> sLGCommandQueue;
static NSMapTable<UIImage *, NSMutableDictionary<NSNumber *, id> *> *sLGTextureCache;

static UIImage *LGSharedNormalizedImageForUpload(UIImage *image) {
    if (!image) return nil;
    if (image.imageOrientation == UIImageOrientationUp) return image;
    UIGraphicsBeginImageContextWithOptions(image.size, NO, image.scale);
    [image drawInRect:CGRectMake(0, 0, image.size.width, image.size.height)];
    UIImage *normalized = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return normalized ?: image;
}

static CGColorSpaceRef LGSharedRGBColorSpace(void) {
    static CGColorSpaceRef sColorSpace = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sColorSpace = CGColorSpaceCreateDeviceRGB();
    });
    return sColorSpace;
}

@interface LGSharedTextureCacheEntry : NSObject
@property (nonatomic, strong) id<MTLTexture> bgTexture;
@property (nonatomic, strong) id bridge;
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, id> *blurVariants;
@end
@implementation LGSharedTextureCacheEntry @end

@interface LGSharedBlurVariant : NSObject
@property (nonatomic, strong) id<MTLTexture> texture;
@property (nonatomic, assign) float bakedBlurRadius;
@end
@implementation LGSharedBlurVariant @end

@interface LGSharedZeroCopyBridge : NSObject
@property (nonatomic, strong) id<MTLDevice> device;
@property (nonatomic, assign) CVMetalTextureCacheRef textureCache;
@property (nonatomic, assign) CVPixelBufferRef pixelBuffer;
@property (nonatomic, assign) CVMetalTextureRef cvTexture;
- (instancetype)initWithDevice:(id<MTLDevice>)device;
- (BOOL)setupBufferWithWidth:(size_t)width height:(size_t)height;
- (id<MTLTexture>)renderWithActions:(void (^)(CGContextRef context))actions;
@end

@implementation LGSharedZeroCopyBridge

- (instancetype)initWithDevice:(id<MTLDevice>)device {
    self = [super init];
    if (!self) return nil;
    _device = device;
    CVMetalTextureCacheRef cache = NULL;
    if (CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache) == kCVReturnSuccess) {
        _textureCache = cache;
    }
    return self;
}

- (void)dealloc {
    if (_cvTexture) CFRelease(_cvTexture);
    if (_pixelBuffer) CVPixelBufferRelease(_pixelBuffer);
    if (_textureCache) CFRelease(_textureCache);
}

- (BOOL)setupBufferWithWidth:(size_t)width height:(size_t)height {
    if (!_textureCache || !width || !height) return NO;
    if (_cvTexture) { CFRelease(_cvTexture); _cvTexture = NULL; }
    if (_pixelBuffer) { CVPixelBufferRelease(_pixelBuffer); _pixelBuffer = NULL; }
    NSDictionary *attrs = @{
        (__bridge NSString *)kCVPixelBufferMetalCompatibilityKey: @YES,
        (__bridge NSString *)kCVPixelBufferCGImageCompatibilityKey: @YES,
        (__bridge NSString *)kCVPixelBufferCGBitmapContextCompatibilityKey: @YES,
        (__bridge NSString *)kCVPixelBufferIOSurfacePropertiesKey: @{}
    };
    CVReturn status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                                          (__bridge CFDictionaryRef)attrs, &_pixelBuffer);
    if (status != kCVReturnSuccess || !_pixelBuffer) return NO;
    CVMetalTextureRef cvTexture = NULL;
    status = CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, _textureCache, _pixelBuffer, nil,
                                                       MTLPixelFormatBGRA8Unorm, width, height, 0, &cvTexture);
    if (status != kCVReturnSuccess || !cvTexture) return NO;
    _cvTexture = cvTexture;
    return YES;
}

- (id<MTLTexture>)renderWithActions:(void (^)(CGContextRef context))actions {
    if (!_pixelBuffer || !_textureCache || !_cvTexture) return nil;
    CVPixelBufferLockBaseAddress(_pixelBuffer, 0);
    void *data = CVPixelBufferGetBaseAddress(_pixelBuffer);
    size_t width = CVPixelBufferGetWidth(_pixelBuffer);
    size_t height = CVPixelBufferGetHeight(_pixelBuffer);
    size_t bytesPerRow = CVPixelBufferGetBytesPerRow(_pixelBuffer);
    CGContextRef context = CGBitmapContextCreate(data, width, height, 8, bytesPerRow, LGSharedRGBColorSpace(),
                                                 kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
    if (!context) {
        CVPixelBufferUnlockBaseAddress(_pixelBuffer, 0);
        return nil;
    }
    if (actions) actions(context);
    CGContextRelease(context);
    CVPixelBufferUnlockBaseAddress(_pixelBuffer, 0);
    CVMetalTextureCacheFlush(_textureCache, 0);
    return CVMetalTextureGetTexture(_cvTexture);
}

@end

static NSNumber *LGTextureScaleKey(CGFloat scale) {
    NSInteger milli = (NSInteger)lrint(scale * 1000.0);
    return @(MAX(milli, 1));
}

static NSNumber *LGBlurSettingKey(CGFloat blur) {
    NSInteger milli = (NSInteger)lrint(fmax(0.0, blur) * 1000.0);
    return @(MAX(milli, 0));
}

static LGSharedTextureCacheEntry *LGGetCacheForImage(UIImage *image, CGFloat scale) {
    NSDictionary *variants = [sLGTextureCache objectForKey:image];
    return variants[LGTextureScaleKey(scale)];
}

static void LGSetCacheForImage(UIImage *image, CGFloat scale, LGSharedTextureCacheEntry *entry) {
    NSMutableDictionary *variants = [sLGTextureCache objectForKey:image];
    if (!variants) {
        variants = [NSMutableDictionary dictionary];
        [sLGTextureCache setObject:variants forKey:image];
    }
    variants[LGTextureScaleKey(scale)] = entry;
}

void LGEnsureSharedGlassPipelinesReady(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sLGDevice = MTLCreateSystemDefaultDevice();
        if (!sLGDevice) return;
        NSError *error = nil;
        id<MTLLibrary> library = [sLGDevice newLibraryWithSource:LGGlassMetalSource()
                                                         options:[MTLCompileOptions new]
                                                           error:&error];
        if (!library) return;
        id<MTLFunction> vertex = [library newFunctionWithName:@"vertexShader"];
        id<MTLFunction> fragment = [library newFunctionWithName:@"fragmentShader"];
        MTLRenderPipelineDescriptor *descriptor = [MTLRenderPipelineDescriptor new];
        descriptor.vertexFunction = vertex;
        descriptor.fragmentFunction = fragment;
        descriptor.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
        descriptor.colorAttachments[0].blendingEnabled = YES;
        descriptor.colorAttachments[0].rgbBlendOperation = MTLBlendOperationAdd;
        descriptor.colorAttachments[0].alphaBlendOperation = MTLBlendOperationAdd;
        descriptor.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
        descriptor.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
        descriptor.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorOne;
        descriptor.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
        sLGPipeline = [sLGDevice newRenderPipelineStateWithDescriptor:descriptor error:&error];
        sLGCommandQueue = [sLGDevice newCommandQueue];
        sLGTextureCache = [NSMapTable weakToStrongObjectsMapTable];
    });
}

@implementation LGSharedGlassView {
    MTKView *_mtkView;
    id<MTLTexture> _bgTexture;
    id<MTLTexture> _blurredTexture;
    LGSharedTextureCacheEntry *_cacheEntry;
    CGPoint _sourceOriginPt;
    CGSize _sourceImagePixelSize;
    CGRect _cachedVisualRectPx;
    CGSize _cachedDrawableSizePx;
    float _cachedVisualScale;
    BOOL _hasCachedVisualMetrics;
    BOOL _drawScheduled;
    BOOL _needsBlurBake;
    float _lastBakedBlurRadius;
    CGFloat _effectiveTextureScale;
    CGSize _lastLayoutBounds;
    CFTimeInterval _lastDrawSubmissionTime;
}

- (instancetype)initWithFrame:(CGRect)frame sourceImage:(UIImage *)image sourceOrigin:(CGPoint)origin {
    LGEnsureSharedGlassPipelinesReady();
    self = [super initWithFrame:frame];
    if (!self || !sLGDevice) return self;
    _cornerRadius = CGRectGetHeight(frame) * 0.5;
    _bezelWidth = 10.0;
    _glassThickness = 18.0;
    _refractionScale = 1.15;
    _refractiveIndex = 1.05;
    _specularOpacity = 0.16;
    _blur = 0.0;
    _sourceScale = 1.0;
    _sourceOriginPt = origin;
    _needsBlurBake = YES;
    _lastBakedBlurRadius = -1;
    _effectiveTextureScale = -1;
    _lastDrawSubmissionTime = 0;
    _mtkView = [[MTKView alloc] initWithFrame:self.bounds device:sLGDevice];
    _mtkView.colorPixelFormat = MTLPixelFormatBGRA8Unorm;
    _mtkView.clearColor = MTLClearColorMake(0, 0, 0, 0);
    _mtkView.framebufferOnly = NO;
    _mtkView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _mtkView.paused = YES;
    _mtkView.enableSetNeedsDisplay = NO;
    _mtkView.opaque = NO;
    _mtkView.layer.opaque = NO;
    _mtkView.delegate = self;
    [self addSubview:_mtkView];
    self.clipsToBounds = YES;
    self.layer.cornerRadius = _cornerRadius;
    if (@available(iOS 13.0, *)) self.layer.cornerCurve = kCACornerCurveContinuous;
    _sourceImage = image;
    return self;
}

- (CGPoint)sourceOrigin { return _sourceOriginPt; }

- (void)setSourceOrigin:(CGPoint)origin {
    if (fabs(_sourceOriginPt.x - origin.x) < 0.001 && fabs(_sourceOriginPt.y - origin.y) < 0.001) return;
    _sourceOriginPt = origin;
    [self scheduleDraw];
}

- (void)setSourceImage:(UIImage *)image {
    if (_sourceImage == image) return;
    _sourceImage = image;
    [self reloadTexture];
}

- (void)setCornerRadius:(CGFloat)value {
    if (fabs(_cornerRadius - value) < 0.001) return;
    _cornerRadius = value;
    self.layer.cornerRadius = value;
    [self scheduleDraw];
}

- (void)setBezelWidth:(CGFloat)value { _bezelWidth = value; [self scheduleDraw]; }
- (void)setGlassThickness:(CGFloat)value { _glassThickness = value; [self scheduleDraw]; }
- (void)setRefractionScale:(CGFloat)value { _refractionScale = value; [self scheduleDraw]; }
- (void)setRefractiveIndex:(CGFloat)value { _refractiveIndex = value; [self scheduleDraw]; }
- (void)setSpecularOpacity:(CGFloat)value { _specularOpacity = value; [self scheduleDraw]; }
- (void)setBlur:(CGFloat)value { _blur = value; _needsBlurBake = YES; [self scheduleDraw]; }

- (void)setSourceScale:(CGFloat)scale {
    CGFloat clamped = fmax(0.1, fmin(scale, 1.0));
    if (fabs(_sourceScale - clamped) < 0.001) return;
    _sourceScale = clamped;
    _effectiveTextureScale = -1;
    [self reloadTexture];
}

- (void)setReleasesSourceAfterUpload:(BOOL)releasesSourceAfterUpload {
    _releasesSourceAfterUpload = releasesSourceAfterUpload;
    if (releasesSourceAfterUpload && (_bgTexture || _cacheEntry)) _sourceImage = nil;
}

- (void)updateOrigin {
    if (!_mtkView.superview) return;
    if (!_bgTexture && self.sourceImage) [self reloadTexture];
    if (self.hidden || self.alpha <= 0.01f || self.layer.opacity <= 0.01f) return;
    BOOL metricsChanged = [self refreshVisualMetrics];
    CGFloat scale = UIScreen.mainScreen.scale;
    CGRect screenBoundsPx = CGRectMake(0, 0, UIScreen.mainScreen.bounds.size.width * scale, UIScreen.mainScreen.bounds.size.height * scale);
    if (!CGRectIntersectsRect(_cachedVisualRectPx, screenBoundsPx)) return;
    if (!metricsChanged && !_needsBlurBake) return;
    [self scheduleDraw];
}

- (void)scheduleDraw {
    if (!_mtkView.superview || _drawScheduled) return;
    _drawScheduled = YES;
    CFTimeInterval now = CACurrentMediaTime();
    CFTimeInterval earliest = _lastDrawSubmissionTime + (1.0 / 60.0);
    CFTimeInterval delay = MAX(0.0, earliest - now);
    __weak typeof(self) weakSelf = self;
    dispatch_block_t block = ^{
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        self->_drawScheduled = NO;
        if (!self->_mtkView.superview) return;
        if (self.hidden || self.alpha <= 0.01f || self.layer.opacity <= 0.01f) return;
        self->_lastDrawSubmissionTime = CACurrentMediaTime();
        [self->_mtkView draw];
    };
    if (delay > 0.0) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), block);
    } else {
        dispatch_async(dispatch_get_main_queue(), block);
    }
}

- (BOOL)refreshVisualMetrics {
    CGFloat scale = UIScreen.mainScreen.scale;
    CGRect visualRect;
    BOOL useDirectScreenConversion = (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad &&
                                      self.window != nil);
    if (useDirectScreenConversion) {
        CGRect screenRect = self.window.windowScene
            ? [self convertRect:self.bounds toCoordinateSpace:UIScreen.mainScreen.coordinateSpace]
            : [self convertRect:self.bounds toView:nil];
        visualRect = CGRectMake(screenRect.origin.x * scale,
                                screenRect.origin.y * scale,
                                screenRect.size.width * scale,
                                screenRect.size.height * scale);
    } else if (self.window) {
        CALayer *pres = self.layer.presentationLayer ?: self.layer;
        CALayer *windowLayer = self.window.layer.presentationLayer ?: self.window.layer;
        CGRect windowScreenRect = self.window.windowScene
            ? [self.window convertRect:self.window.bounds toCoordinateSpace:UIScreen.mainScreen.coordinateSpace]
            : [self.window convertRect:self.window.bounds toView:nil];
        if (pres != windowLayer) {
            CGRect rect = pres.bounds;
            CALayer *current = pres;
            while (current && current != windowLayer) {
                CALayer *up = current.superlayer;
                if (!up) break;
                CALayer *upPres = up.presentationLayer ?: up;
                rect = [current convertRect:rect toLayer:upPres];
                current = upPres;
            }
            visualRect = CGRectMake((windowScreenRect.origin.x + rect.origin.x) * scale,
                                    (windowScreenRect.origin.y + rect.origin.y) * scale,
                                    rect.size.width * scale,
                                    rect.size.height * scale);
        } else {
            CGRect screenRect = self.window.windowScene
                ? [self convertRect:self.bounds toCoordinateSpace:UIScreen.mainScreen.coordinateSpace]
                : [self convertRect:self.bounds toView:nil];
            visualRect = CGRectMake(screenRect.origin.x * scale,
                                    screenRect.origin.y * scale,
                                    screenRect.size.width * scale,
                                    screenRect.size.height * scale);
        }
    } else {
        CALayer *pres = self.layer.presentationLayer ?: self.layer;
        CALayer *root = pres;
        while (root.superlayer) root = root.superlayer.presentationLayer ?: root.superlayer;
        if (root != pres) {
            CGRect rect = pres.bounds;
            CALayer *current = pres;
            while (current && current != root) {
                CALayer *up = current.superlayer;
                if (!up) break;
                CALayer *upPres = up.presentationLayer ?: up;
                rect = [current convertRect:rect toLayer:upPres];
                current = upPres;
            }
            visualRect = CGRectMake(rect.origin.x * scale, rect.origin.y * scale, rect.size.width * scale, rect.size.height * scale);
        } else {
            CGPoint origin = [self convertPoint:CGPointZero toView:nil];
            visualRect = CGRectMake(origin.x * scale, origin.y * scale, self.bounds.size.width * scale, self.bounds.size.height * scale);
        }
    }
    CGSize drawableSize = _mtkView.drawableSize;
    float drawableW = self.bounds.size.width * scale;
    float visualScale = drawableW > 0.0f ? (CGRectGetWidth(visualRect) / drawableW) : 1.0f;
    if (_hasCachedVisualMetrics &&
        fabs(CGRectGetMinX(_cachedVisualRectPx) - CGRectGetMinX(visualRect)) < 0.5f &&
        fabs(CGRectGetMinY(_cachedVisualRectPx) - CGRectGetMinY(visualRect)) < 0.5f &&
        fabs(CGRectGetWidth(_cachedVisualRectPx) - CGRectGetWidth(visualRect)) < 0.5f &&
        fabs(CGRectGetHeight(_cachedVisualRectPx) - CGRectGetHeight(visualRect)) < 0.5f &&
        fabs(_cachedDrawableSizePx.width - drawableSize.width) < 0.5f &&
        fabs(_cachedDrawableSizePx.height - drawableSize.height) < 0.5f &&
        fabs(_cachedVisualScale - visualScale) < 0.001f) {
        return NO;
    }
    _cachedVisualRectPx = visualRect;
    _cachedDrawableSizePx = drawableSize;
    _cachedVisualScale = visualScale;
    _hasCachedVisualMetrics = YES;
    return YES;
}

- (CGFloat)recommendedInternalTextureScaleForSourceWidth:(NSUInteger)width height:(NSUInteger)height {
    CGFloat userScale = fmax(0.1, fmin(_sourceScale, 1.0));
    CGFloat screenScale = UIScreen.mainScreen.scale;
    CGFloat viewMaxPx = MAX(self.bounds.size.width, self.bounds.size.height) * screenScale;
    CGFloat sourceMaxPx = MAX((CGFloat)width, (CGFloat)height);
    if (viewMaxPx <= 1.0 || sourceMaxPx <= 1.0) return userScale;
    CGFloat adaptiveScale = (viewMaxPx * 3.0) / sourceMaxPx;
    adaptiveScale = fmax(0.18, fmin(adaptiveScale, 1.0));
    return fmin(userScale, adaptiveScale);
}

- (void)reloadTexture {
    UIImage *image = LGSharedNormalizedImageForUpload(self.sourceImage);
    if (!image || !sLGDevice) return;
    NSUInteger srcW = (NSUInteger)lrint(image.size.width * image.scale);
    NSUInteger srcH = (NSUInteger)lrint(image.size.height * image.scale);
    CGFloat textureScale = [self recommendedInternalTextureScaleForSourceWidth:srcW height:srcH];
    _effectiveTextureScale = textureScale;
    _sourceImagePixelSize = CGSizeMake(srcW, srcH);
    NSUInteger width = MAX((NSUInteger)1, (NSUInteger)lrint(srcW * textureScale));
    NSUInteger height = MAX((NSUInteger)1, (NSUInteger)lrint(srcH * textureScale));
    LGSharedTextureCacheEntry *cached = LGGetCacheForImage(image, textureScale);
    if (cached) {
        _cacheEntry = cached;
        _bgTexture = cached.bgTexture;
        LGSharedBlurVariant *variant = cached.blurVariants[LGBlurSettingKey(_blur)];
        _blurredTexture = variant.texture;
        _needsBlurBake = (variant.texture == nil);
        _lastBakedBlurRadius = variant.texture ? variant.bakedBlurRadius : -1;
        if (_releasesSourceAfterUpload) _sourceImage = nil;
        return;
    }
    LGSharedZeroCopyBridge *bridge = [[LGSharedZeroCopyBridge alloc] initWithDevice:sLGDevice];
    if (![bridge setupBufferWithWidth:width height:height]) return;
    _bgTexture = [bridge renderWithActions:^(CGContextRef context) {
        CGContextClearRect(context, CGRectMake(0, 0, width, height));
        CGContextDrawImage(context, CGRectMake(0, 0, width, height), image.CGImage);
    }];
    if (!_bgTexture) return;
    MTLTextureDescriptor *descriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                           width:width
                                                                                          height:height
                                                                                       mipmapped:NO];
    descriptor.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
    _blurredTexture = nil;
    LGSharedTextureCacheEntry *entry = [LGSharedTextureCacheEntry new];
    entry.bgTexture = _bgTexture;
    entry.bridge = bridge;
    entry.blurVariants = [NSMutableDictionary dictionary];
    _cacheEntry = entry;
    LGSetCacheForImage(image, textureScale, entry);
    _needsBlurBake = YES;
    _lastBakedBlurRadius = -1;
    if (_releasesSourceAfterUpload) _sourceImage = nil;
}

- (void)runBlurPassWithRadius:(float)radius commandBuffer:(id<MTLCommandBuffer>)commandBuffer {
    if (!_bgTexture || !_blurredTexture) return;
    if (radius < 0.5f) {
        id<MTLBlitCommandEncoder> blit = [commandBuffer blitCommandEncoder];
        if (!blit) return;
        [blit copyFromTexture:_bgTexture sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0)
                   sourceSize:MTLSizeMake(_bgTexture.width, _bgTexture.height, 1)
                    toTexture:_blurredTexture destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0, 0, 0)];
        [blit endEncoding];
        return;
    }
    MPSImageGaussianBlur *blur = [[MPSImageGaussianBlur alloc] initWithDevice:sLGDevice sigma:MAX(radius * 0.5f, 0.1f)];
    blur.edgeMode = MPSImageEdgeModeClamp;
    [blur encodeToCommandBuffer:commandBuffer sourceTexture:_bgTexture destinationTexture:_blurredTexture];
}

- (void)ensureBlurTexture {
    if (_blurredTexture || !_bgTexture) return;
    MTLTextureDescriptor *descriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                           width:_bgTexture.width
                                                                                          height:_bgTexture.height
                                                                                       mipmapped:NO];
    descriptor.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
    _blurredTexture = [sLGDevice newTextureWithDescriptor:descriptor];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat scale = UIScreen.mainScreen.scale;
    CGSize boundsSize = self.bounds.size;
    CGSize drawableSize = CGSizeMake(MAX(1.0, floor(boundsSize.width * scale)), MAX(1.0, floor(boundsSize.height * scale)));
    if (!CGSizeEqualToSize(_mtkView.drawableSize, drawableSize)) {
        _mtkView.drawableSize = drawableSize;
        _hasCachedVisualMetrics = NO;
    }
    if (!CGSizeEqualToSize(_lastLayoutBounds, boundsSize)) {
        _lastLayoutBounds = boundsSize;
        [self scheduleDraw];
    }
}

- (void)mtkView:(MTKView *)view drawableSizeWillChange:(CGSize)size {
    _hasCachedVisualMetrics = NO;
}

- (void)drawInMTKView:(MTKView *)view {
    if (!_bgTexture && self.sourceImage) [self reloadTexture];
    if (_bgTexture && !_blurredTexture) [self ensureBlurTexture];
    if (!sLGPipeline || !_bgTexture || !_blurredTexture) return;
    [self refreshVisualMetrics];
    CGSize drawableSize = _cachedDrawableSizePx;
    if (drawableSize.width < 1 || drawableSize.height < 1) return;
    id<CAMetalDrawable> drawable = view.currentDrawable;
    MTLRenderPassDescriptor *passDescriptor = view.currentRenderPassDescriptor;
    if (!drawable || !passDescriptor) return;
    id<MTLCommandBuffer> commandBuffer = [sLGCommandQueue commandBuffer];
    if (!commandBuffer) return;
    CGFloat scale = UIScreen.mainScreen.scale;
    CGFloat screenW = UIScreen.mainScreen.bounds.size.width * scale;
    CGFloat screenH = UIScreen.mainScreen.bounds.size.height * scale;
    float visOriginX = CGRectGetMinX(_cachedVisualRectPx);
    float visOriginY = CGRectGetMinY(_cachedVisualRectPx);
    float visW = CGRectGetWidth(_cachedVisualRectPx);
    float visH = CGRectGetHeight(_cachedVisualRectPx);
    float visualScale = _cachedVisualScale;
    float imgW = (float)_bgTexture.width;
    float imgH = (float)_bgTexture.height;
    float fillScale = fmaxf((float)screenW / imgW, (float)screenH / imgH);
    float blurPx = (float)_blur * (float)scale / fillScale;
    if ((_needsBlurBake || blurPx != _lastBakedBlurRadius) && _cacheEntry) {
        LGSharedBlurVariant *variant = _cacheEntry.blurVariants[LGBlurSettingKey(_blur)];
        if (variant.texture) {
            _blurredTexture = variant.texture;
            _lastBakedBlurRadius = variant.bakedBlurRadius;
            _needsBlurBake = NO;
        }
    }
    if (_needsBlurBake || blurPx != _lastBakedBlurRadius) {
        [self ensureBlurTexture];
        [self runBlurPassWithRadius:blurPx commandBuffer:commandBuffer];
        _lastBakedBlurRadius = blurPx;
        _needsBlurBake = NO;
        if (_cacheEntry) {
            LGSharedBlurVariant *variant = [LGSharedBlurVariant new];
            variant.texture = _blurredTexture;
            variant.bakedBlurRadius = blurPx;
            _cacheEntry.blurVariants[LGBlurSettingKey(_blur)] = variant;
        }
    }
    id<MTLRenderCommandEncoder> encoder = [commandBuffer renderCommandEncoderWithDescriptor:passDescriptor];
    LGSharedUniforms uniforms = {
        .resolution = { visW, visH },
        .screenResolution = { (float)screenW, (float)screenH },
        .cardOrigin = { visOriginX, visOriginY },
        .wallpaperResolution = { (float)_sourceImagePixelSize.width, (float)_sourceImagePixelSize.height },
        .radius = (float)(_cornerRadius * scale * visualScale),
        .bezelWidth = (float)(_bezelWidth * scale * visualScale),
        .glassThickness = (float)_glassThickness,
        .refractionScale = (float)_refractionScale,
        .refractiveIndex = (float)_refractiveIndex,
        .specularOpacity = (float)_specularOpacity,
        .specularAngle = 2.2689280f,
        .blur = blurPx,
        .wallpaperOrigin = { (float)(_sourceOriginPt.x * scale), (float)(_sourceOriginPt.y * scale) },
        .samplingOrientation = 1.0f,
    };
    [encoder setRenderPipelineState:sLGPipeline];
    [encoder setVertexBytes:&uniforms length:sizeof(uniforms) atIndex:0];
    [encoder setFragmentBytes:&uniforms length:sizeof(uniforms) atIndex:0];
    [encoder setFragmentTexture:_blurredTexture atIndex:0];
    [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
    [encoder endEncoding];
    [commandBuffer presentDrawable:drawable];
    [commandBuffer commit];
}

@end
