// Liquid artwork's picture (SGRFluid.h): Fluid's blurred cover drawn by the GPU through a slow liquid warp, rings
// of ripples spreading from the middle of the screen with a gentle sway through them. One fragment shader over one
// triangle, at half the layer's size in points: the cover is blurred and 128 px, so more pixels would add nothing.
//
// It draws only when asked (-drawAt:), so it costs nothing between frames, and a layer left alone keeps the last
// frame it drew. The owner (SGRFluidLayer) runs the clock.
//
// Threading: main thread only; the shader compiles once, off it.
#import <QuartzCore/QuartzCore.h>

@interface SGRFluidWarpLayer : CAMetalLayer
// The blurred cover. Drawn again at once, at the last time drawn.
- (void)setPicture:(CGImageRef)picture;
// The part of the layer on screen, in its own coordinates: the cover fills it and the rings spread from its middle.
@property (nonatomic) CGRect visibleRect;
// How far the picture is pushed, 0 to 1 (Fluid's Warp setting).
@property (nonatomic) float warp;
// One frame at `time`, in seconds of warp at the standard speed.
- (void)drawAt:(double)time;
@end
