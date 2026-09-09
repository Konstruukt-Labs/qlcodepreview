//
//  main.m
//  QLCodePreview (host app)
//
//  This app has almost no functionality of its own. Its only job is to be a
//  container application that embeds the QLCodePreviewExtension.appex Quick
//  Look extension in its Contents/PlugIns directory.
//
//  Since macOS 12, Quick Look *preview* extensions (QLPreviewingController,
//  extension point com.apple.quicklook.preview) are ordinary App Extensions.
//  Unlike the legacy .qlgenerator plug-ins, they cannot be dropped into
//  ~/Library/QuickLook - PlugInKit only discovers them when they are
//  embedded inside a host .app that macOS knows about (i.e. one that has
//  been launched, or explicitly registered with `pluginkit -a`). This app
//  exists purely to satisfy that requirement.
//
//  Launching it opens a single settings window with two tabs, "Preview
//  Settings" and "Custom File Types" — the app is only ever launched for
//  first-time setup or to tweak a setting, so everything lives in that one
//  window. The actual preview rendering happens entirely inside the
//  embedded extension.
//

@import Cocoa;

#import "FileTypesViewController.h"
#import "PreferencesViewController.h"

@interface QLCCAppDelegate : NSObject <NSApplicationDelegate>
@property(strong) NSWindow *window;
@property(strong) QLCCPreferencesViewController *preferencesViewController;
@property(strong) QLCCFileTypesViewController *fileTypesViewController;
@property(strong) NSTextField *statusLabel;
@end

@implementation QLCCAppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    // Single-instance guard. If another copy of this app is already running,
    // activate it and quit this one before any UI is built. LaunchServices
    // already prevents a second instance for a plain `open`, but `open -n`,
    // a direct binary exec, or an ad-hoc-signed app whose identity
    // LaunchServices can't pin down can each start an extra copy - this
    // stops all of those from the app's own point of view.
    {
        pid_t selfPID = NSProcessInfo.processInfo.processIdentifier;
        NSString *bid = NSBundle.mainBundle.bundleIdentifier;
        for (NSRunningApplication *app in NSWorkspace.sharedWorkspace.runningApplications) {
            if (app.processIdentifier == selfPID) continue;
            if (bid && [app.bundleIdentifier isEqualToString:bid]) {
                [app activateWithOptions:(NSApplicationActivateAllWindows |
                                          NSApplicationActivateIgnoringOtherApps)];
                [NSApp terminate:nil];
                return;
            }
        }
    }

    [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];

    NSRect frame = NSMakeRect(0, 0, 520, 566);
    NSWindowStyleMask style = NSWindowStyleMaskTitled | NSWindowStyleMaskClosable;
    self.window = [[NSWindow alloc] initWithContentRect:frame
                                               styleMask:style
                                                 backing:NSBackingStoreBuffered
                                                   defer:NO];
    self.window.title = @"QLCodePreview";
    self.window.releasedWhenClosed = NO;
    NSView *content = self.window.contentView;

    // One window, two panes. Tab content is sized from the tab view's actual
    // content rect so the fixed-frame layouts land where they should.
    NSTabView *tabView = [[NSTabView alloc] initWithFrame:NSMakeRect(20, 64, 480, 484)];
    NSSize paneSize = tabView.contentRect.size;

    self.preferencesViewController = [[QLCCPreferencesViewController alloc] initWithSize:paneSize];
    NSTabViewItem *prefsItem = [[NSTabViewItem alloc] initWithIdentifier:@"previewSettings"];
    prefsItem.label = @"Preview Settings";
    prefsItem.view = self.preferencesViewController.view;
    [tabView addTabViewItem:prefsItem];

    self.fileTypesViewController = [[QLCCFileTypesViewController alloc] initWithSize:paneSize];
    NSTabViewItem *fileTypesItem = [[NSTabViewItem alloc] initWithIdentifier:@"fileTypes"];
    fileTypesItem.label = @"Custom File Types";
    fileTypesItem.view = self.fileTypesViewController.view;
    [tabView addTabViewItem:fileTypesItem];
    [content addSubview:tabView];

    // Shared bottom bar: status line + Save (both panes) + Quit.
    self.statusLabel = [NSTextField labelWithString:@""];
    self.statusLabel.font = [NSFont systemFontOfSize:11];
    self.statusLabel.textColor = [NSColor secondaryLabelColor];
    self.statusLabel.frame = NSMakeRect(20, 24, 130, 18);
    [content addSubview:self.statusLabel];

    // Footer links sit in the status row, right-aligned against Save/Quit,
    // so the bottom bar reads as one footer: status left, links + buttons
    // right. (The status text is always short — "Saved · Saved." — so a
    // 130pt label leaves the row plenty of room.)
    [self addFooterLinks:@[ @"konstruukt.com", @"Buy me a coffee" ]
                     URLs:@[ @"https://konstruukt.com",
                             @"https://buymeacoffee.com/itsvrk" ]];

    NSButton *quit = [NSButton buttonWithTitle:@"Quit"
                                         target:NSApp
                                         action:@selector(terminate:)];
    quit.frame = NSMakeRect(430, 15, 70, 32);
    [content addSubview:quit];

    NSButton *save = [NSButton buttonWithTitle:@"Save"
                                         target:self
                                         action:@selector(saveClicked:)];
    save.frame = NSMakeRect(338, 15, 80, 32);
    save.bezelStyle = NSBezelStyleRounded;
    save.keyEquivalent = @"\r";
    [content addSubview:save];

    [self.window center];
    [self.window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
}

// Lays out a row of link buttons in the bottom bar, right-aligned so the
// row ends flush against the Save button (which starts at x = 338). Button
// widths come from the rendered attributed text, so the row hugs the buttons
// exactly instead of relying on guessed frame widths.
- (void)addFooterLinks:(NSArray<NSString *> *)titles URLs:(NSArray<NSString *> *)urls {
    NSDictionary<NSAttributedStringKey, id> *attributes = @{
        NSFontAttributeName : [NSFont systemFontOfSize:11],
        NSForegroundColorAttributeName : NSColor.linkColor,
        NSUnderlineStyleAttributeName : @(NSUnderlineStyleSingle),
    };
    const CGFloat gap = 14.0;       // breathing room between the two links
    const CGFloat rightEdge = 328.0; // Save starts at x = 338

    NSMutableArray<NSNumber *> *widths = [NSMutableArray array];
    CGFloat total = (titles.count - 1) * gap;
    for (NSString *title in titles) {
        CGFloat w = ceil([title sizeWithAttributes:attributes].width);
        [widths addObject:@(w)];
        total += w;
    }

    CGFloat x = rightEdge - total;
    for (NSUInteger i = 0; i < titles.count; i++) {
        CGFloat w = widths[i].doubleValue;
        NSButton *button = [NSButton buttonWithTitle:titles[i]
                                              target:self
                                              action:@selector(openLink:)];
        button.frame = NSMakeRect(x, 24, w, 18);
        [button setBordered:NO];
        button.focusRingType = NSFocusRingTypeNone;
        button.identifier = urls[i];
        button.toolTip = urls[i];
        button.attributedTitle = [[NSAttributedString alloc] initWithString:titles[i]
                                                                 attributes:attributes];
        [self.window.contentView addSubview:button];
        x += w + gap;
    }
}

- (void)openLink:(NSButton *)sender {
    NSURL *url = [NSURL URLWithString:sender.identifier];
    if (url) [[NSWorkspace sharedWorkspace] openURL:url];
}

- (void)saveClicked:(id)sender {
    NSString *prefsStatus = [self.preferencesViewController save];
    NSString *mapStatus = [self.fileTypesViewController save];
    self.statusLabel.stringValue =
        [NSString stringWithFormat:@"%@ · %@.", prefsStatus, mapStatus];

    // Nudge Quick Look to re-read preferences for previews opened after this.
    NSTask *task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/qlmanage"];
    task.arguments = @[ @"-r" ];
    [task launchAndReturnError:nil];
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)app {
    return YES;
}

@end

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        QLCCAppDelegate *delegate = [QLCCAppDelegate new];
        app.delegate = delegate;
        [app run];
    }
    return 0;
}
