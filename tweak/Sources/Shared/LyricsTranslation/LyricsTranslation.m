#import <CommonCrypto/CommonDigest.h>
#import <Security/Security.h>
#import "Core/SGCore.h"
#import "Settings/SGModPage.h"
#import "Settings/SGPageStyle.h"
#import "Shared/Lyrics/Lyrics.h"
#import "Shared/LyricsSources/LyricsSources.h"
#import "Shared/LocalFiles/LocalFiles.h"
#import "Headers/SPTPlayer.h"
#import "LyricsTranslation.h"

// gemini-flash-latest follows each Flash release; Google gives two weeks' notice of a breaking change.
static NSString *const kDefaultModel = @"gemini-flash-latest";
// The default, then cheaper ones, which is why a model is picked: Google's ids, and the names shown for them.
static NSArray<NSString *> *models(void) { return @[kDefaultModel, @"gemini-3.6-flash", @"gemini-3.5-flash-lite"]; }
static NSArray<NSString *> *modelNames(void) { return @[@"Flash (latest)", @"3.6 Flash", @"3.5 Flash-Lite"]; }
static NSString *const kDefaultPrompt =
    @"Translate the lines of this song into {language}. Answer with a JSON array of exactly {count} strings, one "
    @"per input line and in the same order. Translate the meaning naturally, keep each line short like a "
    @"lyric, and keep an empty line empty. A line already in {language} stays as it is.";
static NSString *const kService = @"Vitrine.Gemini", *const kAccount = @"api-key";

#pragma mark - the key

static NSDictionary *keyQuery(void) {
    return @{(__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
             (__bridge id)kSecAttrService: kService, (__bridge id)kSecAttrAccount: kAccount};
}

static NSString *storedKey(void) {
    NSMutableDictionary *query = [keyQuery() mutableCopy];
    query[(__bridge id)kSecReturnData] = @YES;
    query[(__bridge id)kSecMatchLimit] = (__bridge id)kSecMatchLimitOne;
    CFTypeRef data = NULL;
    if (SecItemCopyMatching((__bridge CFDictionaryRef)query, &data) != errSecSuccess || !data) return nil;
    NSString *key = [[NSString alloc] initWithData:(__bridge_transfer NSData *)data encoding:NSUTF8StringEncoding];
    return key.length ? key : nil;
}

static void storeKey(NSString *key) {
    SecItemDelete((__bridge CFDictionaryRef)keyQuery());
    if (!key.length) return;
    NSMutableDictionary *item = [keyQuery() mutableCopy];
    item[(__bridge id)kSecValueData] = [key dataUsingEncoding:NSUTF8StringEncoding];
    item[(__bridge id)kSecAttrAccessible] = (__bridge id)kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly;
    OSStatus status = SecItemAdd((__bridge CFDictionaryRef)item, NULL);
    if (status != errSecSuccess) SGLog(@"gemini: the key could not be kept (%d)", (int)status);
}

BOOL SGGeminiKeySet(void) {
    return storedKey() != nil;
}

#pragma mark - the model and the prompt

static NSString *storedString(NSString *key) {
    NSString *value = [NSUserDefaults.standardUserDefaults stringForKey:key];
    return value.length ? value : nil;
}

// A model id as Google writes them, or nil: it goes into the request's URL, and a restored backup can bring
// any text under its key.
static NSString *modelIDIn(NSString *text) {
    static NSCharacterSet *other;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        other = [NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_"].invertedSet;
    });
    NSString *modelID = [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if ([modelID hasPrefix:@"models/"]) modelID = [modelID substringFromIndex:7];
    return modelID.length && [modelID rangeOfCharacterFromSet:other].location == NSNotFound ? modelID : nil;
}

static NSString *model(void) {
    return modelIDIn(storedString(SGKeyGeminiModel)) ?: kDefaultModel;
}

static NSString *promptTemplate(void) {
    return storedString(SGKeyGeminiPrompt) ?: kDefaultPrompt;
}

// The first 8 hex digits of the template's SHA-256, for the log: which prompt went, never what the lyrics were.
static NSString *fingerprint(NSString *text) {
    NSData *data = [text dataUsingEncoding:NSUTF8StringEncoding];
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
    return [NSString stringWithFormat:@"%02x%02x%02x%02x", digest[0], digest[1], digest[2], digest[3]];
}

#pragma mark - asking

NSString *SGLyricsSongName(NSString *trackID) {
    NSDictionary *local = trackID ? SGLocalFileInfo(trackID) : nil;
    SPTPlayerTrack *track = trackID && !local ? SGKaraokeTrackFor(trackID) : nil;
    NSString *title = local ? local[@"title"] : track.trackTitle, *artist = local ? local[@"artist"] : track.artistName;
    if (![title isKindOfClass:NSString.class] || !title.length) return nil;
    return [artist isKindOfClass:NSString.class] && artist.length ? [NSString stringWithFormat:@"\u201C%@\u201D by %@", title, artist]
                                                                     : [NSString stringWithFormat:@"\u201C%@\u201D", title];
}

NSString *SGLyricsGeminiLanguage(void) {
    return SGLyricsTranslationLanguage() ?: NSLocale.preferredLanguages.firstObject ?: @"en";
}

// Why Gemini stopped short, as finishReason or promptFeedback.blockReason name it.
static NSString *blockedBecause(NSString *reason) {
    if ([reason isEqualToString:@"RECITATION"]) return @"Gemini stopped because its answer repeated published lyrics.";
    if ([@[@"SAFETY", @"PROHIBITED_CONTENT", @"BLOCKLIST", @"SPII"] containsObject:reason]) return @"Gemini's filters blocked this song's lyrics.";
    if ([reason isEqualToString:@"MAX_TOKENS"]) return @"The song is too long for one answer from Gemini.";
    return [NSString stringWithFormat:@"Gemini stopped before translating the song (%@).", reason];
}

NSArray<NSString *> *SGGeminiTranslationsIn(id root, NSInteger status, NSError *error, NSUInteger count, NSString **problem) {
    NSDictionary *reply = [root isKindOfClass:NSDictionary.class] ? root : nil;
    id candidates = reply[@"candidates"];
    id first = [candidates isKindOfClass:NSArray.class] ? [candidates firstObject] : nil;
    id parts = [first isKindOfClass:NSDictionary.class] && [first[@"content"] isKindOfClass:NSDictionary.class] ? first[@"content"][@"parts"] : nil;
    id text = [parts isKindOfClass:NSArray.class] && [[parts firstObject] isKindOfClass:NSDictionary.class] ? [parts firstObject][@"text"] : nil;
    id parsed = [text isKindOfClass:NSString.class] ? [NSJSONSerialization JSONObjectWithData:[text dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil] : nil;
    if ([parsed isKindOfClass:NSArray.class] && [parsed count] == count) {
        NSMutableArray<NSString *> *clean = [NSMutableArray arrayWithCapacity:count];
        for (id line in parsed) [clean addObject:[line isKindOfClass:NSString.class] ? line : @""];
        return clean;
    }
    id feedback = reply[@"promptFeedback"];
    id blocked = [feedback isKindOfClass:NSDictionary.class] ? feedback[@"blockReason"] : nil;
    id finished = [first isKindOfClass:NSDictionary.class] ? first[@"finishReason"] : nil;
    id failed = [reply[@"error"] isKindOfClass:NSDictionary.class] ? reply[@"error"][@"message"] : nil;
    NSString *googleSays = [failed isKindOfClass:NSString.class] ? failed : nil;
    if (error) {
        *problem = @"Gemini could not be reached.";
    } else if (status == 401 || status == 403 || (status == 400 && [googleSays localizedCaseInsensitiveContainsString:@"API key"])) {
        *problem = @"Gemini turned the key down. Check it on the Lyrics page.";
    } else if (status == 400) {
        *problem = googleSays.length ? [NSString stringWithFormat:@"Gemini did not take the request: %@", googleSays]
                                     : @"Gemini did not take the request (400).";
    } else if (status == 429) {
        *problem = @"Gemini's limit for this key is reached for now.";
    } else if (status == 503 || status == 500) {
        *problem = @"Gemini is busy right now. Try again in a minute.";
    } else if (status != 200) {
        *problem = [NSString stringWithFormat:@"Gemini did not translate the song (%ld).", (long)status];
    } else if ([blocked isKindOfClass:NSString.class]) {
        *problem = blockedBecause(blocked);
    } else if ([finished isKindOfClass:NSString.class] && ![finished isEqualToString:@"STOP"]) {
        *problem = blockedBecause(finished);
    } else if ([parsed isKindOfClass:NSArray.class]) {
        *problem = [NSString stringWithFormat:@"Gemini answered %lu lines for the song's %lu. Try again.",
                    (unsigned long)[parsed count], (unsigned long)count];
    } else {
        *problem = @"Gemini's answer could not be read. Try again.";
    }
    return nil;
}

// Google's advice for a busy model or a full minute's quota (408, 429, 5xx): ask again after about 1, 2 and 4 s,
// spread a little so phones do not all come back at once. A key turned down or a request that timed out is not
// asked again.
// plain is the same request without the thinking level, sent once if Gemini turns that field down: a model behind
// gemini-flash-latest that does not know it still translates.
static void sendToGemini(NSURLRequest *request, NSURLRequest *plain, NSUInteger attempt,
                         void (^finished)(NSData *data, NSInteger status, NSError *error)) {
    [[NSURLSession.sharedSession dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSInteger status = [response isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse *)response).statusCode : 0;
        NSString *reply = status == 400 && data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
        if (plain && [reply localizedCaseInsensitiveContainsString:@"thinking"]) {
            SGLog(@"gemini: the thinking level was turned down, asking without it");
            sendToGemini(plain, nil, attempt, finished);
            return;
        }
        if (attempt < 3 && !error && (status == 408 || status == 429 || status >= 500)) {
            double delay = (double)(1 << attempt) * (0.75 + arc4random_uniform(500) / 1000.0);
            SGLog(@"gemini: %ld, asking again in %.1f s", (long)status, delay);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                sendToGemini(request, plain, attempt + 1, finished);
            });
            return;
        }
        finished(data, status, error);
    }] resume];
}

static NSMutableDictionary<NSString *, NSArray<NSString *> *> *sg_done;   // per launch, by track and language

void SGLyricsTranslateWithGemini(NSString *trackID, NSArray<SGKaraokeLine *> *lines, NSString *languageTag,
                                 void (^done)(NSArray<NSString *> *translations, NSString *error)) {
    NSString *key = storedKey();
    if (!key) {
        done(nil, @"Add a Gemini API key on the Lyrics page first.");
        return;
    }
    if (!sg_done) sg_done = [NSMutableDictionary dictionary];
    // By model and prompt too: a translation asked again after either changed is a new one.
    NSString *modelID = model(), *template = promptTemplate();
    NSString *memo = [NSString stringWithFormat:@"%@|%@|%@|%@", trackID, languageTag, modelID, template];
    if (trackID && sg_done[memo].count == lines.count) {
        done(sg_done[memo], nil);
        return;
    }
    NSMutableArray<NSString *> *texts = [NSMutableArray arrayWithCapacity:lines.count];
    for (SGKaraokeLine *line in lines) [texts addObject:SGKaraokeLineText(line) ?: @""];
    // By the whole tag, so the script stays: zh-Hant is "Chinese, Traditional" where its language alone is "Chinese".
    NSString *language = [[NSLocale localeWithLocaleIdentifier:@"en"] localizedStringForLocaleIdentifier:languageTag] ?: languageTag;
    NSData *input = [NSJSONSerialization dataWithJSONObject:texts options:0 error:nil];
    // Filled in by replacing, never as a format: the template is the user's own text.
    NSString *instructions = [[template stringByReplacingOccurrencesOfString:@"{language}" withString:language]
                              stringByReplacingOccurrencesOfString:@"{count}" withString:@(texts.count).stringValue];
    NSString *prompt = [NSString stringWithFormat:@"%@\n\n%@", instructions, [[NSString alloc] initWithData:input encoding:NSUTF8StringEncoding]];
    // Lyrics are often explicit, and translating them is what the user asked for, so every filter that can
    // be lowered is. Recitation cannot be switched off, and is named when it stops an answer.
    NSMutableArray *safety = [NSMutableArray array];
    for (NSString *category in @[@"HARM_CATEGORY_HARASSMENT", @"HARM_CATEGORY_HATE_SPEECH",
                                 @"HARM_CATEGORY_SEXUALLY_EXPLICIT", @"HARM_CATEGORY_DANGEROUS_CONTENT"]) {
        [safety addObject:@{@"category": category, @"threshold": @"BLOCK_NONE"}];
    }
    NSDictionary *body = @{
        @"contents": @[@{@"parts": @[@{@"text": prompt}]}],
        @"safetySettings": safety,
        @"generationConfig": @{
            @"responseMimeType": @"application/json",
            @"responseSchema": @{@"type": @"ARRAY", @"items": @{@"type": @"STRING"}},
            // Gemini 3 thinks at length by default, which a whole song's translation does not need and which
            // made it slow enough to time out.
            @"thinkingConfig": @{@"thinkingLevel": @"low"},
        },
    };
    NSString *endpoint = [NSString stringWithFormat:@"https://generativelanguage.googleapis.com/v1beta/models/%@:generateContent", modelID];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:endpoint]];
    request.HTTPMethod = @"POST";
    request.timeoutInterval = 60;
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [request setValue:key forHTTPHeaderField:@"x-goog-api-key"];
    request.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];
    NSMutableURLRequest *plain = [request mutableCopy];
    NSMutableDictionary *plainBody = [body mutableCopy], *plainConfig = [body[@"generationConfig"] mutableCopy];
    [plainConfig removeObjectForKey:@"thinkingConfig"];
    plainBody[@"generationConfig"] = plainConfig;
    plain.HTTPBody = [NSJSONSerialization dataWithJSONObject:plainBody options:0 error:nil];
    SGLog(@"gemini: asking %@, prompt %@%@", modelID, fingerprint(template), storedString(SGKeyGeminiPrompt) ? @" (edited)" : @"");
    sendToGemini(request, plain, 0, ^(NSData *data, NSInteger status, NSError *error) {
        id root = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        NSString *problem = nil;
        NSArray *translations = SGGeminiTranslationsIn(root, status, error, texts.count, &problem);
        SGLog(@"gemini: %@ lines into %@: %@", @(texts.count), languageTag, translations ? @"translated" : problem);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (translations && trackID) sg_done[memo] = translations;
            done(translations, problem);
        });
    });
}

#pragma mark - the row

static void askForKey(void) {
    // Says what leaves the phone, not only where the key stays: each song translated goes to Google whole.
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Gemini API key"
        message:@"Translate with Gemini sends the song's lyrics to Google, on your own key from Google AI Studio. The key stays on this iPhone."
        preferredStyle:UIAlertControllerStyleAlert];
    // An empty field would store nothing and take the key away, which only Remove is for: Save waits for text.
    __weak UIAlertController *weakAlert = alert;
    UIAlertAction *save = [UIAlertAction actionWithTitle:@"Save" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        // A key copied with the quotes around it, as from a code sample, is turned down by Google as it stands.
        NSMutableCharacterSet *around = [NSMutableCharacterSet whitespaceAndNewlineCharacterSet];
        [around addCharactersInString:@"\"'“”‘’"];
        NSString *key = [weakAlert.textFields.firstObject.text stringByTrimmingCharactersInSet:around];
        if (key.length) storeKey(key);
    }];
    save.enabled = NO;
    __weak UIAlertAction *weakSave = save;
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.placeholder = @"API key";
        field.secureTextEntry = YES;
        field.autocorrectionType = UITextAutocorrectionTypeNo;
        field.autocapitalizationType = UITextAutocapitalizationTypeNone;
        __weak UITextField *weakField = field;   // the field keeps its actions, and the alert both
        [field addAction:[UIAction actionWithHandler:^(UIAction *action) {
            weakSave.enabled = [weakField.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].length > 0;
        }] forControlEvents:UIControlEventEditingChanged];
    }];
    [alert addAction:save];
    if (SGGeminiKeySet()) {
        [alert addAction:[UIAlertAction actionWithTitle:@"Remove" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
            storeKey(nil);
        }]];
    }
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [SGTopController() presentViewController:alert animated:YES completion:nil];
}

NSNotificationName const SGLyricsTranslationsDidChangeNotification = @"spotifyglass.lyricsTranslationsDidChange";

SGModRow *SGTranslateEverySongRow(void) {
    SGModRow *row = SGOptionRow(@"Translate any song", @"The lyrics' translate menu for songs that already read as your language",
                                SGKeyLyricsTranslateEverySong);
    row.changed = ^(BOOL on) {
        [NSNotificationCenter.defaultCenter postNotificationName:SGLyricsTranslationsDidChangeNotification object:nil];
    };
    return row;
}

SGModRow *SGGeminiKeyRow(void) {
    return SGStatActionRow(@"Gemini API key", @"Translate any song from the lyrics' corner menu",
                           ^NSString *{ return SGGeminiKeySet() ? @"Set" : @"Off"; }, ^{ askForKey(); });
}

#pragma mark - the model and prompt rows

static void askForModel(void) {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Gemini model"
        message:@"A model id from Google AI Studio, such as gemini-3.5-flash-lite." preferredStyle:UIAlertControllerStyleAlert];
    __weak UIAlertController *weakAlert = alert;
    UIAlertAction *save = [UIAlertAction actionWithTitle:@"Save" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        NSString *modelID = modelIDIn(weakAlert.textFields.firstObject.text);
        if (modelID) [NSUserDefaults.standardUserDefaults setObject:modelID forKey:SGKeyGeminiModel];
    }];
    save.enabled = NO;
    __weak UIAlertAction *weakSave = save;
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.placeholder = kDefaultModel;
        field.text = storedString(SGKeyGeminiModel);
        field.autocorrectionType = UITextAutocorrectionTypeNo;
        field.autocapitalizationType = UITextAutocapitalizationTypeNone;
        __weak UITextField *weakField = field;
        [field addAction:[UIAction actionWithHandler:^(UIAction *action) { weakSave.enabled = modelIDIn(weakField.text) != nil; }]
        forControlEvents:UIControlEventEditingChanged];
    }];
    [alert addAction:save];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [SGTopController() presentViewController:alert animated:YES completion:nil];
}

SGModRow *SGGeminiModelRow(void) {
    NSArray<NSString *> *names = [modelNames() arrayByAddingObject:@"Other…"];
    return SGMenuRow(@"Gemini model", names, ^NSString *{
        NSUInteger index = [models() indexOfObject:model()];
        return index == NSNotFound ? model() : modelNames()[index];
    }, ^(NSInteger index) {
        if (index < (NSInteger)models().count) {
            if (index == 0) [NSUserDefaults.standardUserDefaults removeObjectForKey:SGKeyGeminiModel];
            else [NSUserDefaults.standardUserDefaults setObject:models()[(NSUInteger)index] forKey:SGKeyGeminiModel];
        } else {
            askForModel();
        }
    });
}

// The prompt in a sheet: the checkmark stores it, Default puts Vitrine's back in the field. Stored equal to the
// default, or empty, it is removed, so a later change to the default reaches it.
@interface SGPromptEditor : UIViewController
@end

@implementation SGPromptEditor {
    UITextView *_text;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Translation prompt";
    self.view.backgroundColor = UIColor.systemGroupedBackgroundColor;
    _text = [UITextView new];
    _text.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    _text.adjustsFontForContentSizeCategory = YES;
    _text.backgroundColor = UIColor.clearColor;
    _text.textContainerInset = UIEdgeInsetsMake(16, 16, 16, 16);
    _text.alwaysBounceVertical = YES;
    _text.keyboardDismissMode = UIScrollViewKeyboardDismissModeInteractive;
    _text.text = promptTemplate();
    _text.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_text];
    UILabel *note = [UILabel new];
    note.text = @"{language} and {count} are filled in for each song, and its lines follow the prompt as a JSON array.";
    note.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    note.adjustsFontForContentSizeCategory = YES;
    note.textColor = UIColor.secondaryLabelColor;
    note.numberOfLines = 0;
    note.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:note];
    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [note.topAnchor constraintEqualToAnchor:safe.topAnchor constant:12],
        [note.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:20],
        [note.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-20],
        [_text.topAnchor constraintEqualToAnchor:note.bottomAnchor constant:4],
        [_text.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor],
        [_text.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor],
        [_text.bottomAnchor constraintEqualToAnchor:self.view.keyboardLayoutGuide.topAnchor],
    ]];
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemClose target:self action:@selector(close)];
    // Plain: Spotify's white tint fills a Done item's glass and hides its glyph.
    UIBarButtonItem *done = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"checkmark"] style:UIBarButtonItemStylePlain target:self action:@selector(save)];
    done.accessibilityLabel = @"Save";
    UIBarButtonItem *reset = [[UIBarButtonItem alloc] initWithTitle:@"Default" style:UIBarButtonItemStylePlain target:self action:@selector(reset)];
    self.navigationItem.rightBarButtonItems = @[done, reset];
}

- (void)close {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)reset {
    _text.text = kDefaultPrompt;
}

- (void)save {
    NSString *prompt = [_text.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!prompt.length || [prompt isEqualToString:kDefaultPrompt]) [NSUserDefaults.standardUserDefaults removeObjectForKey:SGKeyGeminiPrompt];
    else [NSUserDefaults.standardUserDefaults setObject:prompt forKey:SGKeyGeminiPrompt];
    SGLog(@"gemini: prompt %@", storedString(SGKeyGeminiPrompt) ? [@"edited, " stringByAppendingString:fingerprint(prompt)] : @"default");
    [self close];
}
@end

SGModRow *SGGeminiPromptRow(void) {
    return SGStatActionRow(@"Translation prompt", @"What Gemini is told to do with a song's lines",
                           ^NSString *{ return storedString(SGKeyGeminiPrompt) ? @"Edited" : @"Default"; }, ^{
        UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:[SGPromptEditor new]];
        nav.modalPresentationStyle = UIModalPresentationPageSheet;
        SGPresentDark(nav);
        [SGTopController() presentViewController:nav animated:YES completion:nil];
    });
}
