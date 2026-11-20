// Fill DJ's Home and Recents placeholders with Spotify's own DJ artwork.
// Verified on 9.1.90: Artwork.Row.Library > EncoreImageView; HomeCard and
// RecentsListRow > Encore.ImageView > UIImageView + PlaceholderView.
#import "Core/SGCore.h"
#import "Shared/Player/DJQueue.h"
#import "Shared/Player/DJArtworkIdentity.h"
#import <objc/runtime.h>

static UIImage *SGDJCover;
static NSHashTable<UIView *> *SGDJHolders;
static NSInteger const SGDJCoverTag = 0x444a43;
static char SGDJOverlayKey;
static char SGDJRegisteredHolderKey;
static NSString *SGDJCoverPath(void) {
    return [NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject
        stringByAppendingPathComponent:@"SG-DJ-cover-v2.png"];
}
static void SGDJDraw(UIView *holder);
static NSDate *SGDJAsked;
// The DJ's own 9.1.90 card supplies this public cover URL (DJQueue's recorded image_url).
// It fills a fresh cache without visiting Library or borrowing artwork from reused cells.
static void SGDJLoad(void) {
    if (SGDJAsked && -SGDJAsked.timeIntervalSinceNow < 60) return;
    SGDJAsked = [NSDate date];
    NSURL *url = [NSURL URLWithString:@"https://lexicon-assets.spotifycdn.com/Your-DJ-Cover-Art-300.png"];
    [[NSURLSession.sharedSession dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        UIImage *cover = data.length && data.length < 8 * 1024 * 1024 ? [UIImage imageWithData:data] : nil;
        if (!cover) {

            return;
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            if (SGDJCover) return;
            SGDJCover = cover;
            NSString *path = SGDJCoverPath();
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{ [data writeToFile:path atomically:YES]; });
            for (UIView *holder in SGDJHolders.allObjects) SGDJDraw(holder);
        });
    }] resume];
}
static void SGDJDraw(UIView *holder) {
    UIView *row = SGDJArtworkEnclosingCard(holder);
    UIImageView *overlay = objc_getAssociatedObject(holder, &SGDJOverlayKey);
    BOOL confirmed = row && SGDJArtworkIsConfirmedCard(row);
    BOOL retry = NO;
    BOOL placeholderFallback = !confirmed && row && SGDJArtworkNeedsPlaceholder(row, holder, &retry);
    if (retry) {
        // Give Spotify's own artwork loader time to finish. A custom playlist
        // named DJ keeps its normal image if one arrives during this interval.
        __weak UIView *weakHolder = holder;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.85 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            UIView *current = weakHolder;
            if (current.window) SGDJDraw(current);
        });
    }
    if (!confirmed && !placeholderFallback) {
        [overlay removeFromSuperview];
        // A reused Spotify cell must not retain the previous DJ overlay.
        if (overlay) objc_setAssociatedObject(holder, &SGDJOverlayKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

        return;
    }
    if (!SGDJHolders) SGDJHolders = [NSHashTable weakObjectsHashTable];
    if (!objc_getAssociatedObject(holder, &SGDJRegisteredHolderKey)) {
        [SGDJHolders addObject:holder];
        objc_setAssociatedObject(holder, &SGDJRegisteredHolderKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (!SGDJCover) SGDJCover = [UIImage imageWithContentsOfFile:SGDJCoverPath()];
    if (!SGDJCover) {
        SGDJLoad();

        return;
    }
    if (!overlay) {
        overlay = [UIImageView new];
        overlay.tag = SGDJCoverTag;
        overlay.accessibilityIdentifier = @"SG.DJArtwork";
        overlay.userInteractionEnabled = NO;
        overlay.accessibilityElementsHidden = YES;
        overlay.contentMode = UIViewContentModeScaleAspectFill;
        overlay.clipsToBounds = YES;
        overlay.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        objc_setAssociatedObject(holder, &SGDJOverlayKey, overlay, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    // Avoid triggering repeated UIKit layout/compositing for unchanged artwork.
    // The same overlay object is reused while its Spotify holder remains a DJ card.
    if (overlay.superview != holder) [holder addSubview:overlay];
    if (!CGRectEqualToRect(overlay.frame, holder.bounds)) overlay.frame = holder.bounds;
    if (overlay.image != SGDJCover) overlay.image = SGDJCover;
    // Spotify's Home holders can have radius zero until their card is first tapped.
    // Other covers already have 4pt corners baked into their artwork; the DJ bitmap does not.
    // Keep the corner radius from Spotify when it is larger, but never draw a square DJ cover.
    CGFloat radius = MAX(4, holder.layer.cornerRadius);
    if (overlay.layer.cornerRadius != radius) overlay.layer.cornerRadius = radius;
    if (holder.subviews.lastObject != overlay) [holder bringSubviewToFront:overlay];

}
%hook SGDJCardImage
- (void)didMoveToWindow {
    %orig;
    SGDJDraw((UIView *)self);
}
- (void)layoutSubviews {
    %orig;
    SGDJDraw((UIView *)self);
}
%end
%ctor {
    // DJ artwork is part of the DJ Queue feature, not a global image replacement.
    if (!SGNativeUI() || !SGEnabled(SGKeyDJQueue)) return;
    %init(SGDJCardImage = objc_getClass("_TtCE15Encore_MediaKitO16EncoreFoundation6Encore9ImageView"));
}
