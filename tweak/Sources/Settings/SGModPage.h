// A page of sections of rows, the shape of every feature's settings page.
#import "SGPage.h"

// Clave global para el estado de la portada animada
FOUNDATION_EXPORT NSString *const SGKeyAnimatedCoversEnabled;

@interface SGModRow : NSObject
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *subtitle;
@property (nonatomic, copy) NSString *key;
@property (nonatomic) BOOL defaultOn;
@property (nonatomic) BOOL flag;
@property (nonatomic) BOOL forceOff;
@property (nonatomic, copy) UIViewController *(^page)(void);
@property (nonatomic, copy) NSString *(^value)(void);
@property (nonatomic, copy) void (^action)(void);
@property (nonatomic, copy) NSString *warning;
@property (nonatomic, copy) void (^changed)(BOOL on);   // after the switch is stored; the page reloads
@property (nonatomic, strong) UIColor *color;   // title, subtitle and symbol, for a warning row
@property (nonatomic, copy) NSString *symbol;
@property (nonatomic, strong) UIColor *tint;   // the square under the symbol, gray when nil (SGWithTile)
@property (nonatomic) BOOL glows;
// The switch shows the opposite of what is stored under its key (SGShownRow).
@property (nonatomic) BOOL inverted;
// An ⓘ button beside the row's switch, whose tap reads this out under the row's title.
@property (nonatomic, copy) NSString *info;
@property (nonatomic, copy) BOOL (^visible)(void);
@property (nonatomic, copy) NSString *waitsOn;
@property (nonatomic, copy) NSArray<NSString *> *choiceNotes;
@property (nonatomic, copy) NSString *choiceFooter;   // under a choice row's list
@property (nonatomic, copy) void (^chosen)(NSInteger index);
@property (nonatomic) double minimum, maximum, step;
@property (nonatomic, copy) double (^number)(void);
@property (nonatomic, copy) void (^setNumber)(double value);
@property (nonatomic, copy) NSString *(^format)(double value);
@property (nonatomic, copy) NSArray<NSString *> *menu;
@property (nonatomic, copy) UIColor *(^swatch)(void);
// One of a few rows picked from on the page itself (an action row each): a checkmark against it while this answers
// YES, read as the row is drawn, so its action reloads the table.
@property (nonatomic, copy) BOOL (^checked)(void);
@end

@interface SGModSection : NSObject
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSArray<SGModRow *> *rows;
@property (nonatomic, copy) NSString *footer;
@end

@interface SGModPage : SGPage
- (instancetype)initWithTitle:(NSString *)title intro:(NSString *)intro sections:(NSArray<SGModSection *> *)sections footer:(NSString *)footer;
- (void)refreshVisibility;
@property (nonatomic) BOOL tiles;
@end

extern NSString *const SGRestartNote;

SGModRow *SGSwitchRow(NSString *title, NSString *subtitle, NSString *key);   // on until switched off
SGModRow *SGHideRow(NSString *title, NSString *subtitle, NSString *key);     // off until switched on
// A part of Spotify the mod can take away, named for the part and shown on: turning it off stores YES under
// `hideKey`, the way SGHideRow does, so a reset (stock) shows the part again.
SGModRow *SGShownRow(NSString *title, NSString *subtitle, NSString *hideKey);
// A switch for something the mod adds rather than takes away: off until it is asked for.
SGModRow *SGOptionRow(NSString *title, NSString *subtitle, NSString *key);
SGModRow *SGUnstableRow(NSString *title, NSString *subtitle, NSString *key, NSString *warning);
SGModRow *SGFlagRow(NSString *title, NSString *key);
SGModRow *SGKillRow(NSString *title, NSString *key);
SGModRow *SGStatRow(NSString *title, NSString *(^value)(void));
SGModRow *SGActionRow(NSString *title, NSString *subtitle, void (^action)(void));
SGModRow *SGWarningRow(NSString *title, NSString *subtitle, void (^action)(void));
SGModRow *SGPageRow(NSString *title, UIViewController *(^page)(void));
SGModRow *SGChoiceRow(NSString *title, NSString *subtitle, NSString *key, NSArray<NSString *> *choices, NSInteger fallback);
SGModRow *SGSliderRow(NSString *title, NSString *subtitle, double minimum, double maximum, double step,
                      double (^get)(void), void (^set)(double value), NSString *(^format)(double value));
SGModRow *SGMenuRow(NSString *title, NSArray<NSString *> *choices, NSString *(^value)(void), void (^chosen)(NSInteger index));
void SGPickColor(NSString *title, NSInteger initial, void (^picked)(NSInteger rgb));
UIColor *SGColorRGB(NSInteger rgb);
SGModRow *SGLinkRow(NSString *title, NSString *subtitle, NSString *url);
SGModRow *SGStatActionRow(NSString *title, NSString *subtitle, NSString *(^value)(void), void (^action)(void));
SGModSection *SGSection(NSString *title, NSArray<SGModRow *> *rows);
SGModSection *SGNotedSection(NSString *title, NSArray<SGModRow *> *rows, NSString *footer);
SGModRow *SGWithSymbol(SGModRow *row, NSString *symbol);
SGModRow *SGWithTile(SGModRow *row, NSString *symbol, UIColor *color);
