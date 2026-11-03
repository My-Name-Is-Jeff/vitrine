#import "SGMarquee.h"

// Speed in pt/s, initial/cycle rest duration in seconds, gap between wrap-around text copies, and edge fade width.
// Measured 1:1 against Apple Music: exactly 4.0 s rest delay, 40.0 pt/s speed, 36.0 pt loop gap, and 14.0 pt edge fade.
static const CGFloat kSpeed = 40.0;
static const CGFloat kLoopGap = 36.0;
static const CGFloat kFade = 14.0;
static const CFTimeInterval kRest = 4.0;
static NSString *const kScroll = @"sg.marquee";

@implementation SGMarqueeLabel {
    UIView *_contentView;
    UILabel *_label1;
    UILabel *_label2;
    CAGradientLayer *_fade;
    CGFloat _scrolled;   // how far the running animation travels, 0 while still
}

- (instancetype)initWithFrame:(CGRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    self.clipsToBounds = YES;
    self.isAccessibilityElement = YES;
    self.accessibilityTraits = UIAccessibilityTraitStaticText;

    _contentView = [UIView new];
    _contentView.userInteractionEnabled = NO;
    [self addSubview:_contentView];

    _label1 = [UILabel new];
    [_contentView addSubview:_label1];

    _label2 = [UILabel new];
    _label2.hidden = YES;
    [_contentView addSubview:_label2];

    _fade = [CAGradientLayer layer];
    _fade.startPoint = CGPointMake(0, 0.5);
    _fade.endPoint = CGPointMake(1, 0.5);

    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(setNeedsLayout)
                                               name:UIAccessibilityReduceMotionStatusDidChangeNotification object:nil];
    return self;
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (NSString *)text { return _label1.text; }
- (NSAttributedString *)attributedText { return _label1.attributedText; }
- (UIFont *)font { return _label1.font; }
- (UIColor *)textColor { return _label1.textColor; }

- (void)setText:(NSString *)text {
    if ([text isEqualToString:_label1.text]) return;
    _label1.text = text;
    _label2.text = text;
    self.accessibilityLabel = text;
    _scrolled = -1;   // starts over from its start
    [_contentView.layer removeAnimationForKey:kScroll];
    [_fade removeAnimationForKey:@"mask.fade"];
    _contentView.transform = CGAffineTransformIdentity;
    [self setNeedsLayout];
}

- (void)setAttributedText:(NSAttributedString *)attributedText {
    _label1.attributedText = attributedText;
    _label2.attributedText = attributedText;
    self.accessibilityLabel = attributedText.string;
    _scrolled = -1;
    [_contentView.layer removeAnimationForKey:kScroll];
    [_fade removeAnimationForKey:@"mask.fade"];
    _contentView.transform = CGAffineTransformIdentity;
    [self setNeedsLayout];
}

- (CGSize)sizeThatFits:(CGSize)size {
    return [_label1 sizeThatFits:size];
}

- (void)setFont:(UIFont *)font {
    _label1.font = font;
    _label2.font = font;
    _scrolled = -1;
    [self setNeedsLayout];
}

- (void)setTextColor:(UIColor *)textColor {
    _label1.textColor = textColor;
    _label2.textColor = textColor;
}

- (void)didMoveToWindow {
    [super didMoveToWindow];
    // A view out of its window loses its animations; back in one, it restarts cleanly.
    _scrolled = -1;
    [_contentView.layer removeAnimationForKey:kScroll];
    [_fade removeAnimationForKey:@"mask.fade"];
    _contentView.transform = CGAffineTransformIdentity;
    [self setNeedsLayout];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGSize size = self.bounds.size;
    if (size.width <= 0 || size.height <= 0) return;

    CGFloat textWidth = ceil([_label1 sizeThatFits:CGSizeMake(CGFLOAT_MAX, size.height)].width);
    CGFloat overflow = textWidth - size.width;
    BOOL scrolls = overflow > 0.5 && !UIAccessibilityIsReduceMotionEnabled() && self.window;

    if (!scrolls) {
        _label2.hidden = YES;
        _label1.lineBreakMode = NSLineBreakByTruncatingTail;
        _label1.frame = CGRectMake(0, 0, size.width, size.height);
        _contentView.frame = CGRectMake(0, 0, size.width, size.height);
        _contentView.transform = CGAffineTransformIdentity;
        [_contentView.layer removeAnimationForKey:kScroll];
        [_fade removeAnimationForKey:@"mask.fade"];
        self.layer.mask = nil;
        _scrolled = 0;
        return;
    }

    _label1.lineBreakMode = NSLineBreakByClipping;
    _label2.lineBreakMode = NSLineBreakByClipping;
    _label2.hidden = NO;

    CGFloat travel = textWidth + kLoopGap;
    _contentView.frame = CGRectMake(0, 0, travel * 2.0, size.height);
    _label1.frame = CGRectMake(0, 0, textWidth, size.height);
    _label2.frame = CGRectMake(travel, 0, textWidth, size.height);

    CGFloat leftEdge = MIN(kFade / size.width, 0.15);
    CGFloat rightEdge = MIN(kFade / size.width, 0.15);
    self.layer.mask = _fade;
    _fade.frame = self.bounds;
    _fade.colors = @[
        (id)UIColor.clearColor.CGColor,
        (id)UIColor.blackColor.CGColor,
        (id)UIColor.blackColor.CGColor,
        (id)UIColor.clearColor.CGColor,
    ];

    if (travel == _scrolled && [_contentView.layer animationForKey:kScroll]) return;
    _scrolled = travel;

    [_contentView.layer removeAnimationForKey:kScroll];
    [_fade removeAnimationForKey:@"mask.fade"];

    CFTimeInterval glide = travel / kSpeed;
    CFTimeInterval total = kRest + glide;

    // Linear translation to -travel with ease-in-out glide and 4.0s rest
    CAKeyframeAnimation *scroll = [CAKeyframeAnimation animationWithKeyPath:@"transform.translation.x"];
    scroll.values = @[@0, @0, @(-travel)];
    scroll.keyTimes = @[@0, @(kRest / total), @1.0];
    scroll.timingFunctions = @[
        [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionLinear],
        [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut],
    ];
    scroll.duration = total;
    scroll.repeatCount = HUGE_VALF;
    scroll.removedOnCompletion = NO;
    scroll.fillMode = kCAFillModeForwards;
    if (@available(iOS 15.0, *)) scroll.preferredFrameRateRange = CAFrameRateRangeMake(30, 60, 60);
    [_contentView.layer addAnimation:scroll forKey:kScroll];

    // Edge mask animation: crisp left edge while resting at x=0; fades in during glide
    CAKeyframeAnimation *maskAnim = [CAKeyframeAnimation animationWithKeyPath:@"locations"];
    NSArray *crisp = @[@0, @0, @(1.0 - rightEdge), @1.0];
    NSArray *faded = @[@0, @(leftEdge), @(1.0 - rightEdge), @1.0];
    CFTimeInterval fadeDuration = MIN(0.35, glide * 0.1);
    maskAnim.values = @[crisp, crisp, faded, faded, crisp];
    maskAnim.keyTimes = @[
        @0,
        @(kRest / total),
        @((kRest + fadeDuration) / total),
        @((total - fadeDuration) / total),
        @1.0,
    ];
    maskAnim.timingFunctions = @[
        [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionLinear],
        [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut],
        [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionLinear],
        [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut],
    ];
    maskAnim.duration = total;
    maskAnim.repeatCount = HUGE_VALF;
    maskAnim.removedOnCompletion = NO;
    maskAnim.fillMode = kCAFillModeForwards;
    if (@available(iOS 15.0, *)) maskAnim.preferredFrameRateRange = CAFrameRateRangeMake(30, 60, 60);
    [_fade addAnimation:maskAnim forKey:@"mask.fade"];
}

@end
