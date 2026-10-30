// SponsorBlock for Spotify podcast episodes.
// Ported from EeveeSpotify Reincarnated (GPL-3.0) and Spot-SponsorBlock-Extension.

#import <UIKit/UIKit.h>

#define SGKeySponsorBlockEnabled          @"spotifyglass.sponsorblock.enabled"
#define SGKeySponsorBlockShowToast        @"spotifyglass.sponsorblock.showToast"
#define SGKeySponsorBlockToastDuration    @"spotifyglass.sponsorblock.toastDuration"
#define SGKeySponsorBlockPromptDuration   @"spotifyglass.sponsorblock.promptDuration"
#define SGKeySponsorBlockHaptics          @"spotifyglass.sponsorblock.haptics"
#define SGKeySponsorBlockMinDuration      @"spotifyglass.sponsorblock.minDuration"
#define SGKeySponsorBlockRespectManual    @"spotifyglass.sponsorblock.respectManualSeek"
#define SGKeySponsorBlockSkipCount        @"spotifyglass.sponsorblock.skipCount"
#define SGKeySponsorBlockTimeSaved        @"spotifyglass.sponsorblock.timeSaved"

#define SGSponsorBlockPromptDurationInfinite 65.0

typedef NS_ENUM(NSInteger, SGSponsorBlockBehavior) {
    SGSponsorBlockBehaviorSkip = 0,    // Auto-skip
    SGSponsorBlockBehaviorPrompt = 1,  // Prompt
    SGSponsorBlockBehaviorOff = 2,     // Off
};

@interface SGSponsorBlockSegment : NSObject
@property (nonatomic) double start;
@property (nonatomic) double end;
@property (nonatomic, copy) NSString *category;
@property (nonatomic, copy) NSString *actionType;
@property (nonatomic, copy) NSString *uuid;
- (NSTimeInterval)duration;
@end

NSArray<NSString *> *SGSponsorBlockAllCategories(void);
NSArray<NSString *> *SGSponsorBlockBehaviorNames(void);
SGSponsorBlockBehavior SGSponsorBlockCategoryBehavior(NSString *category);
void SGSetSponsorBlockCategoryBehavior(NSString *category, SGSponsorBlockBehavior behavior);
void SGResetSponsorBlockCategoriesToDefaults(void);
UIColor *SGSponsorBlockCategoryColor(NSString *category);
NSString *SGSponsorBlockCategorySubtitle(NSString *category);
NSString *SGSponsorBlockCategoryDisplayName(NSString *category);
BOOL SGSponsorBlockSubSwitchEnabled(NSString *key);

NSUInteger SGSponsorBlockSkipCount(void);
NSTimeInterval SGSponsorBlockTimeSaved(void);
NSString *SGSponsorBlockFormattedTimeSaved(void);
void SGRecordSponsorBlockSkip(NSTimeInterval duration);
void SGUndoRecordSponsorBlockSkip(NSTimeInterval duration);
void SGResetSponsorBlockStats(void);

NSTimeInterval SGSponsorBlockToastDuration(void);
void SGSetSponsorBlockToastDuration(NSTimeInterval duration);
NSTimeInterval SGSponsorBlockPromptDuration(void);
void SGSetSponsorBlockPromptDuration(NSTimeInterval duration);
NSTimeInterval SGSponsorBlockMinDuration(void);
void SGSetSponsorBlockMinDuration(NSTimeInterval duration);

NSString *SGSponsorBlockSummary(void);
UIViewController *SGSponsorBlockSettingsPage(void);
void SGSponsorBlockStart(void);
void SGSponsorBlockPreferencesDidChange(void);
