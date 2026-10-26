// Redesign, iOS < 26: every UIAlertController the app presents (an alert or an action sheet, the mod's own and
// Spotify's) comes up as SGRAlertScreen, Telegram's alert: a glass card with 35pt corners and capsule buttons,
// instead of the system's grey one.
//
// The swap is made where the alert is presented, so no call site changes: the controller the caller built is
// read, kept alive, and never shown. Its handlers run when a button is picked, and its text fields (moved into the
// card) hold what the person typed. From iOS 26 the system draws its own glass alert and none of this runs.
//
// An alert that carries a controller of the app's own, or an action sheet on an iPad, is left to the system.
#import "Core/SGCore.h"
#import "Redesigned/Kit/SGRKit.h"
#import "Redesigned/Kit/SGRAlertScreen.h"

%group SGRAlerts
%hook UIViewController
- (void)presentViewController:(UIViewController *)presented animated:(BOOL)animated completion:(void (^)(void))completion {
    // Exactly UIAlertController: a subclass is someone's own idea of an alert.
    if ([presented isMemberOfClass:UIAlertController.class] && [SGRAlertScreen canShow:(UIAlertController *)presented]) {
        SGRAlertScreen *screen = [[SGRAlertScreen alloc] initWithAlert:(UIAlertController *)presented];
        // The screen animates itself, so UIKit's own transition is off.
        %orig(screen, NO, completion);
        return;
    }
    %orig;
}
%end
%end

%ctor {
    if (!SGRedesignedUI()) return;
    if (!SGBelowiOS26()) return;
    if (![SGRAlertScreen handlersReadable]) {
        SGLog(@"UIAlertAction's _handler is gone, alerts keep the system's look");
        return;
    }
    %init(SGRAlerts);
}
