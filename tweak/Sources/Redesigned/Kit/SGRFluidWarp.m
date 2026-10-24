#import <Metal/Metal.h>
#import <UIKit/UIKit.h>
#import "Core/SGCore.h"
#import "SGRFluidWarp.h"

// Compiled from source at run time: Theos has no step for .metal files, and the shader is small.
static NSString *const kShader = @
    "#include <metal_stdlib>\n"
    "using namespace metal;\n"
    "struct V { float4 position [[position]]; float2 uv; };\n"
    "struct U { float4 rect; float2 size; float time; float warp; };\n"
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
    "    constexpr sampler s(filter::linear, address::mirrored_repeat);\n"
    "    float shorter = min(u.size.x, u.size.y);\n"
    "    // From the visible rect's middle, its shorter side 1.\n"
    "    float2 c = ((in.uv - u.rect.xy) / u.rect.zw - 0.5) * u.size / shorter;\n"
    "    // A slow sway: two waves crossing.\n"
    "    c += 0.05 * u.warp * float2(sin(c.y * 3.1 + u.time * 0.23), sin(c.x * 2.7 - u.time * 0.19));\n"
    "    // Rings spreading from the middle, rounded squares like the cover, calm at the very middle.\n"
    "    float2 a = abs(c);\n"
    "    float d = sqrt(sqrt(a.x * a.x * a.x * a.x + a.y * a.y * a.y * a.y));\n"
    "    c += normalize(c + 1e-4) * sin(d * 24.0 - u.time * 0.9) * 0.022 * u.warp * smoothstep(0.05, 0.3, d);\n"
    "    // The cover fills the visible rect; past it (the bleed) it is mirrored.\n"
    "    float2 uv = c * shorter / max(u.size.x, u.size.y) + 0.5;\n"
    "    return float4(cover.sample(s, uv).rgb, 1);\n"
    "}\n";

typedef struct { float rect[4]; float size[2]; float time, warp; } Uniforms;
// The drawable's pixels per point of the layer.
static const CGFloat kResolution = 0.5;

static id<MTLDevice> sDevice;
static id<MTLCommandQueue> sQueue;
static id<MTLRenderPipelineState> sPipeline;
static NSMutableArray<dispatch_block_t> *sWaiting;

// Compiles once, off the main thread, and runs `ready` on the main thread once it has.
static void whenCompiled(dispatch_block_t ready) {
    if (sPipeline) return ready();
    BOOL first = !sWaiting;
    if (first) sWaiting = [NSMutableArray array];
    [sWaiting addObject:ready];
    if (!first) return;
    [sDevice newLibraryWithSource:kShader options:nil completionHandler:^(id<MTLLibrary> library, NSError *error) {
        if (!library) {
            SGLog(@"redesign kit: liquid shader did not compile: %@", error);
            return;
        }
        MTLRenderPipelineDescriptor *descriptor = [MTLRenderPipelineDescriptor new];
        descriptor.vertexFunction = [library newFunctionWithName:@"warpVertex"];
        descriptor.fragmentFunction = [library newFunctionWithName:@"warpFragment"];
        descriptor.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
        NSError *failure;
        id<MTLRenderPipelineState> pipeline = [sDevice newRenderPipelineStateWithDescriptor:descriptor error:&failure];
        if (!pipeline) {
            SGLog(@"redesign kit: liquid pipeline failed: %@", failure);
            return;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            sPipeline = pipeline;
            for (dispatch_block_t block in sWaiting) block();
            [sWaiting removeAllObjects];
        });
    }];
}

@implementation SGRFluidWarpLayer {
    id<MTLTexture> _texture;
    double _time;
    BOOL _stale;   // a frame was asked for while it could not be drawn
}

- (instancetype)init {
    if (!(self = [super init])) return nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        sDevice = MTLCreateSystemDefaultDevice();
        sQueue = [sDevice newCommandQueue];
    });
    self.device = sDevice;
    self.pixelFormat = MTLPixelFormatBGRA8Unorm;
    self.opaque = YES;
    self.actions = @{@"bounds": NSNull.null, @"position": NSNull.null, @"hidden": NSNull.null, @"contents": NSNull.null};
    __weak SGRFluidWarpLayer *weakSelf = self;
    whenCompiled(^{
        SGRFluidWarpLayer *layer = weakSelf;
        if (layer) [layer drawAt:layer->_time];
    });
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

- (void)setPicture:(CGImageRef)picture {
    size_t width = CGImageGetWidth(picture), height = CGImageGetHeight(picture);
    if (!width || !height) return;
    NSMutableData *pixels = [NSMutableData dataWithLength:width * height * 4];
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef bitmap = CGBitmapContextCreate(pixels.mutableBytes, width, height, 8, width * 4, space,
                                                kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(space);
    if (!bitmap) return;
    CGContextDrawImage(bitmap, CGRectMake(0, 0, width, height), picture);
    CGContextRelease(bitmap);
    MTLTextureDescriptor *descriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                                                         width:width height:height mipmapped:NO];
    descriptor.usage = MTLTextureUsageShaderRead;
    id<MTLTexture> texture = [sDevice newTextureWithDescriptor:descriptor];
    [texture replaceRegion:MTLRegionMake2D(0, 0, width, height) mipmapLevel:0 withBytes:pixels.bytes bytesPerRow:width * 4];
    _texture = texture;
    [self drawAt:_time];
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
    [self drawAt:_time];
}

- (void)setWarp:(float)warp {
    if (warp == _warp) return;
    _warp = warp;
    [self drawAt:_time];
}

- (void)drawAt:(double)time {
    _time = time;
    CGRect bounds = self.bounds;
    // The GPU is not Spotify's in the background: a frame sent then fails.
    _stale = UIApplication.sharedApplication.applicationState == UIApplicationStateBackground;
    if (_stale || !sPipeline || !_texture || self.hidden || self.drawableSize.width < 1 || bounds.size.width < 1) return;
    id<CAMetalDrawable> drawable = [self nextDrawable];
    if (!drawable) return;
    CGRect visible = CGRectIsEmpty(_visibleRect) ? bounds : _visibleRect;
    Uniforms u = {
        {(float)(visible.origin.x / bounds.size.width), (float)(visible.origin.y / bounds.size.height),
         (float)(visible.size.width / bounds.size.width), (float)(visible.size.height / bounds.size.height)},
        {(float)visible.size.width, (float)visible.size.height}, (float)time, _warp,
    };
    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = drawable.texture;
    pass.colorAttachments[0].loadAction = MTLLoadActionDontCare;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTLCommandBuffer> buffer = [sQueue commandBuffer];
    id<MTLRenderCommandEncoder> encoder = [buffer renderCommandEncoderWithDescriptor:pass];
    [encoder setRenderPipelineState:sPipeline];
    [encoder setFragmentBytes:&u length:sizeof u atIndex:0];
    [encoder setFragmentTexture:_texture atIndex:0];
    [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [encoder endEncoding];
    [buffer presentDrawable:drawable];
    [buffer commit];
}

@end
