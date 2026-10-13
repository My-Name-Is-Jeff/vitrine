#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "Core/SGCore.h"

// Interfaces para que el compilador conozca las propiedades e instancias nativas
@interface SPTPlayerState : NSObject
- (NSDictionary *)metadata;
@end

@interface SPTNowPlayingFooterUnitViewController : UIViewController
@end

@interface SPTLyricsDataLoader : NSObject
- (id)sg_createFallbackLyricsWithText:(NSString *)text;
@end

#pragma mark - 1. Forzar que las pistas reporten tener letras disponibles

%hook SPTPlayerState

- (NSDictionary *)metadata {
    NSDictionary *origMeta = %orig;
    NSMutableDictionary *meta = origMeta ? [origMeta mutableCopy] : [NSMutableDictionary dictionary];
    meta[@"has_lyrics"] = @"true";
    return meta;
}

%end

#pragma mark - 2. Mantener el botón de letras activo en la interfaz

%hook SPTNowPlayingFooterUnitViewController

- (void)updateLyricsButtonState {
    %orig;
    SGForEachView(self.view, ^(UIView *view) {
        if ([view isKindOfClass:[UIButton class]]) {
            UIButton *btn = (UIButton *)view;
            if ([btn.accessibilityLabel containsString:@"Lyrics"] || 
                [btn.accessibilityLabel containsString:@"Letras"] ||
                [btn.accessibilityIdentifier isEqualToString:@"lyrics_button"]) {
                btn.enabled = YES;
                btn.userInteractionEnabled = YES;
                btn.alpha = 1.0;
            }
        }
    });
}

%end

%hook UIButton

- (void)setEnabled:(BOOL)enabled {
    if ([self.accessibilityIdentifier isEqualToString:@"lyrics_button"] || 
        [self.accessibilityLabel containsString:@"Lyrics"] ||
        [self.accessibilityLabel containsString:@"Letras"]) {
        %orig(YES);
        return;
    }
    %orig(enabled);
}

%end

#pragma mark - 3. Interceptor Fallback de Letras ("Without lyrics")

%hook SPTLyricsDataLoader

- (void)fetchLyricsForTrackURI:(NSURL *)trackURI completion:(void (^)(id lyrics, NSError *error))completion {
    %orig(trackURI, ^(id lyrics, NSError *error) {
        if (!lyrics || error) {
            id fallbackLyrics = [self sg_createFallbackLyricsWithText:@"Without lyrics."];
            if (completion) {
                completion(fallbackLyrics, nil);
            }
        } else {
            if (completion) {
                completion(lyrics, error);
            }
        }
    });
}

%new
- (id)sg_createFallbackLyricsWithText:(NSString *)text {
    Class lineClass = NSClassFromString(@"SPTLyricsLine") ?: NSClassFromString(@"SPTNowPlayingLyricsLine");
    Class trackClass = NSClassFromString(@"SPTLyricsTrack") ?: NSClassFromString(@"SPTNowPlayingLyricsTrack");
    
    if (lineClass && trackClass) {
        id line = [[lineClass alloc] init];
        if ([line respondsToSelector:@selector(setWords:)]) {
            [line performSelector:@selector(setWords:) withObject:text];
        }
        
        id track = [[trackClass alloc] init];
        if ([track respondsToSelector:@selector(setLines:)]) {
            [track performSelector:@selector(setLines:) withObject:@[line]];
        }
        if ([track respondsToSelector:@selector(setSyncType:)]) {
            [track performSelector:@selector(setSyncType:) withObject:@(0)];
        }
        return track;
    }
    
    return @{
        @"syncType": @"UNSYNCED",
        @"lines": @[
            @{@"words": text, @"time": @0}
        ],
        @"provider": @"LocalFallback"
    };
}

%end

%ctor {
    %init;
}
