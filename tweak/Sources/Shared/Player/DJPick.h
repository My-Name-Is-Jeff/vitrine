// The Next DJ Set button's request action. Spotify's native DJ controls are untouched.
#import <Foundation/Foundation.h>
void SGDJPickRequest(id player, void (^completion)(NSError *error));
