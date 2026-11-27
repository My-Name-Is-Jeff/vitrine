// Next DJ Set is drawn separately for this look. Playback and availability are Shared.
#import <objc/runtime.h>
#import "Core/SGCore.h"
#import "Shared/Player/DJQueueHeader.h"

static char kButtonKey, kConfigKey;

static UILabel *editLabel(UIView *root) {
    if (!root) return nil;
    if ([root isKindOfClass:UILabel.class]) {
        UILabel *label = (UILabel *)root;
        NSString *caption = label.text ?: label.attributedText.string;
        if ([caption caseInsensitiveCompare:@"Edit"] == NSOrderedSame && label.font.pointSize > 0) return label;
    }
    for (UIView *child in root.subviews) {
        UILabel *found = editLabel(child);
        if (found) return found;
    }
    return nil;
}

void SGRDJQueueDrawNextSet(UIView *page, UIView *edit, BOOL visible, BOOL enabled, BOOL requestMode, NSString *title) {
    if (!page) return;
    UIButton *button = objc_getAssociatedObject(page, &kButtonKey);
    if (!visible || !edit || page.bounds.size.width < 200) { if (button) button.hidden = YES; return; }
    if (!button) {
        button = [UIButton buttonWithType:UIButtonTypeSystem];
        button.accessibilityIdentifier = @"vitrine-dj-new-segment";
        button.accessibilityLabel = @"Next DJ Set";
        button.titleLabel.adjustsFontForContentSizeCategory = YES;
        [button addAction:[UIAction actionWithHandler:^(__kindof UIAction *action) {
            SGDJQueueNextSetTapped();
        }] forControlEvents:UIControlEventTouchUpInside];
        objc_setAssociatedObject(page, &kButtonKey, button, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    UILabel *label = editLabel(edit);
    CGFloat fontSize = label ? label.font.pointSize : ([edit isKindOfClass:UIButton.class] && ((UIButton *)edit).titleLabel.font.pointSize > 0
        ? ((UIButton *)edit).titleLabel.font.pointSize : [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote].pointSize);
    NSString *signature = [NSString stringWithFormat:@"%@/%d/%.2f", title, requestMode, fontSize];
    if (![objc_getAssociatedObject(button, &kConfigKey) isEqualToString:signature]) {
        // Spotify's QueueHeader Edit pill is a 32pt, 10%-white capsule in
        // this screen. A system glass configuration adds a different
        // live material and makes the adjacent controls look inconsistent.
        // Keep the redesigned implementation independent, but match Edit's
        // actual background rather than applying a different button style.
        UIButtonConfiguration *config = [UIButtonConfiguration plainButtonConfiguration];
        config.background.backgroundColor = [UIColor colorWithWhite:1 alpha:0.10];
        config.background.backgroundInsets = NSDirectionalEdgeInsetsMake(6, 0, 6, 0);
        config.title = title;
        config.image = [UIImage systemImageNamed:@"forward.end.fill"];
        config.imagePadding = 6;
        config.preferredSymbolConfigurationForImage = [UIImageSymbolConfiguration configurationWithPointSize:12 weight:UIImageSymbolWeightSemibold];
        config.baseForegroundColor = UIColor.whiteColor;
        config.background.cornerRadius = 16;
        config.contentInsets = NSDirectionalEdgeInsetsMake(6, 12, 6, 12);
        UIFont *font = [UIFont fontWithName:@"SpotifyMixUI-Bold" size:fontSize] ?: [UIFont systemFontOfSize:fontSize weight:UIFontWeightBold];
        config.titleTextAttributesTransformer = ^NSDictionary *(NSDictionary *attributes) {
            NSMutableDictionary *result = [attributes mutableCopy];
            result[NSFontAttributeName] = font;
            return result;
        };
        button.configuration = config;
        button.accessibilityHint = requestMode ? @"Ask DJ for a new set using a neutral suggestion" : @"Skip to the next DJ segment";
        objc_setAssociatedObject(button, &kConfigKey, signature, OBJC_ASSOCIATION_COPY_NONATOMIC);
    }
    if (button.enabled != enabled) button.enabled = enabled;
    CGRect editFrame = [edit convertRect:edit.bounds toView:page];
    CGSize size = [button sizeThatFits:CGSizeMake(200, 44)];
    CGFloat available = CGRectGetMinX(editFrame) - 108;
    if (available < 100 || CGRectGetMinY(editFrame) < 0 || CGRectGetMaxY(editFrame) > page.bounds.size.height) {
        button.hidden = YES;
        return;
    }
    CGFloat width = MIN(size.width, available);
    button.titleLabel.numberOfLines = 1;
    button.titleLabel.adjustsFontSizeToFitWidth = YES;
    button.titleLabel.minimumScaleFactor = 0.8;
    button.frame = CGRectMake(CGRectGetMinX(editFrame) - width - 8, CGRectGetMidY(editFrame) - 22, width, 44);
    if (button.superview != page) [page addSubview:button];
    [page bringSubviewToFront:button];
    button.hidden = NO;
}
