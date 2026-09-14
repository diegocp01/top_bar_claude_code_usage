#import <Cocoa/Cocoa.h>
#import <ServiceManagement/ServiceManagement.h>
#import <math.h>

static NSString * const DisplayModeKey = @"displayMode";
static NSString * const DisplayModePercent = @"percent";
static NSString * const DisplayModeBattery = @"battery";
static NSString * const TimeModeKey = @"timeMode";
static NSString * const TimeModeClock = @"clock";
static NSString * const TimeModeCountdown = @"countdown";
static NSString * const TimeModeHidden = @"hidden";
static NSString * const MetricModeKey = @"metricMode";
static NSString * const MetricModeLeft = @"left";
static NSString * const MetricModeUsed = @"used";
static NSString * const WidgetWindowModeKey = @"widgetWindowMode";
static NSString * const WidgetWindowSession = @"session";
static NSString * const WidgetWindowWeekly = @"weekly";
// The usage API reports when a window resets but not when it began, so the
// on-pace marker uses the fixed lengths the windows are named after.
static NSTimeInterval const SessionWindowSeconds = 5.0 * 3600.0;
static NSTimeInterval const WeeklyWindowSeconds = 7.0 * 24.0 * 3600.0;
static NSString * const RefreshIntervalKey = @"refreshIntervalSeconds";
static NSTimeInterval const DefaultRefreshIntervalSeconds = 300.0;
// Re-read the keychain this long before the cached token expires. Slightly wider
// than the 60s window validAccessTokenFromCredentials uses to refresh, so we
// pick up a token the CLI already rotated instead of spending our own refresh.
static NSTimeInterval const CredentialCacheSkewSeconds = 120.0;
// Floor between keychain reads. Without it, an expired token the CLI hasn't
// replaced yet would send us back to the keychain on every single poll.
static NSTimeInterval const KeychainReadMinIntervalSeconds = 120.0;
// Past this much staleness the cached numbers are old enough to mislead, so the
// menu bar stops rendering them as if they were current.
static NSTimeInterval const StaleDisplayThresholdSeconds = 600.0;

// Persisted last-good usage snapshot, so the widget keeps showing real numbers
// even while the API is unreachable or rate-limiting us.
static NSString * const LastGoodStateKey = @"lastGoodState";
static NSString * const LastGoodFetchedAtKey = @"lastGoodFetchedAt";
static NSString * const LastErrorKey = @"lastError";
static NSString * const LastErrorAtKey = @"lastErrorAt";
// Upper bound on how long we back off the network after repeated failures.
static NSTimeInterval const UsageBackoffMaxSeconds = 600.0;

// Claude Code OAuth configuration (matches the Claude Code CLI production config).
static NSString * const GitHubRepo = @"diegocp01/top_bar_claude_code_usage";
static NSString * const KeychainService = @"Claude Code-credentials";
// All keychain access goes through /usr/bin/security, exactly as Claude Code
// does. The item's access list trusts that tool (partition "apple-tool:"), so
// reads never prompt, and writes leave the access list untouched. Writing with
// SecItemUpdate from this app instead stamped the item's partition list with
// this app's Team ID, which evicted Claude Code: it then asked for the login
// password on every launch, and "Always Allow" only helped until our next write.
static NSString * const SecurityToolPath = @"/usr/bin/security";
static int const SecurityExitItemNotFound = 44;
// `security -i` reads commands into a fixed line buffer. A longer line is not
// rejected — it is truncated and the truncated bytes get STORED. Stay well under.
static NSUInteger const SecurityInteractiveLineLimit = 3500;
// A pending keychain dialog blocks the tool; never let that wedge polling.
static NSTimeInterval const SecurityToolTimeoutSeconds = 30.0;
static NSString * const OAuthClientID = @"9d1c250a-e61b-44d9-88ed-5944d1962f5e";
static NSString * const OAuthTokenURL = @"https://platform.claude.com/v1/oauth/token";
static NSString * const UsageURL = @"https://api.anthropic.com/api/oauth/usage";
static NSString * const OAuthBetaHeader = @"oauth-2025-04-20";
// Cloudflare rejects URLSession's default client signature on the OAuth token
// endpoint. Identify this as an external Claude CLI companion on every request.
static NSString * const HTTPUserAgent = @"claude-cli/0.1.0 (external, menu-bar)";

@interface AppDelegate : NSObject <NSApplicationDelegate, NSMenuDelegate>
@property(nonatomic, strong) NSStatusItem *statusItem;
@property(nonatomic, strong) NSTimer *pollTimer;
@property(nonatomic, strong) NSTimer *displayTimer;
@property(nonatomic, strong) NSDictionary *latestState;
@property(nonatomic, strong) NSImage *claudeIcon;
@property(nonatomic, copy) NSString *launchAtLoginError;
@property(nonatomic, strong) NSDate *refreshBackoffUntil;
// Credentials live in memory between polls, so the keychain is read roughly once
// per token lifetime instead of on every poll.
@property(nonatomic, strong) NSDictionary *cachedCredentials;
@property(nonatomic, strong) NSDate *lastKeychainReadAt;
// Last successful usage snapshot + when we got it, and the network cool-down
// the API has effectively imposed on us (e.g. after a 429).
@property(nonatomic, strong) NSDictionary *lastGoodState;
@property(nonatomic, strong) NSDate *lastGoodFetchedAt;
@property(nonatomic, strong) NSDate *usageBackoffUntil;
@property(nonatomic, assign) NSTimeInterval usageBackoffSeconds;
// What Check for Updates is doing right now ("Checking…", "Updating…"), or nil.
@property(nonatomic, copy) NSString *updateActivity;
@end

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    (void)notification;
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];

    [NSUserDefaults.standardUserDefaults registerDefaults:@{
        DisplayModeKey: DisplayModePercent,
        TimeModeKey: TimeModeClock,
        MetricModeKey: MetricModeLeft,
        WidgetWindowModeKey: WidgetWindowSession,
        RefreshIntervalKey: @(DefaultRefreshIntervalSeconds)
    }];

    [self restoreLastGoodState];

    self.claudeIcon = [self claudeMenuBarIcon];
    self.statusItem = [[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength];
    self.statusItem.button.title = @"--";
    self.statusItem.button.image = self.claudeIcon;
    self.statusItem.button.imagePosition = NSImageLeft;
    self.statusItem.button.font = [NSFont monospacedDigitSystemFontOfSize:[NSFont systemFontSize]
                                                                    weight:NSFontWeightMedium];
    self.statusItem.menu = [self menuForCurrentState];

    [self refresh];
    [self schedulePollTimer];
    self.displayTimer = [NSTimer scheduledTimerWithTimeInterval:1.0
                                                         target:self
                                                       selector:@selector(updateStatusItem)
                                                       userInfo:nil
                                                        repeats:YES];
}

#pragma mark - Icon

- (NSImage *)claudeMenuBarIcon {
    NSImage *image = [[NSImage alloc] initWithSize:NSMakeSize(18.0, 18.0)];
    [image lockFocus];
    [NSColor.blackColor set];
    [self drawClaudeBurstInRect:NSMakeRect(0.0, 0.0, 18.0, 18.0)];
    [image unlockFocus];
    image.template = YES;
    return image;
}

// Draws the Claude "sunburst" mark as a set of radial rays, sized to fill rect.
- (void)drawClaudeBurstInRect:(NSRect)rect {
    NSPoint center = NSMakePoint(NSMidX(rect), NSMidY(rect));
    CGFloat unit = MIN(rect.size.width, rect.size.height);
    CGFloat outer = unit * 0.46;
    CGFloat inner = unit * 0.05;
    CGFloat thickness = unit * 0.115;

    NSInteger rays = 12;
    for (NSInteger i = 0; i < rays; i++) {
        double angle = (M_PI * 2.0 * i) / rays - M_PI_2;
        NSPoint p0 = NSMakePoint(center.x + cos(angle) * inner,
                                 center.y + sin(angle) * inner);
        NSPoint p1 = NSMakePoint(center.x + cos(angle) * outer,
                                 center.y + sin(angle) * outer);
        NSBezierPath *ray = [NSBezierPath bezierPath];
        ray.lineWidth = thickness;
        ray.lineCapStyle = NSLineCapStyleRound;
        [ray moveToPoint:p0];
        [ray lineToPoint:p1];
        [ray stroke];
    }
}

// onPacePercent places the slim on-pace marker (see onPacePercentForWidgetState:);
// pass NAN to omit it.
- (NSImage *)batteryIconForPercent:(double)percent onPacePercent:(double)onPacePercent {
    double clamped = MAX(0.0, MIN(100.0, percent));
    NSImage *image = [[NSImage alloc] initWithSize:NSMakeSize(66.0, 18.0)];

    [image lockFocus];

    [NSColor.blackColor set];
    [self drawClaudeBurstInRect:NSMakeRect(0.0, 0.0, 18.0, 18.0)];

    NSRect body = NSMakeRect(24.0, 3.0, 34.0, 12.0);
    NSBezierPath *outline = [NSBezierPath bezierPathWithRoundedRect:body xRadius:2.0 yRadius:2.0];
    outline.lineWidth = 1.4;
    [outline stroke];

    NSRect nub = NSMakeRect(NSMaxX(body) + 1.0, 6.5, 2.0, 5.0);
    [[NSBezierPath bezierPathWithRoundedRect:nub xRadius:0.8 yRadius:0.8] fill];

    NSRect interior = NSMakeRect(body.origin.x + 2.0, body.origin.y + 2.0, body.size.width - 4.0, body.size.height - 4.0);
    CGFloat fillWidth = (CGFloat)(interior.size.width * (clamped / 100.0));
    NSBezierPath *fillPath = nil;
    if (fillWidth > 0.5) {
        NSRect fillRect = NSMakeRect(NSMinX(interior), NSMinY(interior), fillWidth, NSHeight(interior));
        fillPath = [NSBezierPath bezierPathWithRoundedRect:fillRect xRadius:1.0 yRadius:1.0];
        [fillPath fill];
    }

    NSString *number = [NSString stringWithFormat:@"%.0f", clamped];
    NSDictionary *attributes = @{
        NSFontAttributeName: [NSFont monospacedDigitSystemFontOfSize:8.5 weight:NSFontWeightSemibold],
        NSForegroundColorAttributeName: NSColor.blackColor
    };
    NSSize numberSize = [number sizeWithAttributes:attributes];
    NSPoint numberPoint = NSMakePoint(NSMidX(body) - numberSize.width / 2.0,
                                      NSMidY(body) - numberSize.height / 2.0 - 0.5);

    if (isfinite(onPacePercent)) {
        CGFloat pace = MAX(0.0, MIN(100.0, onPacePercent));
        CGFloat markerX = NSMinX(interior) + interior.size.width * (pace / 100.0);
        markerX = floor(MAX(NSMinX(interior) + 0.5, MIN(NSMaxX(interior) - 0.5, markerX))) + 0.5;
        NSRect marker = NSMakeRect(markerX - 0.5, NSMinY(interior), 1.0, NSHeight(interior));
        NSRect numberBounds = NSMakeRect(numberPoint.x, numberPoint.y, numberSize.width, numberSize.height);
        // Soften the marker where it runs beneath the digits so they stay legible.
        CGFloat markerOpacity = (NSMinX(marker) < NSMaxX(numberBounds) && NSMaxX(marker) > NSMinX(numberBounds)) ? 0.55 : 1.0;
        [NSGraphicsContext saveGraphicsState];
        [[NSBezierPath bezierPathWithRoundedRect:interior xRadius:1.0 yRadius:1.0] addClip];
        [[NSColor colorWithCalibratedWhite:0.0 alpha:markerOpacity] setFill];
        NSRectFill(marker);
        if (fillPath != nil) {
            // Inside the fill the marker is a cutout, so it contrasts there too.
            [fillPath addClip];
            NSRectFillUsingOperation(marker, NSCompositingOperationClear);
            [[NSColor colorWithCalibratedWhite:0.0 alpha:1.0 - markerOpacity] setFill];
            NSRectFill(marker);
        }
        [NSGraphicsContext restoreGraphicsState];
    }

    // This is a template image: macOS tints everything one color, so digits drawn
    // over the fill would vanish into it. Clear beneath the digits, draw them, then
    // punch them out of the fill so each half shows the opposite menu-bar color.
    [NSGraphicsContext saveGraphicsState];
    NSGraphicsContext.currentContext.compositingOperation = NSCompositingOperationClear;
    [number drawAtPoint:numberPoint withAttributes:attributes];
    [NSGraphicsContext restoreGraphicsState];
    [number drawAtPoint:numberPoint withAttributes:attributes];
    if (fillPath != nil) {
        [NSGraphicsContext saveGraphicsState];
        [fillPath addClip];
        NSGraphicsContext.currentContext.compositingOperation = NSCompositingOperationClear;
        [number drawAtPoint:numberPoint withAttributes:attributes];
        [NSGraphicsContext restoreGraphicsState];
    }

    [image unlockFocus];
    image.template = YES;
    return image;
}

#pragma mark - Menu

- (void)menuWillOpen:(NSMenu *)menu {
    (void)menu;
    self.statusItem.menu = [self menuForCurrentState];
}

- (NSMenu *)menuForCurrentState {
    NSMenu *menu = [[NSMenu alloc] initWithTitle:@"Claude Code Usage"];
    menu.delegate = self;

    NSMenuItem *header = [[NSMenuItem alloc] initWithTitle:@"Claude Code Usage" action:nil keyEquivalent:@""];
    header.enabled = NO;
    [menu addItem:header];
    [menu addItem:[NSMenuItem separatorItem]];

    NSDictionary *state = self.latestState;
    [self addDisabledItem:[self detailUsageTextForState:state] toMenu:menu];
    if ([state[@"weekly_summary"] isKindOfClass:[NSString class]]) {
        [self addDisabledItem:state[@"weekly_summary"] toMenu:menu];
    }
    if ([state[@"weekly_opus_summary"] isKindOfClass:[NSString class]]) {
        [self addDisabledItem:state[@"weekly_opus_summary"] toMenu:menu];
    }
    [self addDisabledItem:[self resetClockDetailForState:state] toMenu:menu];
    [self addDisabledItem:[self countdownDetailForState:state] toMenu:menu];

    if ([state[@"plan_summary"] isKindOfClass:[NSString class]]) {
        [self addDisabledItem:state[@"plan_summary"] toMenu:menu];
    }
    [self addDisabledItem:state[@"updated_summary"] ?: @"Updated: unknown" toMenu:menu];

    if ([state[@"source_summary"] isKindOfClass:[NSString class]]) {
        [self addDisabledItem:state[@"source_summary"] toMenu:menu];
    }
    if (self.launchAtLoginError.length > 0) {
        [self addDisabledItem:[NSString stringWithFormat:@"Login item: %@", self.launchAtLoginError] toMenu:menu];
    }

    NSNumber *ok = state[@"ok"];
    BOOL stale = [state[@"stale"] respondsToSelector:@selector(boolValue)] && [state[@"stale"] boolValue];
    if ((([ok respondsToSelector:@selector(boolValue)] && ![ok boolValue]) || stale) &&
        [state[@"error"] isKindOfClass:[NSString class]]) {
        [menu addItem:[NSMenuItem separatorItem]];
        NSString *prefix = stale ? @"Refresh failed" : @"Error";
        [self addDisabledItem:[NSString stringWithFormat:@"%@: %@", prefix, state[@"error"]] toMenu:menu];
    }

    [menu addItem:[NSMenuItem separatorItem]];
    [self addChoiceWithTitle:@"Show Percentage"
                      action:@selector(usePercentDisplay)
                     checked:[[self displayMode] isEqualToString:DisplayModePercent]
                      toMenu:menu];
    [self addChoiceWithTitle:@"Show Battery"
                      action:@selector(useBatteryDisplay)
                     checked:[[self displayMode] isEqualToString:DisplayModeBattery]
                      toMenu:menu];

    [menu addItem:[NSMenuItem separatorItem]];
    [self addChoiceWithTitle:@"Show % Left"
                      action:@selector(useLeftMetric)
                     checked:[[self metricMode] isEqualToString:MetricModeLeft]
                      toMenu:menu];
    [self addChoiceWithTitle:@"Show % Used"
                      action:@selector(useUsedMetric)
                     checked:[[self metricMode] isEqualToString:MetricModeUsed]
                      toMenu:menu];

    [menu addItem:[NSMenuItem separatorItem]];
    [self addChoiceWithTitle:@"Widget: Session (5h)"
                      action:@selector(useSessionWidgetWindow)
                     checked:[[self widgetWindowMode] isEqualToString:WidgetWindowSession]
                      toMenu:menu];
    [self addChoiceWithTitle:@"Widget: Weekly (7d)"
                      action:@selector(useWeeklyWidgetWindow)
                     checked:[[self widgetWindowMode] isEqualToString:WidgetWindowWeekly]
                      toMenu:menu];

    [menu addItem:[NSMenuItem separatorItem]];
    [self addChoiceWithTitle:@"Show Reset Time"
                      action:@selector(useClockTime)
                     checked:[[self timeMode] isEqualToString:TimeModeClock]
                      toMenu:menu];
    [self addChoiceWithTitle:@"Show Countdown"
                      action:@selector(useCountdownTime)
                     checked:[[self timeMode] isEqualToString:TimeModeCountdown]
                      toMenu:menu];
    [self addChoiceWithTitle:@"Hide Time"
                      action:@selector(useHiddenTime)
                     checked:[[self timeMode] isEqualToString:TimeModeHidden]
                      toMenu:menu];

    [menu addItem:[NSMenuItem separatorItem]];
    [self addRefreshIntervalSubmenuToMenu:menu];

    [menu addItem:[NSMenuItem separatorItem]];
    [self addChoiceWithTitle:@"Launch at Login"
                      action:@selector(toggleLaunchAtLogin)
                     checked:[self launchAtLoginEnabled]
                      toMenu:menu];

    [self addActionsToMenu:menu];
    return menu;
}

- (void)addActionsToMenu:(NSMenu *)menu {
    [menu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *refresh = [[NSMenuItem alloc] initWithTitle:@"Refresh Now"
                                                     action:@selector(refresh)
                                              keyEquivalent:@"r"];
    refresh.target = self;
    [menu addItem:refresh];

    // No action while busy: the menu auto-enables items, so that greys it out.
    NSMenuItem *updates = [[NSMenuItem alloc] initWithTitle:self.updateActivity ?: @"Check for Updates…"
                                                     action:self.updateActivity ? nil : @selector(checkForUpdates)
                                              keyEquivalent:@""];
    updates.target = self;
    [menu addItem:updates];

    NSMenuItem *quit = [[NSMenuItem alloc] initWithTitle:@"Quit"
                                                  action:@selector(quit)
                                           keyEquivalent:@"q"];
    quit.target = self;
    [menu addItem:quit];
}

- (void)addChoiceWithTitle:(NSString *)title action:(SEL)action checked:(BOOL)checked toMenu:(NSMenu *)menu {
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title action:action keyEquivalent:@""];
    item.target = self;
    item.state = checked ? NSControlStateValueOn : NSControlStateValueOff;
    [menu addItem:item];
}

- (void)addRefreshIntervalSubmenuToMenu:(NSMenu *)menu {
    NSTimeInterval current = [self refreshIntervalSeconds];
    NSMenuItem *root = [[NSMenuItem alloc] initWithTitle:[NSString stringWithFormat:@"Refresh Every: %@",
                                                          [self refreshIntervalLabelForSeconds:current]]
                                                  action:nil
                                           keyEquivalent:@""];
    NSMenu *submenu = [[NSMenu alloc] initWithTitle:@"Refresh Every"];
    NSArray<NSNumber *> *intervals = @[@30.0, @60.0, @180.0, @300.0];

    for (NSNumber *interval in intervals) {
        NSTimeInterval seconds = interval.doubleValue;
        NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:[self refreshIntervalLabelForSeconds:seconds]
                                                      action:@selector(useRefreshInterval:)
                                               keyEquivalent:@""];
        item.target = self;
        item.representedObject = interval;
        item.state = fabs(seconds - current) < 0.5 ? NSControlStateValueOn : NSControlStateValueOff;
        [submenu addItem:item];
    }

    root.submenu = submenu;
    [menu addItem:root];
}

- (void)addDisabledItem:(NSString *)title toMenu:(NSMenu *)menu {
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title ?: @"" action:nil keyEquivalent:@""];
    item.enabled = NO;
    [menu addItem:item];
}

#pragma mark - Status item rendering

- (void)updateStatusItem {
    NSDictionary *state = self.latestState;
    NSNumber *ok = state[@"ok"];
    self.statusItem.button.imagePosition = NSImageLeft;
    if (![ok respondsToSelector:@selector(boolValue)] || ![ok boolValue]) {
        // Even with the time hidden, errors keep their "--" so they stay visible.
        self.statusItem.button.image = self.claudeIcon;
        self.statusItem.button.title = @"--";
        return;
    }

    double metric = [self displayPercentForWidgetState:state];
    BOOL hideTime = [[self timeMode] isEqualToString:TimeModeHidden];
    NSString *timeText = hideTime ? @"" : [self timeTextForWidgetState:state];
    BOOL stale = [self displayIsStale];

    if ([[self displayMode] isEqualToString:DisplayModeBattery]) {
        // Never draw a stale snapshot as a battery level: an hours-old "0% used"
        // renders as a full charge, which reads as good news rather than as no
        // news. Fall back to the plain icon plus a stale marker.
        if (stale) {
            self.statusItem.button.image = self.claudeIcon;
            self.statusItem.button.title = [self staleMarkedTitle:timeText];
            return;
        }
        // The marker is measured in quota left, so it only means something in % Left.
        double onPace = [[self metricMode] isEqualToString:MetricModeLeft]
            ? [self onPacePercentForWidgetState:state]
            : NAN;
        self.statusItem.button.image = [self batteryIconForPercent:metric onPacePercent:onPace];
        // With the time hidden the battery already carries the percentage, so show the image alone.
        self.statusItem.button.imagePosition = hideTime ? NSImageOnly : NSImageLeft;
        self.statusItem.button.title = timeText;
        return;
    }

    self.statusItem.button.image = self.claudeIcon;
    NSString *title = nil;
    if (isnan(metric)) {
        title = timeText.length > 0 ? timeText : @"--";
    } else {
        NSString *metricLabel = [self metricLabel];
        NSString *percentText = metricLabel.length > 0
            ? [NSString stringWithFormat:@"%.0f%% %@", metric, metricLabel]
            : [NSString stringWithFormat:@"%.0f%%", metric];
        title = hideTime ? percentText : [NSString stringWithFormat:@"%@ | %@", timeText, percentText];
    }
    self.statusItem.button.title = stale ? [self staleMarkedTitle:title] : title;
}

// Quota that would be left if usage were spread evenly across the window:
// (time until reset / window length) × 100. If the battery fill ends right of
// the marker, you are under pace. NAN when there is no active window.
- (double)onPacePercentForWidgetState:(NSDictionary *)state {
    // Match the window the battery is actually showing: weekly mode falls back
    // to session numbers when the response has no weekly usage.
    BOOL weekly = [[self widgetWindowMode] isEqualToString:WidgetWindowWeekly] &&
                  [state[@"secondary_used_percent"] respondsToSelector:@selector(doubleValue)];
    id reset = weekly ? state[@"secondary_resets_at"] : state[@"primary_resets_at"];
    if (![reset respondsToSelector:@selector(doubleValue)]) {
        return NAN;
    }
    double remaining = [reset doubleValue] - [NSDate date].timeIntervalSince1970;
    if (remaining <= 0.0) {
        return NAN;
    }
    NSTimeInterval duration = weekly ? WeeklyWindowSeconds : SessionWindowSeconds;
    return MAX(0.0, MIN(100.0, (remaining / duration) * 100.0));
}

// Stale for a few minutes is just a missed poll; stale for longer means the
// numbers on screen are no longer describing the current session.
- (BOOL)displayIsStale {
    NSDictionary *state = self.latestState;
    if (![state[@"stale"] respondsToSelector:@selector(boolValue)] || ![state[@"stale"] boolValue]) {
        return NO;
    }
    if (self.lastGoodFetchedAt == nil) {
        return YES;
    }
    return -[self.lastGoodFetchedAt timeIntervalSinceNow] > StaleDisplayThresholdSeconds;
}

- (NSString *)staleMarkedTitle:(NSString *)title {
    return title.length > 0 ? [NSString stringWithFormat:@"⚠ %@", title] : @"⚠";
}

- (NSString *)detailUsageTextForState:(NSDictionary *)state {
    double used = [self usagePercentForState:state];
    if (isnan(used)) {
        return @"Claude Code usage: unavailable";
    }
    double left = MAX(0.0, MIN(100.0, 100.0 - used));
    return [NSString stringWithFormat:@"Session (5h): %.0f%% left, %.0f%% used", left, used];
}

- (NSString *)resetClockDetailForState:(NSDictionary *)state {
    NSString *clock = [self resetClockTextForWidgetState:state];
    if (clock.length == 0) {
        return [NSString stringWithFormat:@"Reset time: %@", [self missingResetReasonForState:state]];
    }
    return [NSString stringWithFormat:@"Reset time: %@", clock];
}

- (NSString *)countdownDetailForState:(NSDictionary *)state {
    NSString *countdown = [self countdownTextForWidgetState:state];
    if (countdown.length == 0) {
        return [NSString stringWithFormat:@"Countdown: %@", [self missingResetReasonForState:state]];
    }
    return [NSString stringWithFormat:@"Countdown: %@", countdown];
}

// The selected window can have valid usage but no reset timestamp: the 5h
// session window only has a reset_at once it's active. Distinguish that idle
// case ("no active session") from a genuine unavailable response ("unknown").
- (NSString *)missingResetReasonForState:(NSDictionary *)state {
    if ([state[@"stale"] respondsToSelector:@selector(boolValue)] && [state[@"stale"] boolValue]) {
        return @"stale";
    }
    NSNumber *reset = [self widgetResetSecondsForState:state];
    if (reset != nil && reset.doubleValue <= [NSDate date].timeIntervalSince1970) {
        return @"expired";
    }
    NSNumber *ok = state[@"ok"];
    BOOL haveUsage = !isnan([self widgetUsagePercentForState:state]);
    if ([ok respondsToSelector:@selector(boolValue)] && [ok boolValue] && haveUsage) {
        return [[self widgetWindowMode] isEqualToString:WidgetWindowWeekly] ? @"no active window" : @"no active session";
    }
    return @"unknown";
}

- (double)usagePercentForState:(NSDictionary *)state {
    id value = state[@"primary_used_percent"];
    if ([value respondsToSelector:@selector(doubleValue)]) {
        return MAX(0.0, MIN(100.0, [value doubleValue]));
    }
    return NAN;
}

- (double)displayPercentForWidgetState:(NSDictionary *)state {
    double used = [self widgetUsagePercentForState:state];
    if (isnan(used)) {
        return NAN;
    }
    if ([[self metricMode] isEqualToString:MetricModeUsed]) {
        return used;
    }
    return MAX(0.0, MIN(100.0, 100.0 - used));
}

- (double)widgetUsagePercentForState:(NSDictionary *)state {
    id value = [[self widgetWindowMode] isEqualToString:WidgetWindowWeekly] ? state[@"secondary_used_percent"] : state[@"primary_used_percent"];
    if (![value respondsToSelector:@selector(doubleValue)] && [[self widgetWindowMode] isEqualToString:WidgetWindowWeekly]) {
        value = state[@"primary_used_percent"];
    }
    if ([value respondsToSelector:@selector(doubleValue)]) {
        return MAX(0.0, MIN(100.0, [value doubleValue]));
    }
    return NAN;
}

- (NSString *)metricLabel {
    if ([[self metricMode] isEqualToString:MetricModeUsed]) {
        return @"used";
    }
    return @"";
}

- (NSNumber *)widgetResetSecondsForState:(NSDictionary *)state {
    id value = [[self widgetWindowMode] isEqualToString:WidgetWindowWeekly] ? state[@"secondary_resets_at"] : state[@"primary_resets_at"];
    if (![value respondsToSelector:@selector(doubleValue)] && [[self widgetWindowMode] isEqualToString:WidgetWindowWeekly]) {
        value = state[@"primary_resets_at"];
    }
    if ([value respondsToSelector:@selector(doubleValue)]) {
        return @([value doubleValue]);
    }
    return nil;
}

- (NSString *)timeTextForWidgetState:(NSDictionary *)state {
    if ([[self timeMode] isEqualToString:TimeModeCountdown]) {
        return [self countdownTextForWidgetState:state] ?: @"--:--";
    }
    return [self resetClockTextForWidgetState:state] ?: @"--";
}

- (NSString *)resetClockTextForWidgetState:(NSDictionary *)state {
    NSNumber *seconds = [self widgetResetSecondsForState:state];
    if (seconds == nil || seconds.doubleValue <= [NSDate date].timeIntervalSince1970) {
        return nil;
    }

    NSDate *date = [NSDate dateWithTimeIntervalSince1970:seconds.doubleValue];
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    formatter.dateStyle = NSDateFormatterNoStyle;
    formatter.timeStyle = NSDateFormatterShortStyle;
    return [formatter stringFromDate:date];
}

- (NSString *)countdownTextForWidgetState:(NSDictionary *)state {
    NSNumber *seconds = [self widgetResetSecondsForState:state];
    if (seconds == nil) {
        return nil;
    }

    NSInteger remaining = (NSInteger)llround(seconds.doubleValue - [NSDate date].timeIntervalSince1970);
    if (remaining <= 0) {
        return nil;
    }
    NSInteger hours = remaining / 3600;
    NSInteger minutes = (remaining % 3600) / 60;
    NSInteger secs = remaining % 60;
    return [NSString stringWithFormat:@"%ld:%02ld:%02ld", (long)hours, (long)minutes, (long)secs];
}

#pragma mark - Defaults accessors

- (NSString *)displayMode {
    NSString *mode = [NSUserDefaults.standardUserDefaults stringForKey:DisplayModeKey];
    return mode.length > 0 ? mode : DisplayModePercent;
}

- (NSString *)timeMode {
    NSString *mode = [NSUserDefaults.standardUserDefaults stringForKey:TimeModeKey];
    return mode.length > 0 ? mode : TimeModeClock;
}

- (NSString *)metricMode {
    NSString *mode = [NSUserDefaults.standardUserDefaults stringForKey:MetricModeKey];
    return mode.length > 0 ? mode : MetricModeLeft;
}

- (NSString *)widgetWindowMode {
    NSString *mode = [NSUserDefaults.standardUserDefaults stringForKey:WidgetWindowModeKey];
    if ([mode isEqualToString:WidgetWindowWeekly]) {
        return WidgetWindowWeekly;
    }
    return WidgetWindowSession;
}

- (NSTimeInterval)refreshIntervalSeconds {
    NSTimeInterval seconds = [NSUserDefaults.standardUserDefaults doubleForKey:RefreshIntervalKey];
    NSArray<NSNumber *> *allowed = @[@30.0, @60.0, @180.0, @300.0];
    for (NSNumber *interval in allowed) {
        if (fabs(seconds - interval.doubleValue) < 0.5) {
            return interval.doubleValue;
        }
    }
    return DefaultRefreshIntervalSeconds;
}

- (NSString *)refreshIntervalLabelForSeconds:(NSTimeInterval)seconds {
    if (fabs(seconds - 30.0) < 0.5) {
        return @"30 sec";
    }
    NSInteger minutes = (NSInteger)llround(seconds / 60.0);
    return [NSString stringWithFormat:@"%ld min", (long)minutes];
}

#pragma mark - Menu actions

- (void)usePercentDisplay {
    [NSUserDefaults.standardUserDefaults setObject:DisplayModePercent forKey:DisplayModeKey];
    [self updateStatusItem];
    self.statusItem.menu = [self menuForCurrentState];
}

- (void)useBatteryDisplay {
    [NSUserDefaults.standardUserDefaults setObject:DisplayModeBattery forKey:DisplayModeKey];
    [self updateStatusItem];
    self.statusItem.menu = [self menuForCurrentState];
}

- (void)useClockTime {
    [NSUserDefaults.standardUserDefaults setObject:TimeModeClock forKey:TimeModeKey];
    [self updateStatusItem];
    self.statusItem.menu = [self menuForCurrentState];
}

- (void)useCountdownTime {
    [NSUserDefaults.standardUserDefaults setObject:TimeModeCountdown forKey:TimeModeKey];
    [self updateStatusItem];
    self.statusItem.menu = [self menuForCurrentState];
}

- (void)useHiddenTime {
    [NSUserDefaults.standardUserDefaults setObject:TimeModeHidden forKey:TimeModeKey];
    [self updateStatusItem];
    self.statusItem.menu = [self menuForCurrentState];
}

- (void)useLeftMetric {
    [NSUserDefaults.standardUserDefaults setObject:MetricModeLeft forKey:MetricModeKey];
    [self updateStatusItem];
    self.statusItem.menu = [self menuForCurrentState];
}

- (void)useUsedMetric {
    [NSUserDefaults.standardUserDefaults setObject:MetricModeUsed forKey:MetricModeKey];
    [self updateStatusItem];
    self.statusItem.menu = [self menuForCurrentState];
}

- (void)useSessionWidgetWindow {
    [NSUserDefaults.standardUserDefaults setObject:WidgetWindowSession forKey:WidgetWindowModeKey];
    [self updateStatusItem];
    self.statusItem.menu = [self menuForCurrentState];
}

- (void)useWeeklyWidgetWindow {
    [NSUserDefaults.standardUserDefaults setObject:WidgetWindowWeekly forKey:WidgetWindowModeKey];
    [self updateStatusItem];
    self.statusItem.menu = [self menuForCurrentState];
}

- (void)useRefreshInterval:(NSMenuItem *)sender {
    NSNumber *interval = sender.representedObject;
    if (![interval respondsToSelector:@selector(doubleValue)]) {
        return;
    }

    [NSUserDefaults.standardUserDefaults setDouble:interval.doubleValue forKey:RefreshIntervalKey];
    [self schedulePollTimer];
    self.statusItem.menu = [self menuForCurrentState];
}

- (void)schedulePollTimer {
    [self.pollTimer invalidate];
    self.pollTimer = [NSTimer scheduledTimerWithTimeInterval:[self refreshIntervalSeconds]
                                                      target:self
                                                    selector:@selector(refresh)
                                                    userInfo:nil
                                                     repeats:YES];
}

- (void)refresh {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSDictionary *state = [self loadUsageState];
        dispatch_async(dispatch_get_main_queue(), ^{
            self.latestState = state;
            [self updateStatusItem];
            self.statusItem.menu = [self menuForCurrentState];
        });
    });
}

#pragma mark - Data source: Claude Code OAuth usage API

- (NSDictionary *)loadUsageState {
    // If the API has effectively throttled us, don't poke it again — keep showing
    // the last good numbers until the cool-down passes. The display still ticks.
    if (self.usageBackoffUntil != nil && [self.usageBackoffUntil timeIntervalSinceNow] > 0 &&
        self.lastGoodState != nil) {
        NSString *message = [self.latestState[@"error"] isKindOfClass:[NSString class]]
            ? self.latestState[@"error"]
            : @"Waiting to retry after a failed refresh";
        return [self staleStateFromGood:self.lastGoodState failure:message];
    }

    NSString *credsError = nil;
    NSDictionary *creds = [self credentialsReloading:NO error:&credsError];
    if (creds == nil) {
        return [self stateForFailure:credsError ?: @"Claude Code credentials not found"];
    }

    NSString *tokenError = nil;
    NSString *accessToken = [self validAccessTokenFromCredentials:creds error:&tokenError];
    if (accessToken.length == 0) {
        return [self stateForFailure:tokenError ?: @"No valid access token"];
    }

    NSInteger status = 0;
    NSString *httpError = nil;
    NSTimeInterval retryAfter = 0;
    NSData *data = [self getURL:UsageURL bearer:accessToken statusCode:&status retryAfter:&retryAfter error:&httpError];

    // A 401 means the token we used is stale. Prefer a token the CLI may have
    // rotated in behind us — that costs nothing — and only spend our own refresh
    // if the keychain has nothing newer than what we just tried.
    if (status == 401) {
        NSDictionary *freshCreds = [self credentialsReloading:YES error:NULL];
        if (freshCreds != nil) {
            creds = freshCreds;
        }

        NSString *keychainToken = [self stringFromDictionary:creds keys:@[@"accessToken"]];
        NSString *retryToken = (keychainToken.length > 0 && ![keychainToken isEqualToString:accessToken])
            ? keychainToken
            : [self refreshAccessTokenWithCredentials:creds error:NULL];

        if (retryToken.length > 0) {
            data = [self getURL:UsageURL bearer:retryToken statusCode:&status retryAfter:&retryAfter error:&httpError];
            accessToken = retryToken;
        }
    }

    // Rate limited (or any transient failure): enter a cool-down and serve cache.
    if (status == 429) {
        [self enterUsageBackoffWithRetryAfter:retryAfter];
        return [self stateForFailure:@"Rate limited by Claude usage API"];
    }
    if (data == nil || status != 200) {
        [self enterUsageBackoffWithRetryAfter:0];
        NSString *detail = httpError.length > 0 ? httpError : [NSString stringWithFormat:@"HTTP %ld", (long)status];
        return [self stateForFailure:[NSString stringWithFormat:@"Usage request failed: %@", detail]];
    }

    id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![json isKindOfClass:[NSDictionary class]]) {
        return [self stateForFailure:@"Usage response was not valid JSON"];
    }

    NSString *plan = [self stringFromDictionary:creds keys:@[@"subscriptionType"]];
    NSDictionary *fresh = [self buildStateFromUsageResponse:json plan:plan timestamp:[NSDate date]];

    NSNumber *ok = fresh[@"ok"];
    if ([ok respondsToSelector:@selector(boolValue)] && [ok boolValue]) {
        [self clearUsageBackoff];
        [self storeLastGoodState:fresh];
        return fresh;
    }
    // Built but unusable (e.g. no rate-limit windows): keep prior good numbers.
    return [self stateForFailure:fresh[@"error"] ?: @"Usage response was incomplete"];
}

// Once we've seen real numbers, never flash "unavailable" again: serve the last
// good snapshot (marked stale) on any failure. Only a cold start shows an error.
- (NSDictionary *)stateForFailure:(NSString *)message {
    // Failures are otherwise invisible — they hide behind the stale snapshot.
    // Record the last one so it can be inspected without attaching a debugger.
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    [defaults setObject:(message.length > 0 ? message : @"Refresh failed") forKey:LastErrorKey];
    [defaults setDouble:[NSDate date].timeIntervalSince1970 forKey:LastErrorAtKey];

    if (self.lastGoodState != nil) {
        return [self staleStateFromGood:self.lastGoodState failure:message];
    }
    return [self errorStateWithMessage:message];
}

- (NSDictionary *)staleStateFromGood:(NSDictionary *)good failure:(NSString *)message {
    NSMutableDictionary *state = [good mutableCopy];
    state[@"stale"] = @YES;
    state[@"error"] = message.length > 0 ? message : @"Refresh failed";
    state[@"updated_summary"] = [self stalenessSummary];
    return state;
}

- (NSString *)stalenessSummary {
    if (self.lastGoodFetchedAt == nil) {
        return @"Updated: unknown";
    }
    NSTimeInterval ago = -[self.lastGoodFetchedAt timeIntervalSinceNow];
    if (ago < 60.0) {
        return @"Updated: just now";
    }
    NSInteger minutes = (NSInteger)(ago / 60.0);
    if (minutes < 60) {
        return [NSString stringWithFormat:@"Updated: %ldm ago", (long)minutes];
    }
    return [NSString stringWithFormat:@"Updated: %ldh ago", (long)(minutes / 60)];
}

- (void)storeLastGoodState:(NSDictionary *)state {
    self.lastGoodState = state;
    self.lastGoodFetchedAt = [NSDate date];
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    [defaults setObject:state forKey:LastGoodStateKey];
    [defaults setDouble:self.lastGoodFetchedAt.timeIntervalSince1970 forKey:LastGoodFetchedAtKey];
}

- (void)restoreLastGoodState {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSDictionary *saved = [defaults dictionaryForKey:LastGoodStateKey];
    double fetchedAt = [defaults doubleForKey:LastGoodFetchedAtKey];
    if (![saved isKindOfClass:[NSDictionary class]] || fetchedAt <= 0) {
        return;
    }
    self.lastGoodState = saved;
    self.lastGoodFetchedAt = [NSDate dateWithTimeIntervalSince1970:fetchedAt];
    self.latestState = [self staleStateFromGood:saved failure:@"Waiting for a fresh update"];
}

// Exponential cool-down (honoring Retry-After when the server sends a real one),
// capped so we always recover. retryAfter <= 0 means "no useful hint" -> backoff.
- (void)enterUsageBackoffWithRetryAfter:(NSTimeInterval)retryAfter {
    NSTimeInterval wait;
    if (retryAfter > 0) {
        wait = MIN(retryAfter, UsageBackoffMaxSeconds);
    } else {
        NSTimeInterval next = self.usageBackoffSeconds > 0
            ? self.usageBackoffSeconds * 2.0
            : MAX([self refreshIntervalSeconds], 30.0);
        wait = MIN(next, UsageBackoffMaxSeconds);
    }
    self.usageBackoffSeconds = wait;
    self.usageBackoffUntil = [NSDate dateWithTimeIntervalSinceNow:wait];
}

- (void)clearUsageBackoff {
    self.usageBackoffSeconds = 0;
    self.usageBackoffUntil = nil;
}

- (NSDictionary *)errorStateWithMessage:(NSString *)message {
    return @{
        @"ok": @NO,
        @"updated_summary": @"Updated: unavailable",
        @"source_summary": @"Source: Claude Code usage API",
        @"error": message ?: @"unknown error"
    };
}

- (NSDictionary *)buildStateFromUsageResponse:(NSDictionary *)response plan:(NSString *)plan timestamp:(NSDate *)timestamp {
    NSDictionary *fiveHour = [response[@"five_hour"] isKindOfClass:[NSDictionary class]] ? response[@"five_hour"] : nil;
    NSDictionary *sevenDay = [response[@"seven_day"] isKindOfClass:[NSDictionary class]] ? response[@"seven_day"] : nil;
    NSDictionary *sevenDayOpus = [response[@"seven_day_opus"] isKindOfClass:[NSDictionary class]] ? response[@"seven_day_opus"] : nil;

    NSNumber *primaryUsed = [self utilizationPercentFromWindow:fiveHour];
    NSNumber *primaryReset = [self resetEpochFromWindow:fiveHour];
    NSNumber *secondaryUsed = [self utilizationPercentFromWindow:sevenDay];
    NSNumber *secondaryReset = [self resetEpochFromWindow:sevenDay];

    if (primaryUsed == nil && secondaryUsed == nil) {
        return [self errorStateWithMessage:@"Usage response had no rate-limit windows"];
    }

    NSMutableDictionary *state = [@{
        @"ok": @YES,
        @"updated_summary": [self updatedSummaryForDate:timestamp],
        @"source_summary": @"Source: Claude Code usage API"
    } mutableCopy];

    if (primaryUsed != nil) {
        state[@"primary_used_percent"] = primaryUsed;
    }
    if (primaryReset != nil) {
        state[@"primary_resets_at"] = primaryReset;
    }
    if (secondaryUsed != nil) {
        state[@"secondary_used_percent"] = secondaryUsed;
    }
    if (secondaryReset != nil) {
        state[@"secondary_resets_at"] = secondaryReset;
    }

    NSString *weekly = [self windowSummaryWithLabel:@"Weekly (7d)" used:secondaryUsed reset:secondaryReset includeDate:YES];
    if (weekly.length > 0) {
        state[@"weekly_summary"] = weekly;
    }

    NSNumber *opusUsed = [self utilizationPercentFromWindow:sevenDayOpus];
    NSNumber *opusReset = [self resetEpochFromWindow:sevenDayOpus];
    if (opusUsed != nil) {
        NSString *opus = [self windowSummaryWithLabel:@"Weekly (Opus)" used:opusUsed reset:opusReset includeDate:YES];
        if (opus.length > 0) {
            state[@"weekly_opus_summary"] = opus;
        }
    }

    if (plan.length > 0) {
        state[@"plan_summary"] = [NSString stringWithFormat:@"Plan: %@", [plan capitalizedString]];
    }

    return state;
}

// The /api/oauth/usage endpoint returns "utilization" already as a 0-100
// percentage (e.g. 34.0 means 34% of the window used).
- (NSNumber *)utilizationPercentFromWindow:(NSDictionary *)window {
    if (![window isKindOfClass:[NSDictionary class]]) {
        return nil;
    }
    id value = window[@"utilization"];
    if (![value respondsToSelector:@selector(doubleValue)]) {
        return nil;
    }
    return @(MAX(0.0, MIN(100.0, [value doubleValue])));
}

- (NSNumber *)resetEpochFromWindow:(NSDictionary *)window {
    if (![window isKindOfClass:[NSDictionary class]]) {
        return nil;
    }
    id value = window[@"resets_at"];
    if ([value isKindOfClass:[NSString class]]) {
        NSDate *date = [self dateFromISOString:value];
        return date != nil ? @(date.timeIntervalSince1970) : nil;
    }
    if ([value respondsToSelector:@selector(doubleValue)]) {
        double number = [value doubleValue];
        // Heuristic: treat large values as milliseconds.
        if (number > 1e12) {
            number /= 1000.0;
        }
        return @(number);
    }
    return nil;
}

- (NSString *)windowSummaryWithLabel:(NSString *)label used:(NSNumber *)used reset:(NSNumber *)reset includeDate:(BOOL)includeDate {
    if (used == nil) {
        return nil;
    }
    double usedValue = MAX(0.0, MIN(100.0, used.doubleValue));
    NSString *usedText;
    if ([[self metricMode] isEqualToString:MetricModeUsed]) {
        usedText = [NSString stringWithFormat:@"%.0f%% used", usedValue];
    } else {
        double leftValue = MAX(0.0, MIN(100.0, 100.0 - usedValue));
        usedText = [NSString stringWithFormat:@"%.0f%% left, %.0f%% used", leftValue, usedValue];
    }
    NSString *resetText = [self resetLabelForSeconds:reset includeDate:includeDate];
    return [NSString stringWithFormat:@"%@: %@, resets %@", label, usedText, resetText];
}

#pragma mark - Keychain + OAuth

- (BOOL)cachedCredentialsAreUsable {
    if (self.cachedCredentials == nil) {
        return NO;
    }
    NSString *accessToken = [self stringFromDictionary:self.cachedCredentials keys:@[@"accessToken"]];
    if (accessToken.length == 0) {
        return NO;
    }
    NSNumber *expiresAt = [self numberFromDictionary:self.cachedCredentials keys:@[@"expiresAt"]];
    return expiresAt == nil ||
        [NSDate date].timeIntervalSince1970 < (expiresAt.doubleValue / 1000.0) - CredentialCacheSkewSeconds;
}

// Access tokens are good for about an hour, so one keychain read serves a few
// hundred polls. Pass forceReload when the cache is known-bad (a 401).
- (NSDictionary *)credentialsReloading:(BOOL)forceReload error:(NSString **)error {
    if (!forceReload && [self cachedCredentialsAreUsable]) {
        return self.cachedCredentials;
    }

    // Rate-limit the keychain itself. Once the cached token expires we want the
    // CLI's replacement, but if the CLI is idle there isn't one yet — and asking
    // again every poll is what turns one lost grant into a prompt storm.
    if (self.cachedCredentials != nil && self.lastKeychainReadAt != nil &&
        -[self.lastKeychainReadAt timeIntervalSinceNow] < KeychainReadMinIntervalSeconds) {
        return self.cachedCredentials;
    }

    self.lastKeychainReadAt = [NSDate date];
    NSDictionary *creds = [self readKeychainCredentials:error];
    if (creds != nil) {
        self.cachedCredentials = creds;
    }
    return creds;
}

// Runs /usr/bin/security and returns its exit status, or -1 if it could not be
// launched or had to be killed after SecurityToolTimeoutSeconds. stderr is
// discarded; stdout is returned through `output`.
- (int)runSecurityWithArguments:(NSArray<NSString *> *)arguments
                          input:(NSData *)input
                         output:(NSData **)output {
    NSTask *task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:SecurityToolPath];
    task.arguments = arguments;
    NSPipe *outPipe = [NSPipe pipe];
    NSPipe *inPipe = input != nil ? [NSPipe pipe] : nil;
    task.standardOutput = outPipe;
    task.standardError = [NSFileHandle fileHandleWithNullDevice];
    task.standardInput = inPipe ?: (id)[NSFileHandle fileHandleWithNullDevice];

    dispatch_semaphore_t exited = dispatch_semaphore_create(0);
    task.terminationHandler = ^(NSTask *finished) {
        (void)finished;
        dispatch_semaphore_signal(exited);
    };
    if (![task launchAndReturnError:NULL]) {
        return -1;
    }

    // Drain stdout concurrently so a large reply can't fill the pipe and stall.
    __block NSData *outData = nil;
    dispatch_semaphore_t drained = dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        outData = [outPipe.fileHandleForReading readDataToEndOfFile];
        dispatch_semaphore_signal(drained);
    });
    if (inPipe != nil) {
        [inPipe.fileHandleForWriting writeData:input error:NULL];
        [inPipe.fileHandleForWriting closeAndReturnError:NULL];
    }

    dispatch_time_t deadline = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(SecurityToolTimeoutSeconds * NSEC_PER_SEC));
    BOOL timedOut = dispatch_semaphore_wait(exited, deadline) != 0;
    if (timedOut) {
        [task terminate];
        dispatch_semaphore_wait(exited, DISPATCH_TIME_FOREVER);
    }
    dispatch_semaphore_wait(drained, DISPATCH_TIME_FOREVER);
    if (timedOut) {
        return -1;
    }
    if (output) {
        *output = outData;
    }
    return task.terminationStatus;
}

// The whole stored JSON document (Claude Code nests the OAuth tokens under
// "claudeAiOauth" and may keep other keys alongside them).
- (NSDictionary *)readKeychainRoot:(NSString **)error {
    NSData *data = nil;
    int status = [self runSecurityWithArguments:@[@"find-generic-password", @"-s", KeychainService, @"-w"]
                                          input:nil
                                         output:&data];
    if (status != 0 || data.length == 0) {
        if (error) {
            if (status == SecurityExitItemNotFound) {
                *error = @"Not signed in to Claude Code (no keychain item)";
            } else if (status == -1) {
                *error = @"Keychain read timed out";
            } else {
                *error = [NSString stringWithFormat:@"Keychain read failed (security exit %d)", status];
            }
        }
        return nil;
    }

    id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![json isKindOfClass:[NSDictionary class]]) {
        if (error) {
            *error = @"Keychain credentials were not valid JSON";
        }
        return nil;
    }
    return json;
}

// The item's account attribute. An update must name the existing account, or
// `add-generic-password -U` creates a second item instead of replacing this one.
- (NSString *)keychainAccount {
    NSData *data = nil;
    // Attributes only (no -w): this never touches the secret.
    if ([self runSecurityWithArguments:@[@"find-generic-password", @"-s", KeychainService]
                                 input:nil
                                output:&data] != 0) {
        return nil;
    }
    NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"\"acct\"<blob>=\"(.*)\"$"
                                                                           options:NSRegularExpressionAnchorsMatchLines
                                                                             error:NULL];
    NSTextCheckingResult *match = text != nil ? [regex firstMatchInString:text options:0 range:NSMakeRange(0, text.length)] : nil;
    return match != nil ? [text substringWithRange:[match rangeAtIndex:1]] : nil;
}

- (NSDictionary *)readKeychainCredentials:(NSString **)error {
    NSDictionary *root = [self readKeychainRoot:error];
    if (root == nil) {
        return nil;
    }
    NSDictionary *oauth = [root[@"claudeAiOauth"] isKindOfClass:[NSDictionary class]] ? root[@"claudeAiOauth"] : root;
    if (![oauth isKindOfClass:[NSDictionary class]]) {
        if (error) {
            *error = @"Keychain credentials were not valid JSON";
        }
        return nil;
    }
    return oauth;
}

// Nothing else refreshes this keychain item — the Claude Code CLI can go a day
// without touching it — so the widget has to do it or the token simply expires
// and the display freezes. Refresh only when actually expired (~hourly), and
// always write the rotated token back: reusing a spent refresh token is what
// earns an invalid_grant.
- (NSString *)validAccessTokenFromCredentials:(NSDictionary *)creds error:(NSString **)error {
    NSString *accessToken = [self stringFromDictionary:creds keys:@[@"accessToken"]];
    NSNumber *expiresAt = [self numberFromDictionary:creds keys:@[@"expiresAt"]];

    BOOL expired = NO;
    if (expiresAt != nil) {
        // expiresAt is epoch milliseconds; refresh a minute early.
        double expiresSeconds = expiresAt.doubleValue / 1000.0;
        expired = ([NSDate date].timeIntervalSince1970 >= (expiresSeconds - 60.0));
    }

    if (accessToken.length > 0 && !expired) {
        return accessToken;
    }

    NSString *refreshError = nil;
    NSString *refreshed = [self refreshAccessTokenWithCredentials:creds error:&refreshError];
    if (refreshed.length > 0) {
        return refreshed;
    }

    if (accessToken.length > 0 && expiresAt == nil) {
        // If the credential has no expiry metadata, let the API validate it.
        return accessToken;
    }
    if (error) {
        *error = refreshError ?: @"Could not obtain access token";
    }
    return nil;
}

- (NSString *)refreshAccessTokenWithCredentials:(NSDictionary *)creds error:(NSString **)error {
    // Back off after a recent failure (e.g. rate limiting) to avoid hammering the endpoint.
    if (self.refreshBackoffUntil != nil && [self.refreshBackoffUntil timeIntervalSinceNow] > 0) {
        if (error) {
            *error = @"Token refresh backing off after a recent failure";
        }
        return nil;
    }

    NSString *refreshToken = [self stringFromDictionary:creds keys:@[@"refreshToken"]];
    if (refreshToken.length == 0) {
        if (error) {
            *error = @"No refresh token available";
        }
        return nil;
    }

    NSMutableArray<NSString *> *scopes = [NSMutableArray array];
    if ([creds[@"scopes"] isKindOfClass:[NSArray class]]) {
        for (id scope in creds[@"scopes"]) {
            if ([scope isKindOfClass:[NSString class]]) {
                [scopes addObject:scope];
            }
        }
    }

    NSDictionary *body = @{
        @"grant_type": @"refresh_token",
        @"refresh_token": refreshToken,
        @"client_id": OAuthClientID,
        @"scope": [scopes componentsJoinedByString:@" "]
    };

    NSInteger status = 0;
    NSString *httpError = nil;
    NSData *responseData = [self postURL:OAuthTokenURL jsonBody:body statusCode:&status error:&httpError];

    if (responseData == nil || status != 200) {
        // Throttle further attempts for a while on failure.
        self.refreshBackoffUntil = [NSDate dateWithTimeIntervalSinceNow:300.0];
        if (error) {
            *error = httpError.length > 0 ? httpError : [NSString stringWithFormat:@"Token refresh HTTP %ld", (long)status];
        }
        return nil;
    }

    id json = [NSJSONSerialization JSONObjectWithData:responseData options:0 error:nil];
    NSDictionary *root = [json isKindOfClass:[NSDictionary class]] ? json : nil;
    NSString *newAccess = [self stringFromDictionary:root keys:@[@"access_token"]];
    if (newAccess.length == 0) {
        self.refreshBackoffUntil = [NSDate dateWithTimeIntervalSinceNow:300.0];
        if (error) {
            *error = @"Token refresh response had no access_token";
        }
        return nil;
    }

    self.refreshBackoffUntil = nil;

    NSString *newRefresh = [self stringFromDictionary:root keys:@[@"refresh_token"]] ?: refreshToken;
    NSNumber *expiresIn = [self numberFromDictionary:root keys:@[@"expires_in"]];
    double expiresAtMs = expiresIn != nil
        ? ([NSDate date].timeIntervalSince1970 + expiresIn.doubleValue) * 1000.0
        : ([NSDate date].timeIntervalSince1970 + 3600.0) * 1000.0;

    [self writeBackRefreshedCredentials:creds
                            accessToken:newAccess
                           refreshToken:newRefresh
                            expiresAtMs:expiresAtMs];

    return newAccess;
}

// Persist refreshed tokens to the same keychain item so the Claude Code CLI and
// this widget stay in sync (refresh tokens rotate on each use).
- (void)writeBackRefreshedCredentials:(NSDictionary *)creds
                          accessToken:(NSString *)accessToken
                         refreshToken:(NSString *)refreshToken
                          expiresAtMs:(double)expiresAtMs {
    NSMutableDictionary *oauth = [creds mutableCopy];
    oauth[@"accessToken"] = accessToken;
    oauth[@"refreshToken"] = refreshToken;
    oauth[@"expiresAt"] = @((long long)llround(expiresAtMs));

    // Update the in-memory copy FIRST, and unconditionally. Refresh tokens are
    // single-use: if the cache kept the spent one, the next poll would refresh
    // again with it and the server would answer invalid_grant, permanently
    // wedging the widget until the user re-ran `claude /login`.
    self.cachedCredentials = [oauth copy];

    // Merge into what is stored now rather than rebuilding the item from our
    // copy, so any other keys Claude Code keeps there survive.
    NSMutableDictionary *root = [[self readKeychainRoot:NULL] mutableCopy];
    if (root == nil) {
        [self recordKeychainWriteFailure:@"could not read the item to update it"];
        return;
    }
    root[@"claudeAiOauth"] = oauth;
    NSData *data = [NSJSONSerialization dataWithJSONObject:root options:0 error:nil];
    NSString *account = [self keychainAccount];
    if (data == nil || account.length == 0) {
        [self recordKeychainWriteFailure:@"could not determine the keychain account"];
        return;
    }

    // Same write Claude Code performs: hex-encoded (-X) over `security -i` stdin,
    // so the tokens never appear in the process list.
    NSMutableString *hex = [NSMutableString stringWithCapacity:data.length * 2];
    const unsigned char *bytes = data.bytes;
    for (NSUInteger i = 0; i < data.length; i++) {
        [hex appendFormat:@"%02x", bytes[i]];
    }
    BOOL accountIsQuotable = [account rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"\"\\\n"]].location == NSNotFound;
    NSString *line = [NSString stringWithFormat:@"add-generic-password -U -a \"%@\" -s \"%@\" -X %@\n", account, KeychainService, hex];
    int status;
    if (accountIsQuotable && line.length <= SecurityInteractiveLineLimit) {
        status = [self runSecurityWithArguments:@[@"-i"]
                                          input:[line dataUsingEncoding:NSUTF8StringEncoding]
                                         output:NULL];
    } else {
        // Too long for `security -i` (it would store a truncated value). Like
        // Claude Code, fall back to argv, which briefly exposes it to `ps`.
        status = [self runSecurityWithArguments:@[@"add-generic-password", @"-U", @"-a", account,
                                                  @"-s", KeychainService, @"-X", hex]
                                          input:nil
                                         output:NULL];
    }

    // Refresh tokens are single-use, so a silently failed write strands Claude
    // Code with a spent token. Verify by reading it back.
    NSDictionary *stored = [self readKeychainCredentials:NULL];
    NSString *storedRefresh = [self stringFromDictionary:stored keys:@[@"refreshToken"]];
    if (status != 0 || ![storedRefresh isEqualToString:refreshToken]) {
        [self recordKeychainWriteFailure:[NSString stringWithFormat:@"security exit %d", status]];
    }
}

- (void)recordKeychainWriteFailure:(NSString *)reason {
    NSString *message = [NSString stringWithFormat:@"Could not save refreshed token to keychain (%@)", reason];
    NSLog(@"%@", message);
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    [defaults setObject:message forKey:LastErrorKey];
    [defaults setDouble:[NSDate date].timeIntervalSince1970 forKey:LastErrorAtKey];
}

#pragma mark - HTTP helpers (synchronous, run on a background queue)

- (NSData *)getURL:(NSString *)urlString bearer:(NSString *)bearer statusCode:(NSInteger *)statusCode retryAfter:(NSTimeInterval *)retryAfter error:(NSString **)error {
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urlString]];
    request.HTTPMethod = @"GET";
    request.timeoutInterval = 10.0;
    [request setValue:HTTPUserAgent forHTTPHeaderField:@"User-Agent"];
    [request setValue:[NSString stringWithFormat:@"Bearer %@", bearer] forHTTPHeaderField:@"Authorization"];
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [request setValue:OAuthBetaHeader forHTTPHeaderField:@"anthropic-beta"];
    return [self sendRequest:request statusCode:statusCode retryAfter:retryAfter error:error];
}

- (NSData *)postURL:(NSString *)urlString jsonBody:(NSDictionary *)body statusCode:(NSInteger *)statusCode error:(NSString **)error {
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urlString]];
    request.HTTPMethod = @"POST";
    request.timeoutInterval = 15.0;
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [request setValue:OAuthBetaHeader forHTTPHeaderField:@"anthropic-beta"];
    request.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];
    return [self sendRequest:request statusCode:statusCode retryAfter:NULL error:error];
}

- (NSData *)sendRequest:(NSURLRequest *)request statusCode:(NSInteger *)statusCode retryAfter:(NSTimeInterval *)retryAfter error:(NSString **)error {
    __block NSData *resultData = nil;
    __block NSInteger resultStatus = 0;
    __block NSTimeInterval resultRetryAfter = 0;
    __block NSString *resultError = nil;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);

    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:request
                                                                completionHandler:^(NSData *data, NSURLResponse *response, NSError *taskError) {
        if (taskError != nil) {
            resultError = taskError.localizedDescription;
        } else {
            resultData = data;
            if ([response isKindOfClass:[NSHTTPURLResponse class]]) {
                NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
                resultStatus = http.statusCode;
                id rawRetryAfter = http.allHeaderFields[@"Retry-After"];
                if ([rawRetryAfter respondsToSelector:@selector(doubleValue)]) {
                    resultRetryAfter = [rawRetryAfter doubleValue];
                }
            }
        }
        dispatch_semaphore_signal(done);
    }];
    [task resume];

    long waited = dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(20.0 * NSEC_PER_SEC)));
    if (waited != 0) {
        [task cancel];
        if (error) {
            *error = @"Request timed out";
        }
        return nil;
    }

    if (statusCode) {
        *statusCode = resultStatus;
    }
    if (retryAfter) {
        *retryAfter = resultRetryAfter;
    }
    if (error && resultError != nil) {
        *error = resultError;
    }
    return resultData;
}

#pragma mark - Formatting helpers

- (NSNumber *)numberFromDictionary:(NSDictionary *)dictionary keys:(NSArray<NSString *> *)keys {
    if (![dictionary isKindOfClass:[NSDictionary class]]) {
        return nil;
    }
    for (NSString *key in keys) {
        id value = dictionary[key];
        if ([value respondsToSelector:@selector(doubleValue)] && ![value isKindOfClass:[NSString class]]) {
            return @([value doubleValue]);
        }
        if ([value isKindOfClass:[NSString class]] && [value length] > 0) {
            return @([value doubleValue]);
        }
    }
    return nil;
}

- (NSString *)stringFromDictionary:(NSDictionary *)dictionary keys:(NSArray<NSString *> *)keys {
    if (![dictionary isKindOfClass:[NSDictionary class]]) {
        return nil;
    }
    for (NSString *key in keys) {
        id value = dictionary[key];
        if ([value isKindOfClass:[NSString class]] && [value length] > 0) {
            return value;
        }
    }
    return nil;
}

- (NSString *)resetLabelForSeconds:(NSNumber *)seconds includeDate:(BOOL)includeDate {
    if (seconds == nil) {
        return @"unknown";
    }
    NSDate *date = [NSDate dateWithTimeIntervalSince1970:seconds.doubleValue];
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    formatter.dateStyle = includeDate ? NSDateFormatterMediumStyle : NSDateFormatterNoStyle;
    formatter.timeStyle = includeDate ? NSDateFormatterNoStyle : NSDateFormatterShortStyle;
    return [formatter stringFromDate:date];
}

- (NSString *)updatedSummaryForDate:(NSDate *)date {
    if (date == nil) {
        return @"Updated: unknown";
    }
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    formatter.dateStyle = NSDateFormatterNoStyle;
    formatter.timeStyle = NSDateFormatterMediumStyle;
    return [NSString stringWithFormat:@"Updated: %@", [formatter stringFromDate:date]];
}

- (NSDate *)dateFromISOString:(id)value {
    if (![value isKindOfClass:[NSString class]]) {
        return nil;
    }
    NSISO8601DateFormatter *formatter = [[NSISO8601DateFormatter alloc] init];
    formatter.formatOptions = NSISO8601DateFormatWithInternetDateTime | NSISO8601DateFormatWithFractionalSeconds;
    NSDate *date = [formatter dateFromString:value];
    if (date != nil) {
        return date;
    }
    formatter.formatOptions = NSISO8601DateFormatWithInternetDateTime;
    return [formatter dateFromString:value];
}

#pragma mark - Launch at login

- (BOOL)launchAtLoginEnabled {
    if (@available(macOS 13.0, *)) {
        return SMAppService.mainAppService.status == SMAppServiceStatusEnabled;
    }
    return NO;
}

- (void)toggleLaunchAtLogin {
    self.launchAtLoginError = nil;

    if (@available(macOS 13.0, *)) {
        NSError *error = nil;
        BOOL ok = NO;
        if (SMAppService.mainAppService.status == SMAppServiceStatusEnabled) {
            ok = [SMAppService.mainAppService unregisterAndReturnError:&error];
        } else {
            ok = [SMAppService.mainAppService registerAndReturnError:&error];
        }
        if (!ok) {
            self.launchAtLoginError = error.localizedDescription ?: @"could not update";
        }
    } else {
        self.launchAtLoginError = @"requires macOS 13 or newer";
    }

    self.statusItem.menu = [self menuForCurrentState];
}

- (void)quit {
    [NSApp terminate:nil];
}

#pragma mark - Updates

// Where this build came from; scripts/build.sh writes both into Info.plist.
- (NSString *)bundledGitCommit {
    NSString *sha = NSBundle.mainBundle.infoDictionary[@"ClaudeUsageGitCommit"];
    return [sha isKindOfClass:[NSString class]] ? sha : @"";
}

- (NSString *)bundledSourceRepo {
    NSString *path = NSBundle.mainBundle.infoDictionary[@"ClaudeUsageSourceRepo"];
    return [path isKindOfClass:[NSString class]] ? path : @"";
}

// Compares the commit this build came from with GitHub main. Returns ok,
// updateAvailable, aheadBy, remoteSHA and changes (merged PR titles, or commit
// subjects when nothing came in through a PR) — or ok = NO with an error.
- (NSDictionary *)checkForUpdateSinceCommit:(NSString *)sha {
    if (sha.length < 7) {
        return @{@"ok": @NO, @"error": @"This build has no commit info. Rebuild it with ./scripts/build.sh."};
    }
    NSString *url = [NSString stringWithFormat:@"https://api.github.com/repos/%@/compare/%@...main", GitHubRepo, sha];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:url]];
    request.timeoutInterval = 15.0;
    [request setValue:@"application/vnd.github+json" forHTTPHeaderField:@"Accept"];
    [request setValue:@"ClaudeCodeUsageMenuBar" forHTTPHeaderField:@"User-Agent"];

    NSInteger status = 0;
    NSString *httpError = nil;
    NSData *data = [self sendRequest:request statusCode:&status retryAfter:NULL error:&httpError];
    if (status == 404) {
        return @{@"ok": @NO, @"error": [NSString stringWithFormat:
            @"This build's commit (%@) isn't on GitHub. Push it, or rebuild from main.", [sha substringToIndex:7]]};
    }
    id json = data != nil ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    if (status != 200 || ![json isKindOfClass:[NSDictionary class]]) {
        return @{@"ok": @NO, @"error": httpError ?: [NSString stringWithFormat:@"GitHub HTTP %ld", (long)status]};
    }

    NSArray *commits = [json[@"commits"] isKindOfClass:[NSArray class]] ? json[@"commits"] : @[];
    NSMutableArray<NSString *> *pullRequests = [NSMutableArray array];
    NSMutableArray<NSString *> *subjects = [NSMutableArray array];
    for (NSDictionary *commit in commits) {
        if (![commit isKindOfClass:[NSDictionary class]]) {
            continue;
        }
        NSString *message = [commit[@"commit"] isKindOfClass:[NSDictionary class]] ? commit[@"commit"][@"message"] : nil;
        if (![message isKindOfClass:[NSString class]]) {
            continue;
        }
        NSMutableArray<NSString *> *lines = [NSMutableArray array];
        for (NSString *line in [message componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
            NSString *trimmed = [line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
            if (trimmed.length > 0) {
                [lines addObject:trimmed];
            }
        }
        if (lines.count == 0) {
            continue;
        }
        // GitHub merge commits read "Merge pull request #N from …", then the PR title.
        NSInteger number = 0;
        NSScanner *scanner = [NSScanner scannerWithString:lines[0]];
        if ([scanner scanString:@"Merge pull request #" intoString:NULL] && [scanner scanInteger:&number]) {
            [pullRequests addObject:lines.count > 1
                ? [NSString stringWithFormat:@"#%ld %@", (long)number, lines[1]]
                : [NSString stringWithFormat:@"PR #%ld", (long)number]];
        } else {
            [subjects addObject:lines[0]];
        }
    }

    // "behind" means this build is newer than main (e.g. a branch build): nothing to pull.
    NSInteger aheadBy = MAX(0, [json[@"ahead_by"] integerValue]);
    NSDictionary *tip = commits.lastObject;
    NSString *remoteSHA = [tip isKindOfClass:[NSDictionary class]] && [tip[@"sha"] isKindOfClass:[NSString class]] ? tip[@"sha"] : sha;
    return @{
        @"ok": @YES,
        @"updateAvailable": @(aheadBy > 0),
        @"aheadBy": @(aheadBy),
        @"currentSHA": sha,
        @"remoteSHA": remoteSHA,
        @"changes": pullRequests.count > 0 ? pullRequests : subjects
    };
}

// Runs a command to completion; stdout and stderr come back together.
- (int)runCommand:(NSString *)path arguments:(NSArray<NSString *> *)arguments directory:(NSString *)directory output:(NSString **)output {
    NSTask *task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:path];
    task.arguments = arguments;
    task.currentDirectoryURL = [NSURL fileURLWithPath:directory];
    NSMutableDictionary *environment = [NSProcessInfo.processInfo.environment mutableCopy];
    // Apps started from Finder get a minimal PATH; the build needs clang, codesign, etc.
    environment[@"PATH"] = @"/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin";
    environment[@"GIT_TERMINAL_PROMPT"] = @"0";
    task.environment = environment;
    NSPipe *pipe = [NSPipe pipe];
    task.standardOutput = pipe;
    task.standardError = pipe;
    task.standardInput = [NSFileHandle fileHandleWithNullDevice];
    if (![task launchAndReturnError:NULL]) {
        if (output) {
            *output = [NSString stringWithFormat:@"Could not run %@", path.lastPathComponent];
        }
        return -1;
    }
    // Drain before waiting so a chatty build can't fill the pipe and stall.
    NSData *data = [pipe.fileHandleForReading readDataToEndOfFile];
    [task waitUntilExit];
    if (output) {
        NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"";
        *output = [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    }
    return task.terminationStatus;
}

// Fast-forwards the checkout this build came from and rebuilds the app in place.
// Returns nil and the rebuilt .app path on success, else a message for the user.
- (NSString *)pullAndRebuildRepo:(NSString *)repo appPath:(NSString **)appPath {
    BOOL isDirectory = NO;
    if (repo.length == 0 ||
        ![NSFileManager.defaultManager fileExistsAtPath:[repo stringByAppendingPathComponent:@".git"] isDirectory:&isDirectory]) {
        return @"Can't find the git checkout this app was built from. Update by hand:\ngit pull && ./scripts/build.sh";
    }

    NSString *output = nil;
    if ([self runCommand:@"/usr/bin/git" arguments:@[@"rev-parse", @"--abbrev-ref", @"HEAD"] directory:repo output:&output] != 0) {
        return output;
    }
    if (![output isEqualToString:@"main"]) {
        return [NSString stringWithFormat:@"The checkout at %@ is on branch \"%@\". Switch it to main to update.", repo, output];
    }
    if ([self runCommand:@"/usr/bin/git" arguments:@[@"pull", @"--ff-only", @"origin", @"main"] directory:repo output:&output] != 0) {
        return [NSString stringWithFormat:@"git pull failed:\n%@", output];
    }
    if ([self runCommand:@"/bin/bash" arguments:@[@"scripts/build.sh"] directory:repo output:&output] != 0) {
        NSString *tail = output.length > 800 ? [output substringFromIndex:output.length - 800] : output;
        return [NSString stringWithFormat:@"Build failed:\n%@", tail];
    }
    // build.sh prints the .app path as its last line.
    NSString *built = [[output componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet] lastObject];
    if (![built.pathExtension isEqualToString:@"app"] || ![NSFileManager.defaultManager fileExistsAtPath:built]) {
        return @"The build finished, but the app wasn't where build.sh said it would be.";
    }
    if (appPath) {
        *appPath = built;
    }
    return nil;
}

- (void)setUpdateActivityAndRefreshMenu:(NSString *)activity {
    self.updateActivity = activity;
    self.statusItem.menu = [self menuForCurrentState];
}

- (void)checkForUpdates {
    if (self.updateActivity != nil) {
        return;
    }
    [self setUpdateActivityAndRefreshMenu:@"Checking for Updates…"];
    NSString *sha = [self bundledGitCommit];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSDictionary *result = [self checkForUpdateSinceCommit:sha];
        dispatch_async(dispatch_get_main_queue(), ^{
            [self setUpdateActivityAndRefreshMenu:nil];
            [self presentUpdateCheckResult:result];
        });
    });
}

- (void)presentUpdateCheckResult:(NSDictionary *)result {
    [NSApp activateIgnoringOtherApps:YES];
    NSAlert *alert = [[NSAlert alloc] init];
    if (![result[@"ok"] boolValue]) {
        alert.messageText = @"Couldn't check for updates";
        alert.informativeText = result[@"error"] ?: @"GitHub could not be reached.";
        [alert runModal];
        return;
    }
    if (![result[@"updateAvailable"] boolValue]) {
        NSString *sha = result[@"currentSHA"];
        alert.messageText = @"No updates";
        alert.informativeText = [NSString stringWithFormat:@"You're on the latest main (%@).", [sha substringToIndex:MIN((NSUInteger)7, sha.length)]];
        [alert runModal];
        return;
    }

    NSInteger aheadBy = [result[@"aheadBy"] integerValue];
    NSArray<NSString *> *changes = result[@"changes"];
    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    for (NSUInteger i = 0; i < MIN(changes.count, (NSUInteger)8); i++) {
        [lines addObject:[@"• " stringByAppendingString:changes[i]]];
    }
    if (changes.count > 8) {
        [lines addObject:[NSString stringWithFormat:@"• …and %lu more", (unsigned long)(changes.count - 8)]];
    }
    alert.messageText = @"Update?";
    alert.informativeText = [NSString stringWithFormat:@"%@ on GitHub main:\n\n%@\n\nPull, rebuild, and restart now?",
                             aheadBy == 1 ? @"1 new commit" : [NSString stringWithFormat:@"%ld new commits", (long)aheadBy],
                             [lines componentsJoinedByString:@"\n"]];
    [alert addButtonWithTitle:@"Yes"];
    [alert addButtonWithTitle:@"No"];
    if ([alert runModal] == NSAlertFirstButtonReturn) {
        [self applyUpdate];
    }
}

- (void)applyUpdate {
    [self setUpdateActivityAndRefreshMenu:@"Updating…"];
    NSString *repo = [self bundledSourceRepo];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *appPath = nil;
        NSString *failure = [self pullAndRebuildRepo:repo appPath:&appPath];
        dispatch_async(dispatch_get_main_queue(), ^{
            [self setUpdateActivityAndRefreshMenu:nil];
            if (failure != nil) {
                [NSApp activateIgnoringOtherApps:YES];
                NSAlert *alert = [[NSAlert alloc] init];
                alert.messageText = @"Update failed";
                alert.informativeText = failure;
                [alert runModal];
                return;
            }
            // Start the new build, then get out of its way.
            NSTask *open = [[NSTask alloc] init];
            open.executableURL = [NSURL fileURLWithPath:@"/usr/bin/open"];
            open.arguments = @[@"-g", @"-n", appPath];
            [open launchAndReturnError:NULL];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                [NSApp terminate:nil];
            });
        });
    });
}

@end

int main(int argc, const char *argv[]) {
    // We feed /usr/bin/security over a pipe; if it ever exits before reading,
    // the write must fail with EPIPE rather than kill the app.
    signal(SIGPIPE, SIG_IGN);

    @autoreleasepool {
        // Headless update check for scripts and testing: prints the result as JSON.
        if (argc > 1 && strcmp(argv[1], "--check-updates") == 0) {
            AppDelegate *delegate = [[AppDelegate alloc] init];
            NSDictionary *result = [delegate checkForUpdateSinceCommit:[delegate bundledGitCommit]];
            NSData *json = [NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingPrettyPrinted error:NULL];
            fwrite(json.bytes, 1, json.length, stdout);
            fputc('\n', stdout);
            return [result[@"ok"] boolValue] ? 0 : 1;
        }

        NSApplication *app = [NSApplication sharedApplication];
        AppDelegate *delegate = [[AppDelegate alloc] init];
        app.delegate = delegate;
        [app run];
    }
    return 0;
}
