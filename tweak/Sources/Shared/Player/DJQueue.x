// The AI DJ's queue on Spotify's own queue page. The DJ's session is one track playing, and the player's queue
// (SPTPlayerQueue) holds nothing of the DJ's after it, though the player's state knows the tracks that follow
// (SPTPlayerState.future: the DJ's segment, five tracks and the voice between them). Those are put in the queue
// before each of its readers takes it, after the hand-queued tracks and in the DJ's order, so they draw the tracks
// as they draw any tracks to come: its rows, Spotify's. The readers are the queue page's own two observers (the page
// does not go through the Up next card's provider) and that provider.
//
// Only the DJ's session is touched (isDJSession): in any other context every hook here passes Spotify's own through.
// The switch is SGKeyDJQueue (DJQueue.h), on until switched off, read at launch.
//
// The player's subscription asks the core for the state with a cap on the tracks to come
// (ESPGetStateRequest.nextTracksCap), two at first; it is raised here so the state's future is the whole segment. The
// subscription is made once, at launch, before any context is known. Scoping it by the
// *current* state would permanently leave DJ with two tracks when playback starts later;
// do not do so. Only a request carrying an explicit context can be scoped. Remaining
// context-free subscriptions retain the larger cap outside DJ (see docs/pr227-getstate-cap-measurement.md). The core gives no more than one segment whatever the cap (9.1.90: with a
// cap of 80 the DJ's future was its 4 tracks and 2 voices); the next segment is made when the core comes to the last
// track of this one. The core asks for it itself: the app gives it no context page then (no play, updateContext or
// updateContextPage, 9.1.90), so there is nothing here to ask it earlier with.
//
// The DJ's "Up next" card is its own row, before the track it introduces; the track's row has no title (the core
// names it only when it plays) and no card cover. The card and its track have one uid, and the page's rows are told
// apart by it, so the card's row has a uid of its own (the track's with a suffix); the core is only ever given the
// player's own tracks, never these rows' copies.
//
// Between two segments the core has no tracks to come for a moment; the rows the page had stay for it (up to
// kGapSeconds) instead of going empty.
//
// The core keeps ten tracks behind the DJ's current one. The tracks the DJ has played are kept here whole (uri, uid,
// metadata), and a step back with none left behind in the state asks the core to skip to the one before the current
// by its uid, in the same session; if the core does not move, it is not asked again in that session.
//
// The core does not have the DJ's tracks in its queue, so what the page does to them (a swipe to remove, to queue or
// to play next, a drag) the core cannot do. A removed track is hidden here (sHidden, by its uid) and the player skips
// it if it still comes up; a track queued or played next by hand is the core's own queued track, and its DJ row is
// hidden so it shows once. The DJ's tracks are left out of the queue the core is given. Every command the page gives
// for the queue is logged (a drag in the DJ's segment is only logged: the core's order is not the page's to change).
//
// The order the user gave the DJ's rows (a drag on the page) is kept here (sOrder), over a copy of the rows the DJ has sent
// (sKept: the core's own future forgets the tracks it has been moved past). The core does not take another order for
// them (a setQueue with the DJ's tracks rearranged leaves its future as it was, 9.1.90), so the page shows that order and
// the player is held to it: when the core comes to a DJ track that is not the first of ours, it is skipped to the first
// of ours. A track with an "Up next" card is skipped to through its voice, wherever the drag put it, so the voice plays.
// Spotify's now playing screens are shown the state with its future in the user's order (djLens), so the cover list
// moves forward to the track the skip goes to, though the core may have stepped back to it.
// The user's next is put in the core's queue as the track before it starts (queueAhead), so a track that ends by itself
// goes on to it and not to the core's own for a moment. A track played from the core's queue is a copy, which Spotify
// draws as queued by hand; the now playing screens are shown it as the DJ's track it stands for (sCopyOf).
// With nothing of the segment left but removed or played tracks, the player crosses the spent context under the
// render-thread mute, to the segment anchor and then to the newly loaded DJ page. Do not toggle native Pause/Play;
// a paused hand-over can be visible and takes longer than the actual targeted skips.
// The order, what was removed or played, the voices heard and the copies are kept over a launch (SGKeyDJQueueSession).
// A tap on a row passes the DJ's rows before it (they are hidden). The row of the "Up next" card has no swipe actions.
// The page takes a tap on one of the tracks for a row of the core's queue, which it is not, and gives no command; it
// is skipped to as the player's here.
#import <objc/runtime.h>
#import <objc/message.h>
#import "Core/SGCore.h"
#import "Core/SGLog.h"
#import "PlayerState.h"
#import "DJQueue.h"
#import "DJPick.h"
#import "SpeedPitch.h"
#import "Shared/AlbumQueue/AlbumQueue.h"
#import "DJQueueHeader.h"

// Persistent models, queue order, identities and session restoration.
#include "DJQueueState.inc"
// Core queue commands, logical order and transitions.
#include "DJQueuePlayback.inc"
%hook _TtC16Queue_UpNextImpl19UpNextTrackProvider
- (void)player:(id)player queueDidChange:(id)queue {
    id forward = queue;
    if (lineUpTheFuture(self, player, queue, &forward)) return;
    %orig(player, forward);
}
%end

%hook _TtC14Queue_ViewImpl22PlayerStateEventSource
- (void)player:(id)player queueDidChange:(id)queue {
    id forward = queue;
    if (lineUpTheFuture(self, player, queue, &forward)) return;
    %orig(player, forward);
}
%end

%hook _TtC14Queue_ViewImpl20QueuedTracksObserver
- (void)player:(id)player queueDidChange:(id)queue {
    id forward = queue;
    if (lineUpTheFuture(self, player, queue, &forward)) return;
    %orig(player, forward);
}
%end

// The queue table's diffable data source reconfigures a row by asking the page's cell provider for it again, and the
// provider reads the page's own list, which can already be the next one: the snapshot had five rows and the provider four
// (the skip to a later DJ track took the first away), so for the fifth it gave a bare UITableViewCell and UIKit aborted
// ("returned a different cell ... than the cell being reconfigured", path 1-4, on the phone). The queue table is never
// reconfigured: it is loaded again once the update is in, which takes whatever cell the provider gives.
static BOOL sReloadQueued;
%hook UITableView
- (void)reconfigureRowsAtIndexPaths:(NSArray<NSIndexPath *> *)paths {
    static Class queueSource;
    if (!queueSource) queueSource = NSClassFromString(@"_TtC14Queue_ViewImpl38QueueTableViewDataSourceImplementation");
    if (!sDJActive || !queueSource || ![(id)self.dataSource isKindOfClass:queueSource]) {
        %orig;
        return;
    }
    if (sReloadQueued) return;
    sReloadQueued = YES;
    __weak UITableView *weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        sReloadQueued = NO;
        [weakSelf reloadData];
    });
}
%end

// The drag handle of a row is UIKit's UITableViewCellReorderControl, a view of the cell itself, right of the content.
// On rows the page made late it stays at {0, 0}, over the cover, and on a row the page reloads mid-change UIKit can
// leave it stretched at the far right ({355, 0, 27, 64} beside {342, 10, 44, 44}). Every handle is given the frame of
// one UIKit laid out the usual way, a square right of the content; until one is known, a late handle goes to the right
// edge of the content.
static CGRect sHandleFrame = {{-1, 0}, {0, 0}};
static __weak UIView *sUIKitHandle;
static void alignHeaderPlay(UIView *page);
// While Spotify is switching to Edit, the native Edit pill can remain visible
// for a layout pass. Do not let a queued redraw resurrect our action meanwhile.
static BOOL queueInEdit(UIView *page);
static void drawNewSegmentButton(UIView *page);
// On first presentation the Edit control and the DJ queue arrive on different
// layout passes. Redraw during that short interval instead of waiting for the
// half-second header timer (which used to make the button pop in late).
static void drawNewSegmentButtonSoon(UIView *page) {
    if (!page) return;
    for (NSNumber *delay in @[@0, @0.04, @0.12, @0.25]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay.doubleValue * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (page == sQueuePageView && page.window) drawNewSegmentButton(page);
        });
    }
}
// Behaviour and current DJ state belong to Shared. Each look independently
// renders this action beside Spotify's Edit pill, through DJQueueHeader.h.
void SGDJQueueNextSetTapped(void) {
    BOOL allowed = SGEnabled(SGKeyDJQueuePickButton) && sDJActive && !sPickingSegment && !sHandingOver &&
        isDJSession(SGPlayerState());

    if (!allowed) return;
    if (SGInt(SGKeyDJQueueSetMode, SGDJQueueSetModeSkip) != SGDJQueueSetModeRequest) {
        skipToNextDJSegment();
        return;
    }
    SGDJPickRequest(queuePlayer(), ^(NSError *error) {
        if (error && error.code != NSUserCancelledError) {
            [SGAlbumQueueNotice showIn:sQueuePageView.window title:@"Couldn't change DJ set"
                               detail:error.localizedDescription symbol:@"exclamationmark.circle"];
        }
    });
}
static void renderNextDJSet(UIView *page, UIView *edit, BOOL visible) {
    BOOL requestMode = SGInt(SGKeyDJQueueSetMode, SGDJQueueSetModeSkip) == SGDJQueueSetModeRequest;
    BOOL enabled = !sPickingSegment && !sHandingOver && (!requestMode ||
        [queuePlayer() respondsToSelector:NSSelectorFromString(@"signal:parameters:options:loggingParams:")]);
    NSString *title = sPickingSegment ? @"Changing…" : @"Next DJ Set";
    if (SGRedesignedUI()) SGRDJQueueDrawNextSet(page, edit, visible, enabled, requestMode, title);
    else SGDJNativeDrawNextSet(page, edit, visible, enabled, requestMode, title);
}
static void hideNextDJSet(UIView *page) {
    if (!page) return;
    renderNextDJSet(page, nil, NO);
}
static void drawNewSegmentButton(UIView *page) {
    if (!page) return;
    UIView *edit = descendant(page, ^BOOL(UIView *view) {
        return [view.accessibilityIdentifier isEqualToString:@"queue-edit-button"];
    });
    BOOL visible = SGEnabled(SGKeyDJQueuePickButton) && sDJActive && isDJSession(SGPlayerState()) && edit &&
        ![objc_getAssociatedObject(page, &kNewSegmentEditPending) boolValue] && !queueInEdit(page);
    for (UIView *view = edit; view && view != page; view = view.superview) {
        if (view.hidden || view.alpha <= 0.01) { visible = NO; break; }
    }
    renderNextDJSet(page, edit, visible);
}

void SGDJQueueBeginPick(void) {

    if (!sDJActive) return;
    sPickingSegment = YES;
    // A prompt replaces the context, but the core preserves its hand queue.
    // Remove our prepared old song before that replacement can consume it.
    SPTPlayerTrack *prepared = sAheadQueued;
    sAheadQueued = nil;
    if (prepared) dropQueued(prepared, @"waiting for a new DJ set");
    drawNewSegmentButton(sQueuePageView);
}
void SGDJQueueFinishPick(BOOL changed) {

    sPickingSegment = NO;
    if (changed && sDJActive) {
        if (sAheadQueued) dropQueued(sAheadQueued, @"new DJ set landed");
        sAheadQueued = nil;
        forgetOrder();
    }
    if (sDJActive) {
        sSignature = nil;
        refreshReaders();
        if (!changed) queueAhead(); // restore the old order's preparation after a cancelled/failed Pick
    }
    drawNewSegmentButton(sQueuePageView);
}

static void placeReorderHandle(UITableViewCell *cell) {
    UIView *control = nil;
    for (UIView *view in cell.subviews) {
        if ([NSStringFromClass(view.class) isEqualToString:@"UITableViewCellReorderControl"]) { control = view; break; }
    }
    if (!control || control.hidden || cell.bounds.size.width < 100 || control.frame.size.width <= 0) return;
    CGFloat width = cell.bounds.size.width, height = cell.bounds.size.height;
    CGRect frame = control.frame;
    BOOL usual = frame.origin.x >= width / 2 && fabs(frame.size.width - frame.size.height) < 1 && frame.size.height < height;
    if (usual && control != sUIKitHandle && (sHandleFrame.origin.x < 0 || fabs(frame.origin.x - sHandleFrame.origin.x) > 0.5)) {
        BOOL first = sHandleFrame.origin.x < 0;
        sHandleFrame = frame;
        sUIKitHandle = control;
        // The handles are made anew each time the queue opens, after the page's own layout pass: the ▶ goes to their
        // column in the same pass, before the page is on screen.
        if (first || sQueuePageView) alignHeaderPlay(sQueuePageView);
    } else if (usual && !sUIKitHandle) {
        sUIKitHandle = control;
    }
    CGRect want;
    if (sHandleFrame.origin.x >= 0) {
        want = CGRectMake(sHandleFrame.origin.x, (height - sHandleFrame.size.height) / 2, sHandleFrame.size.width, sHandleFrame.size.height);
    } else if (frame.origin.x < width / 2) {
        CGFloat content = cell.contentView.frame.size.width;
        CGFloat x = (content > 0 && content < width) ? CGRectGetMaxX(cell.contentView.frame) - 3 : width - 60;
        want = CGRectMake(x, (height - frame.size.height) / 2, frame.size.width, frame.size.height);
    } else {
        return;
    }
    if (CGRectEqualToRect(CGRectIntegral(want), CGRectIntegral(frame))) return;
    control.frame = want;
}

// The "Now playing" row has no handle, so Spotify lays it out the table's full width and its ▶ sits against the
// sheet's edge, right of the handles' column. It is moved to that column's middle with a transform, which Auto
// Layout leaves alone.
static void alignHeaderPlay(UIView *page) {
    UIView *handle = sUIKitHandle;
    if (!page || !handle.window) return;
    UIView *row = descendant(page, ^BOOL(UIView *view) { return [view.accessibilityIdentifier isEqualToString:@"TrackRowQueue.Header"]; });
    UIView *play = row ? descendant(row.superview ?: row, ^BOOL(UIView *view) { return [view.accessibilityIdentifier isEqualToString:@"header-play-button"]; }) : nil;
    if (!play.superview || play.window != handle.window) return;
    CGFloat want = [handle.superview convertPoint:handle.center toView:play.superview].x;
    CGFloat dx = want - play.center.x;
    if (fabs(dx) > 60) return;
    if (fabs(play.transform.tx - dx) > 0.5) {
        [UIView performWithoutAnimation:^{ play.transform = CGAffineTransformMakeTranslation(dx, 0); }];
    }
    // Spotify lays the title out up to where the button was, so moved left the button sat over the text and the text
    // showed past it: the row's text fades out before the button.
    UIView *content = descendant(row, ^BOOL(UIView *view) { return [view.accessibilityIdentifier isEqualToString:@"Track.Row.Content"]; });
    if (!content || content.bounds.size.width <= 0) return;
    CGFloat cut = [play.superview convertRect:play.frame toView:content].origin.x - 8;
    CGFloat width = content.bounds.size.width, fade = 16;
    CAGradientLayer *mask = [content.layer.mask isKindOfClass:CAGradientLayer.class] && [content.layer.mask.name isEqualToString:@"SGQueuePlayFade"] ?
        (CAGradientLayer *)content.layer.mask : nil;
    if (cut >= width) {
        if (mask) content.layer.mask = nil;
        return;
    }
    if (!mask) {
        if (content.layer.mask) return;   // a mask of Spotify's own is left alone
        mask = [CAGradientLayer layer];
        mask.name = @"SGQueuePlayFade";
        mask.startPoint = CGPointMake(0, 0.5);
        mask.endPoint = CGPointMake(1, 0.5);
        mask.colors = @[(id)UIColor.blackColor.CGColor, (id)UIColor.blackColor.CGColor, (id)UIColor.clearColor.CGColor, (id)UIColor.clearColor.CGColor];
        content.layer.mask = mask;
    }
    CGFloat end = MAX(0, cut) / width, start = MAX(0, cut - fade) / width;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    mask.frame = content.bounds;
    mask.locations = @[@0, @(start), @(end), @1];
    [CATransaction commit];
}

// Spotify lays the button out again on its own (a play state change rebuilds it): it is put back in the column in
// that pass, not at the page's next tick.
// The "Now playing" row is the new track's as soon as the player is on it: its avatar and ▶ are put in then and as
// the row settles, not at the page's next tick.
static void drawHeaderSoon(void) {
    for (NSNumber *delay in @[@0.05, @0.3, @0.8]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay.doubleValue * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            UIView *page = sQueuePageView;
            if (!page.window || !sDJActive) return;
            drawHeaderAvatar(page);
            alignHeaderPlay(page);
        });
    }
}

%hook _TtC28EncoreConsumerMobile_BaseKit14PlayButtonView
- (void)layoutSubviews {
    %orig;
    UIView *button = (UIView *)self;
    if (!sDJActive || !sQueuePageView || button.window != sQueuePageView.window) return;
    if (![button.accessibilityIdentifier isEqualToString:@"header-play-button"]) return;
    alignHeaderPlay(sQueuePageView);
}
%end

%hook _TtC14Queue_ViewImpl9QueueCell
- (void)layoutSubviews {
    %orig;
    if (!sDJActive) return;
    placeReorderHandle((UITableViewCell *)(id)self);
    // The hooked class is declared here without its superclass, so it is taken as the table cell it is.
    UITableViewCell *cellSelf = (UITableViewCell *)(id)self;
    if (!sQueueCells) sQueueCells = [NSHashTable weakObjectsHashTable];
    [sQueueCells addObject:cellSelf];
    drawCardAvatar(cellSelf);
    // The row's own image view, and the handle, may be set again a moment after the layout.
    __weak UITableViewCell *weakSelf = cellSelf;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        UITableViewCell *cell = weakSelf;
        if (cell) { drawCardAvatar(cell); placeReorderHandle(cell); }
    });
}
- (void)setSelected:(BOOL)selected animated:(BOOL)animated {
    %orig;
    drawCardAvatarSoon((UITableViewCell *)(id)self);
}
- (void)setHighlighted:(BOOL)highlighted animated:(BOOL)animated {
    %orig;
    drawCardAvatarSoon((UITableViewCell *)(id)self);
}
%end

// The DJ's rows ticked in Edit (their trackKey): Edit's Remove sends the core its queue with none of the DJ's rows in it
// (it builds it from the core's own), so which of them were removed is told only by what was ticked. Spotify keeps the
// ticks itself (the table has one row selected at a time), so they are followed here, tap by tap.
static NSMutableOrderedSet<NSString *> *sPicked;

// Edit Remove hides the selected DJ rows in our model. Spotify 9.1.90
// does not display a native Undo snackbar for those synthetic rows, so do not
// attach a global UIControl interception to unrelated Spotify snackbars.
// Native queue items retain Spotify's normal Undo behavior unchanged.

// Whether the queue page is in its Edit: the table is always editing (that is how it shows the reorder handles), so
// it is told by Edit's close button, which shows only then.
static BOOL queueInEdit(UIView *page) {
    return page && descendant(page, ^BOOL(UIView *view) {
        return [view.accessibilityIdentifier isEqualToString:@"queue-close-edit-button"] && !view.hidden && view.alpha > 0.01;
    }) != nil;
}

// SwiftUI's Edit/close controls can dispatch from an inner UIControl. Look up
// through its wrappers, but stop at this queue page so other buttons are untouched.
static BOOL queueEditActionFrom(UIView *control, UIView *page, NSString *identifier) {
    if (!page || !page.window || control.window != page.window) return NO;
    BOOL identified = NO;
    for (UIView *view = control; view; view = view.superview) {
        if ([view.accessibilityIdentifier isEqualToString:identifier]) identified = YES;
        if (view == page) return identified || descendant(control, ^BOOL(UIView *child) {
            return [child.accessibilityIdentifier isEqualToString:identifier];
        }) != nil;
    }
    return NO;
}

// Follow the native Edit pill's visibility as well as the tap: the tap hides
// Next DJ Set immediately, and this hook catches state changes that don't go
// through a UIKit UIControl action (including the return from Edit).
%hook _TtCOOO17NowPlaying_ECMKit11QueueHeader2UI7Private10PillButton
- (void)setHidden:(BOOL)hidden {
    %orig;
    UIView *edit = (UIView *)self;
    if (!sDJActive || (![edit.accessibilityIdentifier isEqualToString:@"queue-edit-button"] &&
        !descendant(edit, ^BOOL(UIView *child) {
            return [child.accessibilityIdentifier isEqualToString:@"queue-edit-button"];
        }))) return;
    UIView *page = sQueuePageView;
    if (!page || !page.window || edit.window != page.window) return;
    objc_setAssociatedObject(page, &kNewSegmentEditPending, hidden ? @YES : nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (hidden) {
        hideNextDJSet(page);
    } else {
        drawNewSegmentButtonSoon(page);
    }
}
%end

%hook UIControl
- (void)sendAction:(SEL)action to:(id)target forEvent:(UIEvent *)event {
    UIView *page = sQueuePageView;
    BOOL enteringEdit = sDJActive && queueEditActionFrom(self, page, @"queue-edit-button");
    BOOL leavingEdit = sDJActive && queueEditActionFrom(self, page, @"queue-close-edit-button");
    if (enteringEdit) {
        // Do this before Spotify's action: no half-second header-timer lag.
        objc_setAssociatedObject(page, &kNewSegmentEditPending, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        hideNextDJSet(page);
    }
    %orig;
    if (leavingEdit) {
        objc_setAssociatedObject(page, &kNewSegmentEditPending, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        drawNewSegmentButtonSoon(page);
    }
    if (!sDJActive || !sEditTable) return;
    NSString *name = self.accessibilityIdentifier;
    if ([name isEqualToString:@"queue-edit-toolbar-clear-selection"]) [sPicked removeAllObjects];
    // Edit's Move up: the DJ's rows ticked go first among the DJ's (after the "Up next" card on top and its track, which
    // nothing goes above), as a drag puts them.
    if ([name isEqualToString:@"queue-edit-toolbar-move-up"] && sPicked.count) {
        NSArray<SPTPlayerTrack *> *list = [sQueue copy];
        NSInteger pairEnd = topPairEnd(list);
        NSString *top = pairEnd >= 0 ? baseUID(list[pairEnd].UID) : nil;
        NSMutableArray<NSString *> *picked = [NSMutableArray array], *rest = [NSMutableArray array];
        for (SPTPlayerTrack *row in list) {
            if (indexIn(sInjected, row) == NSNotFound) continue;
            NSString *uid = baseUID(row.UID);
            if ([picked containsObject:uid] || [rest containsObject:uid] || [uid isEqualToString:top]) continue;
            [([sPicked containsObject:trackKey(row)] ? picked : rest) addObject:uid];
        }
        NSMutableArray<NSString *> *order = [NSMutableArray array];
        if (top) [order addObject:top];
        [order addObjectsFromArray:picked];
        [order addObjectsFromArray:rest];
        if (picked.count) {
            sOrder = order;
            sOrdered = YES;
            sOrderVersion++;
            SGLog(@"queue: Move up puts %lu of the DJ's rows first, now %lu groups", (unsigned long)picked.count, (unsigned long)order.count);
            [sPicked removeAllObjects];   // the page unticks them
            sSignature = nil;
            refreshReaders();
        }
    }
    // Edit's Remove: the DJ's rows ticked go (the core is sent the rest of its own queue, or nothing when it has none).
    if ([name isEqualToString:@"queue-edit-toolbar-remove"] && sPicked.count) {
        for (SPTPlayerTrack *row in [sInjected copy]) {
            if (![sPicked containsObject:trackKey(row)] || isHidden(row)) continue;
            hideTrack(row, @"removed in Edit");
        }
        // There is no DJ Remove Undo toast to bind. Never hijack a later
        // snackbar from a different action to restore these rows.
        [sPicked removeAllObjects];
        sSignature = nil;
        refreshReaders();
    }

}
%end

%hook ESPContextPlayerClientImpl
// The state request the player's subscription makes of the core carries caps on the tracks before and after the current
// one. The future's cap is raised before the request goes.
- (void)getState:(id)request onResponse:(id)onResponse {
    Class requestClass = NSClassFromString(@"ESPGetStateRequest"), optional = NSClassFromString(@"ESPOptionalInt64");
    if (requestClass && optional && [request isKindOfClass:requestClass]) {
        // Context-bearing requests can safely keep Spotify's native cap outside DJ.
        // The long-lived subscription carries no context and is established before
        // DJ starts; do NOT gate that subscription on the currently playing state.
        id boundContext = [request respondsToSelector:@selector(contextURI)] ? [request valueForKey:@"contextURI"] : nil;
        NSString *boundURI = SGURIString(boundContext);
        if (boundURI.length && ![boundURI isEqualToString:kDJContext]) {
            %orig;
            return;
        }
        // The player retains this subscription when the context changes. Do
        // not gate it on today's context: Spotify would not request the missing
        // DJ future tracks when the user switches into DJ later.
        // A message field the request does not have reads as an empty one (value 0): no cap, which is left alone.
        BOOL has = ![request respondsToSelector:NSSelectorFromString(@"hasNextTracksCap")] || [[request valueForKey:@"hasNextTracksCap"] boolValue];
        long long was = has ? [[[request valueForKey:@"nextTracksCap"] valueForKey:@"value"] longLongValue] : 0;
        if (has && was < kFutureCap) {
            id cap = [[optional alloc] init];
            [cap setValue:@(kFutureCap) forKey:@"value"];
            [request setValue:cap forKey:@"nextTracksCap"];
            SGLog(@"queue: next tracks cap %lld raised to %lld", was, (long long)kFutureCap);
        }
        // The tracks behind too: with two, a step back from a new segment found only the removed or played ones the
        // hand-over went past, and nothing to go back to.
        BOOL hasPrev = ![request respondsToSelector:NSSelectorFromString(@"hasPrevTracksCap")] || [[request valueForKey:@"hasPrevTracksCap"] boolValue];
        long long prev = hasPrev ? [[[request valueForKey:@"prevTracksCap"] valueForKey:@"value"] longLongValue] : 0;
        if (hasPrev && prev < kFutureCap) {
            id cap = [[optional alloc] init];
            [cap setValue:@(kFutureCap) forKey:@"value"];
            [request setValue:cap forKey:@"prevTracksCap"];
            static BOOL logged;
            if (!logged) { logged = YES; SGLog(@"queue: previous tracks cap %lld raised to %lld", prev, (long long)kFutureCap); }
        }
    }
    %orig;
}
// A DJ row that is queued by hand stays where it is: the queued track is one more, a hand-queued one that plays next,
// and the DJ's own row of it plays again at its place. The core's copy has its own uid (it starts with q).
- (void)setQueue:(id)request onResponse:(id)onResponse {
    if (sOwnQueueCommand) {
        %orig;
        return;
    }
    sNativeQueueAt = [NSDate date];
    if (!sDJActive || !sInjected.count) {
        %orig;
        return;
    }
    NSMutableArray *tracks = [request valueForKey:@"nextTracksArray"];
    NSMutableArray *djs = [NSMutableArray array];
    NSMutableSet<NSString *> *sent = [NSMutableSet set];
    for (id track in tracks) {
        NSString *uid = espUID(track);
        // Never infer ownership from the song URI alone: hand-queued duplicates have the same URI.
        if (!uid.length || !injectedNamed(espURI(track), uid)) continue;
        [djs addObject:track];
        [sent addObject:uid];
    }

    SGLog(@"queue command: setQueue %lu next tracks, %lu of the DJ's rows, %lu rows shown", (unsigned long)tracks.count,
          (unsigned long)djs.count, (unsigned long)sInjected.count);
    if (djs.count) {
        // The page sent the whole list with the DJ's rows in it: the ones it left out are the ones it removed. None
        // of them is the core's, so they are not given to it.
        for (SPTPlayerTrack *row in [sInjected copy]) {
            if (![sent containsObject:row.UID]) hideTrack(row, @"removed in the page");
        }
        [tracks removeObjectsInArray:djs];
        refreshReaders();
    } else if (sInjected.count) {
        SGLog(@"queue command: setQueue has none of the DJ's rows, not taken for a removal");
    }
    %orig;
}
- (void)playAsNextInQueue:(id)request onResponse:(id)onResponse {
    BOOL hid = NO;
    for (id track in [request valueForKey:@"tracksArray"]) {
        SPTPlayerTrack *dj = injectedNamed(espURI(track), nil);
        if (dj) { hideTrack(dj, @"played next by hand"); hid = YES; }
    }
    if (hid) refreshReaders();
    %orig;
}
%end

// When the page last gave the core a queue command of its own, and the page's queue wrapper: a swipe on a DJ row that
// the page did not act on is done here (the page's swipe does nothing for those rows).

static void swipeDJRow(SPTPlayerTrack *row, CGFloat x) {

    NSDate *at = [NSDate date];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.45 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        // Native setQueue may acknowledge the swipe without including any DJ rows;
        // its timestamp alone does not mean the DJ row was actually removed.
        if (x > 0 && sNativeQueueAt && [sNativeQueueAt timeIntervalSinceDate:at] >= 0) {
            SGLog(@"queue page: the page acted on the swipe of %@ itself", row.trackTitle);
            return;
        }
        if (x > 0) {
            SPTPlayerTrack *own = originalOf(row);
            id wrapper = sWrapper;
            if (!wrapper) wrapper = queueWrapper();
            SGLog(@"queue page: swipe adds %@ [%@] to the queue, the DJ's row stays (wrapper %@)", row.trackTitle, own.UID, [wrapper class]);
            id result = [wrapper respondsToSelector:NSSelectorFromString(@"queueTrack:")] ? ((id (*)(id, SEL, id))objc_msgSend)(wrapper, NSSelectorFromString(@"queueTrack:"), own) : nil;
            SGLog(@"queue page: the swipe's queue answered %@", result);
        } else {
            hideTrack(row, @"removed by a swipe");
            refreshReaders();
        }
    });
}

// The page's own queue commands before they reach the client: what its swipe actions and its drag call.
%hook SPTPlayerQueueWrapperImpl
- (id)queueTrackInternal:(SPTPlayerTrack *)track options:(id)options loggingParams:(id)params {
    sWrapper = self;
    sNativeQueueAt = [NSDate date];
    if (track && indexIn(sInjected, track) != NSNotFound && !isCardRow(track)) {
        // A DJ row: its copy is not the core's track. The core queues the player's own, as one more track among the
        // hand-queued ones before the DJ's. The DJ's row of it is hidden by the addToQueue that follows.
        SPTPlayerTrack *own = originalOf(track);
        SGLog(@"queue page: queue track %@ given to the core as its own %@ [%@], the DJ's row stays", track.trackTitle, SGURIString(own.URI), own.UID);
        return %orig(own, options, params);
    }
    return %orig;
}
- (id)queueTracksInternal:(NSArray<SPTPlayerTrack *> *)tracks options:(id)options loggingParams:(id)params {
    sNativeQueueAt = [NSDate date];
    return %orig;
}
- (id)queueTrackPlayNext:(SPTPlayerTrack *)track {
    sNativeQueueAt = [NSDate date];
    return %orig;
}
%end

%hook _TtC14Queue_ViewImpl38QueueTableViewDataSourceImplementation
- (void)tableView:(UITableView *)tableView moveRowAtIndexPath:(NSIndexPath *)from toIndexPath:(NSIndexPath *)to {
    if (!sDJActive || !sInjected.count) {
        %orig;
        return;
    }
    NSArray<SPTPlayerTrack *> *list = [sQueue copy];
    %orig;
    BOOL arranged = arrangeByDrag(list, placeOf(tableView, from), placeOf(tableView, to));
    if (!arranged) SGLog(@"queue page: the drag moved no DJ row, the page's rows are given again");
    // Once the drop is over, the page is given the list again: ours, or the one it had if the drag was not ours.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ refreshReaders(); });
}
%end

%hook SPTEsperantoPlayer
- (id)skipToNextTrackWithOptions:(id)options track:(SPTPlayerTrack *)track loggingParams:(id)params {
    if (!track && sDJActive && !sAdvancing && !sHandingOver) {
        SPTPlayerTrack *last = lastLogicalNext(SGPlayerState());
        if (last) { id landed = landAtSegmentEnd(last); if (landed) return landed; }
    }
    if (!track && sDJActive && !sAdvancing && !sHandingOver) {
        // A reordered segment can end on a queued copy of its physical last
        // song. Next would otherwise play spent context originals (audibly)
        // before reaching that song's closing DJ voice. Cross them muted.
        SPTPlayerTrack *outro = repeatedCurrentOutro(SGPlayerState());
        if (outro) {
            SGLog(@"queue: next pressed with spent context songs before the outro; crossing them muted");
            skipRepeatedCurrentIntoOutro(outro);
            return @YES;
        }
    }
    if (!track && sDJActive && !sAdvancing && !sHandingOver && segmentSpent(SGPlayerState())) {
        id landed = landAtSegmentEnd(nil);
        if (landed) return landed;
    }
    if (!track && sDJActive && !sAdvancing) {
        SPTPlayerTrack *want = redirectedNext();
        if (want) return advanceTo(want, YES) ?: %orig;
    }
    return %orig;
}
%end

// Navigation and hand-over helpers, with no Logos hooks.
#include "DJQueueTransitions.inc"
// Playback history observer and state lens.
#include "DJQueueHistory.inc"
%hook SPTEsperantoPlayer
- (id)pause:(id)options {

    if (!sInternalDJPause && sDJActive && (sHandingOver || sNextSegmentTimer)) {
        sUserPauseRevision++;
        SGLog(@"queue: explicit Pause during a DJ transition will be preserved");
    }
    return %orig;
}
// Every step back of Spotify's ends here, `track` nil for the plain one. With nothing behind the current track in
// the state, the core has run out of the ten it keeps, and the one the DJ played before is asked for by its uid.
- (id)skipToPreviousTrackWithOptions:(id)options track:(SPTPlayerTrack *)track loggingParams:(id)params {
    sBackAsked = [NSDate date];
    SPTPlayerState *state = SGPlayerState();
    // A refused targeted back-step must fall back only once, even if the fallback
    // re-enters this exact hook. A new track arrival clears the refusal.
    if (sJumpRefused) {

        return %orig;
    }
    // Keep Spotify's restart-current-track behavior after its first three seconds.
    SPTPlayerTrack *target = !track && isDJSession(state) && state.position < 3 ? playedBefore(state) : nil;
    if (!target) return %orig;

    NSString *was = state.track.UID;
    NSUInteger arrivalSerial = sDJTrackArrivalSerial;
    SGLog(@"queue: previous in the DJ history: %@ [%@]", target.trackTitle, target.UID);
    id result = %orig(options, target, params);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kJumpSeconds * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        // The targeted Previous may have succeeded and the user may have
        // pressed Next before this timer fired. Comparing only the current UID
        // falsely interprets that round trip as a refused Previous.
        if (sDJTrackArrivalSerial != arrivalSerial) {

            return;
        }
        if (![SGPlayerState().track.UID isEqualToString:was]) {
            SGLog(@"queue: the core went back to %@", SGPlayerState().track.trackTitle);
            return;
        }
        sJumpRefused = YES;

        SGLog(@"queue: the core did not go back to %@, the plain step back instead", target.trackTitle);
        [(id<SPTPlayer>)queuePlayer() skipToPreviousTrackWithOptions:options];
    });
    return result;
}
%end

// The table's rows are the queue's tracks in order, over its sections (the hand-queued ones, the DJ's, an empty
// one), so a row's place in the table is its track's in the queue.
%hook _TtC14Queue_ViewImpl19QueueViewController
// The page's swipe actions on a row (add to queue, remove) are one horizontal pan. The row of the DJ's "Up next" card
// has none: the pan is cancelled when it begins on that row.
- (void)onSwipePanGestureWithGesture:(UIPanGestureRecognizer *)gesture {
    static BOOL blocked;
    if (gesture.state == UIGestureRecognizerStateBegan) {
        blocked = NO;
        sSwipeRow = nil;
    }
    if (gesture.state == UIGestureRecognizerStateBegan && sDJActive && sInjected.count) {
        UIView *view = gesture.view;
        UITableView *table = [view isKindOfClass:UITableView.class] ? (UITableView *)view
            : (UITableView *)descendant(view, ^BOOL(UIView *candidate) { return [candidate isKindOfClass:UITableView.class]; });
        NSIndexPath *path = table ? [table indexPathForRowAtPoint:[gesture locationInView:table]] : nil;
        if (path) {
            NSInteger place = placeOf(table, path);
            SPTPlayerTrack *row = place < (NSInteger)sQueue.count ? sQueue[place] : nil;
            blocked = row && isCardRow(row) && indexIn(sInjected, row) != NSNotFound;
            sSwipeRow = row && !blocked && indexIn(sInjected, row) != NSNotFound ? row : nil;
        }
        if (blocked) {
            SGLog(@"queue page: swipe on the card's row is cancelled");
            gesture.enabled = NO;
            gesture.enabled = YES;
            return;
        }
    }
    if (gesture.state == UIGestureRecognizerStateEnded) {
        CGFloat x = [gesture translationInView:gesture.view].x;
        if (sSwipeRow && fabs(x) >= 110) swipeDJRow(sSwipeRow, x);
        sSwipeRow = nil;
    }
    if (blocked) {
        if (gesture.state == UIGestureRecognizerStateEnded || gesture.state == UIGestureRecognizerStateCancelled ||
            gesture.state == UIGestureRecognizerStateFailed) blocked = NO;
        return;
    }
    %orig;
}
- (void)viewWillAppear:(BOOL)animated {
    %orig;
    sQueuePageView = ((UIViewController *)(id)self).view;
    // A sheet reused after being closed in Edit must not retain a stale guard.
    objc_setAssociatedObject(sQueuePageView, &kNewSegmentEditPending, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    drawNewSegmentButtonSoon(sQueuePageView);
}
- (void)viewDidLayoutSubviews {
    %orig;
    drawHeaderAvatar(((UIViewController *)(id)self).view);
    sQueuePageView = ((UIViewController *)(id)self).view;
    drawNewSegmentButton(sQueuePageView);
    if (sDJActive) alignHeaderPlay(((UIViewController *)(id)self).view);
}
- (void)viewDidAppear:(BOOL)animated {
    %orig;
    // The header's row is rebuilt without the page laying out, so it is looked at again while the page is on screen.
    [sHeaderTimer invalidate];
    sHeaderTimer = nil;
    if (!sDJActive) return;
    sQueuePageView = ((UIViewController *)(id)self).view;
    drawNewSegmentButtonSoon(sQueuePageView);
    __weak UIViewController *page = (UIViewController *)(id)self;
    sHeaderTimerPage = page;
    sHeaderTimer = [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *timer) {
        UIViewController *strong = page;
        if (!strong || !sDJActive) { [timer invalidate]; return; }
        drawHeaderAvatar(strong.view);
        alignHeaderPlay(strong.view);
        drawNewSegmentButton(strong.view);
    }];
}
- (void)viewDidDisappear:(BOOL)animated {
    %orig;
    // Only the page the timer is for stops it: a queue page going away after a new one has appeared (the queue closed
    // and opened again) stopped the new page's, and the card's avatar was not drawn in its "Now playing" row.
    if (sHeaderTimerPage && sHeaderTimerPage != (UIViewController *)(id)self) return;
    [sHeaderTimer invalidate];
    sHeaderTimer = nil;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    NSInteger place = indexPath.row;
    for (NSInteger section = 0; section < indexPath.section; section++) place += [tableView numberOfRowsInSection:section];
    SPTPlayerTrack *track = place < (NSInteger)sQueue.count ? sQueue[place] : nil;
    // In Edit, a tap selects the row (the circle on its left), as on Spotify's own rows: it plays nothing.
    sEditTable = tableView;
    if (queueInEdit(((UIViewController *)(id)self).view)) {
        %orig;
        // The table keeps one row selected and the page draws its own ticks: each tap on a row ticks it or unticks it.
        if (track && indexIn(sInjected, track) != NSNotFound) {
            if (!sPicked) sPicked = [NSMutableOrderedSet orderedSet];
            NSString *key = trackKey(track);
            if ([sPicked containsObject:key]) [sPicked removeObject:key]; else [sPicked addObject:key];
        }
        return;
    }
    [sPicked removeAllObjects];
    if (track && indexIn(sInjected, track) != NSNotFound) {
        [tableView deselectRowAtIndexPath:indexPath animated:YES];
        // The "Up next" card is the voice item (spotify:media:), which the core is never skipped to: the row after it
        // is the track it introduces, and that one is. The core is given the player's own track, not the row's copy.
        SPTPlayerTrack *row = track;
        if ([SGURIString(track.URI) hasPrefix:@"spotify:media:"]) {
            SPTPlayerTrack *introduced = place + 1 < (NSInteger)sQueue.count ? sQueue[place + 1] : nil;
            row = introduced && [originalOf(introduced).UID isEqualToString:originalOf(track).UID] ? introduced : nil;
        }
        SPTPlayerTrack *target = row ? originalOf(row) : nil;
        if (target) {
            // A tap passes the rows before it: they are not played any more, whichever order the core has them in. With
            // them hidden, the core goes on to the tapped track in one skip when it has nothing else before it (the
            // rows of the page are then the core's own after it, and its next segment comes when it is the last); only
            // tracks the user put after it that the core has before it keep it on its place, and it is played through the
            // queue. Left shown, a tap with no order of the user's queued the track and the page's rows stayed as they were.
            NSString *tapped = baseUID(target.UID);
            for (NSInteger i = 0; i < place; i++) {
                SPTPlayerTrack *before = sQueue[i];
                if (indexIn(sInjected, before) == NSNotFound) continue;
                NSString *uid = baseUID(before.UID);
                if ([uid isEqualToString:tapped]) continue;
                BOOL fresh = ![sHidden containsObject:uid];
                if (fresh) hideTrack(before, @"passed by a tap");
                // Passed, not removed: they stay in the history, so a step back goes over them (5-4-3-2-1). A card and
                // its track have one uid: the card's row makes it passed, the track's row puts it in the history.
                if (fresh || [sPassed containsObject:uid]) {
                    if (!sPassed) sPassed = [NSMutableSet set];
                    [sPassed addObject:uid];
                    SPTPlayerTrack *own = originalOf(before);
                    if (!isCardRow(before) && isDJTrack(own) && playedIndex(uid) == NSNotFound && ![sPlayedBefore containsObject:uid]) [sPlayed addObject:own];
                }
            }
        }
        if (!target) {
            SGLog(@"queue page: the card %@ has no track after it to skip to", track.UID);
            return;
        }
        // A tap on the card plays its voice, then its track; a tap on the track goes to the track, its voice skipped.
        BOOL onCard = [SGURIString(track.URI) hasPrefix:@"spotify:media:"];
        if (onCard || ![sCarded containsObject:target.UID]) {
            sSkipVoiceUID = nil;
        } else {
            sSkipVoiceUID = target.UID;
            sSkipVoiceAsked = [NSDate date];
        }
        // The skip changes the queue, and the page reloads its table for it: it is made once this tap has returned,
        // not inside the table's own selection, after the now playing screens are told the rows the tap passed.
        sTapPending = YES;
        refreshReaders();
        dispatch_async(dispatch_get_main_queue(), ^{
            sTapPending = NO;
            advanceTo(target, onCard);
        });
        return;
    }
    %orig;
}
%end

static NSIndexPath *pathForPlace(UITableView *table, NSInteger place) {
    for (NSInteger section = 0; section < table.numberOfSections; section++) {
        NSInteger rows = [table numberOfRowsInSection:section];
        if (place < rows) return [NSIndexPath indexPathForRow:place inSection:section];
        place -= rows;
    }
    return nil;
}

// While a row is dragged, the place it would be dropped at: a row from below the "Up next" card and its track is not
// let go above them (the table shows it stay below).
static NSIndexPath *(*sOrigTarget)(id, SEL, UITableView *, NSIndexPath *, NSIndexPath *);
static NSIndexPath *targetRow(id self, SEL _cmd, UITableView *table, NSIndexPath *from, NSIndexPath *proposed) {
    NSIndexPath *result = sOrigTarget ? sOrigTarget(self, _cmd, table, from, proposed) : proposed;
    if (!sDJActive || !sInjected.count) return result;
    NSInteger pairEnd = topPairEnd(sQueue);
    if (pairEnd < 0 || !result) return result;
    NSInteger fromPlace = placeOf(table, from), toPlace = placeOf(table, result);
    if (fromPlace > pairEnd && toPlace <= pairEnd) {
        NSIndexPath *held = pathForPlace(table, pairEnd + 1);
        if (held) return held;
    }
    return result;
}

// Every row of the queue page is movable, as Spotify has them (a handle on each, in and out of Edit), but the DJ's card.
// The data source's own method is not asked: it is the diffable superclass's, which says no for every row, though UIKit
// shows Spotify's rows movable without the mod (9.1.90, Liked Songs: a handle on each with the switch off).
static BOOL canMoveRow(id self, SEL _cmd, UITableView *table, NSIndexPath *path) {
    if (!sDJActive || !sInjected.count) return YES;
    NSInteger place = placeOf(table, path);
    SPTPlayerTrack *row = place >= 0 && place < (NSInteger)sQueue.count ? sQueue[place] : nil;
    return !(row && indexIn(sInjected, row) != NSNotFound && isCardRow(row));
}


%ctor {
    if (!SGEnabled(SGKeyDJQueue)) return;
    %init;
    {
        Class source = NSClassFromString(@"_TtC14Queue_ViewImpl38QueueTableViewDataSourceImplementation");
        if (source) class_replaceMethod(source, @selector(tableView:canMoveRowAtIndexPath:), (IMP)canMoveRow, "c@:@@");
        Class delegate = NSClassFromString(@"_TtC14Queue_ViewImpl19QueueViewController");
        SEL target = @selector(tableView:targetIndexPathForMoveFromRowAtIndexPath:toProposedIndexPath:);
        Method current = delegate ? class_getInstanceMethod(delegate, target) : NULL;
        if (delegate) {
            sOrigTarget = current ? (NSIndexPath *(*)(id, SEL, UITableView *, NSIndexPath *, NSIndexPath *))method_getImplementation(current) : NULL;
            class_replaceMethod(delegate, target, (IMP)targetRow, "@@:@@@");
        }
    }
    static SGDJHistory *history;
    history = [[SGDJHistory alloc] init];
    SGAddPlayerStateObserver(history);
    SGSetPlayerStateLens(djLens);
    SGRequireClasses(@[@"_TtC16Queue_UpNextImpl19UpNextTrackProvider", @"_TtC14Queue_ViewImpl22PlayerStateEventSource",
                       @"_TtC14Queue_ViewImpl20QueuedTracksObserver", @"_TtC14Queue_ViewImpl19QueueViewController",
                       @"ESPContextPlayerClientImpl", @"SPTEsperantoPlayer", @"SPTPlayerQueueWrapperImpl", @"_TtC14Queue_ViewImpl9QueueCell", @"_TtC28EncoreConsumerMobile_BaseKit14PlayButtonView",
                       @"_TtC14Queue_ViewImpl38QueueTableViewDataSourceImplementation"]);
}
