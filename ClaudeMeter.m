// Claude Meter — macOS menu bar indicator for Claude subscription usage limits.
// Reads the Claude Code OAuth token from the login Keychain and polls
// Anthropic's usage endpoint. Everything stays local to this Mac.
#import <Cocoa/Cocoa.h>
#import <Security/Security.h>
#import <ServiceManagement/ServiceManagement.h>

#pragma mark - Limit model

@interface UsageLimit : NSObject
@property (nonatomic, copy) NSString *kind;
@property (nonatomic, copy) NSString *label;
@property (nonatomic) double percent;
@property (nonatomic, copy) NSString *severity;
@property (nonatomic, strong) NSDate *resetsAt;
@end
@implementation UsageLimit
@end

#pragma mark - Credentials

static NSString *ReadAccessToken(NSString **errorOut) {
    NSData *data = nil;
    NSDictionary *query = @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: @"Claude Code-credentials",
        (__bridge id)kSecReturnData: @YES,
        (__bridge id)kSecMatchLimit: (__bridge id)kSecMatchLimitOne,
    };
    CFTypeRef item = NULL;
    OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &item);
    if (status == errSecSuccess && item) {
        data = (__bridge_transfer NSData *)item;
    } else {
        // Fallback: plain-file credentials used by some installs
        NSString *path = [NSHomeDirectory() stringByAppendingPathComponent:@".claude/.credentials.json"];
        data = [NSData dataWithContentsOfFile:path];
    }
    if (!data) {
        if (errorOut) *errorOut = @"No Claude Code credentials found — sign in with the claude CLI";
        return nil;
    }
    NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
    NSDictionary *oauth = [json isKindOfClass:NSDictionary.class] ? json[@"claudeAiOauth"] : nil;
    NSString *token = [oauth isKindOfClass:NSDictionary.class] ? oauth[@"accessToken"] : nil;
    if (![token isKindOfClass:NSString.class] || token.length == 0) {
        if (errorOut) *errorOut = @"Could not parse Claude Code credentials";
        return nil;
    }
    NSNumber *expiresAt = oauth[@"expiresAt"];
    if ([expiresAt isKindOfClass:NSNumber.class] &&
        [NSDate dateWithTimeIntervalSince1970:expiresAt.doubleValue / 1000.0].timeIntervalSinceNow < 0) {
        if (errorOut) *errorOut = @"Token expired — open Claude Code once to refresh";
        return nil;
    }
    return token;
}

#pragma mark - Helpers

static NSDate *ParseISODate(id value) {
    if (![value isKindOfClass:NSString.class]) return nil;
    static NSISO8601DateFormatter *frac, *plain;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        frac = [NSISO8601DateFormatter new];
        frac.formatOptions = NSISO8601DateFormatWithInternetDateTime | NSISO8601DateFormatWithFractionalSeconds;
        plain = [NSISO8601DateFormatter new];
    });
    NSDate *d = [frac dateFromString:value];
    return d ?: [plain dateFromString:value];
}

static NSString *Countdown(NSDate *target) {
    if (!target) return @"—";
    NSInteger seconds = (NSInteger)target.timeIntervalSinceNow;
    if (seconds <= 0) return @"now";
    NSInteger days = seconds / 86400, hours = (seconds % 86400) / 3600, minutes = (seconds % 3600) / 60;
    if (days > 0) return [NSString stringWithFormat:@"%ldd %ldh", (long)days, (long)hours];
    if (hours > 0) return [NSString stringWithFormat:@"%ldh %ldm", (long)hours, (long)minutes];
    return [NSString stringWithFormat:@"%ldm", (long)minutes];
}

// Progress ring for the menu bar. Template (black) adapts to the bar theme;
// warning states are drawn in orange/red.
static NSImage *RingImage(double percent, BOOL warning) {
    NSColor *color = warning ? (percent >= 90 ? NSColor.systemRedColor : NSColor.systemOrangeColor)
                             : NSColor.blackColor;
    NSImage *image = [NSImage imageWithSize:NSMakeSize(18, 18) flipped:NO
                             drawingHandler:^BOOL(NSRect rect) {
        NSPoint center = NSMakePoint(NSMidX(rect), NSMidY(rect));
        CGFloat radius = 6.5, lineWidth = 2.5;

        NSBezierPath *track = [NSBezierPath bezierPath];
        [track appendBezierPathWithArcWithCenter:center radius:radius startAngle:0 endAngle:360];
        track.lineWidth = lineWidth;
        [[color colorWithAlphaComponent:warning ? 0.3 : 0.25] setStroke];
        [track stroke];

        double fraction = MAX(0, MIN(percent, 100)) / 100.0;
        if (fraction > 0.01) {
            CGFloat start = 90, end = start - fraction * 360;  // 12 o'clock, clockwise
            NSBezierPath *arc = [NSBezierPath bezierPath];
            [arc appendBezierPathWithArcWithCenter:center radius:radius
                                        startAngle:start endAngle:end clockwise:YES];
            arc.lineWidth = lineWidth;
            arc.lineCapStyle = NSLineCapStyleRound;
            [color setStroke];
            [arc stroke];
        }
        return YES;
    }];
    image.template = !warning;
    return image;
}

// Small Claude-style orange starburst, drawn in code (no bundled assets).
static NSImage *ClaudeIcon(void) {
    static NSImage *icon;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        icon = [NSImage imageWithSize:NSMakeSize(16, 16) flipped:NO
                       drawingHandler:^BOOL(NSRect rect) {
            NSColor *orange = [NSColor colorWithSRGBRed:0.851 green:0.467 blue:0.341 alpha:1]; // #D97757
            [orange setStroke];
            NSPoint center = NSMakePoint(NSMidX(rect), NSMidY(rect));
            int rays = 10;
            for (int i = 0; i < rays; i++) {
                double angle = (2 * M_PI * i) / rays + 0.3;
                double inner = 1.6, outer = (i % 2 == 0) ? 7.0 : 5.6;
                NSBezierPath *ray = [NSBezierPath bezierPath];
                ray.lineWidth = 1.8;
                ray.lineCapStyle = NSLineCapStyleRound;
                [ray moveToPoint:NSMakePoint(center.x + inner * cos(angle), center.y + inner * sin(angle))];
                [ray lineToPoint:NSMakePoint(center.x + outer * cos(angle), center.y + outer * sin(angle))];
                [ray stroke];
            }
            return YES;
        }];
    });
    return icon;
}

#pragma mark - App delegate

static NSString *const kHideFloatingMeterKey = @"HideFloatingMeter";

@interface AppDelegate : NSObject <NSApplicationDelegate>
@property (nonatomic, strong) NSStatusItem *statusItem;
@property (nonatomic, strong) NSTimer *timer;
@property (nonatomic, strong) NSArray<UsageLimit *> *limits;
@property (nonatomic, strong) NSDate *fetchedAt;
@property (nonatomic, copy) NSString *lastError;
@property (nonatomic, strong) NSPanel *panel;
@property (nonatomic, strong) NSImageView *panelIcon;
@property (nonatomic, strong) NSTextField *panelLabel;
@property (nonatomic, strong) NSImageView *brandIcon;
@property (nonatomic, strong) NSTextField *brandLabel;
@property (nonatomic) BOOL didShowSetupAlert;
@end

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    self.statusItem = [NSStatusBar.systemStatusBar statusItemWithLength:NSVariableStatusItemLength];
    self.statusItem.button.image = RingImage(0, NO);
    self.statusItem.button.imagePosition = NSImageLeft;
    self.statusItem.button.title = @" …";
    self.statusItem.menu = [self buildMenu];

    [self setUpFloatingPanel];

    [self refresh];
    self.timer = [NSTimer scheduledTimerWithTimeInterval:60 target:self
                                                selector:@selector(refresh) userInfo:nil repeats:YES];
    self.timer.tolerance = 10;
    [NSWorkspace.sharedWorkspace.notificationCenter addObserver:self selector:@selector(didWake)
                                                           name:NSWorkspaceDidWakeNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(positionPanel)
                                               name:NSApplicationDidChangeScreenParametersNotification object:nil];
}

#pragma mark - Floating panel (pinned bottom-right)

- (void)setUpFloatingPanel {
    NSPanel *panel = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, 150, 32)
                                                styleMask:NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel
                                                  backing:NSBackingStoreBuffered defer:NO];
    panel.opaque = NO;
    panel.backgroundColor = NSColor.clearColor;
    panel.hasShadow = YES;
    panel.level = NSFloatingWindowLevel;
    panel.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces |
                               NSWindowCollectionBehaviorFullScreenAuxiliary |
                               NSWindowCollectionBehaviorStationary;
    panel.hidesOnDeactivate = NO;
    panel.becomesKeyOnlyIfNeeded = YES;

    NSVisualEffectView *blur = [[NSVisualEffectView alloc] initWithFrame:NSMakeRect(0, 0, 150, 32)];
    blur.material = NSVisualEffectMaterialHUDWindow;
    blur.blendingMode = NSVisualEffectBlendingModeBehindWindow;
    blur.state = NSVisualEffectStateActive;
    blur.wantsLayer = YES;
    blur.layer.cornerRadius = 10;
    blur.layer.masksToBounds = YES;
    panel.contentView = blur;

    self.brandIcon = [[NSImageView alloc] initWithFrame:NSMakeRect(10, 8, 12, 12)];
    self.brandIcon.image = ClaudeIcon();
    [blur addSubview:self.brandIcon];

    self.brandLabel = [NSTextField labelWithString:@"Claude Limit"];
    self.brandLabel.font = [NSFont systemFontOfSize:10 weight:NSFontWeightSemibold];
    self.brandLabel.textColor = NSColor.secondaryLabelColor;
    [self.brandLabel sizeToFit];
    [blur addSubview:self.brandLabel];

    self.panelIcon = [[NSImageView alloc] initWithFrame:NSMakeRect(8, 7, 18, 18)];
    self.panelIcon.image = RingImage(0, NO);
    self.panelIcon.contentTintColor = NSColor.labelColor;
    [blur addSubview:self.panelIcon];

    self.panelLabel = [NSTextField labelWithString:@"…"];
    self.panelLabel.font = [NSFont monospacedDigitSystemFontOfSize:12 weight:NSFontWeightMedium];
    self.panelLabel.textColor = NSColor.labelColor;
    [blur addSubview:self.panelLabel];

    NSClickGestureRecognizer *click = [[NSClickGestureRecognizer alloc]
                                       initWithTarget:self action:@selector(panelClicked:)];
    [blur addGestureRecognizer:click];

    NSClickGestureRecognizer *rightClick = [[NSClickGestureRecognizer alloc]
                                            initWithTarget:self action:@selector(panelClicked:)];
    rightClick.buttonMask = 0x2;  // secondary (right) mouse button
    [blur addGestureRecognizer:rightClick];

    self.panel = panel;
    [self updatePanel];
    if (![NSUserDefaults.standardUserDefaults boolForKey:kHideFloatingMeterKey]) {
        [panel orderFrontRegardless];
    }
}

- (void)updatePanel {
    if (!self.panel) return;
    UsageLimit *session = [self sessionLimit];
    UsageLimit *weekly = nil;
    for (UsageLimit *l in self.limits) {
        if ([l.kind isEqualToString:@"weekly_all"]) { weekly = l; break; }
    }
    if (!weekly) {  // fallback: highest of whatever weekly limits exist
        for (UsageLimit *l in self.limits) {
            if ([l.kind hasPrefix:@"weekly"] && (!weekly || l.percent > weekly.percent)) weekly = l;
        }
    }

    NSMutableAttributedString *text = [NSMutableAttributedString new];
    NSFont *font = [NSFont monospacedDigitSystemFontOfSize:12 weight:NSFontWeightMedium];
    if (session) {
        NSColor *sessionColor = session.percent >= 90 ? NSColor.systemRedColor
                              : session.percent >= 70 ? NSColor.systemOrangeColor
                              : NSColor.labelColor;
        [text appendAttributedString:[[NSAttributedString alloc]
            initWithString:[NSString stringWithFormat:@"%d%%", (int)session.percent]
                attributes:@{NSFontAttributeName: font, NSForegroundColorAttributeName: sessionColor}]];
        if (weekly) {
            NSColor *weeklyColor = weekly.percent >= 90 ? NSColor.systemRedColor
                                 : weekly.percent >= 70 ? NSColor.systemOrangeColor
                                 : NSColor.secondaryLabelColor;
            [text appendAttributedString:[[NSAttributedString alloc]
                initWithString:[NSString stringWithFormat:@"  wk %d%%", (int)weekly.percent]
                    attributes:@{NSFontAttributeName: font, NSForegroundColorAttributeName: weeklyColor}]];
        }
        BOOL warning = session.percent >= 70;
        self.panelIcon.image = RingImage(session.percent, warning);
        self.panelIcon.contentTintColor = warning ? nil : NSColor.labelColor;
    } else {
        [text appendAttributedString:[[NSAttributedString alloc]
            initWithString:self.lastError ? @"!" : @"…"
                attributes:@{NSFontAttributeName: font,
                             NSForegroundColorAttributeName: NSColor.labelColor}]];
        self.panelIcon.image = RingImage(0, NO);
        self.panelIcon.contentTintColor = NSColor.labelColor;
    }
    self.panelLabel.attributedStringValue = text;
    [self.panelLabel sizeToFit];

    // Compact two-line layout:
    //   ✳ Claude Limit
    //   ◔ 33% · wk 20%
    CGFloat height = 48, pad = 10;
    CGFloat topRowY = height - 12 - 8;
    CGFloat row1W = 12 + 4 + NSWidth(self.brandLabel.frame);
    CGFloat row2W = 16 + 5 + NSWidth(self.panelLabel.frame);
    CGFloat width = pad + MAX(row1W, row2W) + pad;

    self.brandIcon.frame = NSMakeRect(pad, topRowY, 12, 12);
    self.brandLabel.frame = NSMakeRect(pad + 12 + 4,
                                       topRowY + (12 - NSHeight(self.brandLabel.frame)) / 2,
                                       NSWidth(self.brandLabel.frame), NSHeight(self.brandLabel.frame));
    self.panelIcon.frame = NSMakeRect(pad, 8, 16, 16);
    self.panelLabel.frame = NSMakeRect(pad + 16 + 5,
                                       8 + (16 - NSHeight(self.panelLabel.frame)) / 2,
                                       NSWidth(self.panelLabel.frame), NSHeight(self.panelLabel.frame));

    NSRect frame = self.panel.frame;
    frame.size = NSMakeSize(width, height);
    [self.panel setFrame:frame display:YES];
    self.panel.contentView.frame = NSMakeRect(0, 0, width, height);
    [self positionPanel];
}

- (void)positionPanel {
    if (!self.panel) return;
    NSScreen *screen = self.panel.screen ?: NSScreen.mainScreen ?: NSScreen.screens.firstObject;
    if (!screen) return;
    NSRect vf = screen.visibleFrame;  // excludes Dock and menu bar
    [self.panel setFrameOrigin:NSMakePoint(NSMaxX(vf) - NSWidth(self.panel.frame) - 12,
                                           NSMinY(vf) + 12)];
}

- (void)panelClicked:(NSClickGestureRecognizer *)recognizer {
    NSView *view = self.panel.contentView;
    [[self buildMenu] popUpMenuPositioningItem:nil
                                    atLocation:NSMakePoint(0, NSHeight(view.bounds) + 6)
                                        inView:view];
}

- (void)toggleFloatingMeter {
    BOOL hidden = [NSUserDefaults.standardUserDefaults boolForKey:kHideFloatingMeterKey];
    [NSUserDefaults.standardUserDefaults setBool:!hidden forKey:kHideFloatingMeterKey];
    if (hidden) [self.panel orderFrontRegardless];
    else [self.panel orderOut:nil];
    self.statusItem.menu = [self buildMenu];
}

- (void)didWake {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        [self refresh];
    });
}

- (void)refresh {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSString *credError = nil;
        NSString *token = ReadAccessToken(&credError);
        if (!token) {
            [self finishWithLimits:nil error:credError];
            return;
        }
        NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:
                                        [NSURL URLWithString:@"https://api.anthropic.com/api/oauth/usage"]];
        [request setValue:[@"Bearer " stringByAppendingString:token] forHTTPHeaderField:@"Authorization"];
        [request setValue:@"oauth-2025-04-20" forHTTPHeaderField:@"anthropic-beta"];
        request.timeoutInterval = 20;

        [[NSURLSession.sharedSession dataTaskWithRequest:request
                completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            if (error) {
                [self finishWithLimits:nil error:[@"Network error: " stringByAppendingString:error.localizedDescription]];
                return;
            }
            NSInteger code = ((NSHTTPURLResponse *)response).statusCode;
            if (code == 401) {
                [self finishWithLimits:nil error:@"Token expired — open Claude Code once to refresh"];
                return;
            }
            if (code != 200) {
                [self finishWithLimits:nil error:[NSString stringWithFormat:@"API error (HTTP %ld)", (long)code]];
                return;
            }
            NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
            if (![json isKindOfClass:NSDictionary.class]) {
                [self finishWithLimits:nil error:@"Unexpected API response"];
                return;
            }
            [self finishWithLimits:[self parseLimits:json] error:nil];
        }] resume];
    });
}

- (NSArray<UsageLimit *> *)parseLimits:(NSDictionary *)json {
    NSMutableArray<UsageLimit *> *limits = [NSMutableArray array];
    for (NSDictionary *entry in json[@"limits"]) {
        if (![entry isKindOfClass:NSDictionary.class]) continue;
        UsageLimit *limit = [UsageLimit new];
        limit.kind = [entry[@"kind"] isKindOfClass:NSString.class] ? entry[@"kind"] : @"?";
        limit.percent = [entry[@"percent"] isKindOfClass:NSNumber.class] ? [entry[@"percent"] doubleValue] : 0;
        limit.severity = [entry[@"severity"] isKindOfClass:NSString.class] ? entry[@"severity"] : @"normal";
        limit.resetsAt = ParseISODate(entry[@"resets_at"]);

        if ([limit.kind isEqualToString:@"session"]) {
            limit.label = @"Session (5h)";
        } else if ([limit.kind isEqualToString:@"weekly_all"]) {
            limit.label = @"Weekly (all models)";
        } else if ([limit.kind isEqualToString:@"weekly_scoped"]) {
            NSString *name = @"model";
            NSDictionary *scope = entry[@"scope"];
            if ([scope isKindOfClass:NSDictionary.class]) {
                NSDictionary *model = scope[@"model"];
                if ([model isKindOfClass:NSDictionary.class] &&
                    [model[@"display_name"] isKindOfClass:NSString.class]) {
                    name = model[@"display_name"];
                }
            }
            limit.label = [NSString stringWithFormat:@"Weekly (%@)", name];
        } else {
            limit.label = [limit.kind stringByReplacingOccurrencesOfString:@"_" withString:@" "].capitalizedString;
        }
        [limits addObject:limit];
    }
    // Fallback for older response shapes without "limits"
    if (limits.count == 0) {
        NSDictionary *fiveHour = json[@"five_hour"], *sevenDay = json[@"seven_day"];
        if ([fiveHour isKindOfClass:NSDictionary.class]) {
            UsageLimit *l = [UsageLimit new];
            l.kind = @"session"; l.label = @"Session (5h)"; l.severity = @"normal";
            l.percent = [fiveHour[@"utilization"] doubleValue];
            l.resetsAt = ParseISODate(fiveHour[@"resets_at"]);
            [limits addObject:l];
        }
        if ([sevenDay isKindOfClass:NSDictionary.class]) {
            UsageLimit *l = [UsageLimit new];
            l.kind = @"weekly_all"; l.label = @"Weekly (all models)"; l.severity = @"normal";
            l.percent = [sevenDay[@"utilization"] doubleValue];
            l.resetsAt = ParseISODate(sevenDay[@"resets_at"]);
            [limits addObject:l];
        }
    }
    return limits;
}

- (void)finishWithLimits:(NSArray<UsageLimit *> *)limits error:(NSString *)error {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (limits) {
            self.limits = limits;
            self.fetchedAt = [NSDate date];
            self.lastError = nil;
        } else {
            self.lastError = error;
            // First-run help: no credentials and never fetched successfully
            if (!self.fetchedAt && !self.didShowSetupAlert &&
                [error rangeOfString:@"credentials"].location != NSNotFound) {
                self.didShowSetupAlert = YES;
                NSAlert *alert = [NSAlert new];
                alert.messageText = @"Claude Meter needs Claude Code";
                alert.informativeText = @"This app reuses the sign-in from the Claude Code CLI to read "
                                        @"your usage limits — it never asks for your password.\n\n"
                                        @"1. Install Claude Code (claude.com/claude-code)\n"
                                        @"2. Run \"claude\" in Terminal and sign in\n"
                                        @"3. Click Refresh Now in this app's menu";
                [alert addButtonWithTitle:@"OK"];
                [alert addButtonWithTitle:@"Open Install Page"];
                if ([alert runModal] == NSAlertSecondButtonReturn) {
                    [NSWorkspace.sharedWorkspace openURL:
                     [NSURL URLWithString:@"https://claude.com/claude-code"]];
                }
            }
        }
        [self updateStatusItem];
        [self updatePanel];
        self.statusItem.menu = [self buildMenu];
    });
}

- (UsageLimit *)sessionLimit {
    for (UsageLimit *l in self.limits) if ([l.kind isEqualToString:@"session"]) return l;
    return self.limits.firstObject;
}

- (UsageLimit *)worstLimit {
    UsageLimit *worst = nil;
    for (UsageLimit *l in self.limits) if (!worst || l.percent > worst.percent) worst = l;
    return worst;
}

- (void)updateStatusItem {
    NSStatusBarButton *button = self.statusItem.button;
    UsageLimit *session = [self sessionLimit];
    if (!session) {
        button.image = RingImage(0, NO);
        button.title = @" !";
        return;
    }
    BOOL warning = session.percent >= 70;
    button.image = RingImage(session.percent, warning);

    NSMutableString *title = [NSMutableString stringWithFormat:@" %d%%", (int)session.percent];
    UsageLimit *worst = [self worstLimit];
    if (worst && ![worst.kind isEqualToString:@"session"] && worst.percent >= 90) [title appendString:@" ⚠"];
    if (self.lastError) [title appendString:@" !"];

    NSMutableDictionary *attrs = [NSMutableDictionary dictionaryWithObject:
                                  [NSFont monospacedDigitSystemFontOfSize:12 weight:NSFontWeightMedium]
                                                                    forKey:NSFontAttributeName];
    if (warning) {
        attrs[NSForegroundColorAttributeName] = session.percent >= 90 ? NSColor.systemRedColor
                                                                      : NSColor.systemOrangeColor;
    }
    button.attributedTitle = [[NSAttributedString alloc] initWithString:title attributes:attrs];
}

- (NSMenu *)buildMenu {
    NSMenu *menu = [NSMenu new];

    for (UsageLimit *limit in self.limits) {
        NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:@"" action:nil keyEquivalent:@""];
        NSString *reset = limit.resetsAt ? [NSString stringWithFormat:@"resets in %@", Countdown(limit.resetsAt)] : @"";
        NSMutableAttributedString *text = [[NSMutableAttributedString alloc]
            initWithString:[NSString stringWithFormat:@"%@ — %d%%\n", limit.label, (int)limit.percent]
                attributes:@{NSFontAttributeName: [NSFont menuFontOfSize:13]}];
        [text appendAttributedString:[[NSAttributedString alloc]
            initWithString:[NSString stringWithFormat:@"%@  %@", [self progressBar:limit.percent], reset]
                attributes:@{NSFontAttributeName: [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular],
                             NSForegroundColorAttributeName: NSColor.secondaryLabelColor}]];
        item.attributedTitle = text;
        item.enabled = NO;
        [menu addItem:item];
    }

    if (self.fetchedAt) {
        [menu addItem:[NSMenuItem separatorItem]];
        NSDateFormatter *formatter = [NSDateFormatter new];
        formatter.timeStyle = NSDateFormatterShortStyle;
        NSMenuItem *updated = [[NSMenuItem alloc]
            initWithTitle:[NSString stringWithFormat:@"Updated %@", [formatter stringFromDate:self.fetchedAt]]
                   action:nil keyEquivalent:@""];
        updated.enabled = NO;
        [menu addItem:updated];
    }

    if (self.lastError) {
        NSMenuItem *err = [[NSMenuItem alloc]
            initWithTitle:[@"⚠ " stringByAppendingString:self.lastError] action:nil keyEquivalent:@""];
        err.enabled = NO;
        [menu addItem:err];
    }

    [menu addItem:[NSMenuItem separatorItem]];
    NSMenuItem *refreshItem = [[NSMenuItem alloc] initWithTitle:@"Refresh Now"
                                                         action:@selector(refresh) keyEquivalent:@"r"];
    refreshItem.target = self;
    [menu addItem:refreshItem];

    NSMenuItem *openItem = [[NSMenuItem alloc] initWithTitle:@"Open claude.ai Usage Page"
                                                      action:@selector(openUsagePage) keyEquivalent:@""];
    openItem.target = self;
    [menu addItem:openItem];

    BOOL meterHidden = [NSUserDefaults.standardUserDefaults boolForKey:kHideFloatingMeterKey];
    NSMenuItem *floatItem = [[NSMenuItem alloc]
        initWithTitle:meterHidden ? @"Show Floating Meter (bottom right)" : @"Hide Floating Meter"
               action:@selector(toggleFloatingMeter) keyEquivalent:@""];
    floatItem.target = self;
    [menu addItem:floatItem];

    if (@available(macOS 13.0, *)) {
        NSMenuItem *loginItem = [[NSMenuItem alloc] initWithTitle:@"Launch at Login"
                                                           action:@selector(toggleLaunchAtLogin) keyEquivalent:@""];
        loginItem.target = self;
        loginItem.state = (SMAppService.mainAppService.status == SMAppServiceStatusEnabled)
                          ? NSControlStateValueOn : NSControlStateValueOff;
        [menu addItem:loginItem];
    }

    [menu addItem:[NSMenuItem separatorItem]];
    [menu addItem:[[NSMenuItem alloc] initWithTitle:@"Quit Claude Meter"
                                             action:@selector(terminate:) keyEquivalent:@"q"]];
    return menu;
}

- (NSString *)progressBar:(double)percent {
    NSInteger width = 20;
    NSInteger filled = (NSInteger)llround(MAX(0, MIN(percent, 100)) / 100.0 * width);
    NSMutableString *bar = [NSMutableString string];
    for (NSInteger i = 0; i < width; i++) [bar appendString:i < filled ? @"█" : @"░"];
    return bar;
}

- (void)openUsagePage {
    [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:@"https://claude.ai/settings/usage"]];
}

- (void)toggleLaunchAtLogin {
    if (@available(macOS 13.0, *)) {
        NSError *error = nil;
        if (SMAppService.mainAppService.status == SMAppServiceStatusEnabled) {
            [SMAppService.mainAppService unregisterAndReturnError:&error];
        } else {
            [SMAppService.mainAppService registerAndReturnError:&error];
        }
        if (error) NSLog(@"Launch at login toggle failed: %@", error);
        self.statusItem.menu = [self buildMenu];
    }
}

@end

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSApplication *app = NSApplication.sharedApplication;
        AppDelegate *delegate = [AppDelegate new];
        app.delegate = delegate;
        [app setActivationPolicy:NSApplicationActivationPolicyAccessory];
        [app run];
    }
    return 0;
}
