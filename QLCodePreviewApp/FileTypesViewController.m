//
//  FileTypesViewController.m
//  QLCodePreview (host app)
//

#import "FileTypesViewController.h"
#import "QLCCConfiguration.h"
#import "QLCCFlippedView.h"
#import "QLCCHighlighter.h"

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

@interface QLCCFileTypesViewController () <NSTextFieldDelegate>
@property (nonatomic, strong) NSMutableArray<QLCCFileTypeRow *> *rows;
@property (nonatomic, copy) NSArray<NSString *> *languages;
@property (nonatomic, strong) NSScrollView *scrollView;
@property (nonatomic, strong) QLCCFlippedView *rowsContainer;
@end

@implementation QLCCFileTypesViewController

- (instancetype)initWithSize:(NSSize)size {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _rows = [NSMutableArray array];
        _languages = [QLCCHighlighter supportedLanguageNames];
        self.view = [[QLCCFlippedView alloc]
            initWithFrame:NSMakeRect(0, 0, size.width, size.height)];
        [self buildUI];
        [self loadFromPreferences];
    }
    return self;
}

#pragma mark - UI construction (fixed frames; window is not resizable)

- (void)buildUI {
    NSView *content = self.view;
    CGFloat w = content.bounds.size.width;
    CGFloat h = content.bounds.size.height;

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
    heading.frame = NSMakeRect(20, 14, w - 40, 100);
    [content addSubview:heading];

    NSTextField *extHeader = [NSTextField labelWithString:@"Extension"];
    extHeader.font = [NSFont boldSystemFontOfSize:11];
    extHeader.textColor = [NSColor labelColor];
    extHeader.frame = NSMakeRect(28, 122, 110, 14);
    [content addSubview:extHeader];

    NSTextField *parserHeader = [NSTextField labelWithString:@"Parser"];
    parserHeader.font = [NSFont boldSystemFontOfSize:11];
    parserHeader.textColor = [NSColor labelColor];
    parserHeader.frame = NSMakeRect(166, 122, 228, 14);
    [content addSubview:parserHeader];

    self.scrollView = [[NSScrollView alloc]
        initWithFrame:NSMakeRect(20, 144, w - 40, h - 144 - 46)];
    self.scrollView.hasVerticalScroller = YES;
    self.scrollView.borderType = NSBezelBorder;
    self.scrollView.autoresizingMask = NSViewNotSizable;

    self.rowsContainer = [[QLCCFlippedView alloc]
        initWithFrame:NSMakeRect(0, 0, self.scrollView.contentSize.width, 0)];
    self.scrollView.documentView = self.rowsContainer;
    [content addSubview:self.scrollView];

    NSButton *addButton = [NSButton buttonWithTitle:@"+ Add"
                                              target:self
                                              action:@selector(addRowClicked:)];
    addButton.frame = NSMakeRect(20, h - 34, 80, 28);
    [content addSubview:addButton];
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

- (NSString *)save {
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

    return [NSString stringWithFormat:@"%lu mapping%@",
        (unsigned long)map.count, map.count == 1 ? @"" : @"s"];
}

#pragma mark - Row management

- (void)addRowClicked:(id)sender {
    QLCCFileTypeRow *row = [QLCCFileTypeRow new];
    row.extension = @"";
    row.language = self.languages.firstObject ?: @"text";
    [self.rows addObject:row];
    [self rebuildRowsUI];
}

- (void)removeRowClicked:(NSButton *)sender {
    NSInteger idx = sender.tag;
    if (idx < 0 || (NSUInteger)idx >= self.rows.count) return;
    [self.rows removeObjectAtIndex:(NSUInteger)idx];
    [self rebuildRowsUI];
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
            initWithFrame:NSMakeRect(146, rowY, width - 146 - 44, kRowControlHeight)
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
        removeButton.frame = NSMakeRect(width - 32, rowY, 28, kRowControlHeight);
        removeButton.tag = (NSInteger)idx;
        [self.rowsContainer addSubview:removeButton];
    }];
}

@end
