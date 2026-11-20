// Home redesign: of the sections the feed sends, only the music ones stay: the grid of shortcuts, the
// DJ and the shelves of cards (Recents, Jump back in, Your playlists, New releases, the mixes, For fans
// of...). Every other section reports no height, so the list closes up around it: the medium density
// previews (a video or an episode playing muted under Unmute and Watch full episode, or a playlist to
// Preview), a heading over one of those (Fitness for you, Videos from your top artists), the episode
// cards, and any kind the server adds later.
//
// An allow list, as for the cards under the player (Redesigned/Player/PlayerCards.x): the feed is the
// server's, and a new kind should not turn up on a redesigned Home.
//
// Tree (trees/clean/home/10.txt): a section is an Element_List.CollectionViewCell of the page's list whose
// first subview is an ElementContentView over Home_EvoPageImpl.HomeStructure, then an
// ElementView<HomeStructure>, then the section's own root, which names its kind:
//   Home_CarouselKit.TouchCancellingCollectionView     a shelf of SimpleCards under a heading (:2274)
//   UICollectionView with no identifier                 the shortcuts grid, Home_AnchorsAndShortcutsKit cells (01.txt:33)
//   UICollectionView id=ActionCardCarouselElement        episode cards (:696)
//   UIStackView                                         a heading over the DJ card's LazyElementView (01.txt:460),
//                                                       or over a medium density card (:973, :1443)
//   Discovery_MediumDensityCardKit.MediumCardAnimatingLayout   a preview card (:1300, :1746, :1882)
//
// The DJ stays without its heading ("Your own personal DJ" over a card that says DJ): the stack is a plain
// UIStackView, so the heading's LazyElementView is hidden before the cell is measured and the stack closes up.
//
// Each section is a section of the list's own, one item under a 24pt top inset its layout's provider gives it
// (the first, the shortcuts, has none). A dropped section is marked on the list's layout and asked for again
// without that inset, so the list closes up around it with one 24pt gap, not two.
#import <objc/runtime.h>
#import "Core/SGCore.h"
#import "Redesigned/Kit/SGRKit.h"
#import "Home.h"

typedef NS_ENUM(NSInteger, SGRHomeKind) {
    SGRHomeKindPending,   // the section's root is not in the cell yet: left as it is
    SGRHomeKindKeep,
    SGRHomeKindDrop,
};

static char kCollapsedKey, kDroppedKey, kDJRootKey, kDJShapeKey, kDJResultKey, kDJCheckedAtKey;

#pragma mark - the dropped sections' gap

// The provider's sections, a dropped one without its top inset. `layout` gives the layout once it is made.
static UICollectionViewCompositionalLayoutSectionProvider withoutDroppedInsets(UICollectionViewCompositionalLayoutSectionProvider inner,
                                                                               UICollectionViewCompositionalLayout *(^layout)(void)) {
    return ^NSCollectionLayoutSection *(NSInteger section, id<NSCollectionLayoutEnvironment> environment) {
        NSCollectionLayoutSection *made = inner(section, environment);
        UICollectionViewCompositionalLayout *owner = layout();
        NSIndexSet *dropped = owner ? objc_getAssociatedObject(owner, &kDroppedKey) : nil;
        if ([dropped containsIndex:(NSUInteger)section]) {
            NSDirectionalEdgeInsets insets = made.contentInsets;
            insets.top = 0;
            made.contentInsets = insets;
        }
        return made;
    };
}

%hook UICollectionViewCompositionalLayout
- (instancetype)initWithSectionProvider:(UICollectionViewCompositionalLayoutSectionProvider)provider
                          configuration:(UICollectionViewCompositionalLayoutConfiguration *)configuration {
    if (!provider) return %orig;
    __block __weak UICollectionViewCompositionalLayout *made = nil;
    UICollectionViewCompositionalLayout *layout = %orig(withoutDroppedInsets(provider, ^{ return made; }), configuration);
    made = layout;
    return layout;
}
- (instancetype)initWithSectionProvider:(UICollectionViewCompositionalLayoutSectionProvider)provider {
    if (!provider) return %orig;
    __block __weak UICollectionViewCompositionalLayout *made = nil;
    UICollectionViewCompositionalLayout *layout = %orig(withoutDroppedInsets(provider, ^{ return made; }));
    made = layout;
    return layout;
}
%end

// Marks or clears the list section `index` as dropped, and has the layout ask for it again when that changes.
static void markDropped(UICollectionViewCell *cell, NSInteger index, BOOL dropped) {
    UIView *v = cell.superview;
    while (v && ![v isKindOfClass:UICollectionView.class]) v = v.superview;
    UICollectionViewLayout *layout = ((UICollectionView *)v).collectionViewLayout;
    if (!layout || index < 0) return;
    NSMutableIndexSet *set = objc_getAssociatedObject(layout, &kDroppedKey);
    if ([set containsIndex:(NSUInteger)index] == dropped) return;
    if (!set) {
        set = [NSMutableIndexSet indexSet];
        objc_setAssociatedObject(layout, &kDroppedKey, set, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (dropped) [set addIndex:(NSUInteger)index];
    else [set removeIndex:(NSUInteger)index];
    // Not from inside the list's own sizing pass.
    __weak UICollectionViewLayout *weakLayout = layout;
    dispatch_async(dispatch_get_main_queue(), ^{ [weakLayout invalidateLayout]; });
}

static BOOL classNames(Class cls, NSString *marker, NSMutableDictionary<NSString *, NSMutableDictionary *> *cache) {
    if (!cls || !marker) return NO;
    NSMutableDictionary *answers = cache[marker];
    if (!answers) answers = cache[marker] = [NSMutableDictionary dictionary];
    NSNumber *answer = answers[(id<NSCopying>)cls];
    if (!answer) {
        answer = @([NSStringFromClass(cls) containsString:marker]);
        answers[(id<NSCopying>)cls] = answer;
    }
    return answer.boolValue;
}

static BOOL contentNames(UIView *content, NSString *marker) {
    static NSMutableDictionary<NSString *, NSMutableDictionary *> *cache;
    if (!cache) cache = [NSMutableDictionary dictionary];
    return content && classNames(object_getClass(content), marker, cache);
}

static BOOL isSection(UIView *content) {
    return contentNames(content, @"Home_EvoPageImpl13HomeStructure");
}

static void logOnce(NSString *what) {
    static NSMutableSet<NSString *> *logged;
    if (!logged) logged = [NSMutableSet set];
    if ([logged containsObject:what]) return;
    [logged addObject:what];
    SGLog(@"redesign home: %@", what);
}

// The shortcuts grid names no identifier; episode cards and whatever else comes as a bare list do.
static SGRHomeKind gridKind(UICollectionView *grid) {
    if (grid.accessibilityIdentifier.length) return SGRHomeKindDrop;
    UIView *cell = grid.visibleCells.firstObject;
    // A grid the list sized before it laid its own cells out: nothing but the shortcuts has come as one.
    if (cell && !contentNames(cell.subviews.firstObject, @"Home_AnchorsAndShortcutsKit")) return SGRHomeKindDrop;
    return SGHidden(SGRKeyHomeHideShortcuts) ? SGRHomeKindDrop : SGRHomeKindKeep;
}

// The previews (a video or a playlist playing as Home scrolls) are medium density cards, on their own or under a
// heading; the song suggestions are Spotify's content evaluation carousel. Each stays only when asked for.
static SGRHomeKind optionalKind(NSString *name) {
    // DJ is its own Home section, even when Spotify exposes its MDC view/element
    // directly instead of the older Discovery_DJElementKit wrapper. Preview hiding
    // must not suppress its transcript, animation or original navigation action.
    if ([name containsString:@"Discovery_DJElementKit"] || [name containsString:@"DJMDCElement"] ||
        [name containsString:@"DJMDCView"]) return SGHidden(SGRKeyHomeHideDJ) ? SGRHomeKindDrop : SGRHomeKindKeep;
    if ([name containsString:@"MediumDensityCard"] || [name containsString:@"Discovery_Preview"]) {
        return SGHidden(SGRKeyHomePreviews) ? SGRHomeKindKeep : SGRHomeKindDrop;
    }
    if ([name containsString:@"ContentEvaluationList"]) return SGHidden(SGRKeyHomeSongSuggestions) ? SGRHomeKindKeep : SGRHomeKindDrop;
    return SGRHomeKindDrop;
}

// Spotify can wrap the DJ element in ordinary stacks/views. Recognize the original
// card before treating its container as an optional preview. Nested shelves are separate sections.
static BOOL containsDJCard(UIView *view) {
    NSString *name = NSStringFromClass(view.class);
    if ([name containsString:@"Discovery_DJElementKit"] || [name containsString:@"DJMDCElement"] ||
        [name containsString:@"DJMDCView"]) return YES;
    if ([view isKindOfClass:UICollectionView.class]) return NO;
    for (UIView *child in view.subviews) if (containsDJCard(child)) return YES;
    return NO;
}

// Cache at the *section cell* instead of searching through the DJ subtree on
// every self-sizing pass. A shallow signature notices new LazyElementView
// children without paying for a full recursive walk. Negative results are
// short-lived because Spotify can populate deeper wrappers asynchronously.
static NSUInteger djRootShape(UIView *root) {
    NSUInteger shape = root.subviews.count * 131u + (uintptr_t)root.class;
    for (UIView *child in root.subviews) {
        shape = (shape * 33u) ^ (uintptr_t)child;
        shape = (shape * 33u) ^ child.subviews.count;
    }
    return shape;
}
static void invalidateDJSectionCache(UICollectionViewCell *cell) {
    objc_setAssociatedObject(cell, &kDJRootKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(cell, &kDJResultKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(cell, &kDJShapeKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(cell, &kDJCheckedAtKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
static BOOL sectionContainsDJ(UICollectionViewCell *cell, UIView *root) {
    if (!root) { invalidateDJSectionCache(cell); return NO; }
    NSUInteger shape = djRootShape(root);
    NSValue *cachedRoot = objc_getAssociatedObject(cell, &kDJRootKey);
    NSNumber *cachedShape = objc_getAssociatedObject(cell, &kDJShapeKey);
    NSNumber *cachedResult = objc_getAssociatedObject(cell, &kDJResultKey);
    NSNumber *checkedAt = objc_getAssociatedObject(cell, &kDJCheckedAtKey);
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (cachedResult && cachedRoot.nonretainedObjectValue == root && cachedShape.unsignedIntegerValue == shape &&
        (cachedResult.boolValue || (checkedAt && now - checkedAt.doubleValue < 0.25))) return cachedResult.boolValue;
    BOOL found = containsDJCard(root);
    objc_setAssociatedObject(cell, &kDJRootKey, [NSValue valueWithNonretainedObject:root], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(cell, &kDJShapeKey, @(shape), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(cell, &kDJResultKey, @(found), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(cell, &kDJCheckedAtKey, @(now), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return found;
}

// The DJ subtree is recognized by the caller once for this sizing pass.
// This helper only classifies the other optional stack contents.
static SGRHomeKind stackKind(UIStackView *stack) {
    for (UIView *part in stack.arrangedSubviews) {
        NSString *name = NSStringFromClass(part.class);
        SGRHomeKind optional = optionalKind(name);
        if (optional == SGRHomeKindKeep) return optional;
    }
    return stack.arrangedSubviews.count >= 2 ? SGRHomeKindDrop : SGRHomeKindPending;
}

// A shelf stays unless its heading names one that is switched off; one with no heading to read yet stays, and
// HomeHeadings.x asks the cell to measure again once there is one.
static SGRHomeKind shelfKind(UIView *shelf) {
    NSString *identity = SGRHomeShelfIdentity(shelf);
    if (!identity) return SGRHomeKindKeep;
    SGRHomeNoteShelf(identity);
    return SGRHomeShelfHidden(identity) ? SGRHomeKindDrop : SGRHomeKindKeep;
}

// Before the cell is measured, so the height it reports is without the heading.
static void dropDJHeading(UIView *content, BOOL isDJ) {
    if (!isDJ) return;
    UIStackView *stack = (UIStackView *)content.subviews.firstObject.subviews.firstObject;
    if (![stack isKindOfClass:UIStackView.class]) return;
    for (UIView *part in stack.arrangedSubviews) {
        if (part.hidden || ![NSStringFromClass(part.class) containsString:@"Home_HeadingElementKit"]) continue;
        part.hidden = YES;
        logOnce(@"DJ heading hidden");
    }
}

static SGRHomeKind kindOf(UIView *content, NSString **rootName, BOOL isDJ) {
    UIView *root = content.subviews.firstObject.subviews.firstObject;
    if (!root) return SGRHomeKindPending;
    *rootName = NSStringFromClass(root.class);
    if (isDJ) return SGHidden(SGRKeyHomeHideDJ) ? SGRHomeKindDrop : SGRHomeKindKeep;
    static Class shelf;
    if (!shelf) shelf = NSClassFromString(@"_TtC16Home_CarouselKit29TouchCancellingCollectionView");
    if (shelf && [root isKindOfClass:shelf]) return shelfKind(root);
    if ([root isKindOfClass:UICollectionView.class]) return gridKind((UICollectionView *)root);
    if ([root isKindOfClass:UIStackView.class]) return stackKind((UIStackView *)root);
    return optionalKind(*rootName);
}

void SGRHomeMeasureAgain(UIView *view) {
    UIView *cell = view;
    while (cell && ![cell isKindOfClass:UICollectionViewCell.class]) cell = cell.superview;
    // A cell of a shelf's own list: the page's cell is the one around that.
    for (UIView *v = cell.superview; v; v = v.superview) {
        if ([v isKindOfClass:UICollectionViewCell.class]) cell = v;
    }
    if (!cell || !isSection(((UICollectionViewCell *)cell).contentView)) return;
    // The list asks a self-sizing cell for its size again once the cell's item is invalidated in the layout and the
    // cell lays out; the cell's intrinsic size alone was not enough for a cell already sized.
    dispatch_async(dispatch_get_main_queue(), ^{
        UIView *v = cell.superview;
        while (v && ![v isKindOfClass:UICollectionView.class]) v = v.superview;
        UICollectionView *list = (UICollectionView *)v;
        NSIndexPath *path = list ? [list indexPathForCell:(UICollectionViewCell *)cell] : nil;
        [cell invalidateIntrinsicContentSize];
        [cell setNeedsLayout];
        if (!path) return;
        UICollectionViewLayoutInvalidationContext *context = [[[list.collectionViewLayout class] invalidationContextClass] new];
        [context invalidateItemsAtIndexPaths:@[path]];
        [list.collectionViewLayout invalidateLayoutWithContext:context];
    });
}

// A dropped section's cell is 0 tall, but what it holds keeps the height it measured at, hidden and cut off
// by the cell. Spotify's content squeezed to 0 with the cell (trees/continuous/1.txt:375-381, every stack,
// heading and card at {402, 0}) breaks its required constraints on every layout pass of the cell, which
// held the main thread for up to 1.5 s at a time where dropped sections scrolled in (home perf, 2026-09-17).
static void collapse(UICollectionViewCell *cell, CGFloat natural) {
    UIView *content = cell.contentView;
    objc_setAssociatedObject(cell, &kCollapsedKey, @(natural), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (content.autoresizingMask & UIViewAutoresizingFlexibleHeight) content.autoresizingMask &= ~UIViewAutoresizingFlexibleHeight;
    CGRect frame = CGRectMake(0, 0, cell.bounds.size.width, natural);
    if (!CGRectEqualToRect(content.frame, frame)) content.frame = frame;
    if (!content.hidden) content.hidden = YES;
    if (!cell.clipsToBounds) cell.clipsToBounds = YES;
    cell.accessibilityElementsHidden = YES;
}

static void expand(UICollectionViewCell *cell) {
    UIView *content = cell.contentView;
    objc_setAssociatedObject(cell, &kCollapsedKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    content.autoresizingMask |= UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    content.frame = cell.bounds;
    content.hidden = NO;
    cell.clipsToBounds = NO;
    cell.accessibilityElementsHidden = NO;
}

%hook _TtC12Element_List18CollectionViewCell
- (UICollectionViewLayoutAttributes *)preferredLayoutAttributesFittingAttributes:(UICollectionViewLayoutAttributes *)attributes {
    UICollectionViewCell *cell = (UICollectionViewCell *)self;
    UIView *content = cell.contentView;
    if (!isSection(content)) return %orig;
    CFTimeInterval began = SGRHomeProbeBegin();
    UIView *rootBefore = content.subviews.firstObject.subviews.firstObject;
    BOOL isDJ = sectionContainsDJ(cell, rootBefore);
    dropDJHeading(content, isDJ);
    UICollectionViewLayoutAttributes *result = %orig;

    // Reuse the subtree classification rather than rescanning every stack child.
    // A lazy section can install a different root during Spotify's sizing call;
    // only then must the new root be classified afresh.
    UIView *rootAfter = content.subviews.firstObject.subviews.firstObject;
    if (rootAfter != rootBefore) isDJ = sectionContainsDJ(cell, rootAfter);
    NSString *rootName = nil;
    SGRHomeKind kind = kindOf(content, &rootName, isDJ);
    BOOL collapsed = objc_getAssociatedObject(cell, &kCollapsedKey) != nil;
    if (kind == SGRHomeKindDrop) {
        collapse(cell, MAX(1, result.size.height));
        result.size = CGSizeMake(result.size.width, 0);
        markDropped(cell, attributes.indexPath.section, YES);
        logOnce([@"dropped a section of " stringByAppendingString:rootName]);
    } else if (kind == SGRHomeKindKeep) {
        // Cells are reused across kinds: one collapsed before holds a section to keep now.
        if (collapsed) expand(cell);
        // The page's color (HomeHeader.x) shows through a kept section; Spotify paints a shelf black on each configure.
        UIView *root = content.subviews.firstObject.subviews.firstObject;
        if (SGRHomeLook() && [root isKindOfClass:UICollectionView.class] && ![root.backgroundColor isEqual:UIColor.clearColor]) root.backgroundColor = UIColor.clearColor;
        markDropped(cell, attributes.indexPath.section, NO);
        logOnce([@"kept a section of " stringByAppendingString:rootName]);
    } else {
        logOnce([@"sized a section before its root was in, left as it is: " stringByAppendingString:rootName ?: @"no root"]);
    }
    SGRHomeProbeEnd(SGRHomeProbeSections, began);
    return result;
}

// The cell's own passes may size the content to the cell again.
- (void)layoutSubviews {
    %orig;
    NSNumber *natural = objc_getAssociatedObject(self, &kCollapsedKey);
    if (natural) collapse((UICollectionViewCell *)self, natural.doubleValue);
}

- (void)prepareForReuse {
    %orig;
    invalidateDJSectionCache((UICollectionViewCell *)self);
    if (objc_getAssociatedObject(self, &kCollapsedKey)) expand((UICollectionViewCell *)self);
}
%end

BOOL SGRHomeSectionCollapsed(UIView *cell) {
    return objc_getAssociatedObject(cell, &kCollapsedKey) != nil;
}

%ctor {
    // Registered whatever the switch says: the flag rows elsewhere lock to these while it is on.
    SGRedesignForceFlags(@"home", @{
        // The badge on the DJ card.
        @"ios-home-evopage-impl.dj_mdc_beta_badge_enabled": @NO,
        // The prompt field for Spotify's AI on Home.
        @"ios-home-evopage-impl.interactive_entrypoint_enabled": @NO,
    });
    if (!SGRedesignedUI()) return;
    %init;
    SGRequireClasses(@[
        @"_TtC12Element_List18CollectionViewCell",
        @"_TtC16Home_CarouselKit29TouchCancellingCollectionView",
    ]);
}
