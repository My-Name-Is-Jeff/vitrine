// Player redesign: the player grows out of the now playing bar's card and the cover flies out of the
// card's artwork, the way the Music app opens its player, instead of Spotify's slide up and fade.
//
// Spotify 9.1.78 runs the open and the close through SPTBarOverlayPresentationTransition: it hides the
// real bar and tab bar, moves stand-ins, and sets -setProgress: (0 the bar, 1 the player, clamped) on
// every frame of its own display link, from a spring when tapped and from the finger when dragged
// (setProgress: at 0x109815464). There it sets the player's frame to the container's bounds moved down by
// the bar's bottom edge times (1 - progress), and the player's alpha, and moves and fades the bar's stand-in.
//
// The morph rides on that progress, after Spotify's own, so taps, drags and canceled drags follow:
//   the sheet   a rounded rect from the card's frame and radius to the screen's, filled with the
//               field's color, under the player, showing at once;
//   the player  masked to the sheet, its content scaled and moved so its top left is the sheet's
//               (sublayerTransform, and the frame's top moved to the sheet's; Spotify's gesture code
//               reads back only the frame's height), its own background color lifted off meanwhile
//               (a sublayerTransform does not move it), and faded in over the first part of the growth;
//   the bar     Spotify's stand-in riding the sheet's top edge, gone by a quarter of the way;
//   the tab bar Spotify's stand-in hidden, since the real one stays in view around the sheet
//               and the stand-in would be a second tab bar;
//   the cover   a copy flown from the card's artwork to the player's cover, moved within the sheet,
//               the player's own cover and shadow hidden meanwhile.
// All of it is taken down in -destroyTransitioningContext, which Spotify calls from -animationEnded:.
//
// Skipped on a regular width (Spotify's iPad branch), with Reduce Motion on, or while the bar has no
// card (hidden, not styled yet): Spotify's own transition then runs untouched.
#import "Core/SGCore.h"
#import "Redesigned/Kit/SGRKit.h"
#import "Redesigned/NowPlayingBar/NowPlayingBar.h"
#import "Player.h"

@interface SPTBarOverlayPresentationTransition : NSObject
- (id<UIViewControllerContextTransitioning>)transitioningContext;
- (UIView *)overlayView;
- (UIView *)barSnapshotView;
- (UIView *)tabBarSnapshotView;
- (CGRect)barFrame;
- (double)progress;
@end

static const CGFloat kScreenRadiusFallback = 55;

static CGFloat lerp(CGFloat a, CGFloat b, CGFloat t) {
    return a + (b - a) * t;
}

static CGRect lerpRect(CGRect a, CGRect b, CGFloat t) {
    return CGRectMake(lerp(a.origin.x, b.origin.x, t), lerp(a.origin.y, b.origin.y, t),
                      lerp(a.size.width, b.size.width, t), lerp(a.size.height, b.size.height, t));
}

// 0 until `from`, 1 from `to`, eased between.
static CGFloat ramp(CGFloat from, CGFloat to, CGFloat t) {
    CGFloat x = MIN(1, MAX(0, (t - from) / (to - from)));
    return x * x * (3 - 2 * x);
}

static CGFloat screenRadius(void) {
    static CGFloat radius;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        radius = kScreenRadiusFallback;
        @try {
            id value = [UIScreen.mainScreen valueForKey:@"_displayCornerRadius"];
            if ([value respondsToSelector:@selector(doubleValue)] && [value doubleValue] > 0) radius = [value doubleValue];
        } @catch (__unused NSException *e) {}
    });
    return radius;
}

@interface SGRPlayerMorph : NSObject
@property (nonatomic, readonly) CGFloat restY;
@property (nonatomic, readonly) CGRect card;
@property (nonatomic, readonly) BOOL masksStrip;
@property (nonatomic, readonly) BOOL lockstepped;
@end

static CABasicAnimation *animationForKeyPathPrefix(CALayer *layer, NSString *prefix) {
    CABasicAnimation *fallback = nil;
    for (NSString *key in layer.animationKeys) {
        CAAnimation *anim = [layer animationForKey:key];
        if (![anim isKindOfClass:CABasicAnimation.class]) continue;
        CABasicAnimation *basic = (CABasicAnimation *)anim;
        if ([basic.keyPath hasPrefix:prefix]) return basic;
        if (!fallback && [prefix isEqualToString:@"position"]) fallback = basic;
    }
    return fallback;
}

static void addLockstepAnimation(CALayer *layer, NSString *keyPath, CAPropertyAnimation *tpl, id fromVal, id toVal) {
    if (!layer || !tpl || !fromVal || !toVal || ![tpl isKindOfClass:CABasicAnimation.class]) return;
    CABasicAnimation *anim = [(CABasicAnimation *)tpl copy];
    anim.keyPath = keyPath;
    anim.additive = NO;
    anim.fromValue = fromVal;
    anim.toValue = toVal;
    anim.byValue = nil;
    anim.removedOnCompletion = NO;
    anim.fillMode = kCAFillModeBoth;
    [layer setValue:toVal forKeyPath:keyPath];
    [layer addAnimation:anim forKey:[@"sgr." stringByAppendingString:keyPath]];
}

@implementation SGRPlayerMorph {
    __weak UIView *_container, *_overlay, *_bar;
    UIView *_sheet;
    UIImageView *_cover;
    CALayer *_mask;
    // In a Jam (follow mode only): the mask on the stand-in or its picture, its strip part fading on the way open, and
    // a close's copy of the strip's glass, which fades by alpha.
    CALayer *_stripMask, *_stripPart;
    __weak UIView *_masked, *_stripPane;
    CGFloat _stripPaneAlpha;
    CGRect _card, _barArtwork, _barRest, _spotifyFrame;
    CGPoint _overlayRestOrigin;
    CGFloat _cardRadius, _spotifyAlpha;
    CGColorRef _overlayColor;
    BOOL _coverHidden;
    BOOL _tornDown;
    BOOL _follows;   // 9.1.90: Spotify animates the player's frame and alpha, which the morph then only reads
    BOOL _lockstepped;
}

- (BOOL)lockstepped {
    return _lockstepped;
}

// Where the player's top edge rests when it has become the bar: 9.1.90's CompactOverlayTransition slides it down only
// that far (y 727 of 874), not off the screen.
- (CGFloat)restY {
    return _overlayRestOrigin.y > 0 ? _overlayRestOrigin.y : CGRectGetMinY(_card);
}

// 9.1.90's CompactOverlayTransition animates the player itself, so the morph follows where it is drawn. Spotify also
// crossfades its bar stand-in with the player at each end, on the render server, so the bar is in its place the moment
// the card lands even when the main thread stalls; the stand-in is left to Spotify.
- (void)followFrom:(UIView *)source npbFrame:(CGRect)npbFrame {
    _follows = YES;
    if (!CGRectIsNull(npbFrame) && npbFrame.origin.y > 100) {
        _overlayRestOrigin = npbFrame.origin;
    } else {
        _overlayRestOrigin = CGPointMake(0, CGRectGetMinY(_card));
    }
    if (source && _container) {
        _barRest = [_container convertRect:source.bounds fromView:source];
    } else if (!CGRectIsNull(npbFrame)) {
        _barRest = npbFrame;
    }
    // Next turn, once every hook on the transition's start has run: a close's glass copies (BarTransition.x) exist by
    // then whichever hook runs first. At either end the strip sits in the stand-in at Spotify's own alpha, so the turn
    // without the mask shows nothing new.
    __weak SGRPlayerMorph *weak = self;
    __weak UIView *weakSource = source;
    dispatch_async(dispatch_get_main_queue(), ^{ [weak maskStripFrom:weakSource]; });
}

- (void)maskStripFrom:(UIView *)source {
    if (_tornDown || !source) return;
    UIView *bar = _bar;
    if (!bar) return;
    // Outside a Jam, punch out the mini-player's static artwork from the close stand-in's content image so it never
    // shows a second small cover behind the flying _cover.
    CGRect strip = SGRNowPlayingStripFrameIn(source);
    if (CGRectIsNull(strip)) {
        if (_cover && !CGRectIsNull(_barArtwork) && [bar isKindOfClass:UIImageView.class] && !((UIImageView *)bar).image && [bar.subviews.lastObject isKindOfClass:UIImageView.class]) {
            UIView *content = bar.subviews.lastObject;
            if (!content.layer.mask) {
                CGRect artInSource = [source convertRect:_barArtwork fromView:_container];
                CGSize from = source.bounds.size, to = content.bounds.size;
                CGFloat sx = from.width > 0 ? to.width / from.width : 1, sy = from.height > 0 ? to.height / from.height : 1;
                CGRect hole = CGRectInset(CGRectMake(artInSource.origin.x * sx, artInSource.origin.y * sy, artInSource.size.width * sx, artInSource.size.height * sy), -2, -2);
                CAShapeLayer *mask = [CAShapeLayer layer];
                mask.frame = content.bounds;
                UIBezierPath *path = [UIBezierPath bezierPathWithRect:content.bounds];
                [path appendPath:[UIBezierPath bezierPathWithRect:hole]];
                mask.path = path.CGPath;
                mask.fillRule = kCAFillRuleEvenOdd;
                [CATransaction begin];
                [CATransaction setDisableActions:YES];
                content.layer.mask = mask;
                [CATransaction commit];
                _stripMask = mask;
                _masked = content;
            }
        }
        return;
    }
    // In a Jam the stand-in is the whole bar, strip and card, and the sheet grows from the card alone: the strip fades
    // in the first quarter of an open, so it never stands beside the growing player. Its place comes from Spotify's bar
    // the stand-in copies, scaled to the stand-in, not from the card: Spotify has already set the stand-in's end frame.
    CGSize from = source.bounds.size, to = bar.bounds.size;
    CGFloat sx = from.width > 0 ? to.width / from.width : 1, sy = from.height > 0 ? to.height / from.height : 1;
    strip = CGRectIntersection(CGRectMake(strip.origin.x * sx, strip.origin.y * sy, strip.size.width * sx, strip.size.height * sy), bar.bounds);
    if (CGRectIsEmpty(strip)) return;
    // A close's stand-in is a picture over copies of the bar's glass (BarTransition.x), which a mask above them would
    // break: the mask goes on the picture alone, and the strip's copy of the glass fades by alpha.
    UIView *masked = bar;
    if ([bar isKindOfClass:UIImageView.class] && !((UIImageView *)bar).image && [bar.subviews.lastObject isKindOfClass:UIImageView.class]) {
        masked = bar.subviews.lastObject;
        for (UIView *pane in bar.subviews) {
            if (pane != masked && CGRectContainsPoint(strip, CGPointMake(CGRectGetMidX(pane.frame), CGRectGetMidY(pane.frame)))) _stripPane = pane;
        }
        _stripPaneAlpha = _stripPane.alpha;
    }
    if (masked.layer.mask) {
        _stripPane = nil;
        static dispatch_once_t once;
        dispatch_once(&once, ^{ SGLog(@"player morph: the bar's stand-in has a mask of its own, the Jam strip is not faded"); });
        return;
    }
    strip = [masked convertRect:strip fromView:bar];
    // Opaque but for the strip, above or below the card, which its own part covers at the fade's opacity.
    CAShapeLayer *mask = [CAShapeLayer layer];
    mask.frame = masked.bounds;
    UIBezierPath *path = [UIBezierPath bezierPathWithRect:masked.bounds];
    [path appendPath:[UIBezierPath bezierPathWithRect:strip]];
    mask.path = path.CGPath;
    mask.fillRule = kCAFillRuleEvenOdd;
    _stripPart = [CALayer layer];
    _stripPart.backgroundColor = UIColor.blackColor.CGColor;
    _stripPart.frame = strip;
    [mask addSublayer:_stripPart];
    _stripMask = mask;
    _masked = masked;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    masked.layer.mask = mask;
    [CATransaction commit];
}

- (BOOL)masksStrip {
    return _stripPart != nil;
}

static void overlayOriginsForAnimation(CALayer *layer, CAPropertyAnimation *posAnim, CGPoint fallbackFrom, CGPoint fallbackTo, CGPoint *outFrom, CGPoint *outTo) {
    CGPoint fromOrigin = fallbackFrom, toOrigin = fallbackTo;
    if ([posAnim isKindOfClass:[CABasicAnimation class]]) {
        CABasicAnimation *basic = (CABasicAnimation *)posAnim;
        CGSize sz = layer.bounds.size;
        CGPoint anchor = layer.anchorPoint;
        CGPoint anchorOff = CGPointMake(sz.width * anchor.x, sz.height * anchor.y);
        CGPoint modelOrigin = CGPointMake(layer.position.x - anchorOff.x, layer.position.y - anchorOff.y);
        if ([basic.keyPath isEqualToString:@"position"] && [basic.fromValue isKindOfClass:[NSValue class]]) {
            CGPoint fv = [basic.fromValue CGPointValue];
            CGPoint tv = [basic.toValue isKindOfClass:[NSValue class]] ? [basic.toValue CGPointValue] : (basic.isAdditive ? CGPointZero : layer.position);
            if (basic.isAdditive) {
                fromOrigin = CGPointMake(modelOrigin.x + fv.x, modelOrigin.y + fv.y);
                toOrigin = CGPointMake(modelOrigin.x + tv.x, modelOrigin.y + tv.y);
            } else {
                fromOrigin = CGPointMake(fv.x - anchorOff.x, fv.y - anchorOff.y);
                toOrigin = CGPointMake(tv.x - anchorOff.x, tv.y - anchorOff.y);
            }
        } else if ([basic.keyPath isEqualToString:@"position.y"] && [basic.fromValue isKindOfClass:[NSNumber class]]) {
            CGFloat fv = [basic.fromValue doubleValue];
            CGFloat tv = [basic.toValue isKindOfClass:[NSNumber class]] ? [basic.toValue doubleValue] : (basic.isAdditive ? 0.0 : layer.position.y);
            if (basic.isAdditive) {
                fromOrigin = CGPointMake(modelOrigin.x, modelOrigin.y + fv);
                toOrigin = CGPointMake(modelOrigin.x, modelOrigin.y + tv);
            } else {
                fromOrigin = CGPointMake(modelOrigin.x, fv - anchorOff.y);
                toOrigin = CGPointMake(modelOrigin.x, tv - anchorOff.y);
            }
        }
    }
    *outFrom = fromOrigin;
    *outTo = toOrigin;
}

- (BOOL)attachLockstepFrom:(CGFloat)fromT to:(CGFloat)toT {
    UIView *container = _container, *overlay = _overlay, *bar = _bar;
    if (!container || !overlay || !_follows) return NO;
    CAPropertyAnimation *posAnim = animationForKeyPathPrefix(overlay.layer, @"position");
    if (!posAnim) return NO;
    CAPropertyAnimation *alphaAnim = animationForKeyPathPrefix(overlay.layer, @"opacity") ?: posAnim;

    CGRect full = container.bounds;
    if (full.size.width <= 0) return NO;

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    overlay.layer.sublayerTransform = CATransform3DIdentity;
    CGRect coverInPlayer = SGRPlayerCoverFrameIn(overlay);
    if (CGRectIsNull(coverInPlayer)) {
        [UIView performWithoutAnimation:^{
            [overlay setNeedsLayout];
            [overlay layoutIfNeeded];
        }];
        coverInPlayer = SGRPlayerCoverFrameIn(overlay);
    }
    if (_cover && CGRectIsNull(coverInPlayer)) {
        [CATransaction commit];
        return NO;
    }

    CGPoint restOrigin = _overlayRestOrigin.y > 0 ? _overlayRestOrigin : CGPointMake(0, self.restY);
    CGPoint fallbackFrom = CGPointMake(lerp(restOrigin.x, 0, fromT), lerp(restOrigin.y, 0, fromT));
    CGPoint fallbackTo = CGPointMake(lerp(restOrigin.x, 0, toT), lerp(restOrigin.y, 0, toT));
    CGPoint originFrom = fallbackFrom, originTo = fallbackTo;
    overlayOriginsForAnimation(overlay.layer, posAnim, fallbackFrom, fallbackTo, &originFrom, &originTo);

    CGRect sheetFrom = lerpRect(_card, full, fromT);
    CGRect sheetTo = lerpRect(_card, full, toT);
    CGFloat radiusFrom = lerp(_cardRadius, screenRadius(), fromT);
    CGFloat radiusTo = lerp(_cardRadius, screenRadius(), toT);
    CGFloat scaleFrom = sheetFrom.size.width / full.size.width;
    CGFloat scaleTo = sheetTo.size.width / full.size.width;

    CGSize size = overlay.bounds.size;
    CGPoint middle = CGPointMake(size.width / 2, size.height / 2);

    CGPoint targetFrom = CGPointMake(sheetFrom.origin.x - originFrom.x, sheetFrom.origin.y - originFrom.y);
    CGPoint targetTo = CGPointMake(sheetTo.origin.x - originTo.x, sheetTo.origin.y - originTo.y);

    CGPoint shiftFrom = CGPointMake(targetFrom.x - middle.x + scaleFrom * middle.x, targetFrom.y - middle.y + scaleFrom * middle.y);
    CGPoint shiftTo = CGPointMake(targetTo.x - middle.x + scaleTo * middle.x, targetTo.y - middle.y + scaleTo * middle.y);

    CATransform3D tfFrom = CATransform3DScale(CATransform3DMakeTranslation(shiftFrom.x, shiftFrom.y, 0), scaleFrom, scaleFrom, 1);
    CATransform3D tfTo = CATransform3DScale(CATransform3DMakeTranslation(shiftTo.x, shiftTo.y, 0), scaleTo, scaleTo, 1);

    overlay.layer.sublayerTransform = tfTo;
    addLockstepAnimation(overlay.layer, @"sublayerTransform", posAnim, [NSValue valueWithCATransform3D:tfFrom], [NSValue valueWithCATransform3D:tfTo]);

    CGRect maskBoundsFrom = CGRectMake(0, 0, sheetFrom.size.width, sheetFrom.size.height);
    CGRect maskBoundsTo = CGRectMake(0, 0, sheetTo.size.width, sheetTo.size.height);
    CGPoint maskPosFrom = CGPointMake(targetFrom.x + sheetFrom.size.width * 0.5, targetFrom.y + sheetFrom.size.height * 0.5);
    CGPoint maskPosTo = CGPointMake(targetTo.x + sheetTo.size.width * 0.5, targetTo.y + sheetTo.size.height * 0.5);

    _mask.bounds = maskBoundsTo;
    _mask.position = maskPosTo;
    _mask.cornerRadius = radiusTo;
    addLockstepAnimation(_mask, @"bounds", posAnim, [NSValue valueWithCGRect:maskBoundsFrom], [NSValue valueWithCGRect:maskBoundsTo]);
    addLockstepAnimation(_mask, @"position", posAnim, [NSValue valueWithCGPoint:maskPosFrom], [NSValue valueWithCGPoint:maskPosTo]);
    addLockstepAnimation(_mask, @"cornerRadius", posAnim, @(radiusFrom), @(radiusTo));

    CGRect sheetBoundsFrom = CGRectMake(0, 0, sheetFrom.size.width, sheetFrom.size.height);
    CGRect sheetBoundsTo = CGRectMake(0, 0, sheetTo.size.width, sheetTo.size.height);
    CGPoint sheetPosFrom = CGPointMake(CGRectGetMidX(sheetFrom), CGRectGetMidY(sheetFrom));
    CGPoint sheetPosTo = CGPointMake(CGRectGetMidX(sheetTo), CGRectGetMidY(sheetTo));

    _sheet.layer.bounds = sheetBoundsTo;
    _sheet.layer.position = sheetPosTo;
    _sheet.layer.cornerRadius = radiusTo;
    _sheet.layer.opacity = (float)toT;
    addLockstepAnimation(_sheet.layer, @"bounds", posAnim, [NSValue valueWithCGRect:sheetBoundsFrom], [NSValue valueWithCGRect:sheetBoundsTo]);
    addLockstepAnimation(_sheet.layer, @"position", posAnim, [NSValue valueWithCGPoint:sheetPosFrom], [NSValue valueWithCGPoint:sheetPosTo]);
    addLockstepAnimation(_sheet.layer, @"cornerRadius", posAnim, @(radiusFrom), @(radiusTo));
    addLockstepAnimation(_sheet.layer, @"opacity", alphaAnim, @(fromT), @(toT));

    if (bar && !CGRectIsEmpty(_barRest)) {
        CGFloat riseFrom = sheetFrom.origin.y - _card.origin.y;
        CGFloat riseTo = sheetTo.origin.y - _card.origin.y;
        CGPoint barPosFrom = CGPointMake(CGRectGetMidX(_barRest), CGRectGetMidY(_barRest) + riseFrom);
        CGPoint barPosTo = CGPointMake(CGRectGetMidX(_barRest), CGRectGetMidY(_barRest) + riseTo);
        bar.layer.position = barPosTo;
        addLockstepAnimation(bar.layer, @"position", posAnim, [NSValue valueWithCGPoint:barPosFrom], [NSValue valueWithCGPoint:barPosTo]);
    }

    if (_cover && !CGRectIsNull(coverInPlayer)) {
        if (!_coverHidden) {
            SGRPlayerSetCoverHidden(YES);
            _coverHidden = YES;
        }
        _cover.hidden = NO;
        CGRect fromInCard = CGRectOffset(_barArtwork, -_card.origin.x, -_card.origin.y);
        CGRect toInSheetFrom = CGRectMake(scaleFrom * coverInPlayer.origin.x, scaleFrom * coverInPlayer.origin.y,
                                          coverInPlayer.size.width * scaleFrom, coverInPlayer.size.height * scaleFrom);
        CGRect toInSheetTo = CGRectMake(scaleTo * coverInPlayer.origin.x, scaleTo * coverInPlayer.origin.y,
                                        coverInPlayer.size.width * scaleTo, coverInPlayer.size.height * scaleTo);
        CGRect coverRectFrom = CGRectOffset(lerpRect(fromInCard, toInSheetFrom, fromT), sheetFrom.origin.x, sheetFrom.origin.y);
        CGRect coverRectTo = CGRectOffset(lerpRect(fromInCard, toInSheetTo, toT), sheetTo.origin.x, sheetTo.origin.y);

        CGRect coverBoundsFrom = CGRectMake(0, 0, coverRectFrom.size.width, coverRectFrom.size.height);
        CGRect coverBoundsTo = CGRectMake(0, 0, coverRectTo.size.width, coverRectTo.size.height);
        CGPoint coverPosFrom = CGPointMake(CGRectGetMidX(coverRectFrom), CGRectGetMidY(coverRectFrom));
        CGPoint coverPosTo = CGPointMake(CGRectGetMidX(coverRectTo), CGRectGetMidY(coverRectTo));

        CGFloat barRadius = SGEnabled(SGRKeyBarCompact) ? 7.0 : fromInCard.size.width / 2.0;
        CGFloat fullCoverRadius = SGRRadiusArtwork * SGRPlayerCoverScale();
        CGFloat coverRadiusFrom = lerp(barRadius, fullCoverRadius * scaleFrom, fromT);
        CGFloat coverRadiusTo = lerp(barRadius, fullCoverRadius * scaleTo, toT);

        _cover.layer.bounds = coverBoundsTo;
        _cover.layer.position = coverPosTo;
        _cover.layer.cornerRadius = coverRadiusTo;
        addLockstepAnimation(_cover.layer, @"bounds", posAnim, [NSValue valueWithCGRect:coverBoundsFrom], [NSValue valueWithCGRect:coverBoundsTo]);
        addLockstepAnimation(_cover.layer, @"position", posAnim, [NSValue valueWithCGPoint:coverPosFrom], [NSValue valueWithCGPoint:coverPosTo]);
        addLockstepAnimation(_cover.layer, @"cornerRadius", posAnim, @(coverRadiusFrom), @(coverRadiusTo));
        if (SGRPlayerMotionShowing()) {
            CGFloat alphaFrom = 1 - ramp(0.6, 1, fromT);
            CGFloat alphaTo = 1 - ramp(0.6, 1, toT);
            _cover.layer.opacity = (float)alphaTo;
            addLockstepAnimation(_cover.layer, @"opacity", posAnim, @(alphaFrom), @(alphaTo));
        } else {
            _cover.alpha = 1.0;
        }
    }
    [CATransaction commit];
    _lockstepped = YES;
    return YES;
}

- (instancetype)initWithContainer:(UIView *)container overlay:(UIView *)overlay bar:(UIView *)bar barRest:(CGRect)barRest {
    CGFloat radius = 0;
    CGRect card = SGRNowPlayingCardFrameIn(container, &radius);
    if (CGRectIsNull(card) || CGRectIsEmpty(card)) return nil;
    if (!(self = [super init])) return nil;
    _container = container;
    _overlay = overlay;
    _bar = bar;
    _barRest = barRest;
    _card = card;
    _cardRadius = radius;
    _barArtwork = SGRNowPlayingArtworkFrameIn(container);
    _spotifyAlpha = overlay.alpha;

    _sheet = [[UIView alloc] initWithFrame:card];
    _sheet.userInteractionEnabled = NO;
    _sheet.backgroundColor = SGRPlayerField().fieldColor ?: UIColor.blackColor;
    _sheet.layer.cornerCurve = kCACornerCurveContinuous;
    _sheet.clipsToBounds = YES;
    [container insertSubview:_sheet belowSubview:overlay];

    // The player's own paint is not a sublayer, so the content's transform would leave it where Spotify
    // put the player, a band below the sheet's top edge; the sheet paints instead.
    _overlayColor = CGColorRetain(overlay.layer.backgroundColor);
    overlay.layer.backgroundColor = NULL;

    _mask = [CALayer layer];
    _mask.backgroundColor = UIColor.blackColor.CGColor;
    _mask.cornerCurve = kCACornerCurveContinuous;
    overlay.layer.mask = _mask;

    if (bar.superview == container) [container bringSubviewToFront:bar];

    UIImage *artwork = SGRNowPlayingArtwork(NULL, NULL);
    if (artwork && !CGRectIsNull(_barArtwork)) {
        _cover = [[UIImageView alloc] initWithImage:artwork];
        _cover.userInteractionEnabled = NO;
        _cover.contentMode = UIViewContentModeScaleAspectFill;
        _cover.clipsToBounds = YES;
        _cover.layer.cornerCurve = kCACornerCurveContinuous;
        [container addSubview:_cover];
    }

    static NSUInteger logged;
    if (logged++ < 3) SGLog(@"player morph: card %@ r=%.0f, artwork %@, cover %@, screen r=%.0f", NSStringFromCGRect(card), radius,
                            NSStringFromCGRect(_barArtwork), _cover ? @"flown" : @"not flown", screenRadius());
    return self;
}

- (void)apply:(CGFloat)t {
    UIView *container = _container, *overlay = _overlay, *bar = _bar;
    if (!container || !overlay) return;
    t = MIN(1, MAX(0, t));
    _spotifyAlpha = overlay.alpha;
    _spotifyFrame = overlay.frame;

    if (_follows) {
        // Where Spotify's animation has the player now: its frame's model value is already the end. Not drawn yet (an
        // open's first frame), it is at the bar and transparent.
        CALayer *drawn = overlay.layer.presentationLayer;
        CGPoint restOrigin = _overlayRestOrigin.y > 0 ? _overlayRestOrigin : CGPointMake(_spotifyFrame.origin.x, self.restY);
        _spotifyFrame = drawn ? drawn.frame : (CGRect){restOrigin, _spotifyFrame.size};
        _spotifyAlpha = drawn ? drawn.opacity : 0;
    }
    CGRect full = container.bounds;
    CGRect sheet = lerpRect(_card, full, t);
    CGFloat radius = lerp(_cardRadius, screenRadius(), t);
    CGFloat scale = full.size.width > 0 ? sheet.size.width / full.size.width : 1;
    // The player's top goes to the sheet's: a mask clips nothing above the layer's bounds, so content
    // raised above Spotify's frame would show square corners. Spotify reads back only the player's
    // height (0x109815b4c, 0x109815c28), which stays.
    CGPoint origin = _follows ? _spotifyFrame.origin : CGPointMake(_spotifyFrame.origin.x, sheet.origin.y);
    CGSize size = overlay.bounds.size;
    CGPoint middle = CGPointMake(size.width / 2, size.height / 2);
    CGPoint target = CGPointMake(sheet.origin.x - origin.x, sheet.origin.y - origin.y);
    // A point q of the player lands at middle + scale * (q - middle) + shift; the top left at target.
    CGPoint shift = CGPointMake(target.x - middle.x + scale * middle.x, target.y - middle.y + scale * middle.y);

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    [UIView performWithoutAnimation:^{
        overlay.layer.sublayerTransform = CATransform3DIdentity;
        if (!self->_follows) overlay.frame = (CGRect){origin, self->_spotifyFrame.size};
        CGRect coverInPlayer = SGRPlayerCoverFrameIn(overlay);

        overlay.layer.sublayerTransform = CATransform3DScale(CATransform3DMakeTranslation(shift.x, shift.y, 0), scale, scale, 1);
        self->_mask.frame = CGRectMake(target.x, target.y, sheet.size.width, sheet.size.height);
        self->_mask.cornerRadius = radius;
        if (!self->_follows) overlay.alpha = ramp(0.08, 0.55, t);

        self->_sheet.frame = sheet;
        self->_sheet.layer.cornerRadius = radius;
        // The sheet is the player's own paint, so it fades with the player Spotify fades against its bar stand-in.
        self->_sheet.alpha = self->_follows ? self->_spotifyAlpha : ramp(0, 0.15, t);

        // The card's top edge is the sheet's.
        CGFloat rise = sheet.origin.y - self->_card.origin.y;
        if (bar && !CGRectIsEmpty(self->_barRest)) {
            CGRect frame = bar.frame;
            frame.origin.y = self->_barRest.origin.y + rise;
            bar.frame = frame;
            if (!self->_follows) bar.alpha = 1 - ramp(0, 0.25, t);
        }
        if (self->_stripPart) {
            // Under Spotify's own crossfade of the stand-in, which stays its own.
            CGFloat strip = 1 - ramp(0, 0.25, t);
            self->_stripPart.opacity = strip;
            self->_stripPane.alpha = self->_stripPaneAlpha * strip;
        }

        if (self->_cover) {
            // Worked out relative to the sheet, so the cover stays on it the whole way rather than
            // heading for where the player's cover is while that is still below the screen.
            CGRect from = CGRectOffset(self->_barArtwork, -self->_card.origin.x, -self->_card.origin.y);
            // The player's cover is held hidden from the first frame, laid out or not: the first open lays it out
            // between two frames of the morph, and it is hidden in that layout pass (PlayerArtwork.x).
            if (!self->_coverHidden) {
                SGRPlayerSetCoverHidden(YES);
                self->_coverHidden = YES;
            }
            if (CGRectIsNull(coverInPlayer)) {
                self->_cover.hidden = YES;
            } else {
                CGRect to = CGRectMake(middle.x + scale * (coverInPlayer.origin.x - middle.x) + shift.x + origin.x,
                                       middle.y + scale * (coverInPlayer.origin.y - middle.y) + shift.y + origin.y,
                                       coverInPlayer.size.width * scale, coverInPlayer.size.height * scale);
                self->_cover.hidden = NO;
                to = CGRectOffset(to, -sheet.origin.x, -sheet.origin.y);
                self->_cover.frame = CGRectOffset(lerpRect(from, to, t), sheet.origin.x, sheet.origin.y);
                // The cover's corners are drawn under its paused shrink too.
                CGFloat barRadius = SGEnabled(SGRKeyBarCompact) ? 7.0 : from.size.width / 2.0;
                self->_cover.layer.cornerRadius = lerp(barRadius, SGRRadiusArtwork * SGRPlayerCoverScale() * scale, t);
                // Over an animated artwork the player's cover is hidden: the flown one fades out on the
                // way there instead of landing on an empty slot.
                self->_cover.alpha = SGRPlayerMotionShowing() ? 1 - ramp(0.6, 1, t) : 1;
            }
        }
    }];
    [CATransaction commit];
}

- (void)tearDown {
    _tornDown = YES;
    UIView *overlay = _overlay, *bar = _bar;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    for (NSString *key in [overlay.layer.animationKeys copy]) {
        if ([key hasPrefix:@"sgr."]) [overlay.layer removeAnimationForKey:key];
    }
    if (bar) {
        for (NSString *key in [bar.layer.animationKeys copy]) {
            if ([key hasPrefix:@"sgr."]) [bar.layer removeAnimationForKey:key];
        }
        if (!CGRectIsEmpty(_barRest)) bar.frame = _barRest;
    }
    overlay.layer.sublayerTransform = CATransform3DIdentity;
    if (overlay.layer.mask == _mask) overlay.layer.mask = nil;
    UIView *masked = _masked, *pane = _stripPane;
    if (_stripMask && masked.layer.mask == _stripMask) masked.layer.mask = nil;
    pane.alpha = _stripPaneAlpha;
    _stripMask = nil;
    _stripPart = nil;
    _stripPane = nil;
    if (!_follows) overlay.alpha = _spotifyAlpha;
    if (overlay && !_follows) overlay.frame = _spotifyFrame;
    if (!overlay.layer.backgroundColor) overlay.layer.backgroundColor = _overlayColor;
    CGColorRelease(_overlayColor);
    _overlayColor = NULL;
    [_sheet removeFromSuperview];
    [_cover removeFromSuperview];
    [CATransaction commit];
    if (_coverHidden) SGRPlayerSetCoverHidden(NO);
    _coverHidden = NO;
    _cover = nil;
}

@end

static char kMorphKey;

static SGRPlayerMorph *morphFor(SPTBarOverlayPresentationTransition *transition, BOOL create) {
    SGRPlayerMorph *morph = objc_getAssociatedObject(transition, &kMorphKey);
    if (morph || !create || SGRReduceMotion()) return morph;
    id<UIViewControllerContextTransitioning> context = [transition transitioningContext];
    UIView *container = context.containerView, *overlay = [transition overlayView];
    if (!container || !overlay || overlay.superview != container) return nil;
    if (container.traitCollection.horizontalSizeClass == UIUserInterfaceSizeClassRegular) return nil;
    morph = [[SGRPlayerMorph alloc] initWithContainer:container overlay:overlay bar:[transition barSnapshotView] barRest:[transition barFrame]];
    if (morph) objc_setAssociatedObject(transition, &kMorphKey, morph, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return morph;
}

%hook SPTBarOverlayPresentationTransition
- (void)setProgress:(double)progress {
    %orig;
    SGRPlayerMorph *morph = morphFor(self, YES);
    [morph apply:[self progress]];
    if (morph) [self tabBarSnapshotView].alpha = 0;
}

- (void)destroyTransitioningContext {
    SGRPlayerMorph *morph = morphFor(self, NO);
    if (morph) {
        [morph tearDown];
        objc_setAssociatedObject(self, &kMorphKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    %orig;
}
%end

#pragma mark - 9.1.90

// 9.1.90 presents the player with MainUI_TabBarUIImpl.CompactOverlayTransition, a UIKit animator that moves the
// player up from below the screen (animateTransition:, and startInteractiveTransition: for a drag) with its own
// stand-ins (npbSnapshotView, tabBarSnapshotView; BarTransition.x). A display link reads how far up Spotify's animation
// has the player and morphs to match, so Spotify's frame, alpha and completion stay its own. It is let go once the
// transition is no longer interactive and the player has no animation left and holds still a few frames.
static const CFTimeInterval kGiveUp = 0.9;   // ticking with no move this long; UIKit's whole presentation runs about 0.5 s
static const float kCloseSpeed = 1.2;         // how much faster than Spotify's a close it runs on its own plays

@interface SGRMorphFollower : NSObject
@property (nonatomic, strong) SGRPlayerMorph *morph;
@property (nonatomic, weak) UIView *container, *overlay;
@property (nonatomic, weak) id<UIViewControllerContextTransitioning> context;
@property (nonatomic, strong) CADisplayLink *link;
@property (nonatomic) NSInteger still;
@property (nonatomic) CGFloat lastY, lastT;
@property (nonatomic) CGRect npbFrame;   // Spotify's bar frame, for the Jam close log
@property (nonatomic) CFTimeInterval settledSince;   // when it last moved or was driven by a finger, or began
@property (nonatomic) CFTimeInterval lastTick;
@property (nonatomic) BOOL sped;                     // the container's layer runs at kCloseSpeed until let go
@property (nonatomic) BOOL closing, wasInteractive;
@end

// The container's clock runs at `speed` from now on, continuing from where its animations are.
static void runAtSpeed(CALayer *layer, float speed) {
    CFTimeInterval now = CACurrentMediaTime(), local = [layer convertTime:now fromLayer:nil];
    layer.speed = speed;
    layer.beginTime = layer.superlayer ? [layer.superlayer convertTime:now fromLayer:nil] : now;
    layer.timeOffset = local;
}

@implementation SGRMorphFollower
- (void)tick:(CADisplayLink *)link {
    UIView *container = self.container, *overlay = self.overlay;
    if (!container || !overlay || !overlay.window) {
        [self finish];
        return;
    }
    CALayer *drawn = overlay.layer.presentationLayer;
    CGFloat rest = self.morph.restY > 0 ? self.morph.restY : container.bounds.size.height;
    // An open's first frame has no presentation layer yet and its model already holds the end; Spotify starts it at the bar.
    CGFloat y = drawn ? drawn.frame.origin.y : (self.closing ? 0 : rest);
    self.lastT = rest > 0 ? MIN(1, MAX(0, 1 - y / rest)) : 1;
    BOOL interactive = self.context.isInteractive;
    if (!self.morph.lockstepped) {
        [self.morph apply:self.lastT];
    }
    // When an interactive drag is released, attach render-server lockstep animations for the remainder of the transition.
    if (self.wasInteractive && !interactive && !self.morph.lockstepped) {
        CAPropertyAnimation *posAnim = animationForKeyPathPrefix(overlay.layer, @"position");
        CGFloat fromT = (posAnim && posAnim.beginTime > 0) ? (self.closing ? 1.0 : 0.0) : self.lastT;
        [self.morph attachLockstepFrom:fromT to:(self.closing ? 0.0 : 1.0)];
    }
    // A close dragged by a finger runs faster from the moment it is let go.
    if (self.closing && self.wasInteractive && !interactive && !self.sped) {
        runAtSpeed(container.layer, kCloseSpeed);
        self.sped = YES;
    }
    self.wasInteractive = interactive;
    BOOL moved = fabs(y - self.lastY) > 0.5;
    BOOL hasSpotifyAnim = NO;
    for (NSString *key in overlay.layer.animationKeys) {
        if (![key hasPrefix:@"sgr."]) {
            hasSpotifyAnim = YES;
            break;
        }
    }
    BOOL moving = hasSpotifyAnim || moved || interactive;
    self.lastY = y;
    self.still = moving ? 0 : self.still + 1;
    // Let go once still, or kGiveUp after it last moved whatever the layer holds: a mask and a transform left on the player
    // would keep its glass buttons from drawing. Counted from the last move and over ticks only, so a stall of the main
    // thread before the slide (a cold open's first layout) does not use it up.
    CFTimeInterval now = CACurrentMediaTime();
    if (interactive || moved || !self.settledSince || now - self.lastTick > kGiveUp / 4) self.settledSince = now;
    self.lastTick = now;
    if (self.still >= 3 || now - self.settledSince > kGiveUp) [self finish];
}
- (void)finish {
    if (!self.link) return;
    static NSUInteger logged;
    if (logged++ < 3) SGLog(@"player morph: let go after %.2f s still, %@", CACurrentMediaTime() - self.settledSince, self.still >= 3 ? @"settled" : @"given up");
    [self.link invalidate];
    self.link = nil;
    // Back to 1 from where its animations are, so a close Spotify has not finished does not jump back.
    if (self.sped) runAtSpeed(self.container.layer, 1);
    // Whether a close in a Jam ends at t 0: Spotify parks the player at its bar frame's top, the strip's, and restY is the card's.
    if (self.closing && self.morph.masksStrip) {
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            SGLog(@"player morph: Jam close ended, npbFrame %@, card %@, restY %.1f, last t %.3f", NSStringFromCGRect(self.npbFrame),
                  NSStringFromCGRect(self.morph.card), self.morph.restY, self.lastT);
        });
    }
    [self.morph tearDown];
    self.morph = nil;
}
@end

static id ivarOf(id object, const char *name) {
    Ivar ivar = class_getInstanceVariable(object_getClass(object), name);
    return ivar ? object_getIvar(object, ivar) : nil;
}

static char kFollowerKey;

// A CGRect a Swift object keeps, read at its ivar's offset; CGRectNull without that ivar, or when it cannot be a CGRect
// (an Objective-C type other than one, or too little room in the object), and the class's ivars are then logged once.
static CGRect rectIvarOf(id object, const char *name) {
    Class cls = object_getClass(object);
    Ivar ivar = class_getInstanceVariable(cls, name);
    const char *type = ivar ? ivar_getTypeEncoding(ivar) : NULL;
    BOOL fits = ivar && ivar_getOffset(ivar) >= 0 && (size_t)ivar_getOffset(ivar) + sizeof(CGRect) <= class_getInstanceSize(cls);
    if (fits && (!type || !*type || strncmp(type, "{CGRect", 7) == 0)) return *(CGRect *)((char *)(__bridge void *)object + ivar_getOffset(ivar));
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        unsigned int count = 0;
        Ivar *ivars = class_copyIvarList(cls, &count);
        NSMutableString *names = [NSMutableString string];
        for (unsigned int i = 0; i < count; i++) [names appendFormat:@" %s", ivar_getName(ivars[i])];
        free(ivars);
        SGLog(@"player morph: %@ has no CGRect %s, its ivars:%@", cls, name, names);
    });
    return CGRectNull;
}

static void followTransition(id transition, id<UIViewControllerContextTransitioning> context) {
    if (SGRReduceMotion() || !context) return;
    UIView *container = context.containerView;
    if (container.traitCollection.horizontalSizeClass == UIUserInterfaceSizeClassRegular) return;
    UIViewController *to = [context viewControllerForKey:UITransitionContextToViewControllerKey];
    UIView *overlay = to.isBeingPresented ? [context viewForKey:UITransitionContextToViewKey] : [context viewForKey:UITransitionContextFromViewKey];
    if (!overlay || overlay.superview != container) return;
    SGRMorphFollower *old = objc_getAssociatedObject(transition, &kFollowerKey);
    [old finish];
    CGRect npbFrame = rectIvarOf(transition, "npbFrame");
    SGRPlayerMorph *morph = [[SGRPlayerMorph alloc] initWithContainer:container overlay:overlay bar:ivarOf(transition, "npbSnapshotView") barRest:CGRectZero];
    if (!morph) return;
    [morph followFrom:ivarOf(transition, "npbView") npbFrame:npbFrame];
    ((UIView *)ivarOf(transition, "tabBarSnapshotView")).alpha = 0;
    SGRMorphFollower *follower = [SGRMorphFollower new];
    follower.morph = morph;
    follower.container = container;
    follower.overlay = overlay;
    follower.context = context;
    follower.lastY = CGFLOAT_MAX;
    follower.npbFrame = npbFrame;
    // A close plays faster: its slide, its stand-ins and so the morph that follows them. One Spotify runs on its own
    // from the start, one dragged by a finger from when it is let go (tick:).
    follower.closing = !to.isBeingPresented;
    follower.wasInteractive = context.isInteractive;
    if (!context.isInteractive) {
        CGFloat fromT = follower.closing ? 1.0 : 0.0;
        CGFloat toT = follower.closing ? 0.0 : 1.0;
        [morph apply:fromT];
        [morph attachLockstepFrom:fromT to:toT];
    }
    if (follower.closing && !context.isInteractive) {
        runAtSpeed(container.layer, kCloseSpeed);
        follower.sped = YES;
    }
    follower.link = [CADisplayLink displayLinkWithTarget:follower selector:@selector(tick:)];
    follower.link.preferredFrameRateRange = CAFrameRateRangeMake(80, 120, 120);
    [follower.link addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    objc_setAssociatedObject(transition, &kFollowerKey, follower, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [follower tick:follower.link];
    static NSUInteger logged;
    if (logged++ < 3) SGLog(@"player morph: follows CompactOverlayTransition (%@)", to.isBeingPresented ? @"open" : @"close");
}

%hook _TtC19MainUI_TabBarUIImpl24CompactOverlayTransition
- (void)animateTransition:(id<UIViewControllerContextTransitioning>)context {
    %orig;
    followTransition(self, context);
}
- (void)startInteractiveTransition:(id<UIViewControllerContextTransitioning>)context {
    %orig;
    followTransition(self, context);
}
%end

%ctor {
    if (!SGRedesignedUI()) return;
    %init;
    SGRequireClasses(@[@"SPTBarOverlayPresentationTransition"]);
}
