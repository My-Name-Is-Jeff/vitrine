// Internal implementation of DJ Queue, compiled through DJQueue.x.
// Kept in one translation unit while the Spotify Logos hooks share session state.
static BOOL sAdvancing, sOwnQueueCommand;

static id skipForward(SPTPlayerTrack *to) {
    // Log our own targeted skips so a fast succession of player.state events
    // can be distinguished from external user skips in the diagnostic report.

    sAdvancing = YES;
    id result = to ? [(id<SPTPlayer>)queuePlayer() skipToNextTrackWithOptions:nil track:to]
                   : [(id<SPTPlayer>)queuePlayer() skipToNextTrackWithOptions:nil];
    sAdvancing = NO;
    return result;
}

// The DJ tracks played here from the core's queue, by the uid of the core's copy: the copy is the user's track of the DJ's,
// and the now playing screens are shown it as that (djLens), not as a track queued by hand.
// What is kept of the original is what that needs, and plain, so it is kept over a launch with the session (a launch
// during a copy showed it as a track queued by hand, "Playing Queue"): uri, uid, provider, its metadata's provider, title.
static void noteCopy(SPTPlayerTrack *copy, SPTPlayerTrack *original) {
    if (!copy.UID.length || !original.UID.length) return;
    if (!sCopyOf) sCopyOf = [NSMutableDictionary dictionary];
    NSMutableDictionary *info = [NSMutableDictionary dictionary];
    info[@"uri"] = SGURIString(original.URI) ?: @"";
    info[@"uid"] = original.UID;
    if (original.provider) info[@"provider"] = original.provider;
    if ([original.metadata[@"provider"] isKindOfClass:NSString.class]) info[@"mprovider"] = original.metadata[@"provider"];
    if (copy.trackTitle.length) info[@"title"] = copy.trackTitle;
    sCopyOf[copy.UID] = info;
    // Keep the same span as the saved session. A DJ session can outlive 50 tracks; evicting an internal copy that's
    // still in Spotify's future makes it look hand-queued and lets the original row play again beside it.
    while (sCopyOf.count > kSavedMax) [sCopyOf removeObjectForKey:sCopyOf.allKeys.firstObject];
}

// The DJ track put in the core's queue ahead of its turn (the player's own track; the core's copy has a q uid): when the
// track playing ends by itself, the core goes on to its queue first, so the user's next plays and not the core's own for
// a moment before a skip away from it. Kept while the user's order has it next; taken out of the core's queue when not.
static NSDate *sAheadAt;
// An in-flight queueTrack: the UID is assigned asynchronously by Spotify, so
// only a genuinely new q-UID after this command can be claimed as our copy.
// A preexisting user copy of the same URI is never eligible.
static NSMutableDictionary<NSString *, NSDictionary *> *sPendingCopies;
static NSMutableDictionary<NSString *, NSString *> *sCancelledCopies;
static void dropQueuedUID(NSString *uid, NSString *why);

static void reconcilePendingCopies(SPTPlayerState *state) {
    if (!isDJSession(state) || !sPendingCopies.count) return;
    NSArray<SPTPlayerTrack *> *present = state.track ? [@[state.track] arrayByAddingObjectsFromArray:state.future ?: @[]]
                                                   : state.future ?: @[];
    for (NSString *originalUID in [sPendingCopies.allKeys copy]) {
        NSDictionary *pending = sPendingCopies[originalUID];
        SPTPlayerTrack *original = pending[@"original"];
        if (!original || ![pending[@"context"] isEqualToString:SGURIString(state.contextURI)] ||
            CACurrentMediaTime() - [pending[@"started"] doubleValue] > 8) {
            [sPendingCopies removeObjectForKey:originalUID];
            [sCancelledCopies removeObjectForKey:originalUID];
            continue;
        }
        NSMutableArray<SPTPlayerTrack *> *newCopies = [NSMutableArray array];
        for (SPTPlayerTrack *t in present) {
            if (!isCoreQueued(t) || !t.UID.length || [pending[@"before"] containsObject:t.UID] ||
                ![SGURIString(t.URI) isEqualToString:SGURIString(original.URI)] ||
                sCopyOf[t.UID]) continue;
            BOOL repeated = NO;
            for (SPTPlayerTrack *seen in newCopies) if ([seen.UID isEqualToString:t.UID]) repeated = YES;
            if (!repeated) [newCopies addObject:t];
        }
        // A second fresh copy of this song means a possible concurrent manual
        // add: do not guess which one Vitrine owns, and never delete either.
        if (newCopies.count > 1) {
            [sPendingCopies removeObjectForKey:originalUID];
            [sCancelledCopies removeObjectForKey:originalUID];
            SGLog(@"queue: ambiguous new copies of %@; leaving both in the core", originalUID);
            continue;
        }
        SPTPlayerTrack *owned = newCopies.firstObject;
        if (!owned) continue;
        noteCopy(owned, original);
        [sPendingCopies removeObjectForKey:originalUID];
        NSString *cancel = sCancelledCopies[originalUID];
        [sCancelledCopies removeObjectForKey:originalUID];
        if (cancel) {
            NSString *uid = [owned.UID copy];
            dispatch_async(dispatch_get_main_queue(), ^{ dropQueuedUID(uid, cancel); });
        }
    }
}

// Set while advanceTo waits for a queued copy to reach the state: nothing is queued ahead meanwhile.
static BOOL sQueueWaiting;
// Set from a tap on a row until the player is sent on: the rows the tap hid are not taken for the user's order then.
static BOOL sTapPending;

static BOOL sameGroup(SPTPlayerTrack *a, SPTPlayerTrack *b) {
    return a && b && [historyUID(a) isEqualToString:historyUID(b)];
}

// After Previous, the later entries in the logical history are upcoming again, in their
// listened/passed order. Keep removal and playback bookkeeping intact; this is the visible future.
static NSArray<SPTPlayerTrack *> *historyFutureRows(SPTPlayerState *state) {
    NSUInteger at = playedIndex(historyUID(state.track));
    if (at == NSNotFound) return @[];
    NSMutableArray<SPTPlayerTrack *> *rows = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    for (NSUInteger i = at + 1; i < sPlayed.count; i++) {
        SPTPlayerTrack *track = originalOf(sPlayed[i]);
        NSString *uid = historyUID(track);
        if (!isDJTrack(track) || staysHidden(track) || !uid.length || [seen containsObject:uid]) continue;
        [rows addObject:track];
        [seen addObject:uid];
    }
    return rows;
}

// The core's queued copy of `track` among the tracks queued by hand that come first in the future (the last such, the
// one put in latest), and whether any track queued by hand comes after it.
static SPTPlayerTrack *queuedCopyOf(SPTPlayerTrack *track, SPTPlayerState *state, BOOL *notLast) {
    if (notLast) *notLast = NO;
    if (!track || !state) return nil;
    reconcilePendingCopies(state);
    SPTPlayerTrack *found = nil;
    BOOL after = NO;
    for (SPTPlayerTrack *t in state.future) {
        if ([SGURIString(t.URI) isEqualToString:@"spotify:delimiter"]) break;
        if (!isCoreQueued(t)) continue;
        NSDictionary *owned = t.UID.length ? sCopyOf[t.UID] : nil;
        // URI equality alone is unsafe: the user can queue the same track.
        if (owned && [owned[@"uid"] isEqualToString:track.UID] &&
            [owned[@"uri"] isEqualToString:SGURIString(track.URI)]) { found = t; after = NO; }
        else if (found) after = YES;
    }
    if (notLast) *notLast = after;
    return found;
}

// Takes the core's latest queued copy of `uri` out of its queue: the core is given its queue without it (only tracks it
// queued, never the DJ's own).
// What was last taken out, and when: the core may already be going to it, and plays it.
static SPTPlayerTrack *sDropped;
static NSDate *sDroppedAt;

static NSUInteger sQueueSessionGeneration;
static void dropQueuedTries(NSString *uid, NSString *why, int tries, NSUInteger generation);
// A failed ownership lookup must be non-destructive: if the new q-UID has not
// arrived, defer cancellation until it can be uniquely identified.
static void dropQueued(SPTPlayerTrack *original, NSString *why) {
    if (!original.UID.length) return;
    SPTPlayerTrack *copy = queuedCopyOf(original, SGPlayerState(), NULL);
    if (copy) { dropQueuedUID(copy.UID, why); return; }
    if (sPendingCopies[original.UID]) {
        if (!sCancelledCopies) sCancelledCopies = [NSMutableDictionary dictionary];
        sCancelledCopies[original.UID] = why;
    }
}
static void dropQueuedUID(NSString *uid, NSString *why) {
    if (!uid.length || !sCopyOf[uid]) return;
    dropQueuedTries(uid, why, 0, sQueueSessionGeneration);
}
static void dropQueuedTries(NSString *uid, NSString *why, int tries, NSUInteger generation) {
    if (generation != sQueueSessionGeneration || !sCopyOf[uid]) return;
    id queue = sLastQueue, player = queuePlayer();
    SEL setQueue = NSSelectorFromString(@"setQueue:options:loggingParams:");
    if (!queue || ![player respondsToSelector:setQueue]) {
        SGLog(@"queue: owned copy %@ cannot be removed (%@)", uid, why);
        return;
    }
    NSMutableArray<SPTPlayerTrack *> *left = [[queue valueForKey:@"nextTracks"] mutableCopy];
    NSInteger drop = -1;
    for (NSInteger i = 0; i < (NSInteger)left.count; i++) {
        if ([SGURIString(left[i].URI) isEqualToString:@"spotify:delimiter"]) break;
        if (isCoreQueued(left[i]) && [left[i].UID isEqualToString:uid]) { drop = i; break; }
    }
    if (drop < 0) {
        if (tries < 0) return;
        if (tries < 8) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                if (generation != sQueueSessionGeneration || !sCopyOf[uid]) return;
                // The same copy became the user's next again.
                SPTPlayerTrack *owned = sAheadQueued;
                if (owned && [sCopyOf[uid][@"uid"] isEqualToString:owned.UID]) return;
                dropQueuedTries(uid, why, tries + 1, generation);
            });
        } else SGLog(@"queue: owned copy %@ no longer in core queue (%@)", uid, why);
        return;
    }
    [left removeObjectAtIndex:drop];
    id copy = [queue copy];
    [copy setValue:left forKey:@"nextTracks"];
    sOwnQueueCommand = YES;
    id result = ((id (*)(id, SEL, id, id, id))objc_msgSend)(player, setQueue, copy, nil, nil);
    sOwnQueueCommand = NO;
    SGLog(@"queue: owned copy %@ removed (%@); core answered %@", uid, why, result);
    if (tries >= 100) return;
    int checks = tries < 0 ? -tries : 0;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (generation != sQueueSessionGeneration || !sCopyOf[uid]) return;
        SPTPlayerTrack *owned = sAheadQueued;
        if (owned && [sCopyOf[uid][@"uid"] isEqualToString:owned.UID]) return;
        BOOL there = NO;
        for (SPTPlayerTrack *t in SGPlayerState().future) {
            if ([SGURIString(t.URI) isEqualToString:@"spotify:delimiter"]) break;
            if (isCoreQueued(t) && [t.UID isEqualToString:uid]) { there = YES; break; }
        }
        if (!there) return;
        if (checks >= 3) {
            SGLog(@"queue: owned copy %@ remains after %d tries (%@)", uid, checks + 1, why);
            return;
        }
        dropQueuedTries(uid, why, -(checks + 1), generation);
    });
}

static id queueInCore(SPTPlayerTrack *track) {
    id wrapper = queueWrapper();
    SEL queueTrack = NSSelectorFromString(@"queueTrack:");
    if (![wrapper respondsToSelector:queueTrack]) return nil;
    // Snapshot existing queued UIDs *before* the command: a hand-queued copy
    // of this exact song must never be mistaken for the one we just created.
    SPTPlayerState *state = SGPlayerState();
    if (track.UID.length && isDJSession(state)) {
        NSMutableSet<NSString *> *before = [NSMutableSet set];
        for (SPTPlayerTrack *t in state.future) if (isCoreQueued(t) && t.UID.length) [before addObject:t.UID];
        for (SPTPlayerTrack *t in [sLastQueue valueForKey:@"nextTracks"])
            if (isCoreQueued(t) && t.UID.length) [before addObject:t.UID];
        if (!sPendingCopies) sPendingCopies = [NSMutableDictionary dictionary];
        sPendingCopies[track.UID] = @{@"original":track, @"before":before,
                                      @"context":SGURIString(state.contextURI) ?: @"",
                                      @"started":@(CACurrentMediaTime())};
    }
    // The core takes a song but no voice item into its queue.
    sOwnQueueCommand = YES;
    id result = ((id (*)(id, SEL, id))objc_msgSend)(wrapper, queueTrack, track);
    sOwnQueueCommand = NO;
    // Some wrapper versions return void/nil for a successfully dispatched request.
    // Keep the short-lived pending identity until the core publishes the q-UID.
    return result ?: @YES;
}


// Puts the user's next in the core's queue before the track playing ends, or takes out the one put there that is not the
// next any more. Nothing is queued when the core comes to the user's next anyway (its voice then plays), on a voice, or for
// a track dragged in from the hand-queued ones (that one is put first when its turn comes).
// The DJ track a skip of ours was last sent to, and when: if the core plays a copy of it from its queue instead (one put
// in before a launch), the copy is that track, not one queued by hand.
static SPTPlayerTrack *sSkipTarget;
static NSDate *sSkipAt;
static id landAtSegmentEnd(SPTPlayerTrack *play);
static SPTPlayerTrack *playedAfter(SPTPlayerTrack *current);
static BOOL segmentSpent(SPTPlayerState *state);
static BOOL isUnspent(SPTPlayerTrack *t);
// Set while the DJ hand-over hides/mutes internal anchor positions until the real destination is confirmed.
static BOOL sHandingOver;
// A Pause from Spotify's UI during a crossing supersedes its original resume
// intent, even if an internal targeted skip starts playback again.
static NSUInteger sUserPauseRevision, sLandingPauseRevision;
static BOOL sInternalDJPause;
static void pauseForDJTransition(id<SPTPlayer> player) {
    sInternalDJPause = YES;
    [player pause:nil];
    sInternalDJPause = NO;
}
// Local render muting cannot protect a Spotify Connect speaker. If we cannot
// verify a running local audio path, leave DJ transition timing to Spotify.
static BOOL canMuteDJLocally(void) {
    return SGPlayerMusicOutput() != NULL && SGPlayerSpeedAllowed();
}
static NSString *sHandOverAnchorUID;
static SPTPlayerTrack *sHandOverDisplayTrack;
static SPTPlayerState *sHandOverDisplayState;
static BOOL onlyThisLeft(SPTPlayerState *state, SPTPlayerTrack *target);
static SPTPlayerTrack *lastLogicalNext(SPTPlayerState *state);
static SPTPlayerTrack *repeatedCurrentOutro(SPTPlayerState *state);
static void skipRepeatedCurrentIntoOutro(SPTPlayerTrack *voice);

// `track` has an "Up next" card before it in the core's future that has not been heard (the DJ's words after a track
// have its uid too, and come after it).
static BOOL cardUnheard(SPTPlayerState *state, SPTPlayerTrack *track) {
    for (SPTPlayerTrack *t in state.future) {
        if ([SGURIString(t.URI) isEqualToString:@"spotify:delimiter"]) break;
        if (isCoreQueued(t) || !sameGroup(t, track)) continue;
        if (![SGURIString(t.URI) hasPrefix:@"spotify:media:"]) return NO;   // the track itself comes first
        return ![sVoiced containsObject:t.UID];
    }
    return NO;
}

static void queueAhead(void) {
    SPTPlayerState *state = SGPlayerState();
    if (!sDJActive || sPickingSegment || sAdvancing || sQueueWaiting || sTapPending || sHandingOver || !isDJSession(state)) return;
    SPTPlayerTrack *current = state.track, *want = nil;
    // On a voice (the DJ's words after a track, or a card's), a track about to be skipped or a moved one about to play,
    // what is put in stays as it is: the core may be on its way to it already (a copy taken out as the voice began
    // played all the same, and was put in again).
    if (!current || [SGURIString(current.URI) hasPrefix:@"spotify:media:"] || isHidden(current) || sPlayingMoved) return;
    // What the core plays when this track ends: its next item that is not the track's own (the DJ's words after a track
    // have its uid), past the tracks queued by hand.
    SPTPlayerTrack *coming = nil;
    for (SPTPlayerTrack *t in state.future) {
        if (isCoreQueued(t) || sameGroup(t, current)) continue;
        coming = t;
        break;
    }
    // The user's next, when the core would come to a track that played or was removed first (it sounded for a moment
    // before the skip past it). Only an order the user arranged needs a copy ahead: the core has no other way to play
    // it. Without one, the core's own next is skipped to directly (the next button, skipPastSpent just before the
    // track's end), so nothing is put in the queue, where Spotify draws it as a track queued by hand. Nor on a walk
    // back over the history: the core has those tracks to come, and the next button skips straight to the one that
    // played after this.
    if (sOrdered && !playedAfter(current)) want = wantedNext();
    if (want && (movedBySource(want) || sameGroup(want, current) || sameGroup(want, coming) ||
                 [SGURIString(current.URI) isEqualToString:SGURIString(want.URI)])) want = nil;
    // A track whose card has not played is left to the core, which plays the card's voice first. The card is looked for
    // in the whole future, not only as the core's next: that may be the DJ's words after the track playing, and the
    // card's track was put in ahead and played without its card.
    if (want && cardUnheard(state, want)) want = nil;
    // The copy put in before the launch: taken up when it is still the one wanted (below), taken out when not.
    if (sAheadBeforeLaunch && !sAheadQueued) {
        NSString *uid = sAheadBeforeLaunch;
        sAheadBeforeLaunch = nil;
        NSDictionary *owned = sCopyOf[uid];
        BOOL there = NO;
        for (SPTPlayerTrack *t in state.future) if (isCoreQueued(t) && [t.UID isEqualToString:uid]) there = YES;
        if (there && owned && want && [owned[@"uid"] isEqualToString:want.UID] &&
            [owned[@"uri"] isEqualToString:SGURIString(want.URI)]) {
            sAheadQueued = want;
            sAheadAt = [NSDate date];
        } else if (there && owned) {
            dropQueuedUID(uid, @"old prepared DJ copy no longer wanted after relaunch");
            sSignature = nil;
        }
    }
    if (sAheadQueued && !sameGroup(sAheadQueued, want)) {
        sDropped = sAheadQueued;
        sDroppedAt = [NSDate date];
        dropQueued(sAheadQueued, @"no longer the user's next");
        sAheadQueued = nil;
    }
    if (!want) return;
    BOOL notLast = NO;
    SPTPlayerTrack *copy = sAheadQueued ? queuedCopyOf(sAheadQueued, state, &notLast) : nil;
    // A track queued by hand after it is to play before the DJ's: it is put in again, behind that one.
    if (copy && notLast) {
        dropQueued(sAheadQueued, @"a track was queued by hand after it");
        sAheadQueued = nil;
    }
    // Taken out by the page (Clear, a swipe) a while after it was put in: it is put in again.
    if (sAheadQueued && !copy && sAheadAt && -sAheadAt.timeIntervalSinceNow > 2) {
        SGLog(@"queue: %@, put in ahead, is no longer in the core's queue", sAheadQueued.trackTitle);
        sAheadQueued = nil;
    }
    if (sAheadQueued) return;
    // The request is asynchronous. Do not issue a duplicate while Spotify is
    // still assigning the UID of the copy we just asked it to queue.
    if (sPendingCopies[want.UID]) {
        [sCancelledCopies removeObjectForKey:want.UID];
        sAheadQueued = want;
        sAheadAt = [NSDate date];
        return;
    }
    // A copy of it the core has already (put back in its queue by a step back) is the one: no second is put in.
    SPTPlayerTrack *have = queuedCopyOf(want, state, &notLast);
    if (have && !notLast) {
        sAheadQueued = want;
        sAheadAt = [NSDate date];
        noteCopy(have, want);
        SGLog(@"queue: %@ [%@], the user's next, is in the core's queue already", want.trackTitle, want.UID);
        // Its copy is a row of the DJ's from now on, not one queued by hand.
        sSignature = nil;
        refreshReaders();
        return;
    }
    if (!queueInCore(want)) { SGLog(@"queue: no queue wrapper to put %@ in ahead with", want.trackTitle); return; }
    sAheadQueued = want;
    sAheadAt = [NSDate date];
    SGLog(@"queue: %@ [%@], the user's next, is put in the core's queue ahead of its turn", want.trackTitle, want.UID);
}

// Goes forward to `target`, a DJ track, as any next goes (the now playing screens move on to it):
// - the core comes to it next anyway, past what has played or is hidden: a skip to it, through its voice when
//   `voiceFirst` and its card has not played (a skip forward lands on the first item with the uid, the voice);
// - else it is queued (the core's own copy, a uid of its own) and the player goes on to it there. The core keeps its
//   place before the DJ's tracks it has not come to, so a card the user put later still has its voice when its turn
//   comes; the DJ's row of the track is hidden, and its own copy passed when the core comes to it. A play next does not
//   do: the core takes a context track it is given in a setQueue for the context's, and goes on without it (9.1.90).
// The core is never stepped back to a track of the DJ's: the now playing screens draw a step back backwards, and it
// lands on the track after a voice, the voice never played (9.1.90).
// `target`'s item in the core's future (its voice first when it has one that has not been heard), when everything the core
// has before it is spent: played, removed, passed or a voice heard. The core can be skipped straight to it.
static SPTPlayerTrack *reachableInFuture(SPTPlayerState *state, SPTPlayerTrack *target) {
    for (SPTPlayerTrack *t in state.future) {
        if (isCoreQueued(t)) continue;
        if ([SGURIString(t.URI) isEqualToString:@"spotify:delimiter"]) break;
        BOOL voice = [SGURIString(t.URI) hasPrefix:@"spotify:media:"];
        if (sameGroup(t, target)) {
            if (voice && [sVoiced containsObject:t.UID]) continue;   // its voice was heard: the track itself
            return t;
        }
        if (isUnspent(t)) return nil;
    }
    return nil;
}

static id advanceTo(SPTPlayerTrack *target, BOOL voiceFirst) {
    if (queueMovedNext(target)) return skipForward(nil);
    SPTPlayerState *state = SGPlayerState();
    SPTPlayerTrack *next = coreNextUnplayed(state);
    BOOL aheadThere = sameGroup(sAheadQueued, target) && queuedCopyOf(sAheadQueued, state, NULL);
    // A track the core has still to come, with only tracks that played, were removed or were passed before it (a step
    // back and then forward again): skipped to as it is, not put in the queue.
    if (!aheadThere && !(next && sameGroup(next, target))) {
        SPTPlayerTrack *reach = reachableInFuture(state, target);
        if (reach) next = reach;
    }
    // The last of the segment that has not played, with ones that played or were removed after it in the core's order:
    // gone to directly, the core is not on its last track and makes no next segment until it has played through those.
    if (onlyThisLeft(state, target)) {
        if (sAheadQueued && !sameGroup(sAheadQueued, target)) {
            dropQueued(sAheadQueued, @"the segment's last is played");
            sAheadQueued = nil;
        }
        id landed = landAtSegmentEnd(target);
        if (landed) return landed;
    }
    sSkipTarget = target;
    sSkipAt = [NSDate date];
    if (next && !aheadThere && [baseUID(next.UID) isEqualToString:baseUID(target.UID)]) {
        // A copy put in ahead is not wanted when the core goes to the track itself.
        if (sAheadQueued) {
            sDropped = sAheadQueued;
            sDroppedAt = [NSDate date];
            dropQueued(sAheadQueued, @"the core goes to the track itself");
            sAheadQueued = nil;
        }
        BOOL voice = [SGURIString(next.URI) hasPrefix:@"spotify:media:"];
        SGLog(@"queue: on to %@%@ [%@], the core's next", voice && voiceFirst ? @"the voice of " : @"", target.trackTitle, target.UID);
        return skipForward(voice && !voiceFirst ? target : next);
    }
    // Already put in ahead of its turn: the player goes on to that copy. Another one put in ahead goes out first.
    id result = nil;
    BOOL ahead = sameGroup(sAheadQueued, target);
    if (sAheadQueued && !ahead) dropQueued(sAheadQueued, @"another track is played");
    sAheadQueued = nil;
    if (ahead) {
        SGLog(@"queue: %@ [%@] is played from the core's queue, where it was put ahead", target.trackTitle, target.UID);
        result = @YES;
    } else {
        SGLog(@"queue: %@ [%@] is played through the core's queue (the core has %@ [%@] first)", target.trackTitle, target.UID,
              next.trackTitle ?: SGURIString(next.URI), next.UID);
        result = queueInCore(target);
        if (!result) {
            SGLog(@"queue: no queue wrapper to queue %@ with, a skip to it", target.trackTitle);
            return skipForward(target);
        }
    }
    hideTrack(target, @"played through the queue");
    refreshReaders();
    // The queued copy reaches the state a moment later: the player goes on once the core has it to come.
    NSString *uri = SGURIString(target.URI);
    __block int tries = 0;
    __block void (^wait)(void);
    sQueueWaiting = YES;
    void (^go)(void) = ^{
        BOOL there = NO;
        SPTPlayerTrack *copy = nil;
        for (SPTPlayerTrack *t in SGPlayerState().future) {
            if ([SGURIString(t.URI) isEqualToString:@"spotify:delimiter"]) break;
            if (!isCoreQueued(t)) continue;
            if ([SGURIString(t.URI) isEqualToString:uri]) copy = t;   // the last, the one just put in
        }
        if (copy) { there = YES; noteCopy(copy, target); }
        if (!there && ++tries < 30) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)), dispatch_get_main_queue(), wait);
            return;
        }
        wait = nil;
        sQueueWaiting = NO;
        if (!there) SGLog(@"queue: %@ did not come first in the core's queue, the player goes on anyway", target.trackTitle);
        // To that copy, not to the first of the core's queue: a copy put in ahead for another track may still be there
        // (taking it out had not come through, and a tap played it in place of the tapped track).
        skipForward(copy);
    };
    wait = go;
    dispatch_async(dispatch_get_main_queue(), wait);
    return result;
}

// The core has come to a DJ track of its own order. If the user's order has another first, the player is skipped to it
// (its card's voice is skipped on arrival, as for a tap). YES when that was asked, the track is not taken as played.
// Gone on from a track the user's order had last, the core comes back to the tracks it was skipped past, which have
// played: the player goes on to the first that has not.
// `arrived`: the state is the player's coming to this track, not a pause, a resume or a load on the same one.
static BOOL enforceOrder(SPTPlayerState *state, BOOL arrived, BOOL walking) {
    SPTPlayerTrack *current = state.track;
    NSString *uid = baseUID(current.UID);
    if (sPickingSegment || !sOrdered || !uid.length || !inDJ(current)) return NO;
    BOOL steppedBack = sBackAsked && -sBackAsked.timeIntervalSinceNow < 4;
    // A walk over the history (a step back, the next after it, a track going on to the one that played after it) is the
    // user's, not the core coming back to tracks it was skipped past.
    if (walking || steppedBack || sHandingOver) return NO;
    BOOL replay = arrived && isDJTrack(current) && wasPlayed(uid) && !steppedBack;
    if (!replay && ![sOrder containsObject:uid]) return NO;
    SPTPlayerTrack *want = wantedNext();
    if (replay && !want) want = coreNextUnplayed(state);
    if (!want || [baseUID(want.UID) isEqualToString:uid]) return NO;
    static NSString *lastKey;
    static NSDate *lastAt;
    NSString *key = [NSString stringWithFormat:@"%@>%@", uid, want.UID];
    if ([key isEqualToString:lastKey] && lastAt && -lastAt.timeIntervalSinceNow < 3) return NO;
    lastKey = key;
    lastAt = [NSDate date];
    if (!sBounced) sBounced = [NSMutableSet set];
    [sBounced addObject:uid];
    sSkipVoiceUID = nil;
    SGLog(@"queue: the player came to %@ [%@]%@, the user's order has %@ [%@] first, skipping to it", current.trackTitle, current.UID,
          replay ? @", which played" : @"", want.trackTitle, want.UID);
    dispatch_async(dispatch_get_main_queue(), ^{ advanceTo(want, YES); });
    return YES;
}

// The DJ track that played right after `current`, when the player has been taken back over played tracks; nil at the
// newest one.
static SPTPlayerTrack *playedAfter(SPTPlayerTrack *current) {
    NSString *uid = historyUID(current);
    for (NSUInteger i = 0; i + 1 < sPlayed.count; i++) {
        if (![baseUID(sPlayed[i].UID) isEqualToString:uid]) continue;
        // Not the removed ones it went past (the segment's last a hand-over lands on); the ones the user passed with a tap are
        // part of the way, one by one.
        for (NSUInteger j = i + 1; j < sPlayed.count; j++) if (!staysHidden(sPlayed[j])) return originalOf(sPlayed[j]);
        return nil;
    }
    return nil;
}

// The next button while the user's order is on: the core would go to its own next DJ track, which would sound for a
// moment before enforceOrder skips away from it. The skip is asked for the user's first track at once instead, so the
// tracks passed over are never played and stay in the order. Past the user's order (or with none), the core's own next
// that has not played and was not removed, when the core would come to others first: they are passed in one skip, not
// played for a moment each. nil when the core's next is to be left alone.
static SPTPlayerTrack *redirectedNext(void) {
    SPTPlayerState *state = SGPlayerState();
    SPTPlayerTrack *current = state.track;
    // On a track queued by hand (or one played here through the queue), the user's order still says what comes after.
    if (sPlayingMoved || !current || !(inDJ(current) || isCoreQueued(current)) ||
        [SGURIString(current.URI) hasPrefix:@"spotify:media:"]) return nil;
    // Gone back over tracks that have played, the next one is the one that played after this, not the user's first
    // new track: the new part of the order is reached once the played ones are.
    SPTPlayerTrack *replay = playedAfter(current);
    SPTPlayerTrack *want = replay ?: (sOrdered ? wantedNext() : nil);
    if (!want) {
        SPTPlayerTrack *coreNext = state.future.firstObject, *next = coreNextUnplayed(state);
        if (!next || !coreNext || isCoreQueued(coreNext) || [trackKey(next) isEqualToString:trackKey(coreNext)]) return nil;
        SGLog(@"queue: next pressed on %@, the core's next that has not played is %@ [%@], skipping to it", current.trackTitle,
              next.trackTitle ?: SGURIString(next.URI), next.UID);
        return next;
    }
    if ([baseUID(want.UID) isEqualToString:baseUID(current.UID)]) return nil;
    // A track queued by hand comes first, and the core's own next is the one to be left alone when it is the user's
    // first too (the core goes to it, and its voice plays).
    SPTPlayerTrack *coreNext = SGPlayerState().future.firstObject;
    if (!replay && coreNext && (isCoreQueued(coreNext) || [baseUID(coreNext.UID) isEqualToString:baseUID(want.UID)])) return nil;
    // The voice that introduces the track plays (the skip goes through it): only a tap on a track's row passes it.
    sSkipVoiceUID = nil;
    if (replay) {
        sWalkUID = baseUID(want.UID);
        sWalkAt = [NSDate date];
    }
    SGLog(@"queue: next pressed on %@, %@ %@ [%@], skipping to it at once", current.trackTitle,
          replay ? @"it played before" : @"the user's order has", want.trackTitle, want.UID);
    return want;
}

// The readers are told the queue again, through the hooks, so the rows go at once and not at the core's next change.
@protocol SGQueueReader <NSObject>
- (void)player:(id)player queueDidChange:(id)queue;
@end

// The queue the core gave last and what the readers were given for it: every reader of one queue gets the very same
// object, as each gets the core's own, so the page's table and its cells are made from one list.
static __weak id sForwardFor;
static id sForward;

static void refreshReaders(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        id player = sLastPlayer, queue = sLastQueue;
        if (!player || !queue) { SGLog(@"queue: no queue to refresh the rows with"); return; }
        sForwardFor = nil;
        for (id<SGQueueReader> reader in sReaders.allObjects) [reader player:player queueDidChange:queue];
        // What the now playing screens show of the tracks to come follows the page's rows.
        SGRetellPlayerState();
        queueAhead();
        saveSession();
        scheduleHandOver();
    });
}

// When the core began to have no tracks to come, nil while it has some.
static NSDate *sGapSince;

// What the last list was made from, and the list: the same input gives the readers the same rows (the same objects),
// whichever of them is asked first.
static NSArray<SPTPlayerTrack *> *sCachedMerged;

// A line that tells whether the state, the core's queue or what was hidden has changed since the last list.
static NSString *signatureOf(SPTPlayerState *state, NSArray<SPTPlayerTrack *> *next) {
    NSMutableString *sig = [NSMutableString stringWithFormat:@"%@|%@|%@|", state.contextURI, SGURIString(state.track.URI), state.track.UID];
    for (SPTPlayerTrack *t in state.future) [sig appendFormat:@"%@/%@/%@;", SGURIString(t.URI), t.UID, t.provider];
    [sig appendString:@"|"];
    for (SPTPlayerTrack *t in next) [sig appendFormat:@"%@/%@/%@;", SGURIString(t.URI), t.UID, t.provider];
    [sig appendString:@"|"];
    for (NSString *uid in [sHidden.allObjects sortedArrayUsingSelector:@selector(compare:)]) [sig appendFormat:@"%@,", uid];
    [sig appendFormat:@"|o%lu", (unsigned long)sOrderVersion];
    return sig;
}

// Puts the DJ's tracks to come in `queue`. YES when the readers are to be left as they are: the core has none to come
// just now, and the rows the page had stay.
// The queue the readers are given is a copy of the core's with the DJ's rows in it, in `forward`: the core's own queue
// object is not changed, the page may keep it and read it again later.
// A DJ track playing from the core's queue (a copy, sCopyOf), as the DJ's: its uid and provider, without the queue's
// marks (is_queued, queued_by), so the player and the queue page draw no queue badge and keep the DJ's header. Nil for
// any other track.
static SPTPlayerTrack *asDJTrack(SPTPlayerTrack *playing) {
    NSDictionary *original = playing.UID.length ? sCopyOf[playing.UID] : nil;
    if (!original || ![original[@"uri"] isEqualToString:SGURIString(playing.URI)]) return nil;
    NSMutableDictionary *metadata = [playing.metadata mutableCopy] ?: [NSMutableDictionary dictionary];
    [metadata removeObjectForKey:@"is_queued"];
    [metadata removeObjectForKey:@"queued_by"];
    NSString *provider = original[@"mprovider"];
    if (provider) metadata[@"provider"] = provider; else [metadata removeObjectForKey:@"provider"];
    @try {
        SPTPlayerTrack *asDJ = [playing copy];
        [asDJ setValue:metadata forKey:@"metadata"];
        [asDJ setValue:original[@"uid"] forKey:@"UID"];
        if (original[@"provider"]) [asDJ setValue:original[@"provider"] forKey:@"provider"];
        return asDJ;
    } @catch (NSException *exception) {
        SGLog(@"queue: the playing copy cannot be shown as the DJ's (%@)", exception.reason);
        return nil;
    }
}

// The context anchor is an internal fetch step. Keep the last real song on screen
// while its replacement is inaudible; a voice is always shown as the voice itself.
static SPTPlayerTrack *shownDJTrack(SPTPlayerTrack *playing) {
    if (sHandingOver && sHandOverDisplayTrack) return sHandOverDisplayTrack;
    return asDJTrack(playing);
}

static SPTPlayerState *shownDJStateBase(SPTPlayerState *state) {
    if (sHandingOver && sHandOverDisplayState) return sHandOverDisplayState;
    return state;
}

// The queue the readers are given: `rows` to come when there are any, and its playing track as the DJ's when it is a
// copy (the page draws its now playing row from the queue, not from the player's state: the badge stayed there).
static id queueWith(id queue, NSArray<SPTPlayerTrack *> *rows) {
    SPTPlayerTrack *asDJ = shownDJTrack([queue valueForKey:@"track"]);
    if (!rows && !asDJ) return queue;
    id copy = [queue copy];
    if (!copy) { SGLog(@"queue: the queue cannot be copied, the page gets the core's"); return queue; }
    if (rows) [copy setValue:rows forKey:@"nextTracks"];
    if (asDJ) [copy setValue:asDJ forKey:@"track"];
    return copy;
}

static BOOL lineUpTheFutureFor(id reader, id player, id queue, id *forward);

// Out of the DJ's session: nothing of it is left for the page, its cells or the player to act on.
static void leaveDJ(void) {
    if (!sDJActive) return;

    if (sAheadQueued) dropQueued(sAheadQueued, @"the DJ's session ended");
    sAheadQueued = nil;
    sDJActive = NO;
    // The header timer is about to stop; waiting for its next tick could
    // leave Next DJ Set visible indefinitely on Spotify's non-DJ queue.
    hideNextDJSet(sQueuePageView);
    [sHeaderTimer invalidate];
    sHeaderTimer = nil;
    sQueueSessionGeneration++;
    [sPendingCopies removeAllObjects];
    [sCancelledCopies removeAllObjects];
    clearSavedSession();
    SGPlayerSetDJTransitionMuted(NO);
    sInjected = @[];
    sQueue = @[];
    sAhead = @[];
    sAheadContext = nil;
    sCachedMerged = nil;
    sSignature = nil;
    sForwardFor = nil;
    sForward = nil;
    sGapSince = nil;
    sCardAvatar = nil;
    sCardAvatarURL = nil;
    sCardTitle = nil;
    // These are session-scoped, not playlist-scoped. A later DJ run may reuse
    // the same context URI and songs but must not inherit their old identities.
    [sHidden removeAllObjects];
    [sSkipped removeAllObjects];
    [sPlayed removeAllObjects];
    [sPlayedBefore removeAllObjects];
    [sPassed removeAllObjects];
    [sVoiced removeAllObjects];
    [sCopyOf removeAllObjects];
    [sCarded removeAllObjects];
    [sCardTracks removeAllObjects];
    sAheadBeforeLaunch = nil;
    sPlayedContext = nil;
    for (UIView *view in sAvatarViews.allObjects) [view removeFromSuperview];
    [sAvatarViews removeAllObjects];
    forgetOrder();
    SGLog(@"queue: out of the DJ's session, the queue is Spotify's");
}

static BOOL lineUpTheFuture(id reader, id player, id queue, id *forward) {
    *forward = queue;
    if (!isDJSession(SGPlayerState())) {
        if (sAheadQueued && queue) sLastQueue = queue;
        leaveDJ();
        return NO;
    }
    BOOL becameActive = !sDJActive;
    sDJActive = YES;

    if (becameActive) drawNewSegmentButtonSoon(sQueuePageView);
    restoreSession(SGPlayerState());
    if (queue && queue == sForwardFor && sForward && [signatureOf(SGPlayerState(), [queue valueForKey:@"nextTracks"]) isEqualToString:sSignature]) {
        if (!sReaders) sReaders = [NSHashTable weakObjectsHashTable];
        [sReaders addObject:reader];
        *forward = sForward;
        return NO;
    }
    BOOL keep = lineUpTheFutureFor(reader, player, queue, forward);
    if (!keep) {
        sForwardFor = queue;
        sForward = *forward;
    }
    return keep;
}

static BOOL lineUpTheFutureFor(id reader, id player, id queue, id *forward) {
    if (!sReaders) sReaders = [NSHashTable weakObjectsHashTable];
    [sReaders addObject:reader];
    sLastPlayer = player;
    sLastQueue = queue;
    *forward = queue;
    SPTPlayerState *state = SGPlayerState();
    reconcilePendingCopies(state);
    NSArray<SPTPlayerTrack *> *next = [queue valueForKey:@"nextTracks"];
    NSString *signature = signatureOf(state, next);
    if (sCachedMerged.count && [signature isEqualToString:sSignature]) {
        *forward = queueWith(queue, sCachedMerged);
        return NO;
    }
    NSArray<SPTPlayerTrack *> *future = djFuture(state.future);

    // The state's own, then what was kept after its last one. When hand-queued tracks fill the state's two it names
    // none of the DJ's, and what was kept stands. A list that does not go on from the kept one is the DJ's new.
    NSMutableArray<SPTPlayerTrack *> *ahead = [future mutableCopy];
    if (![state.contextURI isEqual:sAheadContext]) {
        [sHidden removeAllObjects];
        [sSkipped removeAllObjects];
        [sCarded removeAllObjects];
        [sLoggedCards removeAllObjects];
        [sCardTracks removeAllObjects];
        [sVoiced removeAllObjects];
        [sPlayedBefore removeAllObjects];
        forgetOrder();
    }
    if ([state.contextURI isEqual:sAheadContext]) {
        if (!future.count) {
            [ahead addObjectsFromArray:sAhead];
        } else {
            NSUInteger at = indexIn(sAhead, future.lastObject);
            if (at != NSNotFound) [ahead addObjectsFromArray:[sAhead subarrayWithRange:NSMakeRange(at + 1, sAhead.count - at - 1)]];
        }
    }
    // Up to the track playing; a copy of a DJ track playing from the core's queue is not the core's place among them
    // (cut there, the tracks the core has before its original went: a card moved down was gone after a launch).
    for (NSUInteger i = 0; i < ahead.count && !isCoreQueued(state.track); i++) {
        if ([ahead[i].URI isEqual:state.track.URI]) {
            [ahead removeObjectsInRange:NSMakeRange(0, i + 1)];
            break;
        }
    }
    sAheadContext = state.contextURI;
    sAhead = ahead;
    // What the page shows of them: not the ones it removed, nor the ones queued by hand.
    NSMutableArray<SPTPlayerTrack *> *shown = [NSMutableArray array];
    // A track of the DJ's that played before the launch is not a row again: the core restores its place before it (the
    // track was played from its queue), and the next the mod puts in skips it, so it showed as a row that never played.
    NSString *playingUID = baseUID(state.track.UID);
    for (SPTPlayerTrack *track in ahead) {
        if (isHidden(track)) continue;
        NSString *uid = baseUID(track.UID);
        if (uid.length && ![uid isEqualToString:playingUID] && [sPlayedBefore containsObject:uid] && isDJTrack(track) &&
            ![SGURIString(track.URI) hasPrefix:@"spotify:media:"]) continue;
        [shown addObject:track];
    }
    for (NSDictionary *entry in sMoved.allValues) if (!isHidden(entry[@"row"])) [shown addObject:entry[@"row"]];
    if (sOrdered) shown = arrangedRows(shown, state);
    NSArray<SPTPlayerTrack *> *history = historyFutureRows(state);
    NSMutableSet<NSString *> *historyUIDs = [NSMutableSet set];
    for (SPTPlayerTrack *t in history) [historyUIDs addObject:historyUID(t)];
    [shown filterUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(SPTPlayerTrack *t, id _) {
        return ![historyUIDs containsObject:historyUID(t)];
    }]];
    [shown insertObjects:history atIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(0, history.count)]];
    // The hand-queued tracks, the DJ's, then whatever else the queue had.
    NSMutableArray<SPTPlayerTrack *> *queued = [NSMutableArray array], *rest = [NSMutableArray array], *injected = [NSMutableArray array];
    // The core's queue names the session again after the delimiter (stand-ins, some with another provider than the
    // ones the state named) and, after a track is queued by hand, the DJ's tracks once more: a track of the DJ's that
    // `ahead` already holds, by uri, or one already taken, is not a row of its own.
    NSMutableSet<NSString *> *aheadURIs = [NSMutableSet set], *restKeys = [NSMutableSet set];
    for (SPTPlayerTrack *track in ahead) [aheadURIs addObject:SGURIString(track.URI)];
    for (SPTPlayerTrack *track in history) [aheadURIs addObject:SGURIString(track.URI)];
    // A track queued by hand is the core's (isCoreQueued: its provider is "queue", or its uid starts with q when it is a
    // DJ track queued again), whichever provider the core gives it.
    NSString *playing = trackKey(state.track);
    // The user's next, put in the core's queue ahead of its turn, shows as the DJ's row it is, not as one queued by hand.
    SPTPlayerTrack *aheadCopy = sAheadQueued ? queuedCopyOf(sAheadQueued, state, NULL) : nil;
    for (SPTPlayerTrack *track in next) {
        if (aheadCopy && [trackKey(track) isEqualToString:trackKey(aheadCopy)]) continue;
        if ([trackKey(track) isEqualToString:playing]) continue;     // a queue from before the player came to it
        if (isCoreQueued(track) && movedBySource(track)) continue;   // taken into the DJ's rows, the core is being told
        if (isCoreQueued(track)) {
            // Copies we made to enforce the DJ's order are implementation details, not hand-queued rows. The core
            // can keep one in its future after it plays or after the user's order changes; sAheadQueued then no longer
            // identifies it, but sCopyOf still does. A copy queued by the user has no sCopyOf entry and stays visible.
            if (track.UID.length && sCopyOf[track.UID]) continue;
            [queued addObject:track];
            continue;
        }
        // Spotify repeats the DJ's tracks later in the same queue. A hidden original can reappear there after its
        // internal queued copy was played; don't put that original back beside the copy in the visible queue.
        if (isHidden(track)) continue;
        if (indexIn(ahead, track) != NSNotFound) continue;
        NSString *uri = SGURIString(track.URI);
        if ([uri isEqualToString:@"spotify:delimiter"]) continue;
        if (isDJTrack(track) && [aheadURIs containsObject:uri]) continue;
        NSString *key = [NSString stringWithFormat:@"%@|%@", uri, track.UID ?: @""];
        if (track.UID.length && [restKeys containsObject:key]) continue;
        [restKeys addObject:key];
        [rest addObject:track];
    }
    // A row is the DJ's unless the core's queue has that very track (uri and uid): a copy the core queued of it has the
    // context's provider too, and taken for it, the row was not the DJ's (gone from the order at the next drag).
    NSMutableSet<NSString *> *nextKeys = [NSMutableSet set];
    for (SPTPlayerTrack *track in next) [nextKeys addObject:trackKey(track)];
    for (SPTPlayerTrack *track in shown) if (![nextKeys containsObject:trackKey(track)]) [injected addObject:track];
    NSMutableArray<SPTPlayerTrack *> *merged = [NSMutableArray array];
    // One row per track (uri, uid, provider): the same track twice in a row of lists is a repeat, not a second row.
    NSMutableSet<NSString *> *taken = [NSMutableSet set];
    for (NSArray<SPTPlayerTrack *> *group in @[queued, shown, rest]) {
        for (SPTPlayerTrack *track in group) {
            if (track.UID.length) {
                NSString *key = [NSString stringWithFormat:@"%@|%@|%@", SGURIString(track.URI), track.UID, track.provider];
                if ([taken containsObject:key]) continue;
                [taken addObject:key];
            }
            [merged addObject:track];
        }
    }
    [injected filterUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(SPTPlayerTrack *t, id _) { return [merged containsObject:t]; }]];

    if (merged.count) {
        sGapSince = nil;
    } else if (sQueue.count && inDJ(state.track)) {
        if (!sGapSince) {
            sGapSince = [NSDate date];
            // Told again once the wait is over: with no change of the core's after it, the page kept the rows (and the
            // track playing) it had before, a copy put in ahead among them, until it was opened again.
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((kGapSeconds + 0.1) * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                if (sGapSince) { sSignature = nil; refreshReaders(); }
            });
        }
        if (-sGapSince.timeIntervalSinceNow < kGapSeconds) return YES;
    }
    sQueue = merged;
    sInjected = injected;
    if (injected.count) {
        NSMutableArray<NSString *> *rows = [NSMutableArray array];
        for (SPTPlayerTrack *row in merged) [rows addObject:[NSString stringWithFormat:@"%@/%@", [SGURIString(row.URI) componentsSeparatedByString:@":"].lastObject, row.UID]];
        NSString *line = [rows componentsJoinedByString:@" "];
        static NSString *sLastRows;
        if (![line isEqualToString:sLastRows]) { sLastRows = line; SGLog(@"queue: rows (%lu, %lu the DJ's): %@", (unsigned long)merged.count, (unsigned long)injected.count, line); }
    }
    sSignature = signature;
    sCachedMerged = merged;
    // The first rows of a launch: a copy put in ahead before it is taken up, the queue the readers were told is known now.
    static BOOL firstRows;
    if (!firstRows && injected.count) {
        firstRows = YES;
        dispatch_async(dispatch_get_main_queue(), ^{ queueAhead(); });
    }
    *forward = queueWith(queue, ahead.count ? merged : nil);
    return NO;
}

// ESPProvidedTrack exposes the actual URI and UID through contextTrack, not on itself.
// Check selectors before KVC: asking the wrapper for an unknown key throws on 9.1.90.
static id espValue(id track, NSArray<NSString *> *keys) {
    for (NSString *key in keys) {
        if ([track respondsToSelector:NSSelectorFromString(key)]) {
            id value = [track valueForKey:key];
            if (value) return value;
        }
    }
    return nil;
}
static id espContextTrack(id track) {
    return espValue(track, @[@"contextTrack"]);
}
static NSString *espURI(id track) {
    id direct = espValue(track, @[@"uri", @"URI", @"trackUri", @"trackURI"]);
    id nested = direct ?: espValue(espContextTrack(track), @[@"uri", @"URI", @"trackUri", @"trackURI"]);
    return SGURIString(nested);
}
static NSString *espUID(id track) {
    return espValue(track, @[@"uid", @"UID"]) ?: espValue(espContextTrack(track), @[@"uid", @"UID"]);
}
