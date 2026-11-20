// Internal implementation of DJ Queue, compiled through DJQueue.x.
// Kept in one translation unit while the Spotify Logos hooks share session state.
static BOOL sJumpRefused;

// After the DJ's voice the cover list of the full player is to show the track's cover where the voice's blue cell was:
// both are the same uid, so Spotify sometimes keeps the voice's cell (the DJ's logo over the track) until a swipe makes
// the cell reused. A voice cell that is still showing while the player is on a track is reloaded out of the list.
static void freeStuckVoiceCell(void) {
    NSString *uri = SGURIString(SGPlayerState().track.URI);
    if (![uri hasPrefix:@"spotify:track:"] && ![uri hasPrefix:@"spotify:episode:"]) return;
    NSMutableArray<UIWindow *> *windows = [NSMutableArray array];
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if ([scene isKindOfClass:UIWindowScene.class]) [windows addObjectsFromArray:((UIWindowScene *)scene).windows];
    }
    for (UIWindow *window in windows) {
        UIView *list = descendant(window, ^BOOL(UIView *view) { return [NSStringFromClass(view.class) hasSuffix:@"AccessibleCollectionView"]; });
        UIView *voice = list ? descendant(list, ^BOOL(UIView *view) {
            return [NSStringFromClass(view.class) hasSuffix:@"DJMContentLayerCell"] && !view.hidden && view.alpha > 0.01;
        }) : nil;
        if (!voice || ![list isKindOfClass:UICollectionView.class]) continue;
        SGLog(@"queue: the DJ's voice cell still shows on %@, the cover list is reloaded", uri);
        UICollectionView *collection = (UICollectionView *)list;
        [collection reloadData];
        [collection layoutIfNeeded];
    }
}

// While the DJ's voice plays, its cell in the cover list draws the DJ's circle (a VisualizationView). After a card was
// moved, the cell sometimes came up as the current one without it, only the blue background (9.1.90): the list is
// reloaded, which makes the cell again as the current one, with the circle.
static void drawVoiceCircle(void) {
    if (![SGURIString(SGPlayerState().track.URI) hasPrefix:@"spotify:media:"]) return;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            UIView *list = descendant(window, ^BOOL(UIView *view) { return [NSStringFromClass(view.class) hasSuffix:@"AccessibleCollectionView"]; });
            if (![list isKindOfClass:UICollectionView.class]) continue;
            UICollectionView *collection = (UICollectionView *)list;
            CGFloat x = collection.contentOffset.x;
            UIView *cell = nil;
            for (UIView *view in collection.subviews) {
                if ([NSStringFromClass(view.class) hasSuffix:@"DJMContentLayerCell"] && !view.hidden && fabs(view.frame.origin.x - x) < 1) { cell = view; break; }
            }
            if (!cell) continue;
            UIView *circle = descendant(cell, ^BOOL(UIView *view) { return [NSStringFromClass(view.class) hasSuffix:@"VisualizationView"] && !view.hidden && view.alpha > 0.01; });
            if (circle) continue;
            SGLog(@"queue: the DJ's voice cell has no circle, the cover list is reloaded");
            [collection reloadData];
            [collection layoutIfNeeded];
        }
    }
}

static NSString *sVoiceCheckedFor;
static void freeStuckVoiceCellSoon(SPTPlayerTrack *track) {
    NSString *key = trackKey(track);
    if ([key isEqualToString:sVoiceCheckedFor] || ![SGURIString(track.URI) hasPrefix:@"spotify:track:"]) return;
    sVoiceCheckedFor = key;
    for (NSNumber *delay in @[@0.6, @1.5, @3]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay.doubleValue * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ freeStuckVoiceCell(); });
    }
}

// The last item of the DJ's segment in the core's future (before the delimiter), not one queued by hand.
static SPTPlayerTrack *lastOfSegment(SPTPlayerState *state) {
    SPTPlayerTrack *last = nil;
    for (SPTPlayerTrack *t in state.future) {
        if (isCoreQueued(t)) continue;
        if ([SGURIString(t.URI) isEqualToString:@"spotify:delimiter"]) break;
        if (isDJTrack(t) || [SGURIString(t.URI) hasPrefix:@"spotify:media:"]) last = t;
    }
    return last;
}

// Next DJ Set: skip through the *player's* current segment instead of asking
// CompositeJumpable for a different playlist. In Spotify 9.1.90 the core only
// prepares the next page after reaching the last song of the current page.
// Keep the transition silent while the core moves to that anchor and publishes
// the next page, then jump directly to its first item. No signal or prompt is sent.
static NSTimer *sNextSegmentTimer;
static NSString *sNextSegmentContext, *sNextSegmentPage;
static NSSet<NSString *> *sNextSegmentOldUIDs;
static SPTPlayerTrack *sNextSegmentAnchor;
static BOOL sNextSegmentWasPaused, sNextSegmentAnchorSent, sNextSegmentJumpSent, sNextSegmentRemote;
static NSUInteger sNextSegmentPhysicalAdvances;
static NSString *sNextSegmentObservedKey;
static NSTimeInterval sNextSegmentLastProgress;
static NSTimeInterval sNextSegmentStarted;
static const NSTimeInterval kNextSegmentTimeout = 22;

static BOOL isNewSegmentItem(SPTPlayerTrack *track) {
    if (!track || isCoreQueued(track)) return NO;
    NSString *uri = SGURIString(track.URI);
    if (!isDJTrack(track) && ![uri hasPrefix:@"spotify:media:"]) return NO;
    NSString *page = track.metadata[@"page_instance_id"];
    // Page IDs can remain stable when the core appends a fresh DJ segment.
    // A different page is decisive (even if Spotify reused an intro UID), but
    // an unchanged page is not proof that a previously unseen UID is old.
    if ([page isKindOfClass:NSString.class] && page.length && sNextSegmentPage.length &&
        ![page isEqualToString:sNextSegmentPage]) return YES;
    NSString *uid = baseUID(track.UID);
    return uid.length && ![sNextSegmentOldUIDs containsObject:uid];
}

static void endNextSegmentSkip(BOOL changed, NSString *problem, BOOL contextChanged) {

    [sNextSegmentTimer invalidate];
    sNextSegmentTimer = nil;
    sNextSegmentContext = nil;
    sNextSegmentPage = nil;
    sNextSegmentOldUIDs = nil;
    sNextSegmentAnchor = nil;
    BOOL remote = sNextSegmentRemote;
    sNextSegmentRemote = NO;
    sNextSegmentAnchorSent = NO;
    sNextSegmentJumpSent = NO;
    sNextSegmentPhysicalAdvances = 0;
    sNextSegmentObservedKey = nil;
    sNextSegmentLastProgress = 0;
    sHandingOver = NO;
    sHandOverAnchorUID = nil;
    sHandOverDisplayState = nil;
    sHandOverDisplayTrack = nil;
    if (!remote) SGPlayerSetDJTransitionMuted(NO);
    SGDJQueueFinishPick(changed);
    if (!contextChanged) {
        id<SPTPlayer> player = (id<SPTPlayer>)queuePlayer();
        BOOL preservePause = sNextSegmentWasPaused || sUserPauseRevision != sLandingPauseRevision;
        if (remote) {
            // Spotify Connect has no locally rendered audio to mute. Never
            // pause/resume the remote device just to perform a silent landing;
            // only restore Pause if the user actually requested it.
            if (preservePause && !SGPlayerState().isPaused) pauseForDJTransition(player);
        } else if (preservePause) {
            pauseForDJTransition(player);
        } else [player resume:nil];
    }
    if (problem.length && !contextChanged) {
        [SGAlbumQueueNotice showIn:sQueuePageView.window title:@"Couldn't change DJ set"
                           detail:problem symbol:@"exclamationmark.circle"];
    }
}

static void pollNextSegmentSkip(NSTimer *timer) {
    if (timer != sNextSegmentTimer) return;
    SPTPlayerState *state = SGPlayerState();
    if (!isDJSession(state) || ![SGURIString(state.contextURI) isEqualToString:sNextSegmentContext]) {
        SGLog(@"queue: next segment skip cancelled; the DJ context changed");
        endNextSegmentSkip(NO, nil, YES);
        return;
    }
    NSTimeInterval elapsed = CACurrentMediaTime() - sNextSegmentStarted;
    if (elapsed > kNextSegmentTimeout) {
        SGLog(@"queue: next segment did not arrive in %.0f seconds", elapsed);
        endNextSegmentSkip(NO, @"DJ didn't load another segment. Try again.", NO);
        return;
    }
    if (!sNextSegmentAnchorSent) {
        // The pause acknowledgement must arrive before a targeted skip: skip
        // commands can resume audio before a second pause has been accepted.
        if (!sNextSegmentRemote && !state.isPaused) {
            if (elapsed > 2.5) endNextSegmentSkip(NO, @"DJ didn't pause before changing sets.", NO);
            return;
        }
        sNextSegmentAnchorSent = YES;

        SPTPlayerTrack *anchor = sNextSegmentAnchor;
        if (anchor && !sameGroup(state.track, anchor)) {
            SGLog(@"queue: skipping silently to the segment's last song %@ [%@]", SGURIString(anchor.URI), anchor.UID);
            skipForward(anchor);
        } else if ([SGURIString(state.track.URI) hasPrefix:@"spotify:media:"]) {
            // Already in the closing narration: the core requested the next
            // page on the preceding last song, so ask for its next item.
            SGLog(@"queue: already on the closing voice; advancing to the next page");
            skipForward(nil);
        } else {
            SGLog(@"queue: on the segment's last song; awaiting the next page");
        }
        return;
    }
    // A prefetched new page can become the current track before we see it in
    // future. Conversely, an old voice after the anchor is not a new page.
    if (isNewSegmentItem(state.track)) {

        SGLog(@"queue: skipped to the next DJ segment at %@ [%@]", SGURIString(state.track.URI), state.track.UID);
        endNextSegmentSkip(YES, nil, NO);
        return;
    }
    // Once the anchor is confirmed, reset the stall clock whenever the core
    // moves to another physical item (song -> closing voice, for example).
    NSString *observed = trackKey(state.track);
    if (![observed isEqualToString:sNextSegmentObservedKey]) {
        sNextSegmentObservedKey = [observed copy];
        sNextSegmentLastProgress = CACurrentMediaTime();
    }
    if (sNextSegmentJumpSent) return;
    for (SPTPlayerTrack *next in state.future) {
        if ([SGURIString(next.URI) isEqualToString:@"spotify:delimiter"]) break;
        if (!isNewSegmentItem(next)) continue;
        sNextSegmentJumpSent = YES; // one targeted jump, never a run of Next presses

        SGLog(@"queue: the next DJ segment arrived; jumping to %@ [%@]", SGURIString(next.URI), next.UID);
        skipForward(next);
        return;
    }
    // Spotify does not always expose the following page just because the
    // targeted skip reached the old segment's last song. If no new page was
    // published, give the core a bounded *physical* Next to leave that song
    // (and, when present, its closing voice). Never consume a hand queue.
    if (sNextSegmentPhysicalAdvances >= 2 ||
        CACurrentMediaTime() - sNextSegmentLastProgress < 2.5) return;
    for (SPTPlayerTrack *next in state.future) if (isCoreQueued(next)) return;
    sNextSegmentPhysicalAdvances++;

    sNextSegmentLastProgress = CACurrentMediaTime();
    SGLog(@"queue: next DJ page still absent; advancing one physical item (%lu/2), on %@ [%@]",
          (unsigned long)sNextSegmentPhysicalAdvances, SGURIString(state.track.URI), state.track.UID);
    skipForward(nil);
}

static void skipToNextDJSegment(void) {
    if (sNextSegmentTimer || sPickingSegment || sHandingOver) return;
    SPTPlayerState *state = SGPlayerState();
    if (!sDJActive || !isDJSession(state)) return;
    // The local player uses its audio render mute and a Pause acknowledgement
    // for silent jumps. On Spotify Connect the renderer belongs to another
    // device: use the same bounded, targeted segment navigation without a
    // synthetic remote Pause/Resume or a local mute that cannot affect it.
    BOOL remote = SGPlayerMusicOutput() == NULL;
    if (!remote && !canMuteDJLocally()) {

        [SGAlbumQueueNotice showIn:sQueuePageView.window title:@"Next DJ Set unavailable"
                            detail:@"Local playback isn't ready for the transition yet."
                            symbol:@"exclamationmark.circle"];
        return;
    }

    // Collect only the old segment, before the delimiter. Both the voice and
    // its song use the same UID; page_instance_id identifies the new page when
    // the core reuses an introduction UID.
    NSMutableSet<NSString *> *old = [NSMutableSet set];
    NSString *page = state.track.metadata[@"page_instance_id"];
    if (![page isKindOfClass:NSString.class]) page = nil;
    if (baseUID(state.track.UID)) [old addObject:baseUID(state.track.UID)];
    SPTPlayerTrack *anchor = isDJTrack(state.track) ? state.track : nil;
    for (SPTPlayerTrack *track in state.future) {
        if ([SGURIString(track.URI) isEqualToString:@"spotify:delimiter"]) break;
        if (isCoreQueued(track)) continue;
        NSString *trackPage = track.metadata[@"page_instance_id"];
        if (page.length && [trackPage isKindOfClass:NSString.class] && trackPage.length && ![trackPage isEqualToString:page]) break;
        if (!page.length && [trackPage isKindOfClass:NSString.class] && trackPage.length) page = trackPage;
        NSString *uid = baseUID(track.UID);
        if (uid.length) [old addObject:uid];
        if (isDJTrack(track)) anchor = track; // last *song*, not its closing narration
    }
    if (!anchor && ![SGURIString(state.track.URI) hasPrefix:@"spotify:media:"]) {
        [SGAlbumQueueNotice showIn:sQueuePageView.window title:@"Couldn't change DJ set"
                           detail:@"DJ's current segment isn't available yet." symbol:@"exclamationmark.circle"];
        return;
    }
    sNextSegmentContext = [SGURIString(state.contextURI) copy];
    sNextSegmentPage = [page copy];
    sNextSegmentOldUIDs = [old copy];
    sNextSegmentAnchor = anchor;
    sNextSegmentWasPaused = state.isPaused;
    sLandingPauseRevision = sUserPauseRevision;
    sNextSegmentRemote = remote;
    sNextSegmentAnchorSent = NO;
    sNextSegmentJumpSent = NO;
    sNextSegmentPhysicalAdvances = 0;
    sNextSegmentObservedKey = nil;
    sNextSegmentStarted = CACurrentMediaTime();
    sNextSegmentLastProgress = sNextSegmentStarted;
    SGDJQueueBeginPick(); // hold the queue order and drop our prefetched old copy
    sHandOverDisplayState = state;
    sHandOverDisplayTrack = asDJTrack(state.track) ?: state.track;
    sHandOverAnchorUID = anchor ? historyUID(anchor) : historyUID(state.track);
    sHandingOver = YES; // disable the automatic end-of-segment bridge

    if (!remote) SGPlayerSetDJTransitionMuted(YES);
    SGLog(@"queue: Next DJ Set in %@ skip mode: moving across the segment without sending a request",
          remote ? @"Connect" : @"local");
    if (!remote && !state.isPaused) pauseForDJTransition((id<SPTPlayer>)queuePlayer());
    sNextSegmentTimer = [NSTimer timerWithTimeInterval:0.1 repeats:YES block:^(NSTimer *timer) {
        pollNextSegmentSkip(timer);
    }];
    [NSRunLoop.mainRunLoop addTimer:sNextSegmentTimer forMode:NSRunLoopCommonModes];
    // Remote playback has no local Pause acknowledgement to wait for.
    if (remote || state.isPaused) pollNextSegmentSkip(sNextSegmentTimer);
}

// On the segment's last track, hidden: once the next segment's first item is in the future (the core asks for it as it
// comes to the last track, a second on the simulator), the player goes on to it; after kSegmentWait, on anyway.
static const NSTimeInterval kSegmentWait = 6;
static void awaitNextSegment(NSString *onKey) {
    __block int tries = 0;
    __block void (^poll)(void);
    void (^check)(void) = ^{
        SPTPlayerState *now = SGPlayerState();
        if (![trackKey(now.track) isEqualToString:onKey]) { poll = nil; return; }
        SPTPlayerTrack *to = coreNextUnplayed(now);
        if (!to && ++tries < (int)(kSegmentWait / 0.25)) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), poll);
            return;
        }
        poll = nil;
        SGLog(@"queue: %@", to ? [NSString stringWithFormat:@"the next segment came, on to %@", SGURIString(to.URI)] : @"no next segment came, the player goes on");
        skipForward(to);
    };
    poll = check;
    dispatch_async(dispatch_get_main_queue(), poll);
}

// The hand-over to the next segment when nothing of this one is left to play but tracks that played or were removed: the
// core makes the next segment only once it is on this one's last track, and on the way it would play each of those for a
// moment. Just before the current track ends, the core is moved under the output mute to the segment's last track
// and then to the next segment's first item once it arrives. No unnecessary Pause/Play transport change is sent.
static NSTimer *sHandOverTimer;
static const NSTimeInterval kHandOverLead = 0.7;

// An item of the segment still to play: a DJ track that has not played and was not removed, or a voice not heard.
static BOOL isUnspent(SPTPlayerTrack *t) {
    NSString *uid = baseUID(t.UID);
    BOOL voice = [SGURIString(t.URI) hasPrefix:@"spotify:media:"];
    if (!uid.length || (!voice && !isDJTrack(t)) || wasPlayed(uid) || [sHidden containsObject:uid]) return NO;
    return !(voice && [sVoiced containsObject:uid]);
}

// Nothing of the segment left: no track queued by hand, nothing of the user's order, nothing of the core's that has not
// played and was not removed, and something the core would still come to (else it is on the last track already).
static BOOL segmentSpent(SPTPlayerState *state) {
    BOOL onVoice = [SGURIString(state.track.URI) hasPrefix:@"spotify:media:"];
    // A card's voice has its track still to come; the DJ's words after a track end it, and are let play.
    if (!sDJActive || !isDJSession(state) || (onVoice && sCardTracks[state.track.UID])) return NO;
    for (SPTPlayerTrack *t in state.future) if (isCoreQueued(t)) return NO;
    if (sOrdered && wantedNext()) return NO;
    // The DJ's words after the track playing have its uid: they are its own, not something of the segment left.
    for (SPTPlayerTrack *t in state.future) {
        if ([SGURIString(t.URI) isEqualToString:@"spotify:delimiter"]) break;
        if (sameGroup(t, state.track)) {
            if (!onVoice && [SGURIString(t.URI) hasPrefix:@"spotify:media:"]) return NO;   // the DJ's words after it are to come
            continue;
        }
        if (isUnspent(t)) return NO;
    }
    SPTPlayerTrack *last = lastOfSegment(state);
    return last && !sameGroup(last, state.track);
}

// `target` is all the segment has left to play, its card (if any) has been heard, and the core has items after it that
// played or were removed: a tap on the segment's last row after a launch left the core before a track the tap passed,
// and no next segment came.
static BOOL onlyThisLeft(SPTPlayerState *state, SPTPlayerTrack *target) {
    if (!sDJActive || !isDJSession(state) || !target) return NO;
    BOOL seen = NO, after = NO;
    for (SPTPlayerTrack *t in state.future) {
        // The copy put in ahead for another track is taken out on the way (a tap with one in the core's queue went
        // straight to the last row, the core still had a passed track after it, and no next segment came).
        if (isCoreQueued(t) && ((sAheadQueued && [SGURIString(t.URI) isEqualToString:SGURIString(sAheadQueued.URI)]) ||
            (sCopyOf[t.UID] && sameGroup(t, target)))) continue;
        if (isCoreQueued(t)) return NO;
        if ([SGURIString(t.URI) isEqualToString:@"spotify:delimiter"]) break;
        if (sameGroup(t, target)) {
            // Its card before it, not heard yet: played from the queue, it would be lost.
            if (!seen && [SGURIString(t.URI) hasPrefix:@"spotify:media:"] && isUnspent(t)) return NO;
            if (![SGURIString(t.URI) hasPrefix:@"spotify:media:"]) seen = YES;
            continue;
        }
        if (isUnspent(t)) return NO;
        if (seen) after = YES;
    }
    SPTPlayerTrack *last = lastOfSegment(state);
    return seen && after && last && (!sameGroup(last, state.track) || isCoreQueued(state.track));
}

// Enter the user's final song only after the context has requested the next
// segment. This is needed even when that song is already the core's next item:
// tracks after it in the physical context may have played earlier from copies.
static SPTPlayerTrack *lastLogicalNext(SPTPlayerState *state) {
    if (!sOrdered || !isDJSession(state) || playedAfter(state.track)) return nil;
    SPTPlayerTrack *target = wantedNext();
    if (!target || sameGroup(target, state.track)) return nil;
    return onlyThisLeft(state, target) ? target : nil;
}

// The core makes the next segment only once it is on this one's last track, and on the way it would play for a moment
// each track after the one playing that played or was removed. The player is sent to the segment's last track
// under the output mute and, once the next segment has come, on to its first item (or to `play`, put in the core's
// queue first). No internal Pause/Play toggle is necessary; nothing discarded should sound. Nil when it could not be done.
// Core skips are asynchronous and can momentarily play a context anchor. Keep
// the render output muted until the real destination is acknowledged, without
// sending an explicit pause that flickers the native Pause/Play controls.
static void finishDJLanding(id<SPTPlayer> player, SPTPlayerTrack *target, NSString *from, BOOL resume, BOOL outro) {
    __block int tries = 0;
    __block void (^poll)(void);
    __block NSString *advancedFromKey;
    __block NSUInteger physicalAdvances = 0;
    // A targeted skip is asynchronous. At the first poll the *starting* song
    // can still be at position zero: that alone is not evidence that Spotify
    // skipped to another physical item sharing the outro's UID.
    double startingPosition = SGPlayerState().position;
    poll = ^{
        SPTPlayerState *now = SGPlayerState();
        if (!isDJSession(now)) { poll = nil; sHandingOver = NO; SGPlayerSetDJTransitionMuted(NO); return; }
        BOOL sameItem = target && sameGroup(now.track, target) && [SGURIString(now.track.URI) isEqualToString:SGURIString(target.URI)];
        BOOL landed = target ? sameItem : ![trackKey(now.track) isEqualToString:from];
        if (outro && physicalAdvances && [SGURIString(now.track.URI) hasPrefix:@"spotify:media:"]) landed = YES;
        // A targeted skip uses the UID shared by the song and its outro. It can
        // land on the song first. But before its acknowledgement the original
        // song is still current; never treat its zero position as a completed
        // skip and issue an overlapping, untargeted Next command.
        BOOL movedFromStart = ![trackKey(now.track) isEqualToString:from];
        BOOL returnedToSameUID = now.position < 1 &&
            (physicalAdvances > 0 || (startingPosition > 1 && now.position + 1 < startingPosition) || tries >= 7);
        if (outro && physicalAdvances < 8 && isDJTrack(now.track) && sameGroup(now.track, target) && !sameItem &&
            ![trackKey(now.track) isEqualToString:advancedFromKey] &&
            (movedFromStart || returnedToSameUID)) {
            advancedFromKey = trackKey(now.track);
            physicalAdvances++;
            SGLog(@"queue: the outro uid landed on its song; still muted, advancing into the voice");
            skipForward(nil);
        }
        if (!landed && ++tries < 40) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)), dispatch_get_main_queue(), poll);
            return;
        }
        poll = nil;
        sHandingOver = NO;
        sHandOverAnchorUID = nil; sHandOverDisplayTrack = nil; sHandOverDisplayState = nil;
        SGPlayerSetDJTransitionMuted(NO);
        sSignature = nil;
        refreshReaders();
        if (landed) {
            BOOL userPaused = sUserPauseRevision != sLandingPauseRevision;
            SGLog(@"queue: the next destination is confirmed, %@", userPaused ? @"user's Pause preserved" :
                  resume ? (now.isPaused ? @"resuming" : @"already playing") : @"kept paused");
            if (userPaused) {
                if (!now.isPaused) pauseForDJTransition(player);
            } else if (resume && now.isPaused) {
                // Core skips often resume on their own. Only resume when the
                // user has not issued Pause since the crossing began.
                [player resume:nil];
            }
        } else {
            SGLog(@"queue: the destination was not confirmed; releasing the mute to avoid a stuck player");
        }
    };
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)), dispatch_get_main_queue(), poll);
}

static id landAtSegmentEnd(SPTPlayerTrack *play) {
    if (!canMuteDJLocally()) return nil;
    SPTPlayerState *state = SGPlayerState();
    SPTPlayerTrack *last = lastOfSegment(state);
    if (sHandingOver || !last || (sameGroup(last, state.track) && !isCoreQueued(state.track))) return nil;
    sHandOverDisplayState = SGPlayerState();
    sHandOverDisplayTrack = asDJTrack(sHandOverDisplayState.track) ?: sHandOverDisplayState.track;
    sHandingOver = YES;
    sLandingPauseRevision = sUserPauseRevision;
    sHandOverAnchorUID = historyUID(last);

    SGPlayerSetDJTransitionMuted(YES);
    if (play) {
        SPTPlayerTrack *existing = queuedCopyOf(play, state, NULL);
        BOOL pending = sameGroup(sAheadQueued, play);
        if (existing) noteCopy(existing, play);
        if (!existing && !pending && !queueInCore(play)) { sHandingOver = NO; sHandOverAnchorUID = nil; sHandOverDisplayTrack = nil; sHandOverDisplayState = nil; SGPlayerSetDJTransitionMuted(NO); return nil; }
        hideTrack(play, @"played through the queue");
        refreshReaders();
    }
    id<SPTPlayer> player = (id<SPTPlayer>)queuePlayer();
    BOOL resume = !state.isPaused; // preserve a pause already present at entry
    SGLog(@"queue: nothing of the segment is left; crossing muted to its last %@ without pausing", SGURIString(last.URI));
    NSString *from = trackKey(state.track);
    __block int tries = 0;
    __block BOOL sent = NO;
    __block void (^poll)(void);
    poll = ^{
        SPTPlayerState *now = SGPlayerState();
        if (!isDJSession(now) || ![now.contextURI isEqual:state.contextURI]) {
            poll = nil; sHandingOver = NO; sHandOverAnchorUID = nil; sHandOverDisplayTrack = nil; sHandOverDisplayState = nil; SGPlayerSetDJTransitionMuted(NO); return;
        }
        if (!sent) {
            sent = YES;
            tries = 0;
            // Mute was armed before this async targeted skip. Spotify can keep
            // playing throughout the segment hand-over; there is no reason to
            // ask it to pause just to prevent a discarded song from sounding.
            SGLog(@"queue: crossing muted to the segment anchor");
            skipForward(last);
        }
        BOOL moved = ![trackKey(now.track) isEqualToString:from];
        SPTPlayerTrack *to = moved ? coreNextUnplayed(now) : nil;
        // Only the copy created by our queue command may become the landing
        // destination. A manually queued copy has the same URI but a distinct UID.
        SPTPlayerTrack *copy = play ? queuedCopyOf(play, now, NULL) : nil;
        if ((!to || (play && !copy)) && ++tries < (int)(kSegmentWait / 0.1)) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), poll);
            return;
        }
        poll = nil;
        if (play && !copy) {
            SGLog(@"queue: owned landing copy not confirmed; retaining Spotify's playback");
            [sHidden removeObject:baseUID(play.UID)];
            sHandingOver = NO; sHandOverAnchorUID = nil;
            sHandOverDisplayTrack = nil; sHandOverDisplayState = nil;
            SGPlayerSetDJTransitionMuted(NO);
            sSignature = nil; refreshReaders();
            return;
        }
        SPTPlayerTrack *destination = play ? copy : to;
        SGLog(@"queue: the next segment %@; finishing muted hand-over", to ? @"came" : @"has not arrived yet");
        NSString *anchor = trackKey(now.track);
        skipForward(destination);
        finishDJLanding(player, destination, anchor, resume, NO);
    };
    dispatch_async(dispatch_get_main_queue(), poll);
    return @YES;
}

// The player is on the segment's last item (its last track, or the DJ's words after it) and the core has nothing more to
// come yet. The next segment is made once the core is on this last track; when it has not come by the end of the track,
// the core went back over the tracks that had played, and one of them sounded for a moment before it was skipped away
// from. The player is paused just before the end instead, and goes on once the next segment has come.
static BOOL atSegmentEnd(SPTPlayerState *state) {
    SPTPlayerTrack *cur = state.track;
    if (!sDJActive || sHandingOver || sAdvancing || !isDJSession(state) || !cur.UID.length ||
        (isCoreQueued(cur) ? !sCopyOf[cur.UID] : !inDJ(cur))) return NO;
    BOOL onVoice = [SGURIString(cur.URI) hasPrefix:@"spotify:media:"];
    // A voice before its track (a card's) has the track still to come; the DJ's words after a track have played it.
    if (onVoice && !wasPlayed(baseUID(cur.UID))) return NO;
    for (SPTPlayerTrack *t in state.future) if (isCoreQueued(t)) return NO;
    if (sOrdered && wantedNext()) return NO;
    SPTPlayerTrack *last = lastOfSegment(state);
    if (!last || !sameGroup(last, cur)) return NO;
    if (!onVoice && [SGURIString(last.URI) hasPrefix:@"spotify:media:"]) return NO;   // the DJ's words after it are to come
    return coreNextUnplayed(state) == nil;
}

static void holdAtEnd(void) {
    if (!canMuteDJLocally()) return; // never pause a remote Connect device
    SPTPlayerState *state = SGPlayerState();
    if (sHandingOver || !atSegmentEnd(state)) return;
    sHandOverDisplayState = SGPlayerState();
    sHandOverDisplayTrack = asDJTrack(sHandOverDisplayState.track) ?: sHandOverDisplayState.track;
    sHandingOver = YES;
    sLandingPauseRevision = sUserPauseRevision;
    sHandOverAnchorUID = historyUID(state.track);

    SGPlayerSetDJTransitionMuted(YES);
    id<SPTPlayer> player = (id<SPTPlayer>)queuePlayer();
    NSString *from = trackKey(state.track);
    SGLog(@"queue: the player is at the end of the segment's last item %@ and the next segment has not come: paused until it does",
          state.track.trackTitle ?: SGURIString(state.track.URI));
    pauseForDJTransition(player);
    __block int tries = 0;
    __block void (^poll)(void);
    void (^check)(void) = ^{
        SPTPlayerState *now = SGPlayerState();
        BOOL moved = ![trackKey(now.track) isEqualToString:from];
        SPTPlayerTrack *to = moved ? nil : coreNextUnplayed(now);
        if (!moved && !to && ++tries < (int)(kSegmentWait / 0.2)) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), poll);
            return;
        }
        poll = nil;
        if (!moved) {
            SGLog(@"queue: %@", to ? [NSString stringWithFormat:@"the next segment came, on to %@ and resumed", SGURIString(to.URI)]
                                  : @"no next segment came, the player goes on and resumes");
            skipForward(to);
        }
        BOOL userPaused = sUserPauseRevision != sLandingPauseRevision;
        if (moved) {
            sHandingOver = NO;
            SGPlayerSetDJTransitionMuted(NO);
            if (userPaused) {
                if (!now.isPaused) pauseForDJTransition(player);
            } else [player resume:nil];
        } else {
            finishDJLanding(player, to, from, !userPaused, NO);
        }
    };
    poll = check;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), poll);
}

// With no order of the user's: the core's next item is a track that was removed (or played through the queue) and a
// track to play comes after it. The core would play the removed one for a moment before it is skipped away from, and a
// copy of the next put in its queue ahead (which Spotify draws as queued by hand) is no answer: the player is skipped
// to the track that comes, in one skip, just before the end. nil when the core's next is to be left alone.
static SPTPlayerTrack *skipPastSpent(SPTPlayerState *state) {
    SPTPlayerTrack *cur = state.track;
    if (!sDJActive || sHandingOver || sAdvancing || sPlayingMoved || !isDJSession(state) || !cur.UID.length ||
        (isCoreQueued(cur) ? !sCopyOf[cur.UID] : !inDJ(cur)) || playedAfter(cur)) return nil;
    BOOL onVoice = [SGURIString(cur.URI) hasPrefix:@"spotify:media:"];
    if (onVoice && !wasPlayed(baseUID(cur.UID))) return nil;   // a card's voice: its track is to come
    for (SPTPlayerTrack *t in state.future) if (isCoreQueued(t)) return nil;
    SPTPlayerTrack *coming = nil;
    for (SPTPlayerTrack *t in state.future) {
        if ([SGURIString(t.URI) isEqualToString:@"spotify:delimiter"]) break;
        if (sameGroup(t, cur)) {
            if (!onVoice && [SGURIString(t.URI) hasPrefix:@"spotify:media:"]) return nil;   // the DJ's words after it are to come
            continue;
        }
        coming = t;
        break;
    }
    // Reordered tracks also remain in the core's context after their queue copy played.
    // Skip them before audio starts, rather than correcting the order on arrival.
    if (!coming || isUnspent(coming)) return nil;
    SPTPlayerTrack *wanted = sOrdered ? wantedNext() : nil;
    SPTPlayerTrack *next = wanted ? reachableInFuture(state, wanted) : coreNextUnplayed(state);
    return next && !sameGroup(next, coming) ? next : nil;
}

// The core may put the context original of a song played from its queue back
// before that song's closing DJ voice. Reordering can leave *other* spent
// context originals between the queued copy and the voice as well. They must
// not sound for a moment when Next is pressed or playback reaches the end.
// Never jump across a still-unplayed DJ track, a card's fresh voice, or an
// intentional hand-queued song; in those cases the normal player order wins.
static SPTPlayerTrack *repeatedCurrentOutro(SPTPlayerState *state) {
    SPTPlayerTrack *current = state.track;
    if (!sDJActive || sHandingOver || sAdvancing || sPlayingMoved || !isDJSession(state) ||
        !isDJTrack(current) || playedAfter(current) || (sOrdered && wantedNext())) return nil;
    BOOL spentBetween = NO;
    for (SPTPlayerTrack *t in state.future) {
        NSString *uri = SGURIString(t.URI);
        if ([uri isEqualToString:@"spotify:delimiter"]) return nil;
        // Queue copies have their own q-UID, so isUnspent(t) can call even a
        // played copy "fresh". Only cross a known copy of this *same* track;
        // never cross a queued copy for another group or a user's queue item.
        if (isCoreQueued(t) && (!sCopyOf[t.UID] || !sameGroup(t, current))) return nil;
        if (sameGroup(t, current)) {
            if (isDJTrack(t)) { spentBetween = YES; continue; }
            if ([uri hasPrefix:@"spotify:media:"]) return spentBetween ? t : nil;
            return nil;
        }
        if (isUnspent(t)) return nil;
        // These are only the context originals we have already played or
        // hidden. A fresh segment cannot be traversed by this shortcut.
        if (isDJTrack(t) || [uri hasPrefix:@"spotify:media:"]) {
            spentBetween = YES;
            continue;
        }
        return nil;
    }
    return nil;
}

static void skipRepeatedCurrentIntoOutro(SPTPlayerTrack *voice) {
    if (sHandingOver || !canMuteDJLocally()) return;
    sHandOverDisplayState = SGPlayerState();
    sHandOverDisplayTrack = asDJTrack(sHandOverDisplayState.track) ?: sHandOverDisplayState.track;
    sHandingOver = YES;
    sLandingPauseRevision = sUserPauseRevision;
    sHandOverAnchorUID = historyUID(voice);

    SGPlayerSetDJTransitionMuted(YES);
    id<SPTPlayer> player = (id<SPTPlayer>)queuePlayer();
    NSString *from = trackKey(SGPlayerState().track);
    // The render mute is already armed, so even a skip that briefly lands on a
    // spent context original cannot leak it. Keep the playback transport running:
    // asking for an explicit pause here causes the visible Pause/Play hiccup.
    SGLog(@"queue: spent context originals precede the closing DJ voice; crossing them muted without pausing");
    skipForward(voice);
    finishDJLanding(player, voice, from, !SGPlayerState().isPaused, YES);
}

static BOOL needsHandOver(SPTPlayerState *state) {
    return lastLogicalNext(state) != nil || repeatedCurrentOutro(state) != nil || segmentSpent(state) || atSegmentEnd(state) || skipPastSpent(state) != nil;
}

static void handOver(void) {
    if (sHandingOver) return;
    SPTPlayerState *state = SGPlayerState();
    SPTPlayerTrack *last = lastLogicalNext(state);
    if (last) { landAtSegmentEnd(last); return; }
    SPTPlayerTrack *outro = repeatedCurrentOutro(state);
    if (outro) { skipRepeatedCurrentIntoOutro(outro); return; }
    if (segmentSpent(state)) { landAtSegmentEnd(nil); return; }
    if (atSegmentEnd(state)) { holdAtEnd(); return; }
    SPTPlayerTrack *to = skipPastSpent(state);
    if (to) {
        SGLog(@"queue: %@ is about to end and the core's next was removed or played: on to %@ [%@] in one skip", state.track.trackTitle,
              to.trackTitle ?: SGURIString(to.URI), to.UID);
        skipForward(to);
    }
}

// Looked at again whenever the player comes to a track, plays or pauses; while nothing of the segment is left, the time to
// the track's end is watched (a seek tells the state's observers nothing).
static void scheduleHandOver(void) {
    if (!sDJActive || !isDJSession(SGPlayerState())) {
        [sHandOverTimer invalidate]; sHandOverTimer = nil;
        return;
    }
    if (sHandOverTimer.isValid) return;
    // Future/order reports may arrive after the track callback. Keep watching the
    // session, rather than disabling the only clock check on a transient snapshot.
    sHandOverTimer = [NSTimer scheduledTimerWithTimeInterval:0.25 repeats:YES block:^(NSTimer *timer) {
        SPTPlayerState *now = SGPlayerState();
        if (!sDJActive || !isDJSession(now)) { [timer invalidate]; if (sHandOverTimer == timer) sHandOverTimer = nil; return; }
        if (sPickingSegment || sHandingOver || now.isPaused || now.duration <= 0) return;
        double speed = now.playbackSpeed > 0 ? now.playbackSpeed : 1;
        if ((now.duration - now.position) / speed > kHandOverLead) return;
        if (needsHandOver(now)) handOver();
    }];
}
