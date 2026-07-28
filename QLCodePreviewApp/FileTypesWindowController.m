//
//  FileTypesWindowController.m
//  QLCodePreview (host app)
//

#import "FileTypesWindowController.h"
#import "QLCCConfiguration.h"
#import "QLCCHighlighter.h"

// Plain, non-Auto-Layout, top-down-flipped container so rows can be laid
// out with simple fixed frames (index 0 at the top) instead of fighting
// Auto Layout constraints we can't visually iterate on here.
@interface QLCCFlippedView : NSView
@end
@implementation QLCCFlippedView
- (BOOL)isFlipped { return YES; }
@end

/// One extension -> language row. Pure data; views are rebuilt from this
/// on every add/remove so row indices (used as control tags) never drift.
@interface QLCCFileTypeRow : NSObject
@property (nonatomic, copy) NSString *extension;
@property (nonatomic, copy) NSString *language;
@end
@implementation QLCCFileTypeRow
@end

static const CGFloat kRowHeight = 30;
static const CGFloat kRowControlHeight = 24;

@interface QLCCFileTypesWindowController () <NSTextFieldDelegate>
@property (nonatomic, strong) NSMutableArray<QLCCFileTypeRow *> *rows;
@property (nonatomic, copy) NSArray<NSString *> *languages;
@property (nonatomic, strong) NSScrollView *scrollView;
@property (nonatomic, strong) QLCCFlippedView *rowsContainer;
@property (nonatomic, strong) NSTextField *statusLabel;
@end

@implementation QLCCFileTypesWindowController

- (instancetype)init {
    NSRect frame = NSMakeRect(0, 0, 480, 460);
    NSWindowStyleMask style = NSWindowStyleMaskTitled | NSWindowStyleMaskClosable;
    NSWindow *window = [[NSWindow alloc] initWithContentRect:frame
                                                    styleMask:style
                                                      backing:NSBackingStoreBuffered
                                                        defer:NO];
    window.title = @"Custom File Types";
    window.releasedWhenClosed = NO;

    self = [super initWithWindow:window];
    if (self) {
        _rows = [NSMutableArray array];
        _languages = [QLCCHighlighter supportedLanguageNames];
        [self buildUI];
        [self loadFromPreferences];
    }
    return self;
}

#pragma mark - UI construction (fixed frames; window is not resizable)

- (void)buildUI {
    NSView *content = self.window.contentView;

    NSTextField *heading = [NSTextField wrappingLabelWithString:
        @"Map a file extension to a syntax-highlighting language. Takes "
        @"effect immediately for new previews no rebuild needed.\n\n"
        @"This only changes which language an already-previewed file is "
        @"highlighted as. It can't make Quick Look preview a file type it "
        @"doesn't already show at all (that needs a rebuild - ask for that "
        @"extension to be added if one of your file types never shows a "
        @"preview at all, not just the wrong colours)."];
    heading.font = [NSFont systemFontOfSize:12];
    heading.textColor = [NSColor secondaryLabelColor];
    heading.frame = NSMakeRect(20, 366, 440, 72);
    [content addSubview:heading];

    NSTextField *extHeader = [NSTextField labelWithString:@"Extension"];
    extHeader.font = [NSFont boldSystemFontOfSize:11];
    extHeader.textColor = [NSColor labelColor];
    extHeader.frame = NSMakeRect(28, 346, 110, 16);
    [content addSubview:extHeader];

    NSTextField *parserHeader = [NSTextField labelWithString:@"Parser"];
    parserHeader.font = [NSFont boldSystemFontOfSize:11];
    parserHeader.textColor = [NSColor labelColor];
    parserHeader.frame = NSMakeRect(166, 346, 228, 16);
    [content addSubview:parserHeader];

    self.scrollView = [[NSScrollView alloc] initWithFrame:NSMakeRect(20, 88, 440, 250)];
    self.scrollView.hasVerticalScroller = YES;
    self.scrollView.borderType = NSBezelBorder;
    self.scrollView.autoresizingMask = NSViewNotSizable;

    self.rowsContainer = [[QLCCFlippedView alloc] initWithFrame:NSMakeRect(0, 0, 420, 0)];
    self.scrollView.documentView = self.rowsContainer;
    [content addSubview:self.scrollView];

    NSButton *addButton = [NSButton buttonWithTitle:@"+ Add"
                                              target:self
                                              action:@selector(addRowClicked:)];
    addButton.frame = NSMakeRect(20, 54, 80, 28);
    [content addSubview:addButton];

    self.statusLabel = [NSTextField labelWithString:@""];
    self.statusLabel.font = [NSFont systemFontOfSize:11];
    self.statusLabel.textColor = [NSColor secondaryLabelColor];
    self.statusLabel.frame = NSMakeRect(108, 60, 280, 18);
    [content addSubview:self.statusLabel];

    NSButton *closeButton = [NSButton buttonWithTitle:@"Close"
                                                target:self.window
                                                action:@selector(performClose:)];
    closeButton.frame = NSMakeRect(290, 15, 80, 32);
    [content addSubview:closeButton];

    NSButton *saveButton = [NSButton buttonWithTitle:@"Save"
                                               target:self
                                               action:@selector(saveClicked:)];
    saveButton.frame = NSMakeRect(380, 15, 80, 32);
    saveButton.bezelStyle = NSBezelStyleRounded;
    saveButton.keyEquivalent = @"\r";
    [content addSubview:saveButton];
}

#pragma mark - Preferences

- (void)loadFromPreferences {
    [self.rows removeAllObjects];

    NSDictionary *map = [[QLCCConfiguration sharedDefaults]
        dictionaryForKey:kQLCCCustomLanguageMapKey];
    if (![map isKindOfClass:[NSDictionary class]]) map = @{};

    NSArray<NSString *> *keys =
        [map.allKeys sortedArrayUsingSelector:@selector(caseInsensitiveCompare:)];
    for (NSString *ext in keys) {
        if (![map[ext] isKindOfClass:[NSString class]]) continue;
        QLCCFileTypeRow *row = [QLCCFileTypeRow new];
        row.extension = ext;
        row.language = map[ext];
        [self.rows addObject:row];
    }
    [self rebuildRowsUI];
}

- (void)saveClicked:(id)sender {
    NSMutableDictionary<NSString *, NSString *> *map = [NSMutableDictionary dictionary];
    for (QLCCFileTypeRow *row in self.rows) {
        NSString *ext = [row.extension stringByTrimmingCharactersInSet:
                              [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        ext = [ext lowercaseString];
        if ([ext hasPrefix:@"."]) ext = [ext substringFromIndex:1];
        if (ext.length == 0) continue;
        map[ext] = row.language.length ? row.language : @"text";
    }

    NSUserDefaults *suite = [QLCCConfiguration sharedDefaults];
    [suite setObject:map forKey:kQLCCCustomLanguageMapKey];
    [suite synchronize];

    // Nudge Quick Look to re-read preferences for previews opened after this.
    NSTask *task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/qlmanage"];
    task.arguments = @[ @"-r" ];
    [task launchAndReturnError:nil];

    self.statusLabel.stringValue =
        [NSString stringWithFormat:@"Saved %lu mapping%@.",
            (unsigned long)map.count, map.count == 1 ? @"" : @"s"];
}

#pragma mark - Row management

- (void)addRowClicked:(id)sender {
    QLCCFileTypeRow *row = [QLCCFileTypeRow new];
    row.extension = @"";
    row.language = self.languages.firstObject ?: @"text";
    [self.rows addObject:row];
    [self rebuildRowsUI];
    self.statusLabel.stringValue = @"";
}

- (void)removeRowClicked:(NSButton *)sender {
    NSInteger idx = sender.tag;
    if (idx < 0 || (NSUInteger)idx >= self.rows.count) return;
    [self.rows removeObjectAtIndex:(NSUInteger)idx];
    [self rebuildRowsUI];
    self.statusLabel.stringValue = @"";
}

- (void)extensionFieldChanged:(NSTextField *)sender {
    NSInteger idx = sender.tag;
    if (idx < 0 || (NSUInteger)idx >= self.rows.count) return;
    self.rows[(NSUInteger)idx].extension = sender.stringValue;
}

- (void)controlTextDidChange:(NSNotification *)notification {
    NSTextField *field = notification.object;
    if ([field isKindOfClass:[NSTextField class]]) {
        [self extensionFieldChanged:field];
    }
}

- (void)languagePopupChanged:(NSPopUpButton *)sender {
    NSInteger idx = sender.tag;
    if (idx < 0 || (NSUInteger)idx >= self.rows.count) return;
    self.rows[(NSUInteger)idx].language = sender.titleOfSelectedItem ?: @"text";
}

/// Full rebuild rather than incremental diffing, simpler and safer than
/// trying to keep tags in sync with a mutating array by hand.
- (void)rebuildRowsUI {
    for (NSView *v in [self.rowsContainer.subviews copy]) {
        [v removeFromSuperview];
    }

    CGFloat width = self.rowsContainer.frame.size.width;
    NSUInteger count = self.rows.count;
    CGFloat totalHeight = MAX(self.scrollView.contentSize.height,
                               8 + count * kRowHeight + 8);
    self.rowsContainer.frame = NSMakeRect(0, 0, width, totalHeight);

    [self.rows enumerateObjectsUsingBlock:^(QLCCFileTypeRow *row, NSUInteger idx, BOOL *stop) {
        CGFloat rowY = 8 + idx * kRowHeight;

        NSTextField *extField = [[NSTextField alloc]
            initWithFrame:NSMakeRect(8, rowY, 110, kRowControlHeight)];
        extField.placeholderString = @"install";
        extField.stringValue = row.extension;
        extField.tag = (NSInteger)idx;
        extField.delegate = self;
        [self.rowsContainer addSubview:extField];

        NSTextField *arrow = [NSTextField labelWithString:@"→"];
        arrow.frame = NSMakeRect(122, rowY + 3, 18, 18);
        arrow.alignment = NSTextAlignmentCenter;
        [self.rowsContainer addSubview:arrow];

        NSPopUpButton *popup = [[NSPopUpButton alloc]
            initWithFrame:NSMakeRect(146, rowY, 228, kRowControlHeight)
                pullsDown:NO];
        [popup addItemsWithTitles:self.languages];
        if (![popup itemWithTitle:row.language]) {
            [popup addItemWithTitle:row.language.length ? row.language : @"text"];
        }
        [popup selectItemWithTitle:row.language];
        popup.tag = (NSInteger)idx;
        popup.target = self;
        popup.action = @selector(languagePopupChanged:);
        [self.rowsContainer addSubview:popup];

        NSButton *removeButton = [NSButton buttonWithTitle:@"–"
                                                      target:self
                                                      action:@selector(removeRowClicked:)];
        removeButton.frame = NSMakeRect(384, rowY, 28, kRowControlHeight);
        removeButton.tag = (NSInteger)idx;
        [self.rowsContainer addSubview:removeButton];
    }];
}

@end
