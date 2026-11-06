#import "SGRPass.h"
#import "Core/SGCore.h"
#import "SGRRestyle.h"
#import <objc/runtime.h>

void SGRRepeatPass(UIViewController *controller, NSArray<NSNumber *> *delays, SGRControllerPass pass) {
    __weak UIViewController *weak = controller;
    for (NSNumber *delay in delays) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay.doubleValue * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            UIViewController *strong = weak;
            if (strong) pass(strong);
        });
    }
}

void SGRRepeatViewPass(UIView *view, NSArray<NSNumber *> *delays, void (^pass)(UIView *view)) {
    __weak UIView *weak = view;
    for (NSNumber *delay in delays) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay.doubleValue * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            UIView *strong = weak;
            if (strong.window) pass(strong);
        });
    }
}
