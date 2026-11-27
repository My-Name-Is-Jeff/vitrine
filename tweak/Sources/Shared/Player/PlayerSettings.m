// The player's settings that do not depend on the look: the lock screen widget's flags.
#import "Core/SGCore.h"
#import "Settings/SGModPage.h"
#import "PlayerSettings.h"
#import "DJQueue.h"
#import "Shared/AnimatedArtwork/AnimatedArtwork.h"
#import "Shared/Lyrics/Lyrics.h"

// Widget first: the line in place of the artist (on the Lyrics page too, the same switch) and Like and dislike,
// the one lock screen control a song gets, which the Artwork section's star takes the place of
// (Shared/AnimatedArtwork/LockScreenStar.x locks the flag off). Spotify's flags for podcasts, audiobooks and its
// own lock screen artwork stay on the All flags page: the Artwork section is the mod's.
UIViewController *SGLockScreenWidgetPage(void) {
    SGModRow *likes = SGFlagRow(@"Like and dislike buttons", @"ios-feature-lockscreen.like_dislike_enabled");
    likes.subtitle = @"Off and locked while Switch with the star is on: the star takes their place";
    return [[SGModPage alloc] initWithTitle:@"Lock screen" intro:SGRestartNote sections:@[
        SGSection(@"Widget", @[SGLockScreenLyricsRow(), SGLockScreenTranslationRow(), likes]),
        SGSection(@"Artwork", SGLockScreenMotionRows()),
    ] footer:nil];
}

SGModSection *SGDJSettingsSection(void) {
    // The two switches start on. The mode choice appears only while the
    // queue and its Next DJ Set button are enabled.
    SGModRow *queue = SGSwitchRow(@"DJ queue", @"Show the DJ's upcoming tracks in the queue", SGKeyDJQueue);
    SGModRow *button = SGSwitchRow(@"Next DJ Set button", @"Show Next DJ Set beside Edit in the DJ queue", SGKeyDJQueuePickButton);
    button.waitsOn = SGKeyDJQueue;
    SGModRow *action = SGChoiceRow(@"Next DJ Set action", @"Choose what the queue button does", SGKeyDJQueueSetMode,
                                  @[@"Skip to next DJ segment", @"Let DJ pick (request)"], SGDJQueueSetModeSkip);
    action.visible = ^BOOL { return SGEnabled(SGKeyDJQueue) && SGEnabled(SGKeyDJQueuePickButton); };
    action.choiceNotes = @[@"Skip the remaining tracks and start the next DJ segment without sending a request.",
                           @"Ask DJ for another set using one neutral English suggested request."];
    return SGNotedSection(@"DJ", @[queue, button, action],
        @"DJ queue shows the DJ's upcoming songs so you can reorder or remove them; restart Spotify after changing this switch. "
        @"The Next DJ Set button and its action update immediately. By default, Next DJ Set skips to the next DJ segment "
        @"without a request. Let DJ pick (request) instead sends one neutral English suggestion: "
        @"“Surprise me with a new mix based on my taste.” It waits for a new set before changing your queue order. "
        @"Spotify's native Let DJ pick button is unchanged.");
}
