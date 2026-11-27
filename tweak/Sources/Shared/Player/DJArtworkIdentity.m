#import "DJArtworkIdentity.h"
#import <objc/runtime.h>
#import <QuartzCore/QuartzCore.h>

static NSString *const kSpotifyDJURI = @"spotify:playlist:37i9dQZF1EYkqdzj48dyYq";

// A displayed title is a hint, not identity. In particular a playlist named
// DJ is usually exposed as "DJ, Playlist, ..." on Recents/shortcuts.
static BOOL djTitle(NSString *title) {
    return [title isEqualToString:@"DJ"] || [title hasPrefix:@"DJ,"] || [title hasPrefix:@"DJ."] ||
           [title hasPrefix:@"Your DJ"] || [title hasPrefix:@"AI DJ"];
}
// In Spotify 9.1.90, Home and Recents identify both the real AI DJ and a
// user playlist as "DJ, Playlist". The FINAL accessibility publisher field is
// different: "DJ, Playlist, Spotify" vs "DJ, Playlist, <owner>" (Recents may
// include a play-count sentence before the playlist type). Do not infer the
// publisher from an arbitrary occurrence of the word "Spotify" in the title.
typedef NS_ENUM(NSInteger, SGDJArtworkPublisher) {
    SGDJArtworkPublisherUnknown = 0,
    SGDJArtworkPublisherSpotify,
    SGDJArtworkPublisherOther,
};
static NSString *sgDJTrim(NSString *value) {
    return [value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
}
static SGDJArtworkPublisher sgDJCardPublisher(UIView *card) {
    if (!card || !djTitle(card.accessibilityLabel)) return SGDJArtworkPublisherUnknown;
    NSString *kind = card.accessibilityIdentifier;
    if (![kind isEqualToString:@"Components.UI.HomeCard"] &&
        ![kind isEqualToString:@"Components.UI.RecentsListRow"] &&
        ![kind isEqualToString:@"Shortcut.Card.Home"]) return SGDJArtworkPublisherUnknown;
    NSArray<NSString *> *parts = [card.accessibilityLabel componentsSeparatedByString:@","];
    if (parts.count < 2) return SGDJArtworkPublisherUnknown;
    NSString *category = sgDJTrim(parts[parts.count - 2]);
    // Recents sometimes uses "DJ. Playlist, Publisher" (two comma fields).
    BOOL playlistCategory = [category caseInsensitiveCompare:@"Playlist"] == NSOrderedSame ||
        [category.lowercaseString hasSuffix:@". playlist"];
    if (!playlistCategory) return SGDJArtworkPublisherUnknown;
    NSString *publisher = sgDJTrim(parts.lastObject);
    if (!publisher.length) return SGDJArtworkPublisherUnknown;
    return [publisher caseInsensitiveCompare:@"Spotify"] == NSOrderedSame ?
        SGDJArtworkPublisherSpotify : SGDJArtworkPublisherOther;
}

static BOOL containsDJIdentity(NSString *value) {
    if (!value.length) return NO;
    if ([value containsString:kSpotifyDJURI]) return YES;
    NSString *text = value.lowercaseString;
    // These describe Spotify's assistant, not a generic "DJ" playlist name.
    return [text containsString:@"your ai dj"] || [text containsString:@"spotify ai dj"] ||
           [text containsString:@"your personal dj"];
}
static BOOL editorialDJIdentity(NSString *value) {
    if (!value.length) return NO;
    NSString *text = value.lowercaseString;
    // Official DJ entries are sometimes published as *playlists* in Recents,
    // while the model URI never reaches UIKit accessibility fields. Do not
    // mistake the word "playlist" for proof that the card is user-created.
    // These are additional publisher/curation hints, not the DJ title alone.
    return [text containsString:@"made for you"] ||
           [text containsString:@"your own personal dj"] ||
           [text containsString:@"your own dj"] ||
           [text containsString:@"by spotify"] ||
           [text containsString:@"spotify's dj"];
}
static BOOL isDedicatedDJComponent(UIView *card) {
    // Unlike a title, Spotify's dedicated DJ Home component is not an
    // arbitrary playlist and cannot be impersonated by naming a playlist DJ.
    for (UIView *v = card, *stop = card.superview.superview.superview.superview; v && v != stop; v = v.superview) {
        NSString *name = NSStringFromClass(v.class);
        if ([name containsString:@"DJMDCView"] ||
            [name containsString:@"DJMDCElement"] ||
            [name containsString:@"Discovery_DJElementKit"]) return YES;
        // These hooks are used from an image under a known card: do not walk
        // outside the card into neighbouring, unrelated Home elements.
        if ([v isKindOfClass:UIWindow.class]) break;
    }
    return NO;
}
static BOOL viewIdentifiesDJ(UIView *view, NSUInteger depth) {
    if (!view || depth > 8) return NO;
    if (containsDJIdentity(view.accessibilityIdentifier) || containsDJIdentity(view.accessibilityLabel) ||
        containsDJIdentity(view.accessibilityValue) ||
        containsDJIdentity(view.accessibilityHint)) return YES;
    for (UIView *child in view.subviews) if (viewIdentifiesDJ(child, depth + 1)) return YES;
    return NO;
}
static BOOL viewHasEditorialDJIdentity(UIView *view, NSUInteger depth) {
    if (!view || depth > 6) return NO;
    if (editorialDJIdentity(view.accessibilityLabel) || editorialDJIdentity(view.accessibilityValue) ||
        editorialDJIdentity(view.accessibilityHint)) return YES;
    for (UIView *child in view.subviews) if (viewHasEditorialDJIdentity(child, depth + 1)) return YES;
    return NO;
}
@interface SGDJArtworkCardCache : NSObject
@property (nonatomic, weak) UIView *parent;
@property (nonatomic, weak) UIView *card;
@property (nonatomic, weak) UIWindow *window;
@property (nonatomic) CFAbsoluteTime checkedAt;
@end
@implementation SGDJArtworkCardCache
@end
static char kArtworkCardCacheKey;
UIView *SGDJArtworkEnclosingCard(UIView *holder) {
    if (!holder) return nil;
    SGDJArtworkCardCache *cache = objc_getAssociatedObject(holder, &kArtworkCardCacheKey);
    UIView *parent = holder.superview;
    UIWindow *window = holder.window;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    // If no card was found, allow the wrapper to finish mounting lazily.
    // Weak references prevent retaining recycled Spotify cells.
    if (cache && cache.parent == parent && cache.window == window &&
        ((cache.card && [holder isDescendantOfView:cache.card]) ||
         (!cache.card && now - cache.checkedAt < 0.25))) return cache.card;
    UIView *card = parent;
    while (card && ![card.accessibilityIdentifier isEqualToString:@"Components.UI.HomeCard"] &&
           ![card.accessibilityIdentifier isEqualToString:@"Shortcut.Card.Home"] &&
           ![card.accessibilityIdentifier isEqualToString:@"Components.UI.RecentsListRow"]) card = card.superview;
    if (!cache) {
        cache = [SGDJArtworkCardCache new];
        objc_setAssociatedObject(holder, &kArtworkCardCacheKey, cache, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    cache.parent = parent;
    cache.window = window;
    cache.card = card;
    cache.checkedAt = now;
    return card;
}

// The fallback is limited to cards published by Spotify; a DJ title and an
// absent raster are never sufficient evidence for a user-created playlist.
@interface SGDJArtworkPlaceholderState : NSObject
@property (nonatomic, weak) UIView *card;
@property (nonatomic) CFAbsoluteTime firstMissing;
@property (nonatomic) BOOL resolvedNativeArtwork;
@end
@implementation SGDJArtworkPlaceholderState
@end
static char kMissingArtStateKey;

static BOOL sgIsVitrineOverlay(UIView *view) {
    NSString *identifier = view.accessibilityIdentifier;
    return [identifier hasPrefix:@"SG.DJArtwork"] ||
           [identifier hasPrefix:@"SGR.DJArtwork"];
}

static BOOL sgIsPlaceholder(UIView *view) {
    return [NSStringFromClass(view.class) containsString:@"Placeholder"];
}

// The Spotify cover may be backed by UIImageView.image *or* by a layer with
// contents (Encore and SwiftUI do not always expose a UIImageView to callers).
// Never count our own overlay or Spotify's placeholder as native artwork.
static BOOL sgNativeRasterLayer(CALayer *layer, NSUInteger depth) {
    if (!layer || depth > 8) return NO;
    id delegate = layer.delegate;
    if ([delegate isKindOfClass:UIView.class]) {
        UIView *view = (UIView *)delegate;
        if (sgIsVitrineOverlay(view) || sgIsPlaceholder(view)) return NO;
    }
    if (layer.contents) return YES;
    for (CALayer *child in layer.sublayers)
        if (sgNativeRasterLayer(child, depth + 1)) return YES;
    return NO;
}
static BOOL sgNativeUIImage(UIView *view, NSUInteger depth) {
    if (!view || depth > 8 || sgIsVitrineOverlay(view) || sgIsPlaceholder(view)) return NO;
    if ([view isKindOfClass:UIImageView.class] && ((UIImageView *)view).image &&
        !view.hidden && view.alpha > 0.01) return YES;
    for (UIView *child in view.subviews)
        if (sgNativeUIImage(child, depth + 1)) return YES;
    return NO;
}

// The publisher (final accessibility field) is required for a generic Home or
// Recents playlist card. Native artwork remains authoritative for fallbacks;
// a user-created playlist titled DJ is rejected even if it has no bitmap.
BOOL SGDJArtworkNeedsPlaceholder(UIView *card, UIView *holder, BOOL *retry) {
    if (retry) *retry = NO;
    if (!holder) return NO;
    // Fail closed for an unknown publisher. A custom playlist called "DJ" must
    // never qualify solely because its own artwork is missing or delayed.
    BOOL candidate = sgDJCardPublisher(card) == SGDJArtworkPublisherSpotify;
    SGDJArtworkPlaceholderState *state = objc_getAssociatedObject(holder, &kMissingArtStateKey);
    if (!candidate) {
        if (state) objc_setAssociatedObject(holder, &kMissingArtStateKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return NO;
    }
    if (!state || state.card != card) {
        state = [SGDJArtworkPlaceholderState new];
        state.card = card;
        objc_setAssociatedObject(holder, &kMissingArtStateKey, state, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (state.resolvedNativeArtwork) return NO;
    if (sgNativeUIImage(holder, 0) || sgNativeRasterLayer(holder.layer, 0)) {
        // Native art is authoritative even if a stale PlaceholderView remains.
        // The caller removes any previously attached Vitrine overlay.
        state.resolvedNativeArtwork = YES;
        state.firstMissing = 0;
        return NO;
    }
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (state.firstMissing <= 0) {
        state.firstMissing = now;
        if (retry) *retry = YES;
    }
    return now - state.firstMissing >= 0.8;
}

// Frame-scoped identity results avoid traversing the same DJ card's accessibility
// subtree repeatedly during nested layoutSubviews callbacks. The short window
// avoids keeping a stale negative result when Spotify finishes mounting a card.
@interface SGDJArtworkIdentityFrame : NSObject
@property (nonatomic, copy) NSString *label;
@property (nonatomic, copy) NSString *identifier;
@property (nonatomic, weak) UIWindow *window;
@property (nonatomic) CFTimeInterval checkedAt;
@property (nonatomic) BOOL confirmed;
@end
@implementation SGDJArtworkIdentityFrame
@end
static char kDJArtworkIdentityFrameKey;

BOOL SGDJArtworkIsConfirmedCard(UIView *card) {
    if (!card || !djTitle(card.accessibilityLabel)) return NO;
    SGDJArtworkPublisher publisher = sgDJCardPublisher(card);
    // A publisher other than Spotify is authoritative even if a generic DJ
    // label or a descendant happens to contain an editorial phrase.
    if (publisher == SGDJArtworkPublisherOther) return NO;
    NSString *label = card.accessibilityLabel;
    NSString *identifier = card.accessibilityIdentifier;
    UIWindow *window = card.window;
    CFTimeInterval now = CACurrentMediaTime();
    SGDJArtworkIdentityFrame *frame = objc_getAssociatedObject(card, &kDJArtworkIdentityFrameKey);
    // One 120 Hz display frame is the maximum cache lifetime, and cell reuse,
    // label changes and remounting immediately invalidate it.
    if (frame && now >= frame.checkedAt && now - frame.checkedAt < (1.0 / 120.0) &&
        frame.window == window &&
        ((frame.label == label) || [frame.label isEqualToString:label]) &&
        ((frame.identifier == identifier) || [frame.identifier isEqualToString:identifier]))
        return frame.confirmed;
    BOOL explicitIdentity = containsDJIdentity(card.accessibilityLabel) || viewIdentifiesDJ(card, 0);
    BOOL dedicated = !explicitIdentity && isDedicatedDJComponent(card);
    BOOL editorial = !explicitIdentity && !dedicated &&
        (editorialDJIdentity(card.accessibilityLabel) || viewHasEditorialDJIdentity(card, 0));
    BOOL confirmed = explicitIdentity || dedicated || editorial;
    if (publisher == SGDJArtworkPublisherSpotify) confirmed = YES;
    if (!frame) {
        frame = [SGDJArtworkIdentityFrame new];
        objc_setAssociatedObject(card, &kDJArtworkIdentityFrameKey, frame, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    frame.label = label;
    frame.identifier = identifier;
    frame.window = window;
    frame.checkedAt = now;
    frame.confirmed = confirmed;

    return confirmed;
}
