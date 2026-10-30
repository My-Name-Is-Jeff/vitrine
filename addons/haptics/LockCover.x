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

// Spotify's clip for the song into the shared caches, for MediaRemoteUI: copied beside it and moved over the last one,
// so a reader of the last one keeps its own file.
static void shareClip(void) {
    if (!sg_getApp) return;
    sg_getApp(dispatch_get_main_queue(), ^(CFStringRef bundle) {
        NSString *identifier = (__bridge NSString *)bundle;
        Class proxies = NSClassFromString(@"LSApplicationProxy");
        NSURL *container = identifier.length && proxies ? [[proxies applicationProxyForIdentifier:identifier] dataContainerURL] : nil;
        NSURL *clip = [container URLByAppendingPathComponent:@"Library/Caches/" kSGLockClipName];
        NSFileManager *files = NSFileManager.defaultManager;
        if (!clip || ![files fileExistsAtPath:clip.path]) {
            NSLog(@"[vitrine-addon] no clip in %@", identifier);
            return;
        }
        NSURL *shared = [NSURL fileURLWithPath:SGLockSharedClipPath()];
        [files createDirectoryAtURL:shared.URLByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
        NSURL *staging = [shared URLByAppendingPathExtension:@"part"];
        [files removeItemAtURL:staging error:nil];
        NSError *error = nil;
        BOOL done = [files copyItemAtURL:clip toURL:staging error:&error];
        if (done) {
            [files removeItemAtURL:shared error:nil];
            done = [files moveItemAtURL:staging toURL:shared error:&error];
        }
        if (!done) {
            NSLog(@"[vitrine-addon] the clip not shared: %@", error.localizedDescription);
            return;
        }
        notify_post(kSGRelayLockClipShared);
    });
}

%hook CSCoverSheetViewController
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
    notify_register_dispatch(kSGRelayLockClip, &clipToken, dispatch_get_main_queue(), ^(int t) { shareClip(); });
    notify_register_dispatch(kSGRelayLockClipNone, &noneToken, dispatch_get_main_queue(), ^(int t) {
        [NSFileManager.defaultManager removeItemAtPath:SGLockSharedClipPath() error:nil];
    });
    notify_register_dispatch(kSGRelayLockShowing, &showingToken, dispatch_get_main_queue(), ^(int t) { hideWidgets(YES); });
    notify_register_dispatch(kSGRelayLockNotShowing, &hiddenToken, dispatch_get_main_queue(), ^(int t) { hideWidgets(NO); });
}
