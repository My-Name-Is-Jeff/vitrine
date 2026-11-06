// Passes over Spotify's controllers and views, again after a delay: what it builds or paints back after the first
// layout (a sheet's rows, its grey) is caught on a later pass.
//
// Threading: main thread only.
#import <UIKit/UIKit.h>

typedef void (^SGRControllerPass)(UIViewController *controller);

// The delays SGRPassController repeats a pass after, in seconds.
#define SGRSettleDelays @[@0.0, @0.25, @0.6]

// Runs `pass` on the controller after each delay (seconds), while it lives.
void SGRRepeatPass(UIViewController *controller, NSArray<NSNumber *> *delays, SGRControllerPass pass);

// Runs `pass` on the view after each delay (seconds), while it is in a window.
void SGRRepeatViewPass(UIView *view, NSArray<NSNumber *> *delays, void (^pass)(UIView *view));

