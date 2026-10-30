// Settings page and category metadata for SponsorBlock.
// Ported from EeveeSpotify Reincarnated (GPL-3.0) and Spot-SponsorBlock-Extension.

#import "Core/SGCore.h"
#import "Settings/SGModPage.h"
#import "Settings/SGPageStyle.h"
#import "SGSponsorBlock.h"
#import "SGSponsorBlockOverlay.h"

typedef struct {
    __unsafe_unretained NSString *key;
    __unsafe_unretained NSString *rowTitle;
    __unsafe_unretained NSString *toastName;
    __unsafe_unretained NSString *symbol;
    __unsafe_unretained NSString *subtitle;
    SGSponsorBlockBehavior defaultBehavior;
    CGFloat r, g, b;
} SGCategorySpec;

static const SGCategorySpec kCategories[] = {
    { @"sponsor",          @"Sponsors",              @"Sponsor",              @"dollarsign.circle", @"Paid promotions, referrals, and product reads",          SGSponsorBlockBehaviorSkip,   0.00, 0.83, 0.51 },
    { @"selfpromo",        @"Self-promotion",        @"Self-promotion",       @"megaphone",         @"Merchandise, companion shows, and social links",         SGSponsorBlockBehaviorSkip,   1.00, 0.88, 0.00 },
    { @"interaction",      @"Interaction reminders", @"Interaction reminder", @"hand.tap",          @"Prompts to follow, rate, or subscribe",                  SGSponsorBlockBehaviorSkip,   0.80, 0.18, 0.96 },
    { @"intro",            @"Intros & recaps",       @"Intro",                @"forward.end",       @"Opening sequences, theme music, and recaps",             SGSponsorBlockBehaviorPrompt, 0.00, 0.63, 0.95 },
    { @"outro",            @"Outros & credits",      @"Outro",                @"backward.end",      @"Closing credits, end music, and supporter lists",        SGSponsorBlockBehaviorPrompt, 0.20, 0.40, 1.00 },
    { @"preview",          @"Previews & teasers",    @"Preview",              @"eye",               @"Upcoming episode previews and clips",                    SGSponsorBlockBehaviorOff,    0.61, 0.15, 0.69 },
    { @"hook",             @"Hooks",                 @"Hook",                 @"bolt",              @"Cold opens and teasers before the intro",                SGSponsorBlockBehaviorOff,    1.00, 0.43, 0.00 },
    { @"filler",           @"Filler & tangents",     @"Filler",               @"ellipsis.bubble",   @"Off-topic banter and tangents",                          SGSponsorBlockBehaviorOff,    0.47, 0.56, 0.61 },
    { @"exclusive_access", @"Exclusive access",      @"Exclusive access",     @"lock",              @"Bonus previews and subscriber-only pitches",             SGSponsorBlockBehaviorOff,    1.00, 0.63, 0.00 },
};

static const size_t kCategoryCount = sizeof(kCategories) / sizeof(kCategories[0]);

static const SGCategorySpec *specForCategory(NSString *category) {
    if ([category isEqualToString:@"exclusive"]) category = @"exclusive_access";
    for (size_t i = 0; i < kCategoryCount; i++) {
        if ([kCategories[i].key isEqualToString:category]) return &kCategories[i];
    }
    return NULL;
}

static void ensureBehaviorMigration(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        if (!SGFlag(@"spotifyglass.sponsorblock.v2_migration", NO)) {
            for (size_t i = 0; i < kCategoryCount; i++) {
                NSString *prefKey = [@"spotifyglass.sponsorblock.behavior." stringByAppendingString:kCategories[i].key];
                if (SGInt(prefKey, -1) == 2) {
                    SGSetInt(prefKey, SGSponsorBlockBehaviorOff); // migrate legacy 2 (Off) to 3 (Off)
                }
            }
            SGSetEnabled(@"spotifyglass.sponsorblock.v2_migration", YES);
        }
    });
}

NSArray<NSString *> *SGSponsorBlockAllCategories(void) {
    static NSArray<NSString *> *all;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableArray<NSString *> *list = [NSMutableArray arrayWithCapacity:kCategoryCount];
        for (size_t i = 0; i < kCategoryCount; i++) [list addObject:kCategories[i].key];
        all = [list copy];
    });
    return all;
}

NSArray<NSString *> *SGSponsorBlockBehaviorNames(void) {
    return @[@"Auto-skip", @"Prompt", @"Show only", @"Off"];
}

UIColor *SGSponsorBlockCategoryColor(NSString *category) {
    const SGCategorySpec *spec = specForCategory(category);
    if (!spec) return [UIColor colorWithRed:0.00 green:0.83 blue:0.51 alpha:1.0];
    return [UIColor colorWithRed:spec->r green:spec->g blue:spec->b alpha:1.0];
}

NSString *SGSponsorBlockCategorySubtitle(NSString *category) {
    const SGCategorySpec *spec = specForCategory(category);
    return spec ? spec->subtitle : nil;
}

NSString *SGSponsorBlockCategoryDisplayName(NSString *category) {
    const SGCategorySpec *spec = specForCategory(category);
    return spec ? spec->toastName : @"Sponsor";
}

SGSponsorBlockBehavior SGSponsorBlockCategoryBehavior(NSString *category) {
    ensureBehaviorMigration();
    const SGCategorySpec *spec = specForCategory(category);
    if (!spec) return SGSponsorBlockBehaviorOff;
    NSString *prefKey = [@"spotifyglass.sponsorblock.behavior." stringByAppendingString:spec->key];
    NSInteger stored = SGInt(prefKey, -1);
    return (stored >= 0 && stored <= 3) ? (SGSponsorBlockBehavior)stored : spec->defaultBehavior;
}

void SGSetSponsorBlockCategoryBehavior(NSString *category, SGSponsorBlockBehavior behavior) {
    const SGCategorySpec *spec = specForCategory(category);
    if (!spec) return;
    NSString *prefKey = [@"spotifyglass.sponsorblock.behavior." stringByAppendingString:spec->key];
    SGSetInt(prefKey, behavior);
    SGSponsorBlockPreferencesDidChange();
}

void SGResetSponsorBlockCategoriesToDefaults(void) {
    for (size_t i = 0; i < kCategoryCount; i++) {
        NSString *prefKey = [@"spotifyglass.sponsorblock.behavior." stringByAppendingString:kCategories[i].key];
        SGSetInt(prefKey, kCategories[i].defaultBehavior);
    }
    SGSponsorBlockPreferencesDidChange();
}

NSString *SGSponsorBlockSummary(void) {
    NSUInteger active = 0;
    for (size_t i = 0; i < kCategoryCount; i++) {
        if (SGSponsorBlockCategoryBehavior(kCategories[i].key) != SGSponsorBlockBehaviorOff) active++;
    }
    return active ? [NSString stringWithFormat:@"%lu active", (unsigned long)active] : @"None";
}

BOOL SGSponsorBlockSubSwitchEnabled(NSString *key) {
    return SGString(key) ? SGFlag(key, YES) : YES;
}

static void ensureSubSwitchesInitialized(void) {
    for (NSString *subKey in @[SGKeySponsorBlockOverlay, SGKeySponsorBlockShowToast, SGKeySponsorBlockHaptics, SGKeySponsorBlockRespectManual]) {
        if (!SGString(subKey)) SGSetEnabled(subKey, YES);
    }
}

UIViewController *SGSponsorBlockSettingsPage(void) {
    ensureSubSwitchesInitialized();
    __block __weak SGModPage *weakPage = nil;

    NSArray<NSString *> *choices = SGSponsorBlockBehaviorNames();
    NSMutableArray<SGModRow *> *categories = [NSMutableArray arrayWithCapacity:kCategoryCount + 1];
    for (size_t i = 0; i < kCategoryCount; i++) {
        NSString *catKey = kCategories[i].key;
        SGModRow *row = SGMenuRow(kCategories[i].rowTitle, choices,
            ^NSString *{ return choices[(NSUInteger)SGSponsorBlockCategoryBehavior(catKey)]; },
            ^(NSInteger index) { SGSetSponsorBlockCategoryBehavior(catKey, (SGSponsorBlockBehavior)index); });
        row.subtitle = kCategories[i].subtitle;
        row.swatch = ^UIColor *{ return SGSponsorBlockCategoryColor(catKey); };
        [categories addObject:SGWithSymbol(row, kCategories[i].symbol)];
    }

    SGModRow *resetCategoriesRow = SGWithSymbol(SGActionRow(@"Reset categories to defaults", @"Restore default skip and prompt settings", ^{
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Reset categories?"
                                                                       message:@"This restores all categories to their default skip and prompt settings."
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"Reset" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
            SGResetSponsorBlockCategoriesToDefaults();
            [weakPage.tableView reloadData];
        }]];
        [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
        [SGTopController() presentViewController:alert animated:YES completion:nil];
    }), @"arrow.counterclockwise");
    [categories addObject:resetCategoriesRow];

    SGModRow *overlay = SGWithSymbol(SGSwitchRow(@"Show colored progress bar", @"Display colored segment bars along the episode scrubber", SGKeySponsorBlockOverlay), @"chart.bar.xaxis");
    overlay.changed = ^(BOOL on) { SGSponsorBlockPreferencesDidChange(); };

    SGModRow *toast = SGWithSymbol(SGSwitchRow(@"Show skip notifications", @"Show an Undo banner after skipping a segment", SGKeySponsorBlockShowToast), @"bell");
    toast.changed = ^(BOOL on) { SGSponsorBlockPreferencesDidChange(); };

    SGModRow *undoDuration = SGSliderRow(@"Undo banner duration", nil, 5.0, 30.0, 1.0,
        ^double { return SGSponsorBlockToastDuration(); },
        ^(double value) { SGSetSponsorBlockToastDuration(value); },
        ^NSString *(double value) { return [NSString stringWithFormat:@"%.0f s", value]; });
    undoDuration.visible = ^BOOL { return SGSponsorBlockSubSwitchEnabled(SGKeySponsorBlockShowToast); };

    SGModRow *promptDuration = SGSliderRow(@"Skip prompt duration", nil, 5.0, SGSponsorBlockPromptDurationInfinite, 5.0,
        ^double { return SGSponsorBlockPromptDuration(); },
        ^(double value) { SGSetSponsorBlockPromptDuration(value); },
        ^NSString *(double value) {
            return value >= SGSponsorBlockPromptDurationInfinite ? @"Until end" : [NSString stringWithFormat:@"%.0f s", value];
        });

    SGModRow *respectManual = SGWithSymbol(SGSwitchRow(@"Respect manual scrub", @"Prompt instead of auto-skipping when scrubbing into a segment", SGKeySponsorBlockRespectManual), @"slider.horizontal.below.rectangle");
    respectManual.changed = ^(BOOL on) { SGSponsorBlockPreferencesDidChange(); };

    SGModRow *haptics = SGWithSymbol(SGSwitchRow(@"Haptic feedback", @"Play haptics when skipping or showing a prompt", SGKeySponsorBlockHaptics), @"iphone.radiowaves.left.and.right");
    haptics.changed = ^(BOOL on) { SGSponsorBlockPreferencesDidChange(); };

    SGModRow *minDuration = SGSliderRow(@"Minimum segment duration", nil, 0.0, 5.0, 0.5,
        ^double { return SGSponsorBlockMinDuration(); },
        ^(double value) { SGSetSponsorBlockMinDuration(value); },
        ^NSString *(double value) { return value <= 0.0 ? @"None" : [NSString stringWithFormat:@"%.1f s", value]; });

    SGModRow *statRow = SGWithSymbol(SGStatRow(@"Segments skipped", ^NSString *{
        return @(SGSponsorBlockSkipCount()).stringValue;
    }), @"number");

    SGModRow *timeRow = SGWithSymbol(SGStatRow(@"Time saved", ^NSString *{
        return SGSponsorBlockFormattedTimeSaved();
    }), @"clock");

    SGModRow *resetRow = SGWithSymbol(SGActionRow(@"Reset statistics", nil, ^{
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Reset statistics?"
                                                                       message:@"This clears your skipped segment count and time saved."
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"Reset" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
            SGResetSponsorBlockStats();
            [weakPage.tableView reloadData];
        }]];
        [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
        [SGTopController() presentViewController:alert animated:YES completion:nil];
    }), @"trash");

    NSString *categoryFooter = @"Auto-skip jumps past segments automatically. "
                               @"Prompt shows a banner so you can choose when to skip. "
                               @"Show only marks segments on the progress bar without skipping.";
    NSString *footer = @"Segment timestamps come from Spot-SponsorBlock (spotsponsorblock.org) on the SponsorBlock "
                       @"database (sponsor.ajay.app). Because segments are submitted by listeners, newer or less common "
                       @"episodes may not be marked yet.";

    SGModPage *page = [[SGModPage alloc] initWithTitle:@"SponsorBlock" intro:nil sections:@[
        SGNotedSection(@"Categories to skip", categories, categoryFooter),
        SGSection(@"Behavior", @[overlay, toast, undoDuration, promptDuration, respectManual, haptics, minDuration]),
        SGSection(@"Statistics", @[statRow, timeRow, resetRow]),
    ] footer:footer];
    weakPage = page;
    return page;
}
