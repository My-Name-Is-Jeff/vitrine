// Fill DJ's Home and Recents placeholders with Spotify's own DJ artwork.
// Verified on 9.1.90: Artwork.Row.Library > EncoreImageView; HomeCard and
// RecentsListRow > Encore.ImageView > UIImageView + PlaceholderView.
#import "Core/SGCore.h"
#import "Shared/Player/DJQueue.h"
#import "Shared/Player/DJArtworkIdentity.h"
#import <objc/runtime.h>
#import "Redesigned/Kit/SGRKit.h"
#import "Home.h"

static UIImage *SGRDJCover;
static NSHashTable<UIView *> *SGRDJHolders;
static NSInteger const SGRDJCoverTag = 0x444a43;
static char SGRDJOverlayKey;
static char SGRDJRegisteredHolderKey;
static NSString *SGRDJCoverPath(void) {
    return [NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject
        stringByAppendingPathComponent:@"SGR-DJ-cover-v2.png"];
}
static void SGRDJDraw(UIView *holder);
static NSDate *SGRDJAsked;
// The DJ's own 9.1.90 card supplies this public cover URL (DJQueue's recorded image_url).
// It fills a fresh cache without visiting Library or borrowing artwork from reused cells.
static void SGRDJLoad(void) {
    if (SGRDJAsked && -SGRDJAsked.timeIntervalSinceNow < 60) return;
    SGRDJAsked = [NSDate date];
    NSURL *url = [NSURL URLWithString:@"https://lexicon-assets.spotifycdn.com/Your-DJ-Cover-Art-300.png"];
    [[NSURLSession.sharedSession dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        UIImage *cover = data.length && data.length < 8 * 1024 * 1024 ? [UIImage imageWithData:data] : nil;
        if (!cover) {

            return;
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            if (SGRDJCover) return;
            SGRDJCover = cover;
            NSString *path = SGRDJCoverPath();
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{ [data writeToFile:path atomically:YES]; });
            for (UIView *holder in SGRDJHolders.allObjects) SGRDJDraw(holder);
        });
    }] resume];
}
static void SGRDJDraw(UIView *holder) {
    UIView *row = SGDJArtworkEnclosingCard(holder);
    UIImageView *overlay = objc_getAssociatedObject(holder, &SGRDJOverlayKey);
    BOOL confirmed = row && SGDJArtworkIsConfirmedCard(row);
    BOOL retry = NO;
    BOOL placeholderFallback = !confirmed && row && SGDJArtworkNeedsPlaceholder(row, holder, &retry);
    if (retry) {
        // Give Spotify's own artwork loader time to finish. A custom playlist
        // named DJ keeps its normal image if one arrives during this interval.
        __weak UIView *weakHolder = holder;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.85 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            UIView *current = weakHolder;
            if (current.window) SGRDJDraw(current);
        });
    }
    if (!confirmed && !placeholderFallback) {
        [overlay removeFromSuperview];
        // A reused Spotify cell must not retain the previous DJ overlay.
        if (overlay) objc_setAssociatedObject(holder, &SGRDJOverlayKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

        return;
    }
    if (!SGRDJHolders) SGRDJHolders = [NSHashTable weakObjectsHashTable];
    if (!objc_getAssociatedObject(holder, &SGRDJRegisteredHolderKey)) {
        [SGRDJHolders addObject:holder];
        objc_setAssociatedObject(holder, &SGRDJRegisteredHolderKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (!SGRDJCover) SGRDJCover = [UIImage imageWithContentsOfFile:SGRDJCoverPath()];
    if (!SGRDJCover) {
        SGRDJLoad();

        return;
    }
    if (!overlay) {
        overlay = [UIImageView new];
        overlay.tag = SGRDJCoverTag;
        overlay.accessibilityIdentifier = @"SGR.DJArtwork";
        overlay.userInteractionEnabled = NO;
        overlay.accessibilityElementsHidden = YES;
        overlay.contentMode = UIViewContentModeScaleAspectFill;
        overlay.clipsToBounds = YES;
        overlay.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        objc_setAssociatedObject(holder, &SGRDJOverlayKey, overlay, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    // Avoid triggering repeated UIKit layout/compositing for unchanged artwork.
    // The same overlay object is reused while its Spotify holder remains a DJ card.
    if (overlay.superview != holder) [holder addSubview:overlay];
    if (!CGRectEqualToRect(overlay.frame, holder.bounds)) overlay.frame = holder.bounds;
    if (overlay.image != SGRDJCover) overlay.image = SGRDJCover;
    // Spotify's Home image holder starts square and often gets its radius only after a tap.
    // Match Home's cover/tile radius on the very first draw instead of inheriting that zero.
    NSString *kind = row.accessibilityIdentifier;
    CGFloat radius = 4;  // Recents uses the 4pt rounding baked into ordinary artwork.
    if ([kind isEqualToString:@"Components.UI.HomeCard"]) radius = SGRRadiusCover;
    else if ([kind isEqualToString:@"Shortcut.Card.Home"])
        radius = SGRHomeLook() ? SGRHomeTileRadius : SGRRadiusCover;
    radius = MAX(radius, holder.layer.cornerRadius);
    if (overlay.layer.cornerRadius != radius) overlay.layer.cornerRadius = radius;
    if (![overlay.layer.cornerCurve isEqualToString:kCACornerCurveContinuous])
        overlay.layer.cornerCurve = kCACornerCurveContinuous;
    if (holder.subviews.lastObject != overlay) [holder bringSubviewToFront:overlay];

}
%hook SGRDJCardImage
- (void)didMoveToWindow {
    %orig;
    SGRDJDraw((UIView *)self);
}
- (void)layoutSubviews {
    %orig;
    SGRDJDraw((UIView *)self);
}
%end
%ctor {
    // DJ artwork is part of the DJ Queue feature, not a global image replacement.
    if (!SGRedesignedUI() || !SGEnabled(SGKeyDJQueue)) return;
    %init(SGRDJCardImage = objc_getClass("_TtCE15Encore_MediaKitO16EncoreFoundation6Encore9ImageView"));
}
