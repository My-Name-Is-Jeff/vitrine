// Internal implementation of DJ Queue, compiled through DJQueue.x.
// Kept in one translation unit while the Spotify Logos hooks share session state.
static BOOL sameTrack(SPTPlayerTrack *a, SPTPlayerTrack *b) {
    return [a.URI isEqual:b.URI] && [a.provider isEqualToString:b.provider];
}

static NSUInteger indexIn(NSArray<SPTPlayerTrack *> *tracks, SPTPlayerTrack *track) {
    for (NSUInteger i = 0; i < tracks.count; i++) if (sameTrack(tracks[i], track)) return i;
    return NSNotFound;
}

static NSString *sSignature;

// The DJ's tracks to come as last made up (what the player said, then what was kept after it), what the queue is
// as it is put to the readers, and which of its tracks are the ones put in.
static NSArray<SPTPlayerTrack *> *sAhead = @[], *sQueue = @[], *sInjected = @[];
static id sAheadContext;
// The uids of the DJ's tracks the page removed or that were queued by hand (hidden from its rows), and the tracks
// (uri and uid) the player was already skipped past, once each.
static NSMutableSet<NSString *> *sHidden, *sSkipped;
// The uid of a track the page was tapped on whose "Up next" card is ahead of it, and when: the core plays the card's
// voice first (the voice and the track have one uid), and the voice is skipped when the player comes to it.
static NSString *sSkipVoiceUID;
static NSDate *sSkipVoiceAsked;
// The page's readers of the queue, and the last queue they were given, to tell them again when a row is hidden.
static NSHashTable *sReaders;
// Held, not weak: the core lets go of its queue object before a name comes back from the network, and a weak one
// left refreshReaders with nothing to tell the readers ("no queue to refresh the rows with" in the log).
static id sLastPlayer, sLastQueue;
// The player to command: the one the queue's observers were told by, which is the one the app plays through.
// SGPlayer() is the first player to be given an observer and held weakly; it may be another instance, or gone, and a
// command to it does nothing without a word (taps on the page's tracks did nothing).
static id queuePlayer(void) {
    return sLastPlayer ?: SGPlayer();
}

// The queue button offers either a physical segment skip or a single neutral
// DJ request. Neither mode changes Spotify's native Let DJ pick behavior.
static BOOL sPickingSegment;
static void skipToNextDJSegment(void);

// The DJ's segment (five tracks, a voice before the first and one after the last) with room for the hand-queued.
static const int64_t kFutureCap = 16;
// How long the page keeps its rows while the core has no tracks to come.
static const NSTimeInterval kGapSeconds = 3;
// How long the core has to move to a track it was asked to skip back to.
static const NSTimeInterval kJumpSeconds = 1.5;
// How long a tap on a track behind a card is waited for to reach the card's voice.
static const NSTimeInterval kSkipVoiceSeconds = 10;

// The DJ's session: its playlist, or (for a DJ under another uri) a playlist whose tracks carry the DJ's segment.
static NSString *const kDJContext = @"spotify:playlist:37i9dQZF1EYkqdzj48dyYq";
static BOOL isDJSession(SPTPlayerState *state) {
    NSString *context = SGURIString(state.contextURI);
    if ([context isEqualToString:kDJContext]) return YES;
    return [context hasPrefix:@"spotify:playlist:"] && state.track.metadata[@"segment"] != nil;
}

// A track of the DJ's to come (in the DJ's session): not the narration, a page marker or the delimiter that ends the pages.
static BOOL isDJTrack(SPTPlayerTrack *track) {
    NSString *uri = SGURIString(track.URI);
    return [uri hasPrefix:@"spotify:track:"] || [uri hasPrefix:@"spotify:episode:"];
}

// The DJ's "Up next" card: a voice item (spotify:media:ID) with no segment of its own, followed by the track it
// introduces (the same uid), which carries the card's title and cover until the core has the track's own.
static BOOL isCard(NSArray<SPTPlayerTrack *> *future, NSUInteger i) {
    SPTPlayerTrack *track = future[i];
    return [SGURIString(track.URI) hasPrefix:@"spotify:media:"] && !track.metadata[@"segment"] && i + 1 < future.count &&
           [future[i + 1].UID isEqualToString:track.UID];
}

// The player's own track for each row that is a copy of it (by the copy's identity). The core is skipped to by these.
static NSMapTable<SPTPlayerTrack *, SPTPlayerTrack *> *sOriginals;
static NSString *const kCardSuffix = @"-card";
// The uids that had an "Up next" card in this session: their track stays a row without the card's title and cover
// after the card has gone (the voice has started), so the row's content does not change under the table.
static NSMutableSet<NSString *> *sCarded;
static NSMutableSet<NSString *> *sLoggedCards;
// The player's own card track by uid, kept so the card's row can stay while its voice plays, and so a skip to its
// track goes through the voice.
static NSMutableDictionary<NSString *, SPTPlayerTrack *> *sCardTracks;
// The uids whose "Up next" voice the player has come to.
static NSMutableSet<NSString *> *sVoiced;

static SPTPlayerTrack *originalOf(SPTPlayerTrack *row) {
    return [sOriginals objectForKey:row] ?: row;
}

static SPTPlayerTrack *copyOf(SPTPlayerTrack *track, NSDictionary *metadata, NSString *uid) {
    SPTPlayerTrack *copy = [track copy];
    if (metadata) [copy setValue:metadata forKey:@"metadata"];
    if (uid) [copy setValue:uid forKey:@"UID"];
    if (!sOriginals) sOriginals = [NSMapTable mapTableWithKeyOptions:NSPointerFunctionsWeakMemory | NSPointerFunctionsObjectPointerPersonality
                                                        valueOptions:NSPointerFunctionsStrongMemory];
    [sOriginals setObject:track forKey:copy];
    return copy;
}

// The card as its own row, with a uid that is not its track's.
static SPTPlayerTrack *cardRow(SPTPlayerTrack *card) {
    return copyOf(card, nil, [card.UID stringByAppendingString:kCardSuffix]);
}

// The core names the track a card introduces only when it plays, so its name and cover are asked of Spotify's public
// oEmbed once (title and thumbnail, no artist) and put on its row when they come.
static NSMutableDictionary<NSString *, NSDictionary *> *sNamed;
static NSMutableDictionary<NSString *, NSString *> *sArtists;
static NSMutableSet<NSString *> *sNameAsked;
// When a name was last asked and did not come (offline, a refusal): it is asked again only after kNameRetry, not at
// every rebuild of the rows.
static NSMutableDictionary<NSString *, NSDate *> *sNameFailed;
static const NSTimeInterval kNameRetry = 60;
static void refreshReaders(void);
static void saveSession(void);
static void scheduleHandOver(void);

// oEmbed gives the title and the cover but no artist. The artist is read from the track's public page, whose title
// is "<song> - song and lyrics by <artist> | Spotify"; it is put on the row when it comes, and the row has none until.
static void askArtist(NSString *uri) {
    NSURL *url = [NSURL URLWithString:[@"https://open.spotify.com/track/" stringByAppendingString:[uri componentsSeparatedByString:@":"].lastObject]];
    if (!url) return;
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    [request setValue:@"Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
   forHTTPHeaderField:@"User-Agent"];
    [request setValue:@"en-US,en;q=0.9" forHTTPHeaderField:@"Accept-Language"];
    [[[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSString *html = data.length ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
        NSString *artist = nil, *pageTitle = nil;
        NSRange open = html ? [html rangeOfString:@"<title>"] : NSMakeRange(NSNotFound, 0);
        NSRange close = html ? [html rangeOfString:@"</title>"] : NSMakeRange(NSNotFound, 0);
        if (open.location != NSNotFound && close.location != NSNotFound && close.location > NSMaxRange(open)) {
            pageTitle = [html substringWithRange:NSMakeRange(NSMaxRange(open), close.location - NSMaxRange(open))];
            NSRegularExpression *pattern = [NSRegularExpression regularExpressionWithPattern:@"^.* by (.+?) \\| Spotify$"
                options:NSRegularExpressionDotMatchesLineSeparators error:nil];
            NSTextCheckingResult *match = [pattern firstMatchInString:pageTitle options:0 range:NSMakeRange(0, pageTitle.length)];
            if (match) artist = [pageTitle substringWithRange:[match rangeAtIndex:1]];
        }
        artist = [[[[artist stringByReplacingOccurrencesOfString:@"&amp;" withString:@"&"]
                    stringByReplacingOccurrencesOfString:@"&#x27;" withString:@"'"]
                   stringByReplacingOccurrencesOfString:@"&quot;" withString:@"\""]
                  stringByReplacingOccurrencesOfString:@"&#39;" withString:@"'"];
        NSInteger status = [response isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse *)response).statusCode : 0;
        SGLog(@"queue: artist of %@: %@", uri, artist.length ? artist : [NSString stringWithFormat:@"none (http %ld, %lu bytes, page title %@)",
              (long)status, (unsigned long)data.length, pageTitle ?: @"-"]);
        if (!artist.length) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!sArtists) sArtists = [NSMutableDictionary dictionary];
            sArtists[uri] = artist;
            sSignature = nil;
            refreshReaders();
        });
    }] resume];
}

static void askName(NSString *uri) {
    if (!uri.length) return;
    if (!sNameAsked) sNameAsked = [NSMutableSet set];
    if ([sNameAsked containsObject:uri]) return;
    NSDate *failed = sNameFailed[uri];
    if (failed && -failed.timeIntervalSinceNow < kNameRetry) return;
    [sNameAsked addObject:uri];
    NSString *address = [@"https://open.spotify.com/oembed?url=" stringByAppendingString:
        [[@"https://open.spotify.com/track/" stringByAppendingString:[uri componentsSeparatedByString:@":"].lastObject]
         stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLQueryAllowedCharacterSet]];
    NSURL *url = [NSURL URLWithString:address];
    if (!url) return;
    if (!sArtists[uri]) askArtist(uri);
    [[[NSURLSession sharedSession] dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSDictionary *json = data.length ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        NSString *title = [json[@"title"] isKindOfClass:NSString.class] ? json[@"title"] : nil;
        NSInteger status = [response isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse *)response).statusCode : 0;
        SGLog(@"queue: name of %@: %@", uri, title ?: [NSString stringWithFormat:@"none (http %ld, %lu bytes, %@)", (long)status,
              (unsigned long)data.length, error.localizedDescription ?: @"no error"]);
        if (!title.length) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [sNameAsked removeObject:uri];
                if (!sNameFailed) sNameFailed = [NSMutableDictionary dictionary];
                sNameFailed[uri] = [NSDate date];
            });
            return;
        }
        NSString *thumb = [json[@"thumbnail_url"] isKindOfClass:NSString.class] ? json[@"thumbnail_url"] : nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!sNamed) sNamed = [NSMutableDictionary dictionary];
            sNamed[uri] = thumb ? @{@"title": title, @"image": thumb} : @{@"title": title};
            sSignature = nil;
            refreshReaders();
        });
    }] resume];
}

// The track a card introduces, as its own row: the card's title, artist and cover taken off, so the row shows the
// track and not the card (its own title is not known until it plays).
static SPTPlayerTrack *withoutCard(SPTPlayerTrack *track) {
    NSMutableDictionary *metadata = [track.metadata mutableCopy];
    for (NSString *key in track.metadata) {
        if ([key hasPrefix:@"title"] || [key hasPrefix:@"artist_name"] || [key hasPrefix:@"image"] || [key hasPrefix:@"thumbnail"]) [metadata removeObjectForKey:key];
    }
    NSString *uri = SGURIString(track.URI);
    NSDictionary *named = sNamed[uri];
    if (named) {
        metadata[@"title"] = named[@"title"];
        NSString *artist = sArtists[uri];
        if (artist.length) metadata[@"artist_name"] = artist;
        NSString *image = named[@"image"];
        if (image) for (NSString *key in @[@"image_url", @"image_small_url", @"image_large_url", @"image_xlarge_url", @"thumbnail_image_url"]) metadata[key] = image;
    } else {
        askName(uri);
    }
    return copyOf(track, metadata, nil);
}

// The uid a row has as the player's: the card's row has the suffix on it.
static NSString *baseUID(NSString *uid) {
    return [uid hasSuffix:kCardSuffix] ? [uid substringToIndex:uid.length - kCardSuffix.length] : uid;
}

// A track's metadata as one line of the log: each key with the start of its value.
static NSString *describeMeta(NSDictionary *metadata) {
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    for (NSString *key in [metadata.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
        NSString *value = [NSString stringWithFormat:@"%@", metadata[key]];
        if (value.length > 48) value = [[value substringToIndex:48] stringByAppendingString:@"~"];
        [parts addObject:[NSString stringWithFormat:@"%@=%@", key, value]];
    }
    return [parts componentsJoinedByString:@" "];
}

#pragma mark - the card's avatar

// The page leaves the DJ's avatar off the "Up next" card's row (a placeholder where its image is), so it is drawn here:
// the card's image_url is fetched once and put in the row's image view when the cell lays out.
static UIImage *sCardAvatar;
static NSString *sCardAvatarURL, *sCardTitle;
static NSHashTable<UITableViewCell *> *sQueueCells;
// The avatar views put in rows, taken off when the DJ's session ends; and whether it is the DJ's session, as the queue
// was last made up, so the page's cells and table do nothing of this anywhere else.
static NSHashTable<UIView *> *sAvatarViews;
static BOOL sDJActive;
// The queue reader can activate before the page receives its final layout.
static __weak UIView *sQueuePageView;
static char kNewSegmentEditPending;
static void drawNewSegmentButtonSoon(UIView *page);
static void hideNextDJSet(UIView *page);

static void loadCardAvatar(NSString *url) {
    if (!url.length || [url isEqualToString:sCardAvatarURL]) return;
    sCardAvatarURL = url;
    NSURL *address = [NSURL URLWithString:url];
    if (!address) return;
    [[[NSURLSession sharedSession] dataTaskWithURL:address completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        UIImage *image = data.length ? [UIImage imageWithData:data] : nil;
        SGLog(@"queue: card avatar %@: %@", url, image ? @"loaded" : (error.localizedDescription ?: @"no image"));
        if (!image) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            sCardAvatar = image;
            for (UITableViewCell *cell in sQueueCells.allObjects) [cell setNeedsLayout];
        });
    }] resume];
}

static UIView *descendant(UIView *root, BOOL (^match)(UIView *)) {
    for (UIView *view in root.subviews) {
        if (match(view)) return view;
        UIView *found = descendant(view, match);
        if (found) return found;
    }
    return nil;
}

// The avatar in the cell of the card's row (the row whose accessibility label has the card's title): a view of ours in
// the row's art, over Spotify's own image view. Spotify sets its image view's alpha and image again when the row is
// selected or reloaded (the avatar went away on a tap on the card); a view of ours it does not touch stays. In any
// other row the view is taken off, as cells are reused.
static const NSInteger kAvatarTag = 0x5367;
static char kAvatarArtAlpha;
// Spotify rounds the art of its rows; the avatar takes the corners of a row that is not the card's. Nothing else says
// what they are (the row's art has no radius on it until its image is set, which the card's never is).
static const CGFloat kFallbackRadius = 4;

static CGFloat sRowsRadius;
static CGFloat otherRowsRadius(void) {
    if (sRowsRadius > 0) return sRowsRadius;
    for (UITableViewCell *cell in sQueueCells.allObjects) {
        UIView *row = descendant(cell.contentView, ^BOOL(UIView *view) { return [view.accessibilityIdentifier isEqualToString:@"TrackRowQueue.Cell"]; });
        if (!row || (sCardTitle.length && [row.accessibilityLabel containsString:sCardTitle])) continue;
        UIView *art = descendant(row, ^BOOL(UIView *view) { return [view.accessibilityIdentifier isEqualToString:@"Encore.ImageView"]; });
        UIView *image = art ? descendant(art, ^BOOL(UIView *view) { return [view isMemberOfClass:UIImageView.class] && view.tag != kAvatarTag; }) : nil;
        CGFloat radius = MAX(art.layer.cornerRadius, image.layer.cornerRadius);
        if (radius > 0) return sRowsRadius = radius;
    }
    return 0;
}

static void drawAvatarInRow(UIView *row) {
    UIView *art = row ? descendant(row, ^BOOL(UIView *view) { return [view.accessibilityIdentifier isEqualToString:@"Encore.ImageView"]; }) : nil;
    if (!art) return;
    UIImageView *mine = (UIImageView *)[art viewWithTag:kAvatarTag];
    BOOL isCard = sCardAvatar && sCardTitle.length && [row.accessibilityLabel containsString:sCardTitle];
    if (!isCard) {
        NSNumber *original = objc_getAssociatedObject(art, &kAvatarArtAlpha);
        if (mine && original) art.alpha = original.floatValue;
        objc_setAssociatedObject(art, &kAvatarArtAlpha, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [mine removeFromSuperview];
        return;
    }
    UIImageView *inner = (UIImageView *)descendant(art, ^BOOL(UIView *view) { return [view isMemberOfClass:UIImageView.class] && view.tag != kAvatarTag; });
    if (!mine) {
        objc_setAssociatedObject(art, &kAvatarArtAlpha, @(art.alpha), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        mine = [[UIImageView alloc] init];
        mine.tag = kAvatarTag;
        mine.contentMode = UIViewContentModeScaleAspectFill;
        mine.clipsToBounds = YES;
        mine.userInteractionEnabled = NO;
        mine.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [art addSubview:mine];
        if (!sAvatarViews) sAvatarViews = [NSHashTable weakObjectsHashTable];
        [sAvatarViews addObject:mine];
    }
    mine.frame = art.bounds;
    CGFloat radius = MAX(art.layer.cornerRadius, inner.layer.cornerRadius);
    if (radius <= 0) radius = otherRowsRadius();
    mine.layer.cornerRadius = radius > 0 ? radius : kFallbackRadius;
    mine.image = sCardAvatar;
    mine.alpha = 1;
    mine.hidden = NO;
    art.alpha = 1;
    // Never set hidden on Spotify's Encore stacks (AGENTS.md). Their reuse
    // restores the alpha recorded above, without altering the native stack.
    [art bringSubviewToFront:mine];
}

static void drawCardAvatar(UITableViewCell *cell) {
    if (!sDJActive || !sCardAvatar) return;
    UIView *row = descendant(cell.contentView, ^BOOL(UIView *view) { return [view.accessibilityIdentifier isEqualToString:@"TrackRowQueue.Cell"] || [view.accessibilityIdentifier isEqualToString:@"TrackRowQueue.Header"]; });
    if (row) drawAvatarInRow(row);
}

// The "Now playing" row above the table is not a cell: while the DJ's voice plays it is the card, and it has the
// placeholder where the avatar goes. It is found in the page's view and drawn the same.
static void drawHeaderAvatar(UIView *page) {
    if (!sDJActive || !sCardAvatar) return;
    UIView *row = descendant(page, ^BOOL(UIView *view) { return [view.accessibilityIdentifier isEqualToString:@"TrackRowQueue.Header"]; });
    if (row) drawAvatarInRow(row);
}

// The avatar is drawn now and again as the row settles: selecting, highlighting and reloading it all redo Spotify's own.
static void drawCardAvatarSoon(UITableViewCell *cell) {
    if (!sDJActive || !sCardAvatar) return;
    drawCardAvatar(cell);
    __weak UITableViewCell *weakCell = cell;
    for (NSNumber *delay in @[@0.05, @0.3, @0.8]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay.doubleValue * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            UITableViewCell *strongCell = weakCell;
            if (strongCell) drawCardAvatar(strongCell);
        });
    }
}

// The tracks the DJ has to come in the state's future, each "Up next" card as its own row before its track: they end
// at the delimiter, after which the core puts the whole session again as hidden stand-ins, and a track the list has
// already named is such a stand-in too.
// A track the core made for the queue: its provider is "queue", or (as a DJ track queued by hand comes back, with the
// context's provider) its uid starts with q, which a context's uids (hex) never do.
static BOOL isCoreQueued(SPTPlayerTrack *track) {
    return [track.provider isEqualToString:@"queue"] || [track.UID hasPrefix:@"q"];
}

static NSArray<SPTPlayerTrack *> *djFuture(NSArray<SPTPlayerTrack *> *future) {
    NSMutableArray<SPTPlayerTrack *> *tracks = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    SPTPlayerTrack *card;
    for (NSUInteger i = 0; i < future.count; i++) {
        SPTPlayerTrack *track = future[i];
        if (isCoreQueued(track)) continue;
        if ([SGURIString(track.URI) isEqualToString:@"spotify:delimiter"]) break;
        BOOL isTheCard = isCard(future, i);
        if (!isTheCard && !isDJTrack(track)) continue;
        if (track.UID.length) {
            NSString *key = [SGURIString(track.URI) stringByAppendingString:track.UID];
            if ([seen containsObject:key]) break;
            [seen addObject:key];
        }
        if (isTheCard) {
            if (!sCarded) sCarded = [NSMutableSet set];
            [sCarded addObject:track.UID];
            if (!sLoggedCards) sLoggedCards = [NSMutableSet set];
            if (![sLoggedCards containsObject:track.UID]) {
                [sLoggedCards addObject:track.UID];
                SGLog(@"queue: card %@ [%@] metadata: %@", SGURIString(track.URI), track.UID, describeMeta(track.metadata));
                SGLog(@"queue: its track %@ [%@] metadata: %@", SGURIString(future[i + 1].URI), future[i + 1].UID, describeMeta(future[i + 1].metadata));
            }
            if (!sCardTracks) sCardTracks = [NSMutableDictionary dictionary];
            sCardTracks[track.UID] = track;
            card = track;
            sCardTitle = track.metadata[@"title"];
            loadCardAvatar(track.metadata[@"image_url"]);
            track = cardRow(track);
        } else if (!track.metadata[@"segment"] && ((card && [card.UID isEqualToString:track.UID]) || [sCarded containsObject:track.UID])) {
            // The card's track: with the card before it, and after the card has gone, the same row.
            track = withoutCard(track);
        }
        if (!isTheCard) card = nil;
        [tracks addObject:track];
    }
    return tracks;
}

// Whether the track is the DJ's: its metadata names the session's page.
static BOOL inDJ(SPTPlayerTrack *track) {
    return track.metadata[@"page_instance_id"] != nil;
}

static BOOL isHidden(SPTPlayerTrack *track) {
    return track.UID.length && [sHidden containsObject:baseUID(track.UID)];
}

// The DJ's track on the page's rows that a command names: by uri and uid, or by the uri alone when it has no uid.
static SPTPlayerTrack *injectedNamed(NSString *uri, NSString *uid) {
    for (SPTPlayerTrack *track in sInjected) {
        if (![SGURIString(track.URI) isEqualToString:uri]) continue;
        if (!uid.length || [track.UID isEqualToString:uid]) return track;
    }
    return nil;
}

static void hideTrack(SPTPlayerTrack *track, NSString *why) {
    if (!track.UID.length) return;
    if (!sHidden) sHidden = [NSMutableSet set];
    [sHidden addObject:baseUID(track.UID)];
    SGLog(@"queue: %@ is hidden from the DJ's rows (%@) [%@]", track.trackTitle, why, track.UID);
}

#pragma mark - the order the user gave the DJ's rows

// The DJ's tracks as they have played, in the session's order, whole, for the steps back the core has no track for.
static NSMutableArray<SPTPlayerTrack *> *sPlayed;
// Whether the user has arranged the DJ's rows, the uids (base) of the groups (a card and its track, or a track) in
// their order, the rows of each as the DJ sent them, and a number that changes with the order, for the list's cache.
static BOOL sOrdered;
static NSMutableArray<NSString *> *sOrder;
static NSMutableDictionary<NSString *, NSArray<SPTPlayerTrack *> *> *sKept;
static NSUInteger sOrderVersion;
// The uids of DJ tracks the core came to that the user's order did not have first: they were skipped away from, not
// played, so they stay in the order (the core's own future has forgotten them).
static NSMutableSet<NSString *> *sBounced;
// When the player was last asked to step back (the previous button, or a replay here): an arrival at a track that has
// played, soon after, is the step back; any other is the track played again, as the newest.
static NSDate *sBackAsked;
// The uids of the DJ's tracks the user went past with a tap on a later row: hidden from the rows, but they are in the
// core's history and in sPlayed, so a step back (and the next after it) goes over them one by one. A track removed or
// played through the queue is not among them: a step back still goes past it.
static NSMutableSet<NSString *> *sPassed;
// The DJ track the next button was last sent back over the history to, and when: its arrival is the walk, not the core
// coming to a track that played.
static NSString *sWalkUID;
static NSDate *sWalkAt;
static NSTimer *sHeaderTimer;
static __weak UIViewController *sHeaderTimerPage;
static NSDate *sNativeQueueAt;
static __weak id sWrapper;
static SPTPlayerTrack *sSwipeRow;

static BOOL isCardRow(SPTPlayerTrack *row) {
    return [SGURIString(row.URI) hasPrefix:@"spotify:media:"];
}

// The uids of the DJ's tracks that played before this launch (sPlayed holds only this launch's, whole).
static NSMutableSet<NSString *> *sPlayedBefore;
// The queue page's table, for its Edit selection.
static __weak UITableView *sEditTable;

static BOOL wasPlayed(NSString *uid) {
    if ([sPlayedBefore containsObject:uid]) return YES;
    for (SPTPlayerTrack *played in sPlayed) if ([baseUID(played.UID) isEqualToString:uid]) return YES;
    return NO;
}

static NSMutableDictionary<NSString *, NSDictionary *> *sCopyOf;
static BOOL staysHidden(SPTPlayerTrack *track) {
    if (!isHidden(track) || [sPassed containsObject:baseUID(track.UID)]) return NO;
    // A context original hidden because its queue copy played remains a history entry.
    for (NSDictionary *copy in sCopyOf.allValues)
        if ([baseUID(copy[@"uid"]) isEqualToString:baseUID(track.UID)] &&
            [copy[@"uri"] isEqualToString:SGURIString(track.URI)]) return NO;
    return YES;
}

static NSUInteger playedIndex(NSString *uid) {
    for (NSUInteger i = 0; i < sPlayed.count; i++) if ([baseUID(sPlayed[i].UID) isEqualToString:uid]) return i;
    return NSNotFound;
}

// The player came to a track that has played, as a walk over the history and not as the core going back to it on its own:
// the one the next button was sent to, or the one that played right after the track the player was on.
static BOOL walkArrival(SPTPlayerTrack *track, NSString *leftUID) {
    NSString *uid = baseUID(track.UID);
    NSUInteger at = uid.length ? playedIndex(uid) : NSNotFound;
    if (at == NSNotFound) return NO;
    if (sWalkUID && sWalkAt && -sWalkAt.timeIntervalSinceNow < 4 && [sWalkUID isEqualToString:uid]) return YES;
    NSString *left = baseUID(leftUID);
    return at > 0 && left.length && [baseUID(sPlayed[at - 1].UID) isEqualToString:left];
}

static NSInteger placeOf(UITableView *table, NSIndexPath *path) {
    NSInteger place = path.row;
    for (NSInteger section = 0; section < path.section; section++) place += [table numberOfRowsInSection:section];
    return place;
}

// A track the user dragged from the hand-queued rows (the core's) into the DJ's: it is a row of the DJ's order now, by
// the uid (base) of its row, with the row and the core's own track it is made from. The core does not have it in its
// queue any more; it is put first in the core's queue when its turn in the order comes, and the row goes when it plays.
static NSMutableDictionary<NSString *, NSDictionary *> *sMoved;
static BOOL sPlayingMoved;

static NSDictionary *movedBySource(SPTPlayerTrack *track) {
    for (NSDictionary *entry in sMoved.allValues) {
        SPTPlayerTrack *src = entry[@"src"];
        if ([src.UID isEqualToString:track.UID] && [src.URI isEqual:track.URI]) return entry;
    }
    return nil;
}

// The DJ's session as the user left it (the order, what was removed, played or passed, the voices heard), kept in the
// defaults so a launch that goes on in the same session goes on with it. The core keeps the uids of the session's
// tracks over a launch; uids it no longer has match nothing and are let go.
static const NSUInteger kSavedMax = 300;
// The DJ's context URI is constant across sessions. Only restore a recent snapshot
// at the exact physical playback item where it was written.
static const NSTimeInterval kSessionRestoreWindow = 6 * 60 * 60;
static id sPlayedContext;
static NSString *sSavedLine;

static void clearSavedSession(void) {
    sSavedLine = nil;
    SGPrefsWriteUnmemoized(^{ [NSUserDefaults.standardUserDefaults removeObjectForKey:SGKeyDJQueueSession]; });
}


static NSArray<NSString *> *lastOf(id<NSFastEnumeration> uids) {
    NSMutableArray<NSString *> *all = [NSMutableArray array];
    for (NSString *uid in uids) if ([uid isKindOfClass:NSString.class] && uid.length) [all addObject:uid];
    return all.count > kSavedMax ? [all subarrayWithRange:NSMakeRange(all.count - kSavedMax, kSavedMax)] : all;
}

// The copies the core played in the DJ's place (q-uid -> the original's uid, uri, providers, title), below.
// Queue copies and their context original are one position in the user's history.
static NSString *historyUID(SPTPlayerTrack *track) {
    NSDictionary *copy = sCopyOf[track.UID];
    return baseUID(copy && [copy[@"uri"] isEqualToString:SGURIString(track.URI)] ? copy[@"uid"] : track.UID);
}
// The DJ track put in the core's queue ahead of its turn (below), and its uri as kept over a launch: the copy is still in
// the core's queue then, and was shown as a track queued by hand (above its own card) when it was not wanted any more.
static SPTPlayerTrack *sAheadQueued;
// The exact q-UID of an owned copy, never its song URI. Other queued copies
// of that URI are independently owned by the user.
static NSString *sAheadBeforeLaunch;
static SPTPlayerTrack *queuedCopyOf(SPTPlayerTrack *track, SPTPlayerState *state, BOOL *notLast);

static void saveSession(void) {
    SPTPlayerState *state = SGPlayerState();
    if (!sDJActive || !sAheadContext || !isDJSession(state) || !state.track.UID.length) return;
    NSMutableArray<NSString *> *played = [NSMutableArray arrayWithArray:sPlayedBefore.allObjects];
    for (SPTPlayerTrack *t in sPlayed) if (t.UID.length) [played addObject:baseUID(t.UID)];
    NSDictionary *session = @{
        @"context": SGURIString(sAheadContext) ?: @"",
        @"savedAt": @([NSDate date].timeIntervalSince1970),
        @"currentUID": state.track.UID,
        @"currentURI": SGURIString(state.track.URI) ?: @"",
        @"ordered": @(sOrdered),
        @"order": lastOf(sOrder ?: @[]),
        @"hidden": lastOf(sHidden ?: [NSSet set]),
        @"played": lastOf(played),
        @"voiced": lastOf(sVoiced ?: [NSSet set]),
        @"copies": sCopyOf ?: @{},
        @"aheadUID": sAheadQueued ? queuedCopyOf(sAheadQueued, state, NULL).UID ?: @"" : @"",
    };
    NSMutableDictionary *signature = [session mutableCopy];
    [signature removeObjectForKey:@"savedAt"];
    NSString *line = [NSString stringWithFormat:@"%@", signature];
    if ([line isEqualToString:sSavedLine]) return;
    sSavedLine = line;
    SGPrefsWriteUnmemoized(^{ [NSUserDefaults.standardUserDefaults setObject:session forKey:SGKeyDJQueueSession]; });
}

// Once per launch, restore only when the first usable DJ playback item is the
// same as the item saved at shutdown. Identical playlist URIs are NOT session IDs.
static void restoreSession(SPTPlayerState *state) {
    static BOOL done;
    if (done || !isDJSession(state) || !state.track.UID.length) return;
    done = YES;
    NSDictionary *saved = [NSUserDefaults.standardUserDefaults dictionaryForKey:SGKeyDJQueueSession];
    if (!saved) return;
    NSString *context = SGURIString(state.contextURI);
    NSTimeInterval savedAt = [saved[@"savedAt"] respondsToSelector:@selector(doubleValue)] ? [saved[@"savedAt"] doubleValue] : 0;
    NSTimeInterval age = [NSDate date].timeIntervalSince1970 - savedAt;
    if (!context.length || ![saved[@"context"] isEqual:context] || age < 0 || age > kSessionRestoreWindow ||
        ![saved[@"currentUID"] isEqual:state.track.UID] ||
        ![saved[@"currentURI"] isEqual:SGURIString(state.track.URI)]) {
        SGLog(@"queue: saved DJ session discarded: old context, expired or different playback item");
        clearSavedSession();
        return;
    }
    NSSet *(^set)(NSString *) = ^NSSet *(NSString *key) { return [NSSet setWithArray:lastOf([saved[key] isKindOfClass:NSArray.class] ? saved[key] : @[])]; };
    sAheadContext = state.contextURI;
    sPlayedContext = state.contextURI;
    sPlayed = [NSMutableArray array];
    sHidden = [set(@"hidden") mutableCopy];
    sVoiced = [set(@"voiced") mutableCopy];
    sPlayedBefore = [set(@"played") mutableCopy];
    sOrder = [lastOf([saved[@"order"] isKindOfClass:NSArray.class] ? saved[@"order"] : @[]) mutableCopy];
    sOrdered = [saved[@"ordered"] boolValue] && sOrder.count;
    if ([saved[@"aheadUID"] isKindOfClass:NSString.class] && [saved[@"aheadUID"] length]) sAheadBeforeLaunch = saved[@"aheadUID"];
    if ([saved[@"copies"] isKindOfClass:NSDictionary.class]) {
        sCopyOf = [NSMutableDictionary dictionary];
        [(NSDictionary *)saved[@"copies"] enumerateKeysAndObjectsUsingBlock:^(id key, id info, BOOL *stop) {
            if ([key isKindOfClass:NSString.class] && [info isKindOfClass:NSDictionary.class] && [info[@"uid"] isKindOfClass:NSString.class] &&
                [info[@"uri"] isKindOfClass:NSString.class]) sCopyOf[key] = info;
        }];
    }
    sOrderVersion++;
    SGLog(@"queue: the DJ's session goes on from the last launch: %lu in the user's order%@, %lu hidden, %lu played", (unsigned long)sOrder.count,
          sOrdered ? @"" : @" (none arranged)", (unsigned long)sHidden.count, (unsigned long)sPlayedBefore.count);
    // A copy put in ahead before the launch is still in the core's queue: it is taken up again (queueAhead) once the
    // rows are made, not shown as a track queued by hand until the next track.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ refreshReaders(); });
}

static void forgetOrder(void) {
    [sMoved removeAllObjects];
    sOrdered = NO;
    [sOrder removeAllObjects];
    [sKept removeAllObjects];
    [sBounced removeAllObjects];
    sOrderVersion++;
}

// The DJ's rows in the user's order: the groups the core still names and the ones kept from before, without the ones
// that have played, are hidden or are playing now; what the core names that is new goes at the end.
// The group playing now stays in sOrder until it has played (it is only not a row): the queue's readers and the
// history observer hear of a state in either order, and enforceOrder holds the player to sOrder by it. Taken out here
// first, the core's arrival at a group the user had put later was not seen as one, and it played.
static NSMutableArray<SPTPlayerTrack *> *arrangedRows(NSArray<SPTPlayerTrack *> *shown, SPTPlayerState *state) {
    if (!sKept) sKept = [NSMutableDictionary dictionary];
    NSString *current = inDJ(state.track) ? baseUID(state.track.UID) : nil;
    NSMutableArray<NSString *> *seen = [NSMutableArray array];
    NSMutableDictionary<NSString *, NSMutableArray<SPTPlayerTrack *> *> *fresh = [NSMutableDictionary dictionary];
    for (SPTPlayerTrack *row in shown) {
        NSString *uid = baseUID(row.UID);
        if (!uid.length) continue;
        if (!fresh[uid]) { fresh[uid] = [NSMutableArray array]; [seen addObject:uid]; }
        [fresh[uid] addObject:row];
    }
    for (NSString *uid in seen) {
        if (wasPlayed(uid) || ([uid isEqualToString:current] && ![sBounced containsObject:uid])) continue;
        sKept[uid] = fresh[uid];
    }
    NSMutableArray<NSString *> *order = [NSMutableArray array];
    for (NSString *uid in sOrder) if (sKept[uid] && ![order containsObject:uid]) [order addObject:uid];
    for (NSString *uid in seen) if (sKept[uid] && ![order containsObject:uid]) [order addObject:uid];
    for (NSString *uid in [sKept.allKeys copy]) {
        if (wasPlayed(uid) || [sHidden containsObject:uid]) {
            [sKept removeObjectForKey:uid];
            [order removeObject:uid];
        }
    }
    sOrder = order;
    NSMutableArray<SPTPlayerTrack *> *out = [NSMutableArray array];
    for (NSString *uid in order) {
        if ([uid isEqualToString:current] && ![sBounced containsObject:uid]) continue;
        [out addObjectsFromArray:sKept[uid]];
    }
    return out;
}

// The index of the track of the "Up next" card that is the first of the DJ's rows (the card is the row before it),
// -1 when the first of the DJ's rows is not a card. The card and its track are one: nothing is put above or between them.
static NSInteger topPairEnd(NSArray<SPTPlayerTrack *> *list) {
    for (NSUInteger i = 0; i < list.count; i++) {
        if (isCoreQueued(list[i])) continue;
        return isCardRow(list[i]) && i + 1 < list.count ? (NSInteger)i + 1 : -1;
    }
    return -1;
}

// A hand-queued row of the core's dragged into the DJ's rows: its row of the DJ's order (nil when the drag is not that:
// it stays among the hand-queued, or goes above the "Up next" card). The core's queue is given without it.
static void takeOutOfCoreQueue(SPTPlayerTrack *src) {
    id queue = sLastQueue, player = queuePlayer();
    if (!queue || !player) { SGLog(@"queue: moved %@: no queue or player to take it out of the core's queue", src.trackTitle); return; }
    NSMutableArray<SPTPlayerTrack *> *left = [NSMutableArray array];
    for (SPTPlayerTrack *t in [queue valueForKey:@"nextTracks"]) {
        if (!isCoreQueued(t) || ([t.UID isEqualToString:src.UID] && [t.URI isEqual:src.URI])) continue;
        [left addObject:t];
    }
    id copy = [queue copy];
    [copy setValue:left forKey:@"nextTracks"];
    SGLog(@"queue: moved %@ [%@]: the core's queue is set to its %lu hand-queued tracks without it", src.trackTitle, src.UID, (unsigned long)left.count);
    SEL setQueue = NSSelectorFromString(@"setQueue:options:loggingParams:");
    if (![player respondsToSelector:setQueue]) { SGLog(@"queue: moved %@: the player has no setQueue", src.trackTitle); return; }
    id result = ((id (*)(id, SEL, id, id, id))objc_msgSend)(player, setQueue, copy, nil, nil);
    SGLog(@"queue: moved %@: setQueue answered %@", src.trackTitle, result);
}

static SPTPlayerTrack *movedRowFor(NSArray<SPTPlayerTrack *> *list, NSInteger from, NSInteger to) {
    SPTPlayerTrack *src = list[from];
    if (!isCoreQueued(src)) return nil;
    NSInteger queued = 0;
    for (SPTPlayerTrack *t in list) { if (isCoreQueued(t)) queued++; else break; }
    // Still among the hand-queued: the page's own reorder.
    if (to < queued) return nil;
    NSInteger pairEnd = topPairEnd(list);
    if (pairEnd >= 0 && to < pairEnd) {
        SGLog(@"queue: moved %@: not taken above the Up next card", src.trackTitle);
        return nil;
    }
    NSString *uid = [@"m" stringByAppendingString:src.UID ?: @""];
    NSMutableDictionary *metadata = [src.metadata mutableCopy] ?: [NSMutableDictionary dictionary];
    NSString *instance = sInjected.firstObject.metadata[@"page_instance_id"];
    if (instance) metadata[@"page_instance_id"] = instance;
    SPTPlayerTrack *row = copyOf(src, metadata, uid);
    @try { [row setValue:@"context" forKey:@"provider"]; } @catch (NSException *e) { SGLog(@"queue: moved %@: no provider to set: %@", src.trackTitle, e.reason); }
    if (!sMoved) sMoved = [NSMutableDictionary dictionary];
    sMoved[uid] = @{@"row": row, @"src": src};
    SGLog(@"queue: moved %@ [%@] from the hand-queued into the DJ's rows as %@, at %ld", src.trackTitle, src.UID, uid, (long)to);
    takeOutOfCoreQueue(src);
    return row;
}

// A drag on the page: the row at `from` of the list it shows is now at `to`. A card is moved with its track, and a
// track with its card. Only the DJ's rows are arranged; NO when the drag was not one.
static BOOL arrangeByDrag(NSArray<SPTPlayerTrack *> *list, NSInteger from, NSInteger to) {
    NSInteger count = (NSInteger)list.count;
    if (from < 0 || to < 0 || from >= count || to >= count || from == to) return NO;
    SPTPlayerTrack *moved = list[from];
    if (indexIn(sInjected, moved) == NSNotFound) {
        SPTPlayerTrack *row = movedRowFor(list, from, to);
        if (!row) return NO;
        NSMutableArray<SPTPlayerTrack *> *swapped = [list mutableCopy];
        swapped[from] = row;
        list = swapped;
        moved = row;
        sInjected = [sInjected arrayByAddingObject:row];
    }
    // Above the "Up next" card (or between it and its track) goes nothing from below them, and the card is not moved.
    NSInteger pairEnd = topPairEnd(list);
    if (pairEnd >= 0 && (isCardRow(moved) || (from > pairEnd && to <= pairEnd))) {
        SGLog(@"queue: the drag of %@ above the Up next card is not taken", moved.trackTitle);
        return NO;
    }
    NSMutableArray<SPTPlayerTrack *> *after = [list mutableCopy];
    [after removeObjectAtIndex:from];
    [after insertObject:moved atIndex:to];
    NSString *group = baseUID(moved.UID);
    NSString *before = nil;
    for (NSInteger i = to + 1; i < (NSInteger)after.count && !before; i++) {
        if (indexIn(sInjected, after[i]) == NSNotFound) continue;
        NSString *uid = baseUID(after[i].UID);
        if (![uid isEqualToString:group]) before = uid;
    }
    NSMutableArray<NSString *> *order = [NSMutableArray array];
    for (SPTPlayerTrack *row in list) {
        if (indexIn(sInjected, row) == NSNotFound) continue;
        NSString *uid = baseUID(row.UID);
        if (![uid isEqualToString:group] && ![order containsObject:uid]) [order addObject:uid];
    }
    NSUInteger at = before ? [order indexOfObject:before] : order.count;
    [order insertObject:group atIndex:at];
    sOrder = order;
    sOrdered = YES;
    sOrderVersion++;
    SGLog(@"queue: the DJ's rows are arranged by the drag, %@ [%@] from %ld to %ld, now %lu groups", moved.trackTitle, moved.UID,
          (long)from, (long)to, (unsigned long)order.count);
    return YES;
}

// The first of the DJ's tracks in the user's order that has not played: the player's own track.
static SPTPlayerTrack *wantedNext(void) {
    for (NSString *uid in sOrder) {
        if ([sHidden containsObject:uid] || wasPlayed(uid)) continue;
        for (SPTPlayerTrack *row in sKept[uid]) if (!isCardRow(row) && isDJTrack(row)) return originalOf(row);
    }
    return nil;
}

static NSString *trackKey(SPTPlayerTrack *track) {
    return [NSString stringWithFormat:@"%@|%@", SGURIString(track.URI), track.UID];
}

// The page's queue wrapper (the one its swipes go through), or one made for the player the queue's readers are told by.
static id queueWrapper(void) {
    id wrapper = sWrapper;
    if (wrapper) return wrapper;
    Class wrapperClass = NSClassFromString(@"SPTPlayerQueueWrapperImpl");
    SEL initWithPlayer = NSSelectorFromString(@"initWithPlayer:");
    if (![wrapperClass instancesRespondToSelector:initWithPlayer]) return nil;
    // init consumes its receiver, which ARC does not know through a cast objc_msgSend: both on void *, the result handed
    // to ARC once (AGENTS.md).
    void *fresh = ((void *(*)(Class, SEL))objc_msgSend)(wrapperClass, @selector(alloc));
    void *made = fresh ? ((void *(*)(void *, SEL, id))objc_msgSend)(fresh, initWithPlayer, queuePlayer()) : NULL;
    return made ? CFBridgingRelease(made) : nil;
}

// A moved track's turn: the core does not have it, so it is put first in the core's queue and the player goes next.
static BOOL queueMovedNext(SPTPlayerTrack *target) {
    if (!movedBySource(target)) return NO;
    id wrapper = queueWrapper();
    SEL playNext = @selector(queueTrackPlayNext:);
    if (![wrapper respondsToSelector:playNext]) {
        SGLog(@"queue: moved %@: no queue wrapper to put it first with, it plays when the core comes to it", target.trackTitle);
        return NO;
    }
    sPlayingMoved = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ sPlayingMoved = NO; });
    id result = ((id (*)(id, SEL, id))objc_msgSend)(wrapper, playNext, target);
    SGLog(@"queue: moved %@ [%@] is put first in the core's queue, it answered %@", target.trackTitle, target.UID, result);
    return YES;
}

// The first item of the core's own order still to come for the DJ: not queued by hand, not played, not hidden; a voice
// whose card has not played counts.
// It ends at the delimiter: after it the core names the whole session again as stand-ins, whose uids are not the
// tracks' (the segment's last track came up as its own next, and was queued after itself).
static SPTPlayerTrack *coreNextUnplayed(SPTPlayerState *state) {
    for (SPTPlayerTrack *t in state.future) {
        if (isCoreQueued(t)) continue;
        if ([SGURIString(t.URI) isEqualToString:@"spotify:delimiter"]) break;
        NSString *uid = baseUID(t.UID);
        BOOL voice = [SGURIString(t.URI) hasPrefix:@"spotify:media:"];
        if (!uid.length || (!voice && !isDJTrack(t)) || wasPlayed(uid) || [sHidden containsObject:uid]) continue;
        if (voice && [sVoiced containsObject:uid]) continue;
        return t;
    }
    return nil;
}

// Set while a skip of ours is asked, so the next hook does not take it for the user's next; and while a queue command of
// ours is given to the core, so a setQueue it makes is not taken for the page's list of rows.
