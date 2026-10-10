// Home redesign: Top picks, the first shelf of cards drawn large the way the Music app draws its top shelf.
//
// A shelf is a Home_CarouselKit.TouchCancellingCollectionView in a cell of the page's list (HomeSections.x), a
// compositional layout of its own with cards 149 by 195 under a 40pt heading (trees: the 393x235 shelf, cards at
// {149, 195}). Its sizes are Spotify's, made by the layout's section provider each time the layout is asked for one.
// So every compositional layout's provider is wrapped, and while the large shelf's provider runs, the absolute and
// estimated sizes it makes of kSmallest or more are scaled by kScale: the cards and their group, not the heading or
// the spacing. The page's cell is made that much taller to hold it.
//
// The shelf drawn large is the one nearest the top of the page: the lowest index any shelf has been measured at.
// Cells are reused across shelves, so each measuring sets or clears the mark on the layout it holds.
#import <objc/runtime.h>
#import "Core/SGCore.h"
#import "Settings/SGModPage.h"
#import "Redesigned/Kit/SGRKit.h"
#import "Home.h"

static const CGFloat kScale = 1.7, kSmallest = 120, kHeading = 40;
static char kLargeKey, kNaturalKey, kWrappedKey;
static _Thread_local BOOL sg_enlarging;
static NSInteger sg_topIndex = NSIntegerMax;

// The layout a wrapped provider belongs to, set once the layout is made.
@interface SGRLayoutBox : NSObject
@property (nonatomic, weak) UICollectionViewCompositionalLayout *layout;
@end
@implementation SGRLayoutBox
@end

static UICollectionViewCompositionalLayoutSectionProvider wrapped(UICollectionViewCompositionalLayoutSectionProvider provider, SGRLayoutBox *box) {
    return ^NSCollectionLayoutSection *(NSInteger section, id<NSCollectionLayoutEnvironment> environment) {
        UICollectionViewCompositionalLayout *layout = box.layout;
        BOOL was = sg_enlarging;
        sg_enlarging = layout && objc_getAssociatedObject(layout, &kLargeKey) != nil;
        NSCollectionLayoutSection *made = provider(section, environment);
        sg_enlarging = was;
        return made;
    };
}

static UICollectionViewCompositionalLayout *boxed(UICollectionViewCompositionalLayout *made, SGRLayoutBox *box) {
    box.layout = made;
    if (made) objc_setAssociatedObject(made, &kWrappedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return made;
}

%hook UICollectionViewCompositionalLayout
- (instancetype)initWithSectionProvider:(UICollectionViewCompositionalLayoutSectionProvider)provider
                          configuration:(UICollectionViewCompositionalLayoutConfiguration *)configuration {
    if (!provider) return %orig;
    SGRLayoutBox *box = [SGRLayoutBox new];
    return boxed(%orig(wrapped(provider, box), configuration), box);
}
- (instancetype)initWithSectionProvider:(UICollectionViewCompositionalLayoutSectionProvider)provider {
    if (!provider) return %orig;
    SGRLayoutBox *box = [SGRLayoutBox new];
    return boxed(%orig(wrapped(provider, box)), box);
}
%end

%hook NSCollectionLayoutDimension
+ (instancetype)absoluteDimension:(CGFloat)dimension {
    if (sg_enlarging && dimension >= kSmallest) dimension = round(dimension * kScale);
    return %orig(dimension);
}
+ (instancetype)estimatedDimension:(CGFloat)dimension {
    if (sg_enlarging && dimension >= kSmallest) dimension = round(dimension * kScale);
    return %orig(dimension);
}
%end

%hook _TtC12Element_List18CollectionViewCell
- (UICollectionViewLayoutAttributes *)preferredLayoutAttributesFittingAttributes:(UICollectionViewLayoutAttributes *)attributes {
    UICollectionViewLayoutAttributes *result = %orig;
    static Class shelf;
    if (!shelf) shelf = NSClassFromString(@"_TtC16Home_CarouselKit29TouchCancellingCollectionView");
    UIView *content = ((UICollectionViewCell *)self).contentView.subviews.firstObject;
    // Home's sections only, as HomeSections.x tells them: a shelf on another page is not Home's top.
    if (![NSStringFromClass(object_getClass(content)) containsString:@"Home_EvoPageImpl13HomeStructure"]) return result;
    UIView *root = content.subviews.firstObject;
    NSInteger index = attributes.indexPath.section * 10000 + attributes.indexPath.item;
    if (!shelf || ![root isKindOfClass:shelf] || result.size.height <= kHeading) {
        // The top's place holds something else now (the feed came again): the next shelf measured takes it.
        if (index == sg_topIndex) sg_topIndex = NSIntegerMax;
        return result;
    }
    UICollectionViewLayout *layout = ((UICollectionView *)root).collectionViewLayout;
    if (index < sg_topIndex) sg_topIndex = index;
    BOOL large = index == sg_topIndex, was = objc_getAssociatedObject(layout, &kLargeKey) != nil;
    // The shelf's height as Spotify sizes it, from a measuring before it was large.
    if (!was) objc_setAssociatedObject(layout, &kNaturalKey, @(result.size.height), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (large != was) {
        objc_setAssociatedObject(layout, &kLargeKey, large ? @YES : nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [layout invalidateLayout];
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            SGLog(@"redesign home: top picks at %ld, its layout %@ (%@)", (long)index, NSStringFromClass(layout.class),
                  objc_getAssociatedObject(layout, &kWrappedKey) ? @"sized by a provider" : @"not made by a provider: left as it is");
        });
    }
    NSNumber *natural = objc_getAssociatedObject(layout, &kNaturalKey);
    // Large, the natural height scaled; small again in a cell that was large, the natural height, since this measuring
    // was of the cards still drawn large.
    if (natural && large) result.size = CGSizeMake(result.size.width, round(kHeading + (natural.doubleValue - kHeading) * kScale));
    else if (natural && was) result.size = CGSizeMake(result.size.width, natural.doubleValue);
    return result;
}
%end

SGModRow *SGRHomeTopPicksRow(void) {
    return SGWithSymbol(SGSwitchRow(@"Top picks", @"Home's first shelf drawn large", SGRKeyHomeTopPicks), @"rectangle.stack");
}

%ctor {
    if (!SGRedesignedUI() || !SGEnabled(SGRKeyHomeTopPicks)) return;
    %init;
}
