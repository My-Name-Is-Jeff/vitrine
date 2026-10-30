// Music Haptics > Everywhere, with a jailbreak: the mod's own Music Haptics carried on while Spotify is not in front
// (the home screen, other apps, the lock screen), where iOS plays no haptics for an app in the background. Spotify
// keeps listening to its own sound and hands each tap and each level of the rumble to SpringBoard, which is always in
// front and plays them. The SpringBoard side is an add-on package of its own, Vitrine Addon (addons/haptics), installed
// once with a package manager on a jailbroken phone: Vitrine's IPA lives in Spotify's sandbox and has no way into
// SpringBoard. The IPA build lays the add-on's .deb inside Spotify.app (scripts/pipeline.sh), and the page hands that
// file to the package manager through the system's Open In (Sileo and Filza both take a .deb that way), so installing it
// is two taps, and the only way it is offered. An install of Vitrine's .deb alone has no copy inside Spotify: there the
// page says the IPA carries it. Everywhere is offered on a jailbroken phone; nothing plays behind Spotify
// until the add-on answers.
//
// The add-on answers with its build number (kSGRelayAddonBuild, raised whenever addons/haptics changes) as the state of
// its pong, so a copy inside Spotify newer than the one installed is offered as an update.
//
// The two talk by Darwin notifications, which a sandboxed app may post and which carry no payload: the value is in the
// name. A tap is one of kSGRelayLevels intensities times kSGRelaySharpnesses sharpnesses, the rumble one of
// kSGRelayLevels levels or 0 for quiet. Spotify posts each at the moment it is to be felt, so SpringBoard plays it at
// once. Spotify asks whether SpringBoard is there with a ping; SpringBoard answers with a pong, and posts one as it
// starts too, so whichever comes up second is heard.
//
// Threading: the posts are made from any thread; the answer is taken on the main queue.
#import <UIKit/UIKit.h>

#define kSGRelayPrefix "com.vitrine.haptics."
#define kSGRelayPing kSGRelayPrefix "ping"
#define kSGRelayPong kSGRelayPrefix "pong"
// kSGRelayPrefix "tap.<1...kSGRelayLevels>.<0...kSGRelaySharpnesses-1>" and kSGRelayPrefix "rumble.<0...kSGRelayLevels>".
enum { kSGRelayLevels = 10, kSGRelaySharpnesses = 3 };
// The add-on's build, set on its pong; raise it with every change to addons/haptics.
// 2: the rumble's keepalive and the lock screen switch.
// 3: the full-screen cover on the lock screen below iOS 26 (kSGRelayLockArtOn).
// 4: the track's moving artwork there in place of the still cover (kSGRelayLockClip), and no skeleton cover.
// 5: Vitrine Addon (the package renamed, com.vitrine.addon replacing com.vitrine.haptics), the clip fitted on the blurred
//    cover and played with no audio session, and the still cover's switch switch.
// 6: the lock screen's artwork gone while the song is paused.
// 7: that behind a switch of its own.
// 8: the cover and the clip fitted to the width on bands of their edges' colours, and a pause that fades them whole.
// 9: the clip only in place of the lock screen's own large cover, opened by a tap on the player's; the two switches of
//    before gone, the clip's edges faded into its bands, held still while paused.
// 10: the lock screen's tree dumped to the system log as it changes, to read its classes off a phone.
// 11: the tree's dumps and the hook on every view's layout taken out, the lock screen walked at most twice a second
//     and only with a clip to show.
// 12: loaded into MediaRemoteUI too, which draws the lock screen's player, to say what its views are.
// 13: the clip in place of the large cover inside MediaRemoteUI, handed over by SpringBoard, which hides the widgets
//     under the clock as it shows; no tree walked or dumped.
// 14: the large cover held hidden under the clip whatever alpha MediaRemoteUI gives it, and a tap that closes it gives
//     the cover back to shrink into the player while the clip fades.
// 15: a song with no clip gets its still cover the screen's width across too; the clip rests while the screen is dark
//     and starts over on a new display layer when it lights or its decoding fails.
// 16: a new song's clip or cover drawn only once it is in, the last song's held until then and its placeholder only
//     after a wait; one clip's last frame held until the next one's first.
// 17: Spotify's gray placeholder picture told from a song's cover, so a new song waits for its own; and covers and clips
//     crossfade into each other instead of cutting.
enum { kSGRelayAddonBuild = 17 };
// Below iOS 26, the add-on also fills the lock screen with the now playing cover while Spotify's switch for it is on
// (AnimatedArtwork.h, SGKeyLockCoverAddon): told "lockart.1" and "lockart.0" as the switch is set and each time the
// add-on answers. It reads the cover from MediaRemote, as the lock screen's own player does.
#define kSGRelayLockArtOn kSGRelayPrefix "lockart.1"
#define kSGRelayLockArtOff kSGRelayPrefix "lockart.0"
// The track's moving artwork for the cover (Shared/AnimatedArtwork/LockScreenAddonClip.x): copied to kSGLockClipName in
// Spotify's caches, then "lockclip" posted; "lockclip.none" when the track has none, or while its clip is looked up.
#define kSGRelayLockClip kSGRelayPrefix "lockclip"
#define kSGRelayLockClipNone kSGRelayPrefix "lockclip.none"
#define kSGLockClipName "VitrineLockClip.mp4"
// Within the add-on: SpringBoard copies the clip where MediaRemoteUI, which draws the large cover, can read it
// (SGLockSharedClipPath) and posts "lockclip.shared"; MediaRemoteUI posts "lockclip.showing.1" while the clip is in the
// cover's place and "lockclip.showing.0" as it leaves, for SpringBoard to hide the widgets under the clock.
#define kSGRelayLockClipShared kSGRelayPrefix "lockclip.shared"
#define kSGRelayLockShowing kSGRelayPrefix "lockclip.showing.1"
#define kSGRelayLockNotShowing kSGRelayPrefix "lockclip.showing.0"
static inline NSString *SGLockSharedClipPath(void) {
    NSString *root = [NSFileManager.defaultManager fileExistsAtPath:@"/var/jb"] ? @"/var/jb/var/mobile" : @"/var/mobile";
    return [root stringByAppendingPathComponent:@"Library/Caches/com.vitrine.addon/lockclip.mp4"];
}
// Whether the add-on plays while the phone is locked, told it by Spotify as the switch is set and each time the add-on
// answers: kSGRelayPrefix "lockscreen.1" plays there, "lockscreen.0" does not.
#define kSGRelayLockOn kSGRelayPrefix "lockscreen.1"
#define kSGRelayLockOff kSGRelayPrefix "lockscreen.0"
// A rumble that is on is posted again at least this often, unchanged or not, and the add-on stops one it has not heard
// of for kSGRelayRumbleLapse: a Spotify that went away mid-rumble (another copy of it opened, the app killed) left the
// last level vibrating with nothing to stop it.
#define kSGRelayRumbleKeepalive 0.2
#define kSGRelayRumbleLapse 0.6

// The key of the switch, off until switched on.
#define SGKeyMusicHapticsEverywhere @"spotifyglass.haptics.music.everywhere"
// Everywhere's second switch, on the lock screen as well; on unless switched off. With Everywhere it makes the three
// places Music Haptics plays: in Spotify only, everywhere but the lock screen, everywhere.
#define SGKeyMusicHapticsLockScreen @"spotifyglass.haptics.music.lockscreen"
// Tells the add-on the lock screen switch as it is now. Main thread.
void SGHapticRelaySendLockScreen(void);
// Tells the add-on whether to fill the lock screen with the cover, as the switch for it is now. Main thread.
void SGHapticRelaySendLockArt(void);
// The notice for a feature that needs the add-on, switched on without it: what it needs and, from Vitrine's IPA, the
// add-on two taps away. `feature` names what asked ("Everywhere", "The full-screen cover").
void SGHapticAddonExplain(NSString *feature);

// Whether SpringBoard's side has answered in this launch. Main thread.
BOOL SGHapticRelayAvailable(void);
// Whether Everywhere is offered: on a jailbroken phone, or wherever the add-on has answered.
BOOL SGHapticEverywhereOffered(void);
// The add-on's .deb inside Spotify.app, from the IPA build; nil in an install of Vitrine's .deb alone.
NSURL *SGHapticAddonPackage(void);
// The add-on's build as it answered, 0 before it has or when its answer carried none.
uint64_t SGHapticAddonInstalledBuild(void);
// Whether the add-on answered with an older build than the copy inside Spotify.
BOOL SGHapticAddonOutdated(void);
// Hands the copy inside Spotify to the package manager (the system's Open In, Save to Files among its choices), from
// `view`. NO when there is no copy.
BOOL SGHapticAddonShare(UIView *view);
// The add-on's .deb handed to the package manager a moment from now, once an alert it was picked from has gone.
void SGHapticAddonShareSoon(void);
// Posted on the main thread when SpringBoard first answers, for the Vibrations page to show the switch.
extern NSNotificationName const SGHapticRelayAvailableNotification;
// Asks SpringBoard whether it is there; called once at launch.
void SGHapticRelayAsk(void);
// A tap of `intensity` and `sharpness`, 0 to 1, felt now from SpringBoard; nothing without the add-on. Any thread.
void SGHapticRelayTap(float intensity, float sharpness);
// The rumble at `level`, 0 to 1, from now on; 0 stops it. Any thread.
void SGHapticRelayRumble(float level);
