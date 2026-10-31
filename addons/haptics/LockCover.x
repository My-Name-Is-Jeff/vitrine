// Vitrine Addon in SpringBoard, the lock screen's Canvas below iOS 26: SpringBoard's share of it. The lock screen's
// player and its large cover are drawn by MediaRemoteUI, which only shows in SpringBoard's lock screen as a scene of its
// own (the cover sheet has neither, MediaRemoteUI has both), so the clip is put in the
// large cover's place there (MediaRemoteUICanvas.x). Here:
//
//   the clip    Spotify's for the song (kSGRelayLockClip), read through the data container of the now playing app and
//               copied to the jailbreak's shared caches (SGLockSharedClipPath), where MediaRemoteUI, sandboxed, can read
//               it; MediaRemoteUI is told by kSGRelayLockClipShared. kSGRelayLockClipNone comes from Spotify to both.
//   the widgets the row under the clock (CSProminentEmptyElementView) hidden while
//               MediaRemoteUI shows the clip (kSGRelayLockShowing), and given back as it stops.
//   the lyrics  Spotify's lines for the song (kSGRelayLockLyrics), shared the same way (SGLockSharedLyricsPath,
//               kSGRelayLockLyricsShared); and the choice between them and the Canvas that MediaRemoteUI's button makes,
//               kept in the add-on's own preferences for the next song and the next boot, and told MediaRemoteUI again
//               as it asks (kSGRelayLockModeAsk) and as SpringBoard starts.
//   the touches the large cover takes none (MediaRemoteUI draws it behind the cover sheet), so while MediaRemoteUI shows it
//               a catcher lies over the notification list where its lyrics are (kSGRelayLockGestureArea), letting the
//               touches on the player and the notifications through wherever the list has scrolled them: with the lyrics up it takes every touch there and hands drags and taps to
//               MediaRemoteUI, so the lyrics scroll and seek and the cover stays open; with them off it lets a tap on the
//               clip or cover itself through to the list, which closes the cover, and keeps the rest.
//
// Nothing is walked or hooked on the lock screen's layout: the widgets' row is looked for only as it is to be hidden.
//
// Threading: the notifications and MediaRemote's answers come on the main queue.
#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <notify.h>
#import "../../tweak/Sources/Shared/Haptics/SGHapticRelay.h"

@interface CSCoverSheetViewController : UIViewController
@end

@interface LSApplicationProxy : NSObject
+ (instancetype)applicationProxyForIdentifier:(NSString *)identifier;
@property (nonatomic, readonly) NSURL *dataContainerURL;
@end

typedef void (*SGMRGetApp)(dispatch_queue_t queue, void (^handler)(CFStringRef bundle));

static const NSTimeInterval kFade = 0.35;

static SGMRGetApp sg_getApp;
static __weak UIView *sg_sheet;   // the cover sheet's view
static NSHashTable<UIView *> *sg_hidden;

// The widgets' row under the clock, wherever the cover sheet keeps it.
static void collectRows(UIView *root, NSMutableArray<UIView *> *rows, int depth) {
    if (depth > 30) return;
    for (UIView *sub in root.subviews) {
        if ([NSStringFromClass(sub.class) isEqualToString:@"CSProminentEmptyElementView"]) {
            [rows addObject:sub];
            continue;
        }
        collectRows(sub, rows, depth + 1);
    }
}

static void hideWidgets(BOOL away) {
    if (!sg_hidden) sg_hidden = [NSHashTable weakObjectsHashTable];
    NSArray<UIView *> *views = sg_hidden.allObjects;
    if (away) {
        NSMutableArray<UIView *> *rows = [NSMutableArray array];
        if (sg_sheet) collectRows(sg_sheet, rows, 0);
        for (UIView *row in rows) [sg_hidden addObject:row];
        views = rows;
    } else {
        [sg_hidden removeAllObjects];
    }
    for (UIView *view in views) {
        [UIView animateWithDuration:kFade delay:0 options:UIViewAnimationOptionBeginFromCurrentState
                         animations:^{ view.alpha = away ? 0 : 1; } completion:nil];
    }
}

// A file of the now playing app's caches into the jailbreak's shared caches, for MediaRemoteUI: copied beside it and
// moved over the last one, so a reader of the last one keeps its own file; `shared` posted once it is there.
static void share(NSString *name, NSString *sharedPath, const char *shared) {
    if (!sg_getApp) return;
    sg_getApp(dispatch_get_main_queue(), ^(CFStringRef bundle) {
        NSString *identifier = (__bridge NSString *)bundle;
        Class proxies = NSClassFromString(@"LSApplicationProxy");
        NSURL *container = identifier.length && proxies ? [[proxies applicationProxyForIdentifier:identifier] dataContainerURL] : nil;
        NSURL *source = [container URLByAppendingPathComponent:[@"Library/Caches/" stringByAppendingString:name]];
        NSFileManager *files = NSFileManager.defaultManager;
        if (!source || ![files fileExistsAtPath:source.path]) {
            NSLog(@"[vitrine-addon] no %@ in %@", name, identifier);
            return;
        }
        NSURL *target = [NSURL fileURLWithPath:sharedPath];
        [files createDirectoryAtURL:target.URLByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
        NSURL *staging = [target URLByAppendingPathExtension:@"part"];
        [files removeItemAtURL:staging error:nil];
        NSError *error = nil;
        BOOL done = [files copyItemAtURL:source toURL:staging error:&error];
        if (done) {
            [files removeItemAtURL:target error:nil];
            done = [files moveItemAtURL:staging toURL:target error:&error];
        }
        if (!done) {
            NSLog(@"[vitrine-addon] %@ not shared: %@", name, error.localizedDescription);
            return;
        }
        notify_post(shared);
    });
}

static NSString *const kLyricsPickedKey = @"lockLyricsPicked";

static BOOL sg_coverShowing;
static SGLockGestureAreaState sg_area;

// The catcher over the lyrics. Its window's points are the screen's, as the area's are.
@interface SGVLockTouchCatcher : UIView
@end

@implementation SGVLockTouchCatcher

- (instancetype)initWithFrame:(CGRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    self.backgroundColor = UIColor.clearColor;
    [self addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(dragged:)]];
    [self addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(tapped:)]];
    return self;
}

// Whether the cover sheet's own views under the catcher have a player or a notification at `point`: the list scrolls
// them anywhere, the lyrics' band among them, and they keep their touches there.
- (BOOL)platterAt:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *sheet = self.superview;
    Class platter = NSClassFromString(@"PLPlatterView");
    for (UIView *sibling in sheet.subviews.reverseObjectEnumerator) {
        if (sibling == self || sibling.hidden || sibling.alpha < 0.01 || !sibling.userInteractionEnabled) continue;
        UIView *hit = [sibling hitTest:[self convertPoint:point toView:sibling] withEvent:event];
        if (!hit) continue;
        for (UIView *view = hit; view && view != sheet; view = view.superview) {
            if (platter && [view isKindOfClass:platter]) return YES;
        }
        return NO;
    }
    return NO;
}

// With the lyrics off, a tap on the clip or cover itself is the list's, which closes the large cover; a player or a
// notification over the band is always the list's.
- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    if (![super pointInside:point withEvent:event]) return NO;
    if ([self platterAt:point withEvent:event]) return NO;
    if (sg_area.lyricsShown) return YES;
    CGFloat y = [self convertPoint:point toView:nil].y;
    return !(y >= sg_area.coverTop && y <= sg_area.coverBottom);
}

static void tell(const char *name, uint64_t state) {
    int token = 0;
    if (notify_register_check(name, &token) != NOTIFY_STATUS_OK) return;
    notify_set_state(token, state);
    notify_post(name);
    notify_cancel(token);
}

- (void)dragged:(UIPanGestureRecognizer *)pan {
    if (!sg_area.lyricsShown) return;
    int phase = pan.state == UIGestureRecognizerStateBegan ? 0 : pan.state == UIGestureRecognizerStateChanged ? 1 : 2;
    if (phase == 2 && pan.state != UIGestureRecognizerStateEnded && pan.state != UIGestureRecognizerStateCancelled) return;
    tell(kSGRelayLockGesturePan, SGLockGesturePan(phase, [pan translationInView:nil].y, [pan velocityInView:nil].y));
}

- (void)tapped:(UITapGestureRecognizer *)tap {
    if (!sg_area.lyricsShown) return;   // beside the cover with the lyrics off: kept, and nothing done
    tell(kSGRelayLockGestureTap, SGLockGestureTap([tap locationInView:nil]));
}

@end

static SGVLockTouchCatcher *sg_catcher;

// The catcher where the lyrics are while MediaRemoteUI shows the large cover, gone when it does not.
static void placeCatcher(void) {
    UIView *sheet = sg_sheet;
    BOOL wanted = sg_coverShowing && sheet.window && sg_area.lyricsBottom > sg_area.lyricsTop;
    if (!wanted) {
        [sg_catcher removeFromSuperview];
        return;
    }
    if (!sg_catcher) sg_catcher = [[SGVLockTouchCatcher alloc] initWithFrame:CGRectZero];
    CGRect screen = CGRectMake(0, sg_area.lyricsTop, sheet.window.bounds.size.width, sg_area.lyricsBottom - sg_area.lyricsTop);
    if (sg_catcher.superview != sheet) [sheet addSubview:sg_catcher];
    else if (sheet.subviews.lastObject != sg_catcher) [sheet bringSubviewToFront:sg_catcher];
    CGRect frame = [sheet convertRect:screen fromView:nil];
    if (!CGRectEqualToRect(sg_catcher.frame, frame)) sg_catcher.frame = frame;
}

static NSUserDefaults *addonDefaults(void) {
    static NSUserDefaults *defaults;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ defaults = [[NSUserDefaults alloc] initWithSuiteName:@"com.vitrine.addon"]; });
    return defaults;
}

static void tellPicked(void) {
    notify_post([addonDefaults() boolForKey:kLyricsPickedKey] ? kSGRelayLockModeLyrics : kSGRelayLockModeCanvas);
}

// The cover sheet lays itself out again as its list is dragged (the player, the clock or the notifications pulled), and
// its own views can come up over the catcher then: it goes back on top on every pass while the large cover is open.
%hook CSCoverSheetViewController
- (void)viewDidLayoutSubviews {
    %orig;
    if (sg_coverShowing) placeCatcher();
}
- (void)viewDidLoad {
    %orig;
    sg_sheet = ((UIViewController *)self).view;
}
%end

%ctor {
    if (![NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.apple.springboard"]) return;
    if (@available(iOS 26.0, *)) return;
    void *remote = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW);
    sg_getApp = remote ? (SGMRGetApp)dlsym(remote, "MRMediaRemoteGetNowPlayingApplicationDisplayID") : NULL;
    %init;
    int clipToken, noneToken, showingToken, hiddenToken;
    notify_register_dispatch(kSGRelayLockClip, &clipToken, dispatch_get_main_queue(), ^(int t) {
        share(@kSGLockClipName, SGLockSharedClipPath(), kSGRelayLockClipShared);
    });
    int lyricsToken, lyricsPickedToken, canvasPickedToken, askToken;
    notify_register_dispatch(kSGRelayLockLyrics, &lyricsToken, dispatch_get_main_queue(), ^(int t) {
        share(@kSGLockLyricsName, SGLockSharedLyricsPath(), kSGRelayLockLyricsShared);
    });
    // The button's choice kept; a post of it here answers MediaRemoteUI, which hears its own the same way.
    notify_register_dispatch(kSGRelayLockModeLyrics, &lyricsPickedToken, dispatch_get_main_queue(), ^(int t) {
        [addonDefaults() setBool:YES forKey:kLyricsPickedKey];
    });
    notify_register_dispatch(kSGRelayLockModeCanvas, &canvasPickedToken, dispatch_get_main_queue(), ^(int t) {
        [addonDefaults() setBool:NO forKey:kLyricsPickedKey];
    });
    notify_register_dispatch(kSGRelayLockModeAsk, &askToken, dispatch_get_main_queue(), ^(int t) { tellPicked(); });
    tellPicked();
    notify_register_dispatch(kSGRelayLockClipNone, &noneToken, dispatch_get_main_queue(), ^(int t) {
        [NSFileManager.defaultManager removeItemAtPath:SGLockSharedClipPath() error:nil];
    });
    notify_register_dispatch(kSGRelayLockShowing, &showingToken, dispatch_get_main_queue(), ^(int t) {
        hideWidgets(YES);
        sg_coverShowing = YES;
        placeCatcher();
    });
    notify_register_dispatch(kSGRelayLockNotShowing, &hiddenToken, dispatch_get_main_queue(), ^(int t) {
        hideWidgets(NO);
        sg_coverShowing = NO;
        placeCatcher();
    });
    int areaToken;
    notify_register_dispatch(kSGRelayLockGestureArea, &areaToken, dispatch_get_main_queue(), ^(int t) {
        uint64_t state = 0;
        if (notify_get_state(t, &state) != NOTIFY_STATUS_OK) return;
        sg_area = SGLockGestureAreaRead(state);
        placeCatcher();
    });
}
