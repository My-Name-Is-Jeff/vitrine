// The dispatcher is a singleton the app builds at startup; -setMainUILoaded: is the last call of its
// setup (objc-methods.txt:38809).
#import "Core/SGCore.h"
#import "Headers/SPTLinkDispatcherImplementation.h"
#import "Links.h"
#import <objc/message.h>

static __weak SPTLinkDispatcherImplementation *sg_linkDispatcher;

id SGLinkDispatcher(void) {
    return sg_linkDispatcher;
}

// 9.1.88 dropped -navigateToURI:options:interactionID:. In 9.1.78 it only wraps
// -navigateToURI:options:reason:completionHandler:resultHandler:, which every version has, with the reason
// [[SPTUBINavigationReason alloc] initWithSourceApplication:nil interactionID:<its interactionID>] and no handlers
// (read off the 9.1.78 binary), so later versions get the same. A nil reason crashes: Swift reads it as an enum.
BOOL SGOpenSpotifyURI(NSURL *uri) {
    SPTLinkDispatcherImplementation *dispatcher = sg_linkDispatcher;
    if (!uri || !dispatcher) return NO;
    if ([dispatcher respondsToSelector:@selector(navigateToURI:options:interactionID:)]) {
        [dispatcher navigateToURI:uri options:0 interactionID:nil];
        return YES;
    }
    SEL full = NSSelectorFromString(@"navigateToURI:options:reason:completionHandler:resultHandler:");
    // alloc and init by hand, outside ARC: init consumes what alloc made and returns its own +1.
    Class reasonClass = NSClassFromString(@"SPTUBINavigationReason");
    SEL init = NSSelectorFromString(@"initWithSourceApplication:interactionID:");
    id reason = nil;
    if ([reasonClass instancesRespondToSelector:init]) {
        void *raw = ((void *(*)(Class, SEL))objc_msgSend)(reasonClass, @selector(alloc));
        reason = CFBridgingRelease(((void *(*)(void *, SEL, id, id))objc_msgSend)(raw, init, nil, nil));
    }
    if (![dispatcher respondsToSelector:full] || !reason) return NO;
    ((void (*)(id, SEL, NSURL *, long long, id, id, id))objc_msgSend)(dispatcher, full, uri, 0, reason, nil, nil);
    return YES;
}

#pragma mark - asking before opening

// The chain a spotify: link takes in 9.1.78, read off the binary: -[SPTLinkDispatcherImplementation
// navigateToURI:…] hands it to the URI scheme dispatcher, whose "spotify" handler is the dispatcher's
// -spotifyLinkHandler (SPTSpotifyLinkHandler). That one passes the cleaned URI to its
// -URISubtypeRegistry (SPTURISubtypeRegistryImplementation), which keeps the handlers of its -handlers
// hash table that answer -URISubtypeHandlerCanHandleURI: YES and opens with the first by priority;
// pages go through Navigation's PageResolverURISubtypeHandler. With no taker, -handleSpotifyURL:
// tries again once with -remapURI: (its fallback resolver's URI), and only then shows the alert.
static id sg_send(id target, NSString *selector) {
    SEL sel = NSSelectorFromString(selector);
    if (![target respondsToSelector:sel]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(target, sel);
}

static id sg_send1(id target, NSString *selector, id arg) {
    SEL sel = NSSelectorFromString(selector);
    if (![target respondsToSelector:sel]) return nil;
    return ((id (*)(id, SEL, id))objc_msgSend)(target, sel, arg);
}

// The class of the first handler that takes `uri`, nil for none. A handler whose name says it only
// listens (Jam's SGSNavigationURIHandledEventSource) is not asked, so a question is not taken for a
// navigation.
static NSString *takerFor(id<NSFastEnumeration> handlers, NSURL *uri, NSUInteger *asked) {
    SEL canHandle = NSSelectorFromString(@"URISubtypeHandlerCanHandleURI:");
    for (id handler in handlers) {
        NSString *name = NSStringFromClass([handler class]);
        if ([name containsString:@"EventSource"] || ![handler respondsToSelector:canHandle]) continue;
        (*asked)++;
        if (((BOOL (*)(id, SEL, id))objc_msgSend)(handler, canHandle, uri)) return name;
    }
    return nil;
}

SGLinkRoute SGSpotifyURIRoute(NSURL *uri, NSString **via) {
    if (via) *via = nil;
    if (!uri) return SGLinkRouteNone;
    id linkHandler = sg_send(sg_linkDispatcher, @"spotifyLinkHandler");
    id handlers = sg_send(sg_send(linkHandler, @"URISubtypeRegistry"), @"handlers");
    if (![handlers conformsToProtocol:@protocol(NSFastEnumeration)]) return SGLinkRouteUnknown;
    @try {
        NSURL *clean = sg_send(uri, @"spt_normalizedSpotifyURI");
        if (![clean isKindOfClass:NSURL.class]) clean = uri;
        NSUInteger asked = 0;
        NSString *taker = takerFor(handlers, clean, &asked);
        if (!taker) {
            NSURL *remapped = sg_send1(linkHandler, @"remapURI:", clean);
            if ([remapped isKindOfClass:NSURL.class] && ![remapped isEqual:clean]) {
                taker = takerFor(handlers, remapped, &asked);
                if (taker) taker = [NSString stringWithFormat:@"remap %@ %@", remapped.absoluteString, taker];
            }
        }
        if (!asked) return SGLinkRouteUnknown;
        if (via) *via = taker;
        return taker ? SGLinkRouteOpens : SGLinkRouteNone;
    } @catch (NSException *e) {
        SGLog(@"links: asking about %@ threw %@", uri, e.reason);
        return SGLinkRouteUnknown;
    }
}

static BOOL stripPrefix(NSString **text, NSString *prefix) {
    NSRange r = [*text rangeOfString:prefix options:NSCaseInsensitiveSearch | NSAnchoredSearch];
    if (r.location == NSNotFound) return NO;
    *text = [*text substringFromIndex:r.length];
    return YES;
}

static NSURL *spotifyURIForPieces(NSArray<NSString *> *raw) {
    NSMutableArray<NSString *> *path = [NSMutableArray array];
    for (NSString *piece in raw) {
        if (piece.length) [path addObject:piece];
    }
    if (path.count && [path.firstObject.lowercaseString hasPrefix:@"intl-"]) [path removeObjectAtIndex:0];
    if (path.count && [path.firstObject.lowercaseString isEqualToString:@"embed"]) [path removeObjectAtIndex:0];
    if (path.count < 2) return nil;
    return [NSURL URLWithString:[@"spotify:" stringByAppendingString:[path componentsJoinedByString:@":"]]];
}

// Sideloaded builds have no associated-domains entitlement for open.spotify.com, so Safari
// extensions open the app via spotify:// with the web link or path inside (spotify://eevee/…,
// spotify://open.spotify.com/…, spotify://intl-xx/…). Unwrap those and open.spotify.com share
// links into spotify: URIs, and hand wrapped short links back as https://.
static NSURL *rewrittenURI(NSString *raw) {
    if (!raw.length) return nil;
    NSString *decoded = raw.stringByRemovingPercentEncoding;
    if (decoded.length && ([decoded containsString:@"://"] || [decoded containsString:@"open.spotify.com"])) {
        raw = decoded;
    }
    NSString *rest = raw;
    if (stripPrefix(&rest, @"spotify://")) {
        stripPrefix(&rest, @"eevee/");
        if (!stripPrefix(&rest, @"https://")) stripPrefix(&rest, @"http://");
        if ([rest.lowercaseString hasPrefix:@"spotify.app.link/"] || [rest.lowercaseString hasPrefix:@"spotify.link/"]) {
            return [NSURL URLWithString:[@"https://" stringByAppendingString:rest]];
        }
        stripPrefix(&rest, @"open.spotify.com/");
        NSString *clean = [[rest componentsSeparatedByString:@"?"].firstObject componentsSeparatedByString:@"#"].firstObject;
        NSURL *spotifyURI = spotifyURIForPieces([clean componentsSeparatedByString:@"/"]);
        if (spotifyURI) return spotifyURI;
        if ([rest.lowercaseString hasPrefix:@"intl-"] || [rest.lowercaseString hasPrefix:@"embed/"]) {
            raw = [@"https://open.spotify.com/" stringByAppendingString:rest];
        }
    } else if (stripPrefix(&rest, @"spotify:")) {
        BOOL wrapped = stripPrefix(&rest, @"eevee:");
        if (stripPrefix(&rest, @"open.spotify.com:")) wrapped = YES;
        if (wrapped || [rest.lowercaseString hasPrefix:@"intl-"] || [rest.lowercaseString hasPrefix:@"embed:"]) {
            NSString *clean = [[rest componentsSeparatedByString:@"?"].firstObject componentsSeparatedByString:@"#"].firstObject;
            return spotifyURIForPieces([clean componentsSeparatedByString:@":"]);
        }
    }
    NSURLComponents *parts = [NSURLComponents componentsWithString:raw];
    if ([parts.scheme.lowercaseString hasPrefix:@"http"] && [parts.host.lowercaseString hasSuffix:@"open.spotify.com"]) {
        return spotifyURIForPieces([parts.path componentsSeparatedByString:@"/"]) ?: [NSURL URLWithString:raw];
    }
    return nil;
}

NSURL *SGSpotifyURIFromText(NSString *text) {
    NSString *trimmed = [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!trimmed.length) return nil;
    return rewrittenURI(trimmed) ?: [NSURL URLWithString:trimmed];
}

@interface NSURL (SpotifyLinkCategory)
- (NSURL *)spt_normalizedSpotifyURI;
- (NSURL *)spt_normalizedURI;
- (BOOL)sptparse_isSpotifyURI;
@end

%hook NSURL
- (NSURL *)spt_normalizedSpotifyURI {
    NSURL *orig = %orig();
    if ([orig isKindOfClass:NSURL.class]) return orig;
    NSURL *rewritten = rewrittenURI(self.absoluteString);
    if (rewritten) {
        SGLog(@"links: spt_normalizedSpotifyURI rewriting %@ -> %@", self, rewritten);
        return rewritten;
    }
    if ([self.scheme.lowercaseString isEqualToString:@"spotify"]) return self;
    return nil;
}

- (NSURL *)spt_normalizedURI {
    NSURL *orig = %orig();
    if ([orig isKindOfClass:NSURL.class]) return orig;
    NSURL *rewritten = rewrittenURI(self.absoluteString);
    if (rewritten) {
        SGLog(@"links: spt_normalizedURI rewriting %@ -> %@", self, rewritten);
        return rewritten;
    }
    if ([self.scheme.lowercaseString isEqualToString:@"spotify"]) return self;
    return nil;
}

- (BOOL)sptparse_isSpotifyURI {
    BOOL orig = %orig();
    if (orig) return YES;
    if ([self.scheme.lowercaseString isEqualToString:@"spotify"]) return YES;
    return rewrittenURI(self.absoluteString) != nil;
}
%end

@interface SPTURISchemeDispatcher : NSObject
- (BOOL)handleURI:(NSURL *)uri context:(id)context;
@end

@interface SPTSpotifyLinkHandler : NSObject
- (long long)handleSpotifyURL:(NSURL *)url context:(id)context;
@end

@interface _TtC24MusicApp_ContainerWiring18SpotifyAppDelegate : UIResponder <UIApplicationDelegate>
- (BOOL)application:(id)application openURL:(NSURL *)url options:(id)options;
@end

%hook _TtC24MusicApp_ContainerWiring18SpotifyAppDelegate
- (BOOL)application:(id)application openURL:(NSURL *)url options:(id)options {
    NSURL *rewritten = rewrittenURI(url.absoluteString);
    if (rewritten) SGLog(@"links: app openURL rewriting %@ -> %@", url, rewritten);
    return %orig(application, rewritten ?: url, options);
}
%end

%hook SPTURISchemeDispatcher
- (BOOL)handleURI:(NSURL *)uri context:(id)context {
    NSURL *rewritten = rewrittenURI(uri.absoluteString);
    if (rewritten) SGLog(@"links: scheme dispatcher rewriting %@ -> %@", uri, rewritten);
    BOOL res = %orig(rewritten ?: uri, context);
    if (!res && rewritten) {
        SGLog(@"links: scheme dispatcher returned NO for %@, dispatching directly", rewritten);
        return SGOpenSpotifyURI(rewritten);
    }
    return res;
}
%end

%hook SPTSpotifyLinkHandler
- (long long)handleSpotifyURL:(NSURL *)url context:(id)context {
    NSURL *rewritten = rewrittenURI(url.absoluteString);
    if (rewritten) SGLog(@"links: spotify link handler rewriting %@ -> %@", url, rewritten);
    long long res = %orig(rewritten ?: url, context);
    if (res == 0 && rewritten) {
        SGLog(@"links: spotify link handler returned 0 for %@, dispatching directly", rewritten);
        if (SGOpenSpotifyURI(rewritten)) return 3;
    }
    return res;
}
%end

%hook UIOpenURLContext
- (NSURL *)URL {
    NSURL *url = %orig;
    NSURL *rewritten = rewrittenURI(url.absoluteString);
    if (rewritten) SGLog(@"links: UIOpenURLContext rewriting %@ -> %@", url, rewritten);
    return rewritten ?: url;
}
%end

%hook SPTLinkDispatcherImplementation
- (void)setMainUILoaded:(BOOL)loaded {
    %orig;
    sg_linkDispatcher = (SPTLinkDispatcherImplementation *)self;
}

- (void)navigateToURI:(NSURL *)uri options:(long long)options reason:(id)reason completionHandler:(id)completionHandler resultHandler:(id)resultHandler {
    sg_linkDispatcher = (SPTLinkDispatcherImplementation *)self;
    NSURL *rewritten = rewrittenURI(uri.absoluteString);
    if (rewritten) SGLog(@"links: navigateToURI rewriting %@ -> %@", uri, rewritten);
    %orig(rewritten ?: uri, options, reason, completionHandler, resultHandler);
}

- (BOOL)navigateToInternalURI:(NSURL *)uri options:(long long)options reason:(id)reason resultHandler:(id)resultHandler {
    sg_linkDispatcher = (SPTLinkDispatcherImplementation *)self;
    NSURL *rewritten = rewrittenURI(uri.absoluteString);
    if (rewritten) SGLog(@"links: navigateToInternalURI rewriting %@ -> %@", uri, rewritten);
    return %orig(rewritten ?: uri, options, reason, resultHandler);
}

- (void)URISchemeDispatcher:(id)dispatcher showInvalidSpotifyLinkMessageForURI:(NSURL *)uri {
    sg_linkDispatcher = (SPTLinkDispatcherImplementation *)self;
    NSURL *rewritten = rewrittenURI(uri.absoluteString);
    if (rewritten && SGOpenSpotifyURI(rewritten)) {
        SGLog(@"links: intercepted invalid spotify link alert for %@, opened %@", uri, rewritten);
        return;
    }
    %orig;
}

- (void)URISchemeDispatcher:(id)dispatcher showInvalidLinkMessageForURI:(NSURL *)uri {
    sg_linkDispatcher = (SPTLinkDispatcherImplementation *)self;
    NSURL *rewritten = rewrittenURI(uri.absoluteString);
    if (rewritten && SGOpenSpotifyURI(rewritten)) {
        SGLog(@"links: intercepted invalid link alert for %@, opened %@", uri, rewritten);
        return;
    }
    %orig;
}
%end

%ctor {
    %init;
    SGRequireClasses(@[
        @"SPTLinkDispatcherImplementation",
        @"SPTURISchemeDispatcher",
        @"SPTSpotifyLinkHandler",
    ]);
}
