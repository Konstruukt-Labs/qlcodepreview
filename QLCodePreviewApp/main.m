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
//  Launching it just shows a short explanation and lets the user quit; the
//  actual preview rendering happens entirely inside the embedded extension.
//

@import Cocoa;

#import "FileTypesWindowController.h"
#import "PreferencesWindowController.h"

@interface QLCCAppDelegate : NSObject <NSApplicationDelegate>
@property(strong) NSWindow *window;
@property(strong) QLCCFileTypesWindowController *fileTypesWindowController;
@property(strong) QLCCPreferencesWindowController *preferencesWindowController;
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

    NSRect frame = NSMakeRect(0, 0, 440, 220);
    NSWindowStyleMask style = NSWindowStyleMaskTitled | NSWindowStyleMaskClosable;
    self.window = [[NSWindow alloc] initWithContentRect:frame
                                               styleMask:style
                                                 backing:NSBackingStoreBuffered
                                                   defer:NO];
    self.window.title = @"QLCodePreview";
    self.window.releasedWhenClosed = NO;

    NSTextField *label = [NSTextField wrappingLabelWithString:
        @"QLCodePreview is installed.\n\n"
        @"Its Quick Look preview extension runs in the background — you can "
        @"quit this window now. Source files (code, config, markup, etc.) "
        @"should get colourised previews in Finder and Quick Look (Space bar).\n\n"
        @"If previews don't appear, open System Settings → General → "
        @"Login Items & Extensions → Quick Look, and make sure "
        @"“QLCodePreview Extension” is turned on."];
    label.frame = NSMakeRect(20, 60, 400, 140);
    label.font = [NSFont systemFontOfSize:13];
    [self.window.contentView addSubview:label];

    NSButton *quit = [NSButton buttonWithTitle:@"Quit"
                                         target:NSApp
                                         action:@selector(terminate:)];
    quit.frame = NSMakeRect(340, 15, 80, 32);
    quit.bezelStyle = NSBezelStyleRounded;
    quit.keyEquivalent = @"\r";
    [self.window.contentView addSubview:quit];

    NSButton *fileTypes = [NSButton buttonWithTitle:@"Custom File Types…"
                                              target:self
                                              action:@selector(showFileTypes:)];
    fileTypes.frame = NSMakeRect(20, 15, 170, 32);
    [self.window.contentView addSubview:fileTypes];

    NSButton *preferences = [NSButton buttonWithTitle:@"Preferences…"
                                                target:self
                                                action:@selector(showPreferences:)];
    preferences.frame = NSMakeRect(200, 15, 130, 32);
    [self.window.contentView addSubview:preferences];

    [self.window center];
    [self.window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
}

- (void)showFileTypes:(id)sender {
    if (!self.fileTypesWindowController) {
        self.fileTypesWindowController = [[QLCCFileTypesWindowController alloc] init];
    }
    [self.fileTypesWindowController showWindow:nil];
    [self.fileTypesWindowController.window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
}

- (void)showPreferences:(id)sender {
    if (!self.preferencesWindowController) {
        self.preferencesWindowController = [[QLCCPreferencesWindowController alloc] init];
    }
    [self.preferencesWindowController showWindow:nil];
    [self.preferencesWindowController.window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
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
