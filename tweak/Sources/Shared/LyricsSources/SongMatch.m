// Whether a song a catalog offers is the track playing, for the searches that answer with whole songs
// and no id to match on: Genius's (LyricsMeanings/Meanings.m, Genius.m) and LRCLIB's (LrcLib.m).
#import "Core/SGCore.h"
#import "LyricsSources.h"

NSString *SGLyricsFoldedText(NSString *text) {
    static NSCharacterSet *kept;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ kept = NSCharacterSet.alphanumericCharacterSet; });
    NSString *plain = [text stringByFoldingWithOptions:NSCaseInsensitiveSearch | NSDiacriticInsensitiveSearch | NSWidthInsensitiveSearch
                                                locale:nil];
    NSMutableString *out = [NSMutableString stringWithCapacity:plain.length];
    BOOL space = NO;
    for (NSUInteger i = 0; i < plain.length; i++) {
        unichar c = [plain characterAtIndex:i];
        if (c == '\'' || c == 0x2019 || c == 0x2018 || c == '`') continue;
        if ([kept characterIsMember:c]) {
            if (space && out.length) [out appendString:@" "];
            space = NO;
            [out appendFormat:@"%C", c];
        } else {
            space = YES;
        }
    }
    return out;
}

NSString *SGLyricsBareTitle(NSString *title) {
    NSString *bare = title ?: @"";
    NSRange dash = [bare rangeOfString:@" - "];
    if (dash.location != NSNotFound) bare = [bare substringToIndex:dash.location];
    static NSRegularExpression *brackets;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ brackets = [NSRegularExpression regularExpressionWithPattern:@"\\s*[\\(\\[][^\\)\\]]*[\\)\\]]" options:0 error:nil]; });
    bare = [brackets stringByReplacingMatchesInString:bare options:0 range:NSMakeRange(0, bare.length) withTemplate:@""];
    return [bare stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
}

// What a title says beyond the song's name: "Old Town Road - Remix" is {remix}, "Blinding Lights (Live)" {live}.
static NSSet<NSString *> *versionOf(NSString *title) {
    NSMutableSet<NSString *> *words = [NSMutableSet setWithArray:[SGLyricsFoldedText(title) componentsSeparatedByString:@" "]];
    [words minusSet:[NSSet setWithArray:[SGLyricsFoldedText(SGLyricsBareTitle(title)) componentsSeparatedByString:@" "]]];
    [words removeObject:@""];
    return words;
}

// The track's title without Spotify's "(feat. Billy Ray Cyrus)" or "(with Diplo)": who sings with the lead
// is not which recording it is. A catalog's titles keep theirs, so a version of its own with a guest stays apart.
static NSString *withoutGuests(NSString *title) {
    static NSRegularExpression *guests;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        guests = [NSRegularExpression regularExpressionWithPattern:@"\\s*[\\(\\[](feat\\.?|ft\\.?|featuring|with)\\s[^\\)\\]]*[\\)\\]]"
                                                            options:NSRegularExpressionCaseInsensitive error:nil];
    });
    return [guests stringByReplacingMatchesInString:title options:0 range:NSMakeRange(0, title.length) withTemplate:@""];
}

NSSet<NSString *> *SGLyricsTitleVersion(NSString *title) {
    return versionOf(withoutGuests(title ?: @""));
}

// Spotify joins a track's artists with ", ", which a name can hold too ("Tyler, The Creator"), so the
// lead artist is any run of the first names; a local file's tag may name the lead before " feat." instead.
static NSSet<NSString *> *leadNames(NSString *artist) {
    NSMutableSet<NSString *> *names = [NSMutableSet setWithObject:SGLyricsFoldedText(SGLyricsLeadArtist(artist))];
    NSString *run = @"";
    for (NSString *part in [artist componentsSeparatedByString:@", "]) {
        run = run.length ? [run stringByAppendingFormat:@" %@", SGLyricsFoldedText(part)] : SGLyricsFoldedText(part);
        if (run.length) [names addObject:run];
    }
    return names;
}

// A catalog writes several artists as one name, joined by punctuation ("A & B", "A/B", "A; B", "A, B") or a
// word ("A and B", "A x B"), in either order; LRCLIB has every one of these. Lowercase " x " only: " X " ends
// Lil Nas X.
static NSArray<NSString *> *namesJoinedIn(NSString *name) {
    NSMutableString *split = [name mutableCopy];
    for (NSString *joiner in @[@"&", @"/", @";", @"+", @"•", @",", @" and ", @" with ", @" vs ", @" vs. "]) {
        [split replaceOccurrencesOfString:joiner withString:@"\n" options:NSCaseInsensitiveSearch range:NSMakeRange(0, split.length)];
    }
    [split replaceOccurrencesOfString:@" x " withString:@"\n" options:0 range:NSMakeRange(0, split.length)];
    return [split componentsSeparatedByString:@"\n"];
}

// Whether one of the song's own artists is the track's lead, by either name of one written twice over
// ("BTS (방탄소년단)", "Дора (Dora)"), by the name before its " feat.", or by one of the names joined in it;
// a featured singer or a translation page's "Genius English Translations" never is.
static BOOL byLead(NSArray<NSString *> *songArtists, NSSet<NSString *> *leads) {
    for (NSString *name in songArtists) {
        if (![name isKindOfClass:NSString.class]) continue;
        NSArray<NSString *> *parts = [name componentsSeparatedByCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"()"]];
        parts = [parts arrayByAddingObjectsFromArray:@[name, SGLyricsLeadArtist(name)]];
        for (NSString *part in [parts arrayByAddingObjectsFromArray:namesJoinedIn(name)]) {
            if ([leads containsObject:SGLyricsFoldedText(part)]) return YES;
        }
    }
    return NO;
}

NSInteger SGLyricsSongRank(NSString *title, NSString *artist, NSString *songTitle, NSArray<NSString *> *songArtists) {
    if (!title.length || !artist.length || ![songTitle isKindOfClass:NSString.class]) return 0;
    NSString *wantTitle = SGLyricsFoldedText(SGLyricsBareTitle(title));
    if (!wantTitle.length || ![SGLyricsFoldedText(SGLyricsBareTitle(songTitle)) isEqualToString:wantTitle]) return 0;
    if (!byLead(songArtists, leadNames(artist))) return 0;
    NSSet<NSString *> *version = versionOf(songTitle);
    return [version isEqualToSet:SGLyricsTitleVersion(title)] ? 3 : version.count == 0 ? 2 : 1;
}
