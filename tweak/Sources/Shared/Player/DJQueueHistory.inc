// Internal implementation of DJ Queue, compiled through DJQueue.x.
// Kept in one translation unit while the Spotify Logos hooks share session state.
// Any observed track arrival invalidates an in-flight Previous fallback.
// A later Next can bring the player back to the same UID without making the
// original Previous request a failure.
static NSUInteger sDJTrackArrivalSerial;

@interface SGDJHistory : NSObject <SGPlayerStateObserver>
@end

@implementation SGDJHistory
- (void)playerStateDidChange:(SPTPlayerState *)state {
    if (isDJSession(state)) restoreSession(state);
    if (![state.contextURI isEqual:sPlayedContext]) {
        sPlayedContext = state.contextURI;
        sPlayed = [NSMutableArray array];
        sJumpRefused = NO;
    }
    if (!isDJSession(state)) return;
    reconcilePendingCopies(state);
    SPTPlayerTrack *track = state.track;
    static NSString *lastKey, *lastUID;
    // The first state of a launch is the session going on where it was, not the player coming to the track.
    BOOL arrived = lastKey && ![trackKey(track) isEqualToString:lastKey];
    if (arrived) ++sDJTrackArrivalSerial;
    NSString *leftUID = arrived ? lastUID : nil;
    lastUID = track.UID;
    // A walk over the history: the next button's replay, or the track that played right after the one that was playing.
    SPTPlayerTrack *historyTrack = asDJTrack(track) ?: track;
    NSString *historyLeft = sCopyOf[leftUID][@"uid"] ?: leftUID;
    BOOL walking = arrived && walkArrival(historyTrack, historyLeft);
    // A step back from a DJ track played from the core's queue: it has not played for the user any more, its row comes
    // back first in their order (before, it was gone from the page, and a next went past it).
    NSDictionary *backFrom = leftUID ? sCopyOf[leftUID] : nil;
    if (backFrom && sBackAsked && -sBackAsked.timeIntervalSinceNow < 4) {
        NSString *uid = baseUID(backFrom[@"uid"]);
        [sHidden removeObject:uid];
        for (NSString *key in [sSkipped copy]) if ([key hasSuffix:uid]) [sSkipped removeObject:key];
        if (!sOrder) sOrder = [NSMutableArray array];
        [sOrder removeObject:uid];
        [sOrder insertObject:uid atIndex:0];
        sOrdered = YES;
        sOrderVersion++;
        SGLog(@"queue: back from %@, played from the core's queue: its row is the user's next again", backFrom[@"title"] ?: uid);
    }
    lastKey = trackKey(track);
    // After the rows and the queue put in ahead have settled for this state.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ scheduleHandOver(); });
    if (arrived) {
        sJumpRefused = NO;
        SGLog(@"queue: the player is on %@ [%@] at %.1f s", SGURIString(track.URI), track.UID, state.position);
        // The core tells the page of a queued track it has come to only with its next queue: the rows are made again now.
        refreshReaders();
        drawHeaderSoon();
    }
    if (arrived && [SGURIString(track.URI) hasPrefix:@"spotify:media:"]) {
        for (NSNumber *delay in @[@0.8, @1.6]) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay.doubleValue * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ drawVoiceCircle(); });
        }
    }
    if ([SGURIString(track.URI) hasPrefix:@"spotify:media:"] && track.UID.length && sCardTracks[track.UID]) {
        if (!sVoiced) sVoiced = [NSMutableSet set];
        [sVoiced addObject:track.UID];
    }
    if (inDJ(track)) freeStuckVoiceCellSoon(track);
    NSDictionary *movedPlaying = track.UID.length && isCoreQueued(track) ? movedBySource(track) : nil;
    BOOL droppedLate = sDropped && sDroppedAt && -sDroppedAt.timeIntervalSinceNow < 5;
    SPTPlayerTrack *put = sAheadQueued ?: (droppedLate ? sDropped : nil);
    // A skip of ours to a DJ track that the core took to a copy of it in its queue (put in ahead before a launch).
    // A matching URI is not proof this was a DJ copy: only an owned q-UID
    // identified at creation may borrow the DJ's artwork or history.
    // A copy known from before a launch (sCopyOf is kept): its DJ track has played now, the core's own is passed.
    NSString *copied = isCoreQueued(track) ? sCopyOf[track.UID][@"uid"] : nil;
    if (arrived && copied.length && !put && ![sHidden containsObject:baseUID(copied)]) {
        if (!sHidden) sHidden = [NSMutableSet set];
        [sHidden addObject:baseUID(copied)];
        SGLog(@"queue: %@ plays from the core's queue, its DJ track [%@] is passed", track.trackTitle, copied);
        sSignature = nil;
        refreshReaders();
    }
    reconcilePendingCopies(state);
    NSDictionary *ownedArrival = track.UID.length ? sCopyOf[track.UID] : nil;
    if (put && arrived && isCoreQueued(track) && [ownedArrival[@"uid"] isEqualToString:put.UID] &&
        [ownedArrival[@"uri"] isEqualToString:SGURIString(put.URI)]) {
        // By the player's own track: its row is no longer among the page's once the core's copy of it plays.
        SGLog(@"queue: %@, put in ahead, is playing from the core's queue", track.trackTitle);
        noteCopy(track, put);
        hideTrack(put, @"played through the queue");
        sAheadQueued = nil;
        sDropped = nil;
        refreshReaders();
    }
    if (movedPlaying) {
        SPTPlayerTrack *row = movedPlaying[@"row"];
        SGLog(@"queue: moved %@ is playing, its row is taken out of the DJ's order", track.trackTitle);
        hideTrack(row, @"moved track played");
        [sMoved removeObjectForKey:baseUID(row.UID)];
        sOrderVersion++;
        sPlayingMoved = NO;
        refreshReaders();
    }
    // A track tapped on the page that has the DJ's card ahead of it: the core plays the voice first (it has the track's
    // uid), and the voice is skipped, so the tap lands on the track.
    if (sSkipVoiceUID && track.UID.length) {
        BOOL stale = !sSkipVoiceAsked || -sSkipVoiceAsked.timeIntervalSinceNow > kSkipVoiceSeconds;
        if (!stale && [track.UID isEqualToString:sSkipVoiceUID] && [SGURIString(track.URI) hasPrefix:@"spotify:media:"]) {
            sSkipVoiceUID = nil;
            SGLog(@"queue: the DJ's voice before the tapped track %@ is skipped", track.UID);
            [(id<SPTPlayer>)queuePlayer() skipToNextTrackWithOptions:nil];
            return;
        }
        if (stale || ([track.UID isEqualToString:sSkipVoiceUID] && isDJTrack(track))) sSkipVoiceUID = nil;
    }
    // A DJ track the page removed (or queued by hand) that the player has come to: its voice, then the track itself,
    // are skipped, once each.
    // Come to by a step back that found nothing else behind: back to the track it came from, not on past it (the
    // tracks after a hidden one count as played once they were).
    // A muted internal landing used only to make the next segment is not a listened-to track.
    // Keep it out of the history and out of order enforcement.
    if (sHandingOver && [historyUID(track) isEqualToString:sHandOverAnchorUID]) return;
    BOOL backAsked = sBackAsked && -sBackAsked.timeIntervalSinceNow < 4;
    // A track the user passed with a tap, come to by a step back or as a walk over the history, is played: it is one of
    // the way back, not a track the core came to that was removed or played through the queue.
    BOOL passedWalk = isHidden(track) && playedIndex(historyUID(track)) != NSNotFound && arrived && (backAsked || walking);
    if (isHidden(track) && !passedWalk && !sHandingOver && arrived && backAsked) {
        SPTPlayerTrack *to = nil;
        for (SPTPlayerTrack *t in state.future) {
            if ([SGURIString(t.URI) isEqualToString:@"spotify:delimiter"]) break;
            if (isCoreQueued(t) || isHidden(t)) continue;
            to = t;
            break;
        }
        if (to) {
            SGLog(@"queue: a step back came to the removed or played %@, back to %@", track.trackTitle, to.trackTitle ?: SGURIString(to.URI));
            skipForward(to);
            return;
        }
    }
    if (isHidden(track) && !passedWalk && !sHandingOver) {
        NSString *key = [SGURIString(track.URI) stringByAppendingString:track.UID];
        if (!sSkipped) sSkipped = [NSMutableSet set];
        if (![sSkipped containsObject:key]) {
            [sSkipped addObject:key];
            // Past it and any other the core would come to that played or was removed, in one skip.
            SPTPlayerTrack *to = coreNextUnplayed(state);
            if (!to) {
                // Nothing of the segment is left to play: the core makes the next segment only once it is on the
                // segment's last track, so it goes there in one skip (not through each removed or played track), and on
                // from there once the next segment has come.
                SPTPlayerTrack *last = lastOfSegment(state);
                if (last && !sameGroup(last, track)) {
                    SGLog(@"queue: the player is on a hidden track %@, nothing of the segment is left: on to its last, %@", track.trackTitle, SGURIString(last.URI));
                    skipForward(last);
                } else {
                    SGLog(@"queue: the player is on the segment's last track %@, hidden: on once the next segment comes", track.trackTitle);
                    awaitNextSegment(trackKey(track));
                }
                return;
            }
            SGLog(@"queue: the player is on a hidden track %@ %@, skipping it to %@", track.trackTitle, SGURIString(track.URI), SGURIString(to.URI));
            skipForward(to);
            return;
        }
    }
    // The core has come to a DJ track of its own order that the user's order does not have first.
    if (enforceOrder(state, arrived, walking)) return;
    // noteCopy above may only have learned this copy on its first arrival.
    track = asDJTrack(state.track) ?: state.track;
    if (!isDJTrack(track) || (!inDJ(track) && !sCopyOf[state.track.UID]) || !track.UID.length) return;
    NSUInteger at = NSNotFound;
    for (NSUInteger i = 0; i < sPlayed.count; i++) if ([sPlayed[i].UID isEqualToString:track.UID]) { at = i; break; }
    if (at == NSNotFound) {
        [sPlayed addObject:track];
        return;
    }
    BOOL steppedBack = sBackAsked && -sBackAsked.timeIntervalSinceNow < 4;
    if (!steppedBack && !walking && at + 1 != sPlayed.count) {
        // The core went on to a track that played (its own order has it after this one): it is the newest now, or "next"
        // on it would go back to the track that played after it, and the two would take turns.
        [sPlayed removeObjectAtIndex:at];
        [sPlayed addObject:track];
        SGLog(@"queue: %@ played again, as the newest of the played", track.trackTitle);
    }
}
@end

// What Spotify's now playing screens are shown of the state: its future in the user's order, without what the page
// removed or what has played, so the cover list's next cover is the track the player goes to and a skip to it moves the
// list forward, though the core may step back to it. The mod's own observers, and everything here, read the core's.
static SPTPlayerState *djLens(SPTPlayerState *state) {
    if (!sDJActive || !NSThread.isMainThread || !isDJSession(state)) return state;
    NSArray<SPTPlayerTrack *> *raw = state.future;
    NSArray<SPTPlayerTrack *> *history = historyFutureRows(state);
    NSMutableSet<NSString *> *historyUIDs = [NSMutableSet set];
    for (SPTPlayerTrack *t in history) [historyUIDs addObject:historyUID(t)];
    NSMutableArray<SPTPlayerTrack *> *future = [NSMutableArray array];
    NSMutableSet<NSString *> *placed = [NSMutableSet set];
    for (SPTPlayerTrack *t in raw) {
        if (!isCoreQueued(t)) break;
        if ([historyUIDs containsObject:historyUID(t)]) continue;
        [future addObject:t];
        [placed addObject:trackKey(t)];
    }
    for (SPTPlayerTrack *t in history) { [future addObject:t]; [placed addObject:trackKey(t)]; }
    NSString *current = historyUID(state.track);
    BOOL onVoice = [SGURIString(state.track.URI) hasPrefix:@"spotify:media:"];
    if (sOrdered) {
        for (NSString *uid in sOrder) {
            if (wasPlayed(uid) || [sHidden containsObject:uid]) continue;
            BOOL playing = [uid isEqualToString:current];
            if (playing && !onVoice) continue;
            // Its copy in the core's queue, at the end of the queued tracks, stands for it.
            if (sameGroup(sAheadQueued, sKept[uid].firstObject) && queuedCopyOf(sAheadQueued, state, NULL)) continue;
            for (SPTPlayerTrack *row in sKept[uid]) {
                SPTPlayerTrack *own = originalOf(row);
                if (isCardRow(row) && (playing || [sVoiced containsObject:uid])) continue;
                if ([placed containsObject:trackKey(own)]) continue;
                [future addObject:own];
                [placed addObject:trackKey(own)];
            }
        }
    }
    for (SPTPlayerTrack *t in raw) {
        if ([placed containsObject:trackKey(t)] || [historyUIDs containsObject:historyUID(t)]) continue;
        NSString *uid = baseUID(t.UID);
        BOOL voice = [SGURIString(t.URI) hasPrefix:@"spotify:media:"];
        if (!isCoreQueued(t) && uid.length && (isHidden(t) || (isDJTrack(t) && wasPlayed(uid)) || (voice && [sVoiced containsObject:uid]))) continue;
        [future addObject:t];
        [placed addObject:trackKey(t)];
    }
    // A DJ track playing from the core's queue is shown as the DJ's: its uid and provider, without the queue's marks
    // (is_queued, queued_by), so the player draws no queue badge and keeps the DJ's header and footer.
    SPTPlayerTrack *asDJ = shownDJTrack(state.track);
    if (!asDJ && [future isEqualToArray:raw]) return state;
    static BOOL told;
    if (!told) { told = YES; SGLog(@"queue: the now playing screens are shown the user's order (%lu to come)", (unsigned long)future.count); }
    static BOOL refused;
    if (refused || ![state conformsToProtocol:@protocol(NSCopying)]) {
        if (!refused) SGLog(@"queue: the player's state cannot be copied, the now playing screens get the core's order");
        refused = YES;
        return state;
    }
    @try {
        SPTPlayerState *shown = [(id<NSCopying>)shownDJStateBase(state) copyWithZone:nil];
        [shown setValue:future forKey:@"future"];
        if (asDJ) [shown setValue:asDJ forKey:@"track"];
        return shown;
    } @catch (NSException *exception) {
        refused = YES;
        SGLog(@"queue: the player's state took no other future (%@), the now playing screens get the core's order", exception.reason);
        return state;
    }
}

// The track the DJ played before the one the player is on (or is introducing: the voice has its song's uid), nil
// when none was kept.
// The newest track the DJ played before the current one that is not hidden, a track and not the current one's.
static SPTPlayerTrack *playedBefore(SPTPlayerState *state) {
    NSUInteger at = playedIndex(historyUID(state.track));
    if (at == NSNotFound) at = sPlayed.count;
    while (at > 0) {
        SPTPlayerTrack *candidate = sPlayed[--at];
        if (!isDJTrack(candidate) || staysHidden(candidate) || sameGroup(candidate, state.track)) continue;
        // Prefer the actual instance still held by the core, including a queue copy.
        for (SPTPlayerTrack *past in state.reverse.reverseObjectEnumerator)
            if (sameGroup(past, candidate)) return past;
        return candidate;
    }
    return nil;
}
