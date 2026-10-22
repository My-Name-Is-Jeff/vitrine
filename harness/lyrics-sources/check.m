// Checks what is new in the lyrics sources and their words without the phone or the network: lines in
// Thai and the scripts like it split at the dictionary's words (KaraokeTiming.m), KuGou's KRC unpacked
// and read (KuGou.m, through NetEase.m's parser), and the QQ Music and KuGou asks matching a track
// against made-up search replies. The requests are answered here, by host. Any file named on the
// command line is a real KuGou download or QQ lyrics reply, saved as JSON, and only its line count is
// printed. Exits non-zero on the first wrong answer.
#import <UIKit/UIKit.h>
#import <zlib.h>
#import "Shared/LyricsSources/LyricsSources.h"

#define CHECK(cond) do { if (!(cond)) { fprintf(stderr, "FAILED line %d: %s\n", __LINE__, #cond); exit(1); } } while (0)

// What the sources reach outside themselves for: the requests, answered by sg_answer.
@implementation SGLyricsResult
@end
@implementation SGLyricsQuery
@end
void SGLyricsPageLines(NSArray<SGKaraokeLine *> *lines, NSArray<NSNumber *> **starts, NSArray<NSString *> **texts) {
    NSMutableArray *at = [NSMutableArray array], *said = [NSMutableArray array];
    for (SGKaraokeLine *line in lines) {
        [at addObject:@(line.start)];
        [said addObject:SGKaraokeLineText(line)];
    }
    *starts = at;
    *texts = said;
}
void SGLyricsNoteReply(NSURLResponse *response, NSError *error) {}
NSURL *SGLyricsURL(NSString *base, NSDictionary<NSString *, NSString *> *query) {
    NSURLComponents *url = [NSURLComponents componentsWithString:base];
    NSMutableArray<NSURLQueryItem *> *items = [NSMutableArray array];
    [query enumerateKeysAndObjectsUsingBlock:^(NSString *name, NSString *value, BOOL *stop) {
        [items addObject:[NSURLQueryItem queryItemWithName:name value:value]];
    }];
    url.queryItems = items;
    return url.URL;
}
static id (^sg_answer)(NSURL *url, id body);
void SGLyricsGetJSON(NSURL *url, NSDictionary *headers, void (^done)(id root)) { done(sg_answer(url, nil)); }
void SGLyricsPostJSON(NSURL *url, NSDictionary *headers, id body, void (^done)(id root)) { done(sg_answer(url, body)); }

static NSString *param(NSURL *url, NSString *name) {
    for (NSURLQueryItem *item in [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO].queryItems) {
        if ([item.name isEqualToString:name]) return item.value;
    }
    return nil;
}

static NSArray<SGKaraokeWord *> *piecesOf(NSString *text) {
    return SGKaraokeStaticLines(@[text]).firstObject.words;
}

// The words of an unspaced token come back flush, so the line reads as it was written.
static void checkSplit(NSString *text, BOOL split) {
    NSArray<SGKaraokeWord *> *words = piecesOf(text);
    printf("%lu pieces: %s\n", (unsigned long)words.count, [[words valueForKey:@"text"] componentsJoinedByString:@"|"].UTF8String);
    CHECK([SGKaraokeLineText(SGKaraokeStaticLines(@[text]).firstObject) isEqualToString:text]);
    CHECK(!split || words.count > 1);
}

// KRC as KuGou packs it: "krc1", then the zlib of the text XORed with the key, all in base64.
static NSString *packed(NSString *krc, NSString *magic) {
    NSData *text = [krc dataUsingEncoding:NSUTF8StringEncoding];
    uLongf length = compressBound(text.length);
    NSMutableData *zipped = [NSMutableData dataWithLength:length];
    compress(zipped.mutableBytes, &length, text.bytes, text.length);
    zipped.length = length;
    static const uint8_t key[16] = {64, 71, 97, 119, 94, 50, 116, 71, 81, 54, 49, 45, 206, 210, 110, 105};
    uint8_t *bytes = zipped.mutableBytes;
    for (NSUInteger i = 0; i < zipped.length; i++) bytes[i] ^= key[i % 16];
    NSMutableData *all = [[magic dataUsingEncoding:NSASCIIStringEncoding] mutableCopy];
    [all appendData:zipped];
    return [all base64EncodedStringWithOptions:0];
}

static NSString *const kKRC = @"﻿[id:$00000000]\r\n[ar:Someone]\r\n"
    "[1000,2000]<0,500,0>Hel<500,300,0>lo <800,700,0>world\r\n"
    "[4000,1500]<0,400,0>你<400,400,0>好<800,0,0>啊\r\n"
    "[7000,100]<0,300,0>late\r\n";

// Every line's words read back as its text, the spaces aside, and start in order inside it.
static void checkWordLines(NSArray<SGKaraokeLine *> *lines) {
    for (SGKaraokeLine *line in lines) {
        CHECK(line.timing != SGKaraokeTimingWords || line.words.count);
        for (NSUInteger i = 0; i < line.words.count; i++) {
            CHECK(line.words[i].start >= line.start && line.words[i].end > line.words[i].start && line.words[i].end <= line.end);
            CHECK(!i || line.words[i].start >= line.words[i - 1].start);
        }
    }
}

static void checkLive(NSString *path) {
    NSDictionary *root = [NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:path] options:0 error:nil];
    if (root[@"lyricsfile"]) {
        // An LRCLIB record: one that times words reads as word timed lines with the text it had.
        NSArray<SGKaraokeLine *> *lines = SGLyricsfileLines(root[@"lyricsfile"]);
        NSUInteger words = 0, timed = 0;
        NSInteger startSum = 0;
        for (SGKaraokeLine *line in lines) {
            words += line.words.count;
            timed += line.timing == SGKaraokeTimingWords;
            startSum += line.start;
        }
        printf("%s: Lyricsfile, %lu lines (%lu word timed), %lu words, starts sum %ld\n", path.lastPathComponent.UTF8String,
               (unsigned long)lines.count, (unsigned long)timed, (unsigned long)words, (long)startSum);
        CHECK(!!lines == [root[@"hasWordSync"] boolValue]);
        checkWordLines(lines);
        return;
    }
    if (root[@"content"]) {
        NSArray<SGKaraokeLine *> *lines = SGKuGouLines(root[@"content"]);
        printf("%s: KRC, %lu word timed lines; first \"%s\" at %ld\n", path.lastPathComponent.UTF8String, (unsigned long)lines.count,
               SGKaraokeLineText(lines.firstObject).UTF8String, (long)lines.firstObject.start);
        CHECK(lines.count);
        return;
    }
    id lyric = root[@"music.musichallSong.PlayLyricInfo.GetPlayLyricInfo"][@"data"][@"lyric"];
    NSString *lrc = [[NSString alloc] initWithData:[[NSData alloc] initWithBase64EncodedString:lyric options:0] encoding:NSUTF8StringEncoding];
    SGLyricsResult *result = SGLyricsLRCResult(lrc);
    printf("%s: QQ LRC, %lu timed lines\n", path.lastPathComponent.UTF8String, (unsigned long)result.karaokeLines.count);
    CHECK(result.synced && result.karaokeLines.count);
}

int main(int argc, char **argv) {
    @autoreleasepool {
        // Thai, Lao, Khmer and Burmese, long lines with no space, and Thai among Latin and brackets.
        checkSplit(@"ฉันรักเธอมากกว่าสิ่งใดในโลกนี้และจะอยู่เคียงข้างเธอตลอดไป", YES);
        checkSplit(@"วันนี้อากาศดีมากเราไปเดินเล่นที่สวนสาธารณะด้วยกันไหมนะที่รัก", YES);
        checkSplit(@"Baby(ที่รัก)ฉันคิดถึงเธอทุกวันทุกคืนไม่เคยลืมเลย,ok?", YES);
        checkSplit(@"ฉันรักเธอ, เธอรักฉัน... (ด้วยหัวใจ)", YES);
        CHECK([piecesOf(@"(ด้วยหัวใจ)").firstObject.text isEqualToString:@"(ด้วย"]);   // what comes before the first word stays with it
        checkSplit(@"ຂ້ອຍຮັກເຈົ້າຫຼາຍທີ່ສຸດໃນໂລກນີ້ແລະຈະຢູ່ນຳເຈົ້າຕະຫຼອດໄປ", NO);
        checkSplit(@"ខ្ញុំស្រលាញ់អ្នកខ្លាំងណាស់ហើយនឹងនៅជាមួយអ្នកជារៀងរហូត", NO);
        checkSplit(@"ကျွန်တော်မင်းကိုအရမ်းချစ်တယ်ထာဝရမင်းနဲ့အတူရှိနေမယ်", NO);
        CHECK(piecesOf(@"๏๚").count == 1);   // Thai punctuation alone: no word, one piece
        CHECK(piecesOf(@"hello world").count == 2 && !piecesOf(@"hello world")[1].joined);
        CHECK(piecesOf(@"日本語の歌").count == 5 && piecesOf(@"日本語の歌")[4].joined);
        NSArray<SGKaraokeWord *> *thai = piecesOf(@"ฉันรักเธอมากกว่าสิ่งใดในโลกนี้");
        CHECK(!thai[0].joined && thai[1].joined);

        // The keys the two catalogs are matched by.
        CHECK([SGLyricsMatchKey(@"晴天（Live版）") isEqualToString:SGLyricsMatchKey(@"晴天 (Live版)")]);
        CHECK([SGLyricsMatchKey(@"Hello,　World!") isEqualToString:@"helloworld"]);
        CHECK([SGLyricsMatchKey(@"《稻香》") isEqualToString:@"稻香"]);
        CHECK([SGLyricsLeadArtist(@"周杰伦 feat. 费玉清") isEqualToString:@"周杰伦"]);
        CHECK(SGLyricsSameArtist(@"周杰伦、费玉清", @"周杰伦 Feat. Someone") && !SGLyricsSameArtist(@"林俊杰", @"周杰伦"));
        CHECK(!SGLyricsSameArtist(@"", @"周杰伦") && !SGLyricsSameArtist(nil, @"x"));

        // KRC: pieces timed from their line's start, a spaced word's pieces run together, a syllable each
        // in Chinese, a piece of no length shown for 1 ms, a line ending at its last word when that is later.
        NSArray<SGKaraokeLine *> *lines = SGKuGouLines(packed(kKRC, @"krc1"));
        CHECK(lines.count == 3);
        CHECK([SGKaraokeLineText(lines[0]) isEqualToString:@"Hello world"] && lines[0].words.count == 2);
        CHECK(lines[0].words[0].start == 1000 && lines[0].words[0].end == 1800 && lines[0].words[1].start == 1800);
        CHECK(lines[0].start == 1000 && lines[0].end == 3000 && lines[0].timing == SGKaraokeTimingWords);
        CHECK(lines[1].words.count == 3 && [SGKaraokeLineText(lines[1]) isEqualToString:@"你好啊"]);
        CHECK(lines[1].words[1].joined && lines[1].words[2].start == 4800 && lines[1].words[2].end == 4801);
        CHECK(lines[2].end == 7300);
        CHECK(!SGKuGouLines(packed(kKRC, @"krc2")) && !SGKuGouLines(@"bm90IGtyYw==") && !SGKuGouLines(nil));
        CHECK(!SGKuGouLines(packed(@"[ar:only tags]", @"krc1")));

        // KuGou: the user uploads, another title, another singer, a length 21 s off and a candidate with
        // no key are passed over; the rest are tried closest in length first, three at most.
        NSArray *candidates = @[
            @{@"id": @"a", @"accesskey": @"k", @"product_from": @"ugc", @"song": @"晴天", @"singer": @"周杰伦", @"duration": @269000},
            @{@"id": @"b", @"accesskey": @"k", @"song": @"晴天 (Live)", @"singer": @"周杰伦", @"duration": @269000},
            @{@"id": @"c", @"accesskey": @"k", @"song": @"晴天", @"singer": @"Other", @"duration": @269000},
            @{@"id": @"d", @"accesskey": @"k", @"song": @"晴天", @"singer": @"周杰伦", @"duration": @290000},
            @{@"id": @"e", @"accesskey": @"k", @"song": @"晴天", @"singer": @"周杰伦", @"duration": @265000},
            @{@"id": @7, @"accesskey": @"k", @"song": @"晴天", @"singer": @"周杰伦", @"duration": @269500},
            @{@"id": @"g", @"accesskey": @"k", @"song": @"晴天", @"singer": @"周杰伦", @"duration": @262000},
            @{@"id": @"h", @"song": @"晴天", @"singer": @"周杰伦", @"duration": @270000},
            @{@"id": @"i", @"accesskey": @"k", @"song": @" 晴天！", @"singer": @"周杰伦、费玉清", @"duration": @"268000"},
        ];
        NSMutableArray<NSString *> *tried = [NSMutableArray array];
        __block NSString *keyword, *duration, *good = @"e";
        sg_answer = ^id(NSURL *url, id body) {
            if ([url.host isEqualToString:@"krcs.kugou.com"]) {
                keyword = param(url, @"keyword");
                duration = param(url, @"duration");
                return @{@"status": @200, @"candidates": candidates};
            }
            NSString *song = param(url, @"id");
            [tried addObject:song];
            if ([song isEqualToString:good]) return @{@"status": @200, @"content": packed(kKRC, @"krc1")};
            return [song isEqualToString:@"7"] ? @{@"status": @200, @"content": @"garbage"} : @{@"status": @404};
        };
        SGLyricsQuery *query = [SGLyricsQuery new];
        query.title = @"晴天";
        query.artist = @"周杰伦 feat. Someone";
        query.seconds = 269;
        __block SGLyricsResult *got = nil;
        SGKuGouAsk(query, ^(SGLyricsResult *result) { got = result; });
        CHECK([keyword isEqualToString:@"周杰伦 - 晴天"] && [duration isEqualToString:@"269000"]);
        CHECK([tried isEqualToArray:(@[@"7", @"i", @"e"])]);
        CHECK(got.synced && got.wordTimed && got.karaokeLines.count == 3 && got.texts.count == 3);
        [tried removeAllObjects];
        good = @"g";   // fourth in line: never asked
        got = [SGLyricsResult new];
        SGKuGouAsk(query, ^(SGLyricsResult *result) { got = result; });
        CHECK([tried isEqualToArray:(@[@"7", @"i", @"e"])] && !got);
        query.artist = @"";
        got = [SGLyricsResult new];
        [tried removeAllObjects];
        SGKuGouAsk(query, ^(SGLyricsResult *result) { got = result; });
        CHECK(!got && !tried.count);

        // QQ Music: the first result with the title, a singer and the length is taken, and its LRC read.
        NSString *lrc = @"[ti:x]\n[ar:y]\n[00:01.00]第一行\n[00:03.50]第二行\n";
        __block NSDictionary *asked = nil;
        sg_answer = ^id(NSURL *url, NSDictionary *body) {
            if (body[@"req"]) return @{@"req": @{@"data": @{@"body": @{@"song": @{@"list": @[
                @{@"title": @"晴天", @"interval": @269, @"singer": @[@{@"name": @"Someone Else"}], @"id": @1},
                @{@"title": @"晴天", @"interval": @300, @"singer": @[@{@"name": @"周杰伦"}], @"id": @2},
                @{@"title": @"雨天", @"interval": @269, @"singer": @[@{@"name": @"周杰伦"}], @"id": @3},
                @{@"songname": @"晴天", @"interval": @270, @"singer": @[@{@"name": @"x"}, @{@"name": @"周杰伦"}], @"id": @97773},
            ]}}}}};
            asked = body[@"music.musichallSong.PlayLyricInfo.GetPlayLyricInfo"][@"param"];
            NSString *encoded = [[lrc dataUsingEncoding:NSUTF8StringEncoding] base64EncodedStringWithOptions:0];
            return @{@"music.musichallSong.PlayLyricInfo.GetPlayLyricInfo": @{@"data": @{@"lyric": encoded}}};
        };
        query.artist = @"周杰伦";
        got = nil;
        SGQQMusicAsk(query, ^(SGLyricsResult *result) { got = result; });
        CHECK([asked[@"songID"] isEqual:@97773] && [asked[@"qrc"] isEqual:@0] && [asked[@"crypt"] isEqual:@0]);
        CHECK(got.synced && !got.wordTimed && got.karaokeLines.count == 2 && got.karaokeLines[1].start == 3500);
        query.seconds = 200;   // no recording that long: nothing asked for lyrics
        asked = nil;
        got = [SGLyricsResult new];
        SGQQMusicAsk(query, ^(SGLyricsResult *result) { got = result; });
        CHECK(!got && !asked);

        // Lyricsfile: the spec's own example, two words timed to the end of each.
        NSArray<SGKaraokeLine *> *lf = SGLyricsfileLines(@"version: '1.0'\n\nmetadata:\n  title: 'Example Song'\n  artist: 'Example Artist'\n"
            "  language: 'en'\n  instrumental: false\n\nlines:\n  - text: 'Hello world'\n    start_ms: 1200\n    end_ms: 2800\n    words:\n"
            "      - text: 'Hello '\n        start_ms: 1200\n        end_ms: 1900\n      - text: 'world'\n        start_ms: 1900\n        end_ms: 2800\n\n"
            "plain: |\n  Hello world\n");
        CHECK(lf.count == 1 && lf[0].words.count == 2 && [SGKaraokeLineText(lf[0]) isEqualToString:@"Hello world"]);
        CHECK(lf[0].start == 1200 && lf[0].end == 2800 && lf[0].timing == SGKaraokeTimingWords);
        CHECK(lf[0].words[0].end == 1900 && lf[0].words[1].start == 1900 && !lf[0].words[1].joined);

        // As LRCLIB writes it: keys in any order, words with no end of their own ending where the next
        // starts and the last one with its line; a segment with no space after it runs into the next
        // one, Japanese syllables stay apart and flush, and a line timed only as a whole is estimated.
        // The rows a sequence's items start on are at its key's indent, quoted the way YAML quotes.
        NSString *lrclib = @"version: \"1.0\"\nmetadata:\n  title: ကမ္ဘာ\n  artist: Someone # a comment\nlines:\n"
            "- text: \"Hold on \"\n  words:\n  - text: \"Hold \"\n    start_ms: 48712\n  - text: \"on \"\n    start_ms: 49109\n  start_ms: 48712\n  end_ms: 52187\n"
            "- text: wanted now\n  start_ms: 53000\n  words:\n    - text: wan\n      start_ms: 53000\n    - text: \"ted \"\n      start_ms: 53200\n      end_ms: 53500\n"
            "    - {text: now}\n";
        CHECK(!SGLyricsfileLines(lrclib));   // a flow mapping is refused, and the whole file with it
        lrclib = [lrclib stringByReplacingOccurrencesOfString:@"    - {text: now}\n" withString:@"    - text: now\n      start_ms: 54000\n"];
        lrclib = [lrclib stringByAppendingString:@"- text: '''Cause I''m-'\n  start_ms: 60000\n  end_ms: 62000\n- text: ''\n  start_ms: 62000\n"
            "- text: \"\\u65e5\\u672c語\"\n  start_ms: 63000\n  end_ms: 64000\n  words:\n  - text: 日本\n    start_ms: 63000\n  - text: 語\n    start_ms: 63500\n"
            "plain: |-\n  Hold on\n\n  wanted now\n"];
        lf = SGLyricsfileLines(lrclib);
        CHECK(lf.count == 4);
        checkWordLines(lf);
        CHECK([SGKaraokeLineText(lf[0]) isEqualToString:@"Hold on"] && lf[0].words[0].end == 49109 && lf[0].words[1].end == 52187);
        CHECK(lf[1].words.count == 2 && [lf[1].words[0].text isEqualToString:@"wanted"] && lf[1].words[0].end == 53500);
        CHECK([lf[1].words[1].text isEqualToString:@"now"] && !lf[1].words[1].joined && lf[1].end == 55000);   // no end anywhere: a second past its last word
        CHECK([SGKaraokeLineText(lf[2]) isEqualToString:@"'Cause I'm-"] && lf[2].timing == SGKaraokeTimingLine && lf[2].start == 60000);
        CHECK(lf[3].words.count == 2 && lf[3].words[1].joined && [SGKaraokeLineText(lf[3]) isEqualToString:@"日本語"]);

        // LRCLIB's Lyricsfile for a record timed by the line alone: nothing the LRC does not have.
        CHECK(!SGLyricsfileLines(@"version: '1.0'\nmetadata:\n  title: a\n  artist: b\nlines:\n- text: Biatch!\n  start_ms: 90\n  end_ms: 960\n"));
        // Refused whole: another version, a key twice, a tab for indent, a negative time, an end before its
        // start, a quote never closed, words not a list, an alias, a stray row, not YAML at all.
        NSString *wordFile = @"version: '1.0'\nlines:\n- text: a\n  start_ms: 10\n  words:\n  - text: a\n    start_ms: 10\n";
        CHECK(SGLyricsfileLines(wordFile).count == 1);
        for (NSArray<NSString *> *swap in @[@[@"'1.0'", @"'2.0'"], @[@"  start_ms: 10\n  words", @"  start_ms: 10\n  start_ms: 11\n  words"],
                                            @[@"  start_ms: 10\n  words", @"\tstart_ms: 10\n  words"], @[@"    start_ms: 10", @"    start_ms: -10"],
                                            @[@"    start_ms: 10", @"    start_ms: 10\n    end_ms: 5"], @[@"- text: a", @"- text: \"a"],
                                            @[@"  - text: a\n    start_ms: 10\n", @"  a\n"], @[@"- text: a", @"- text: *a"],
                                            @[@"lines:", @"  stray\nlines:"]]) {
            CHECK(!SGLyricsfileLines([wordFile stringByReplacingOccurrencesOfString:swap[0] withString:swap[1]]));
        }
        CHECK(!SGLyricsfileLines(@"[not, yaml") && !SGLyricsfileLines(@"") && !SGLyricsfileLines(nil) && !SGLyricsfileLines((NSString *)@3));

        // LRCLIB: a record with words timed answers with them; one whose Lyricsfile cannot be read
        // answers with its LRC; the search picks the record with words over a closer one without.
        NSString *twoLines = @"[00:01.00]a\n[00:02.00]b\n";
        __block NSDictionary *record = @{@"id": @1, @"duration": @200, @"hasWordSync": @YES, @"syncedLyrics": twoLines, @"lyricsfile": wordFile};
        __block NSArray *found = nil;
        sg_answer = ^id(NSURL *url, id body) { return [url.path hasSuffix:@"/get"] ? record : found; };
        query.title = @"a";
        query.artist = @"b";
        query.seconds = 200;
        got = nil;
        SGLrcLibAsk(query, ^(SGLyricsResult *result) { got = result; });
        CHECK(got.wordTimed && got.synced && got.karaokeLines.count == 1 && got.texts.count);
        record = @{@"id": @1, @"duration": @200, @"hasWordSync": @YES, @"syncedLyrics": twoLines, @"lyricsfile": @"version: '9'"};
        SGLrcLibAsk(query, ^(SGLyricsResult *result) { got = result; });
        CHECK(!got.wordTimed && got.synced && got.karaokeLines.count == 2);
        record = nil;
        found = @[@{@"id": @2, @"duration": @200, @"syncedLyrics": twoLines},
                  @{@"id": @3, @"duration": @202, @"hasWordSync": @YES, @"syncedLyrics": twoLines, @"lyricsfile": wordFile}];
        SGLrcLibAsk(query, ^(SGLyricsResult *result) { got = result; });
        CHECK(got.wordTimed && got.karaokeLines.count == 1);

        for (int i = 1; i < argc; i++) checkLive(@(argv[i]));
        printf("lyrics-sources: all checks passed\n");
    }
    return 0;
}
