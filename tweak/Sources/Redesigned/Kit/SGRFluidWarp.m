#import <Metal/Metal.h>
#import <UIKit/UIKit.h>
#import "Core/SGCore.h"
#import "SGRFluidWarp.h"

// Compiled from source at run time: Theos has no step for .metal files, and the shader is small. Lengths are in
// the layer's points.
static NSString *const kShader = @
    "#include <metal_stdlib>\n"
    "using namespace metal;\n"
    "struct V { float4 position [[position]]; float2 uv; };\n"
    "struct U { float4 cover; float2 size; float time; float warp; };\n"
    "\n"
    "// The rings: how many, how wide, the light each keeps of the one inside it, and how far their edges wave.\n"
    "constant float kSteps = 6.0, kBandWidth = 20.0, kFade = 0.55, kWave = 8.0;\n"
    "// The cover's corner as a share of its side (12 of 354).\n"
    "constant float kCorner = 0.034;\n"
    "// The reflection under the cover: the height of a ripple band, its light, and the length it fades over.\n"
    "constant float kRipple = 14.0, kReflection = 0.6, kReflectionFade = 260.0;\n"
    "\n"
    "vertex V warpVertex(uint i [[vertex_id]]) {\n"
    "    float2 q = float2((i << 1) & 2, i & 2);\n"
    "    V v;\n"
    "    v.position = float4(q.x * 2 - 1, 1 - q.y * 2, 0, 1);\n"
    "    v.uv = q;\n"
    "    return v;\n"
    "}\n"
    "\n"
    "fragment float4 warpFragment(V in [[stage_in]], constant U &u [[buffer(0)]], texture2d<float> cover [[texture(0)]]) {\n"
    "    constexpr sampler s(filter::linear, address::clamp_to_edge);\n"
    "    float2 halfSize = u.cover.zw * 0.5;\n"
    "    float2 rel = in.uv * u.size - (u.cover.xy + halfSize);\n"
    "    float t = u.time;\n"
    "    // Distance from the cover's rounded rect, 0 on its edge.\n"
    "    float radius = kCorner * u.cover.z;\n"
    "    float2 q = abs(rel) - halfSize + radius;\n"
    "    float d = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - radius;\n"
    "    if (d <= 0) return float4(cover.sample(s, rel / u.cover.zw + 0.5).rgb, 1);\n"
    "    // The rings' edges wave slowly around the cover, calm where they leave it.\n"
    "    float angle = atan2(rel.y, rel.x);\n"
    "    float wave = sin(angle * 3 + t * 0.45) + 0.6 * sin(angle * 5 - t * 0.31 + d * 0.015);\n"
    "    float stepped = d + u.warp * kWave * wave * min(1.0, d / kBandWidth);\n"
    "    float band = floor(max(stepped, 0.0) / kBandWidth);\n"
    "    // Each ring the cover's own edge nearest it, a little inside, drifting along the edge.\n"
    "    float2 edge = clamp(rel, -halfSize, halfSize) / u.cover.zw * 0.9 + 0.5;\n"
    "    edge += 0.03 * u.warp * float2(sin(band * 1.7 + t * 0.3), cos(band * 1.3 - t * 0.25));\n"
    "    float light = band < kSteps ? pow(kFade, band + 1) : 0.0;\n"
    "    // Darker toward a ring's outer edge, so the rings read as steps.\n"
    "    light *= mix(1.0, 0.45, smoothstep(0.7, 1.0, fract(stepped / kBandWidth)));\n"
    "    float3 color = cover.sample(s, edge).rgb * light;\n"
    "    // Under the cover, its reflection in dark water: mirrored, in horizontal bands that sway.\n"
    "    float below = rel.y - halfSize.y;\n"
    "    if (below > 0) {\n"
    "        float row = floor(below / kRipple);\n"
    "        float2 mirrored = float2(rel.x / u.cover.z + 0.5 + 0.02 * u.warp * sin(row * 0.9 + t * 0.6),\n"
    "                                 1.0 - below / u.cover.w * 1.2);\n"
    "        float ripple = mix(1.0, 0.6, smoothstep(0.4, 1.0, fract(below / kRipple)));\n"
    "        float3 water = cover.sample(s, clamp(mirrored, 0.0, 1.0)).rgb * kReflection * exp(-below / kReflectionFade) * ripple;\n"
    "        float inside = 1.0 - smoothstep(halfSize.x - 24.0, halfSize.x + 12.0, abs(rel.x));\n"
    "        color = mix(color, water, inside * smoothstep(0.0, 6.0, below));\n"
    "    }\n"
    "    return float4(color, 1);\n"
    "}\n";

typedef struct { float cover[4]; float size[2]; float time, warp; } Uniforms;
// The drawable's pixels per point of the layer.
static const CGFloat kResolution = 0.5;
// Where the cover sits without one to follow (the Player page's card): a share of the width, its middle at a
// share of the visible rect's height, as the player has it.
static const CGFloat kDefaultSide = 0.88, kDefaultMiddle = 0.4;

static id<MTLDevice> sDevice;
static id<MTLCommandQueue> sQueue;
static id<MTLRenderPipelineState> sPipeline;
static NSMutableArray *sWaiting;
static BOOL sFailed;

static void makeDevice(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        sDevice = MTLCreateSystemDefaultDevice();
        sQueue = [sDevice newCommandQueue];
    });
}

static void finish(id<MTLRenderPipelineState> pipeline) {
    dispatch_async(dispatch_get_main_queue(), ^{
        sPipeline = pipeline;
        sFailed = !pipeline;
        for (void (^done)(BOOL) in sWaiting) done(pipeline != nil);
        [sWaiting removeAllObjects];
    });
}

void SGRFluidWarpPrepare(void (^done)(BOOL works)) {
    if (sPipeline || sFailed) return done(sPipeline != nil);
    BOOL first = !sWaiting;
    if (first) sWaiting = [NSMutableArray array];
    [sWaiting addObject:[done copy]];
    if (!first) return;
    makeDevice();
    if (!sDevice) {
        SGLog(@"redesign kit: liquid has no Metal device, Fluid instead");
        return finish(nil);
    }
    // Off the main thread: even the asynchronous call sets up the compiler there first, a 200-300 ms stall at launch.
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{ [sDevice newLibraryWithSource:kShader options:nil completionHandler:^(id<MTLLibrary> library, NSError *error) {
        if (!library) {
            SGLog(@"redesign kit: liquid shader did not compile, Fluid instead: %@", error);
            return finish(nil);
        }
        MTLRenderPipelineDescriptor *descriptor = [MTLRenderPipelineDescriptor new];
        descriptor.vertexFunction = [library newFunctionWithName:@"warpVertex"];
        descriptor.fragmentFunction = [library newFunctionWithName:@"warpFragment"];
        descriptor.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
        NSError *failure;
        id<MTLRenderPipelineState> pipeline = [sDevice newRenderPipelineStateWithDescriptor:descriptor error:&failure];
        if (!pipeline) SGLog(@"redesign kit: liquid pipeline failed, Fluid instead: %@", failure);
        finish(pipeline);
    }]; });
}

id<MTLTexture> SGRFluidWarpTexture(CGImageRef picture) {
    size_t width = CGImageGetWidth(picture), height = CGImageGetHeight(picture);
    if (!width || !height) return nil;
    makeDevice();
    NSMutableData *pixels = [NSMutableData dataWithLength:width * height * 4];
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef bitmap = CGBitmapContextCreate(pixels.mutableBytes, width, height, 8, width * 4, space,
                                                kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(space);
    if (!bitmap) return nil;
    CGContextDrawImage(bitmap, CGRectMake(0, 0, width, height), picture);
    CGContextRelease(bitmap);
    MTLTextureDescriptor *descriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                                                         width:width height:height mipmapped:NO];
    descriptor.usage = MTLTextureUsageShaderRead;
    id<MTLTexture> texture = [sDevice newTextureWithDescriptor:descriptor];
    [texture replaceRegion:MTLRegionMake2D(0, 0, width, height) mipmapLevel:0 withBytes:pixels.bytes bytesPerRow:width * 4];
    return texture;
}

@implementation SGRFluidWarpLayer {
    double _time;
    BOOL _stale;   // a frame was asked for while it could not be drawn
    BOOL _coverDrawAsked;
}

- (instancetype)init {
    if (!(self = [super init])) return nil;
    makeDevice();
    self.device = sDevice;
    self.pixelFormat = MTLPixelFormatBGRA8Unorm;
    self.opaque = YES;
    self.actions = @{@"bounds": NSNull.null, @"position": NSNull.null, @"hidden": NSNull.null, @"contents": NSNull.null};
    // A frame asked for while Spotify was in the background (a new cover) is drawn on its return.
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(becameActive)
        name:UIApplicationDidBecomeActiveNotification object:nil];
    return self;
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)becameActive {
    if (_stale) [self drawAt:_time];
}

- (void)setPicture:(id<MTLTexture>)picture {
    _picture = picture;
    [self drawAt:_time];
}

- (void)setOffscreen:(BOOL)offscreen {
    if (offscreen == _offscreen) return;
    _offscreen = offscreen;
    if (!offscreen && _stale) [self drawAt:_time];
}

- (void)layoutSublayers {
    [super layoutSublayers];
    CGSize size = self.bounds.size;
    CGSize drawable = CGSizeMake(ceil(size.width * kResolution), ceil(size.height * kResolution));
    if (CGSizeEqualToSize(drawable, self.drawableSize) || drawable.width < 1) return;
    self.drawableSize = drawable;
    [self drawAt:_time];
}

- (void)setVisibleRect:(CGRect)rect {
    if (CGRectEqualToRect(rect, _visibleRect)) return;
    _visibleRect = rect;
    if (CGRectIsEmpty(_coverRect)) [self drawAt:_time];
}

// Moved by less than a point it is drawn where it was: the rings sit under Spotify's cover's own edge anyway.
- (void)setCoverRect:(CGRect)rect {
    if (CGRectIsEmpty(rect) && CGRectIsEmpty(_coverRect)) return;
    if (fabs(rect.origin.x - _coverRect.origin.x) < 1 && fabs(rect.origin.y - _coverRect.origin.y) < 1
        && fabs(rect.size.width - _coverRect.size.width) < 1 && fabs(rect.size.height - _coverRect.size.height) < 1) return;
    _coverRect = rect;
    // The cover moves on every frame of a swipe or a scroll: one frame at most every thirtieth of a second, as the
    // link draws, and none while nothing else asks.
    if (_coverDrawAsked) return;
    _coverDrawAsked = YES;
    __weak SGRFluidWarpLayer *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(NSEC_PER_SEC / 30)), dispatch_get_main_queue(), ^{
        SGRFluidWarpLayer *layer = weakSelf;
        if (!layer) return;
        layer->_coverDrawAsked = NO;
        [layer drawAt:layer->_time];
    });
}

- (void)setWarp:(float)warp {
    if (warp == _warp) return;
    _warp = warp;
    [self drawAt:_time];
}

- (void)drawAt:(double)time {
    _time = time;
    CGRect bounds = self.bounds;
    // Nothing is drawn while no one sees it, and the GPU is not Spotify's in the background: a frame sent then fails.
    _stale = _offscreen || UIApplication.sharedApplication.applicationState == UIApplicationStateBackground;
    if (_stale || !sPipeline || !_picture || self.hidden || self.drawableSize.width < 1 || bounds.size.width < 1) return;
    id<CAMetalDrawable> drawable = [self nextDrawable];
    if (!drawable) return;
    CGRect cover = _coverRect;
    if (CGRectIsEmpty(cover)) {
        CGRect visible = CGRectIsEmpty(_visibleRect) ? bounds : _visibleRect;
        CGFloat side = visible.size.width * kDefaultSide;
        cover = CGRectMake(CGRectGetMidX(visible) - side / 2, CGRectGetMinY(visible) + visible.size.height * kDefaultMiddle - side / 2, side, side);
    }
    Uniforms u = {
        {(float)cover.origin.x, (float)cover.origin.y, (float)cover.size.width, (float)cover.size.height},
        {(float)bounds.size.width, (float)bounds.size.height}, (float)time, _warp,
    };
    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = drawable.texture;
    pass.colorAttachments[0].loadAction = MTLLoadActionDontCare;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTLCommandBuffer> buffer = [sQueue commandBuffer];
    id<MTLRenderCommandEncoder> encoder = [buffer renderCommandEncoderWithDescriptor:pass];
    [encoder setRenderPipelineState:sPipeline];
    [encoder setFragmentBytes:&u length:sizeof u atIndex:0];
    [encoder setFragmentTexture:_picture atIndex:0];
    [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [encoder endEncoding];
    [buffer presentDrawable:drawable];
    [buffer commit];
}

@end
