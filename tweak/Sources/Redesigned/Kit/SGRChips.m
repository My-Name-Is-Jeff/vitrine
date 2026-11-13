#import "Core/SGCore.h"
#import "SGRChips.h"
#import "SGRGlass.h"
#import "SGRRestyle.h"

// How much of its colour a selected chip keeps: enough for the label (#121212 on it) to read, little enough for the
// glass under it to show as a tint.
static const CGFloat kSelectedTintAlpha = 0.62;

CGColorRef SGRSelectedChipPaint(CGColorRef paint) {
    if (!paint || CFGetTypeID(paint) != CGColorGetTypeID() || CGColorGetAlpha(paint) < 0.95) return paint;
    return (CGColorRef)CFAutorelease(CGColorCreateCopyWithAlpha(paint, kSelectedTintAlpha));
}

void SGRTintSelectedFill(UIView *fill) {
    CGColorRef paint = fill.layer.backgroundColor;
    if (!paint || CGColorGetAlpha(paint) < 0.95) return;
    fill.layer.backgroundColor = SGRSelectedChipPaint(paint);
}

void SGRGlassChip(UIView *chip, UIView *fill, BOOL selected, const void *key) {
    CGSize size = chip.bounds.size;
    if (size.width < 1 || size.height < 1) return;
    if (selected) SGRTintSelectedFill(fill);
    else if (fill.layer.backgroundColor) fill.layer.backgroundColor = NULL;
    SGRGlassCapsuleInside(chip, key, size, NO);
}
