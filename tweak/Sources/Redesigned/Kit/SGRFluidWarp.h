// Liquid artwork's picture (SGRFluid.h): the cover's edges echoed outward as rings of its own edge colors that
// wave slowly and fade into black, and under it a dark reflection in rippling bands. One fragment shader over one
// triangle, at half the layer's size in points: the cover is blurred and 256 px, so more pixels would add nothing.
// Spotify draws the cover itself over it; the shader only places the rings around where it sits (coverRect).
//
// It draws only when asked (-drawAt:) or when what it shows changes, so it costs nothing between frames, and a
// layer left alone keeps the last frame it drew. The owner (SGRFluidLayer) runs the clock.
//
// Threading: main thread only, but for SGRFluidWarpTexture; the shader compiles once, off it.
#import <QuartzCore/QuartzCore.h>
#import <Metal/Metal.h>

// Compiles the shader once and runs `done` on the main thread with whether the warp can draw: NO without Metal or
// when the shader fails, and the owner shows Fluid then.
void SGRFluidWarpPrepare(void (^done)(BOOL works));
// `picture` as the layer's texture, nil for none. Any thread, so the cover is made with its blur, off the main one.
id<MTLTexture> SGRFluidWarpTexture(CGImageRef picture);

// Make it only once SGRFluidWarpPrepare has said it works.
@interface SGRFluidWarpLayer : CAMetalLayer
// The blurred cover (SGRFluidWarpTexture). Drawn again at once, at the last time drawn.
@property (nonatomic) id<MTLTexture> picture;
// The part of the layer on screen, in its own coordinates; without a coverRect the cover is placed in it as the
// player places its own.
@property (nonatomic) CGRect visibleRect;
// Where Spotify draws the cover, in the layer's coordinates; empty for none.
@property (nonatomic) CGRect coverRect;
// How far the rings wave and drift, 0 to 1 (Fluid's Warp setting).
@property (nonatomic) float warp;
// Out of sight (the player closed): frames asked for are drawn once it is NO again.
@property (nonatomic) BOOL offscreen;
// One frame at `time`, in seconds of warp at the standard speed.
- (void)drawAt:(double)time;
@end
