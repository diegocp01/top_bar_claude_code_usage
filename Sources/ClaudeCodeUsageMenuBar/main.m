#import <Cocoa/Cocoa.h>
#import <ServiceManagement/ServiceManagement.h>
#import <Security/Security.h>
#import <math.h>

static NSString * const DisplayModeKey = @"displayMode";
static NSString * const DisplayModePercent = @"percent";
static NSString * const DisplayModeBattery = @"battery";
static NSString * const TimeModeKey = @"timeMode";
static NSString * const TimeModeClock = @"clock";
static NSString * const TimeModeCountdown = @"countdown";
static NSString * const MetricModeKey = @"metricMode";
static NSString * const MetricModeLeft = @"left";
static NSString * const MetricModeUsed = @"used";
static NSString * const WidgetWindowModeKey = @"widgetWindowMode";
static NSString * const WidgetWindowSession = @"session";
static NSString * const WidgetWindowWeekly = @"weekly";
static NSString * const RefreshIntervalKey = @"refreshIntervalSeconds";
static NSTimeInterval const DefaultRefreshIntervalSeconds = 300.0;

// Persisted last-good usage snapshot, so the widget keeps showing real numbers
// even while the API is unreachable or rate-limiting us.
static NSString * const LastGoodStateKey = @"lastGoodState";
static NSString * const LastGoodFetchedAtKey = @"lastGoodFetchedAt";
// Upper bound on how long we back off the network after repeated failures.
static NSTimeInterval const UsageBackoffMaxSeconds = 600.0;

// Claude Code OAuth configuration (matches the Claude Code CLI production config).
static NSString * const KeychainService = @"Claude Code-credentials";
static NSString * const OAuthClientID = @"9d1c250a-e61b-44d9-88ed-5944d1962f5e";
static NSString * const OAuthTokenURL = @"https://platform.claude.com/v1/oauth/token";
static NSString * const UsageURL = @"https://api.anthropic.com/api/oauth/usage";
static NSString * const OAuthBetaHeader = @"oauth-2025-04-20";

@interface AppDelegate : NSObject <NSApplicationDelegate, NSMenuDelegate>
@property(nonatomic, strong) NSStatusItem *statusItem;
@property(nonatomic, strong) NSTimer *pollTimer;
@property(nonatomic, strong) NSTimer *displayTimer;
@property(nonatomic, strong) NSDictionary *latestState;
@property(nonatomic, strong) NSImage *claudeIcon;
@property(nonatomic, copy) NSString *launchAtLoginError;
@property(nonatomic, strong) NSDate *refreshBackoffUntil;
// Last successful usage snapshot + when we got it, and the network cool-down
// the API has effectively imposed on us (e.g. after a 429).
@property(nonatomic, strong) NSDictionary *lastGoodState;
@property(nonatomic, strong) NSDate *lastGoodFetchedAt;
@property(nonatomic, strong) NSDate *usageBackoffUntil;
@property(nonatomic, assign) NSTimeInterval usageBackoffSeconds;
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

- (NSImage *)batteryIconForPercent:(double)percent {
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

    CGFloat fillWidth = (CGFloat)((body.size.width - 4.0) * (clamped / 100.0));
    if (fillWidth > 0.5) {
        NSRect fillRect = NSMakeRect(body.origin.x + 2.0, body.origin.y + 2.0, fillWidth, body.size.height - 4.0);
        [[NSBezierPath bezierPathWithRoundedRect:fillRect xRadius:1.0 yRadius:1.0] fill];
    }

    NSString *number = [NSString stringWithFormat:@"%.0f", clamped];
    NSDictionary *attributes = @{
        NSFontAttributeName: [NSFont monospacedDigitSystemFontOfSize:8.5 weight:NSFontWeightSemibold],
        NSForegroundColorAttributeName: NSColor.blackColor
    };
    NSSize numberSize = [number sizeWithAttributes:attributes];
    NSPoint numberPoint = NSMakePoint(NSMidX(body) - numberSize.width / 2.0,
                                      NSMidY(body) - numberSize.height / 2.0 - 0.5);
    [number drawAtPoint:numberPoint withAttributes:attributes];

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
    if ([ok respondsToSelector:@selector(boolValue)] && ![ok boolValue] &&
        [state[@"error"] isKindOfClass:[NSString class]]) {
        [menu addItem:[NSMenuItem separatorItem]];
        [self addDisabledItem:[NSString stringWithFormat:@"Error: %@", state[@"error"]] toMenu:menu];
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
    if (![ok respondsToSelector:@selector(boolValue)] || ![ok boolValue]) {
        self.statusItem.button.image = self.claudeIcon;
        self.statusItem.button.title = @"--";
        return;
    }

    double metric = [self displayPercentForWidgetState:state];
    NSString *timeText = [self timeTextForWidgetState:state];

    if ([[self displayMode] isEqualToString:DisplayModeBattery]) {
        self.statusItem.button.image = [self batteryIconForPercent:metric];
        self.statusItem.button.title = timeText;
        return;
    }

    self.statusItem.button.image = self.claudeIcon;
    if (isnan(metric)) {
        self.statusItem.button.title = timeText.length > 0 ? timeText : @"--";
    } else {
        NSString *metricLabel = [self metricLabel];
        if (metricLabel.length > 0) {
            self.statusItem.button.title = [NSString stringWithFormat:@"%@ | %.0f%% %@", timeText, metric, metricLabel];
        } else {
            self.statusItem.button.title = [NSString stringWithFormat:@"%@ | %.0f%%", timeText, metric];
        }
    }
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
        return @"Reset time: unknown";
    }
    return [NSString stringWithFormat:@"Reset time: %@", clock];
}

- (NSString *)countdownDetailForState:(NSDictionary *)state {
    NSString *countdown = [self countdownTextForWidgetState:state];
    if (countdown.length == 0) {
        return @"Countdown: unknown";
    }
    return [NSString stringWithFormat:@"Countdown: %@", countdown];
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
    if (seconds == nil) {
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

    NSInteger remaining = MAX(0, (NSInteger)llround(seconds.doubleValue - [NSDate date].timeIntervalSince1970));
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
        return [self staleStateFromGood:self.lastGoodState];
    }

    NSString *credsError = nil;
    NSDictionary *creds = [self readKeychainCredentials:&credsError];
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

    // A 401 can mean the cached token went stale mid-flight; try one forced refresh.
    if (status == 401) {
        NSString *refreshError = nil;
        NSString *refreshed = [self refreshAccessTokenWithCredentials:creds error:&refreshError];
        if (refreshed.length > 0) {
            data = [self getURL:UsageURL bearer:refreshed statusCode:&status retryAfter:&retryAfter error:&httpError];
            accessToken = refreshed;
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
    if (self.lastGoodState != nil) {
        return [self staleStateFromGood:self.lastGoodState];
    }
    return [self errorStateWithMessage:message];
}

- (NSDictionary *)staleStateFromGood:(NSDictionary *)good {
    NSMutableDictionary *state = [good mutableCopy];
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
    self.latestState = [self staleStateFromGood:saved];
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

- (NSDictionary *)readKeychainCredentials:(NSString **)error {
    NSDictionary *query = @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: KeychainService,
        (__bridge id)kSecReturnData: @YES,
        (__bridge id)kSecMatchLimit: (__bridge id)kSecMatchLimitOne
    };

    CFTypeRef result = NULL;
    OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &result);
    if (status != errSecSuccess || result == NULL) {
        if (error) {
            if (status == errSecItemNotFound) {
                *error = @"Not signed in to Claude Code (no keychain item)";
            } else if (status == errSecUserCanceled || status == errSecAuthFailed) {
                *error = @"Keychain access denied";
            } else {
                *error = [NSString stringWithFormat:@"Keychain error %d", (int)status];
            }
        }
        return nil;
    }

    NSData *data = (__bridge_transfer NSData *)result;
    id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    NSDictionary *root = [json isKindOfClass:[NSDictionary class]] ? json : nil;
    NSDictionary *oauth = [root[@"claudeAiOauth"] isKindOfClass:[NSDictionary class]] ? root[@"claudeAiOauth"] : root;
    if (![oauth isKindOfClass:[NSDictionary class]]) {
        if (error) {
            *error = @"Keychain credentials were not valid JSON";
        }
        return nil;
    }
    return oauth;
}

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

    if (accessToken.length > 0) {
        // Couldn't refresh, but try the (possibly stale) token rather than nothing.
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

    NSDictionary *root = @{@"claudeAiOauth": oauth};
    NSData *data = [NSJSONSerialization dataWithJSONObject:root options:0 error:nil];
    if (data == nil) {
        return;
    }

    NSDictionary *query = @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: KeychainService
    };
    NSDictionary *update = @{ (__bridge id)kSecValueData: data };
    SecItemUpdate((__bridge CFDictionaryRef)query, (__bridge CFDictionaryRef)update);
}

#pragma mark - HTTP helpers (synchronous, run on a background queue)

- (NSData *)getURL:(NSString *)urlString bearer:(NSString *)bearer statusCode:(NSInteger *)statusCode retryAfter:(NSTimeInterval *)retryAfter error:(NSString **)error {
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urlString]];
    request.HTTPMethod = @"GET";
    request.timeoutInterval = 10.0;
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

@end

int main(int argc, const char *argv[]) {
    (void)argc;
    (void)argv;

    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        AppDelegate *delegate = [[AppDelegate alloc] init];
        app.delegate = delegate;
        [app run];
    }
    return 0;
}
