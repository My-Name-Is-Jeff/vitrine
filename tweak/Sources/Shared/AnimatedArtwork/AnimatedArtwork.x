// AnimatedArtwork.x
#import <AVFoundation/AVFoundation.h>
#import <UIKit/UIKit.h>
#import "Core/SGCore.h"
#import "AnimatedArtwork.h"
#import "Headers/SPTPlayer.h"

extern NSString *const SGKeyAnimatedCoversEnabled;
extern NSString *const SGKeyAnimatedCoversFullBrightness;

@interface SGAnimatedArtworkViewManager : NSObject
@property (nonatomic, strong) AVQueuePlayer *player;
@property (nonatomic, strong) AVPlayerLooper *looper;
@property (nonatomic, strong) AVPlayerLayer *playerLayer;
@property (nonatomic, weak) UIView *activeContainer;
@property (nonatomic, strong) SGMotionFollower *follower;

+ (instancetype)shared;
- (void)attachToView:(UIView *)container videoURL:(NSURL *)fileURL;
- (void)detach;
@end

@implementation SGAnimatedArtworkViewManager

+ (instancetype)shared {
    static SGAnimatedArtworkViewManager *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [SGAnimatedArtworkViewManager new];
    });
    return instance;
}

// Aplica el degradado suave en la parte inferior para evitar líneas verticales estiradas
- (void)applyGradientMaskToLayer:(CALayer *)layer bounds:(CGRect)bounds {
    if (!layer || CGRectIsEmpty(bounds)) return;

    CAGradientLayer *gradient = [CAGradientLayer layer];
    gradient.frame = bounds;
    
    gradient.colors = @[
        (id)[UIColor blackColor].CGColor,
        (id)[UIColor blackColor].CGColor,
        (id)[UIColor clearColor].CGColor
    ];
    
    gradient.locations = @[@0.0, @0.6, @1.0];
    gradient.startPoint = CGPointMake(0.5, 0.0);
    gradient.endPoint = CGPointMake(0.5, 1.0);

    layer.mask = gradient;
}

// Ajusta el brillo / oscurecimiento de la portada e interfaz de acuerdo a la preferencia
- (void)applyBrightnessSettingsToContainer:(UIView *)container {
    if (!container) return;

    BOOL fullBrightness = SGFlag(@"spotifyglass.animatedCovers.fullBrightness", NO);

    // Si la opción está encendida, quitamos la opacidad al playerLayer y ocultamos capas oscuras
    if (self.playerLayer) {
        self.playerLayer.opacity = fullBrightness ? 1.0f : 0.85f;
    }

    SGForEachView(container.superview ?: container, ^(UIView *v) {
        NSString *className = NSStringFromClass(v.class);
        if ([className containsString:@"DimmingView"] || [className containsString:@"OverlayView"] || [v.accessibilityIdentifier isEqualToString:@"SGDarkOverlay"]) {
            v.alpha = fullBrightness ? 0.0f : 1.0f;
        }
    });
}

- (void)attachToView:(UIView *)container videoURL:(NSURL *)fileURL {
    if (!container || !fileURL) {
        [self detach];
        return;
    }

    if (self.activeContainer == container && self.playerLayer && self.playerLayer.superlayer == container.layer) {
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        self.playerLayer.frame = container.bounds;
        [self applyGradientMaskToLayer:self.playerLayer bounds:container.bounds];
        [self applyBrightnessSettingsToContainer:container];
        [CATransaction commit];
        return;
    }

    [self detach];
    self.activeContainer = container;

    AVPlayerItem *item = [AVPlayerItem playerItemWithURL:fileURL];
    self.player = [AVQueuePlayer queuePlayerWithItems:@[item]];
    self.looper = [AVPlayerLooper playerLooperWithPlayer:self.player templateItem:item];

    self.playerLayer = [AVPlayerLayer playerLayerWithPlayer:self.player];
    self.playerLayer.videoGravity = AVLayerVideoGravityResizeAspectFill;
    self.playerLayer.frame = container.bounds;

    // Ocultamos la carátula estática nativa
    SGForEachView(container, ^(UIView *v) {
        if ([v isKindOfClass:UIImageView.class]) {
            v.alpha = 0.0;
        }
    });

    [self applyGradientMaskToLayer:self.playerLayer bounds:container.bounds];
    [self applyBrightnessSettingsToContainer:container];

    [container.layer addSublayer:self.playerLayer];
    [self.player play];
}

- (void)detach {
    if (self.activeContainer) {
        SGForEachView(self.activeContainer, ^(UIView *v) {
            if ([v isKindOfClass:UIImageView.class]) {
                v.alpha = 1.0;
            }
        });
    }
    if (self.player) {
        [self.player pause];
        self.player = nil;
    }
    self.looper = nil;
    if (self.playerLayer) {
        self.playerLayer.mask = nil;
        [self.playerLayer removeFromSuperlayer];
        self.playerLayer = nil;
    }
    self.activeContainer = nil;
}

@end

%hook UIView

- (void)layoutSubviews {
    %orig;

    if (!SGFlag(SGKeyAnimatedCoversEnabled, YES)) {
        [[SGAnimatedArtworkViewManager shared] detach];
        return;
    }

    NSString *className = NSStringFromClass(self.class);
    if ([className containsString:@"SPTNowPlayingArtworkView"] ||
        [className containsString:@"NowPlayingCoverArtView"] ||
        [className containsString:@"ArtworkCell"]) {
        
        SGAnimatedArtworkViewManager *manager = [SGAnimatedArtworkViewManager shared];
        if (manager.playerLayer && (manager.activeContainer == self || manager.activeContainer == nil)) {
            manager.activeContainer = self;
            if (manager.playerLayer.superlayer != self.layer) {
                [self.layer addSublayer:manager.playerLayer];
            }

            SGForEachView(self, ^(UIView *v) {
                if ([v isKindOfClass:UIImageView.class]) {
                    v.alpha = 0.0;
                }
            });

            [CATransaction begin];
            [CATransaction setDisableActions:YES];
            manager.playerLayer.frame = self.bounds;
            [manager applyGradientMaskToLayer:manager.playerLayer bounds:self.bounds];
            [manager applyBrightnessSettingsToContainer:self];
            [CATransaction commit];
        }
    }
}

- (void)didMoveToWindow {
    %orig;
    if (!self.window) {
        SGAnimatedArtworkViewManager *manager = [SGAnimatedArtworkViewManager shared];
        if (manager.activeContainer == self) {
            [manager detach];
        }
    }
}

%end

%hook SPTNowPlayingModel

- (void)player:(id)player stateDidChange:(SPTPlayerState *)state {
    %orig;
    
    if (!SGFlag(SGKeyAnimatedCoversEnabled, YES)) {
        [[SGAnimatedArtworkViewManager shared] detach];
        return;
    }

    SGAnimatedArtworkViewManager *manager = [SGAnimatedArtworkViewManager shared];
    if (!manager.follower) {
        manager.follower = [[SGMotionFollower alloc] initWithBegin:^BOOL(NSString *uri, SPTPlayerState *st) {
            return SGFlag(SGKeyAnimatedCoversEnabled, YES);
        } found:^(NSString *uri, NSURL *file) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (file) {
                    [manager attachToView:manager.activeContainer videoURL:file];
                } else {
                    [manager detach];
                }
            });
        }];
    }
}

%end

%ctor {
    %init;
}
