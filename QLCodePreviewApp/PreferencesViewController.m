//
//  PreferencesViewController.m
//  QLCodePreview (host app)
//

#import "PreferencesViewController.h"
#import "QLCCConfiguration.h"
#import "QLCCFlippedView.h"
#import "QLCCTheme.h"

@interface QLCCPreferencesViewController ()
@property (nonatomic, strong) NSComboBox *fontField;
@property (nonatomic, strong) NSTextField *fontSizeField;
@property (nonatomic, strong) NSStepper *fontSizeStepper;
@property (nonatomic, strong) NSPopUpButton *lightThemePopup;
@property (nonatomic, strong) NSPopUpButton *darkThemePopup;
@property (nonatomic, strong) NSButton *lineNumbersCheckbox;
@property (nonatomic, strong) NSTextField *gutterWidthField;
@property (nonatomic, strong) NSStepper *gutterWidthStepper;
@property (nonatomic, strong) NSButton *wrapCheckbox;
@property (nonatomic, strong) NSTextField *tabWidthField;
@property (nonatomic, strong) NSStepper *tabWidthStepper;
@property (nonatomic, strong) NSTextField *maxFileSizeField;
@end

@implementation QLCCPreferencesViewController

- (instancetype)initWithSize:(NSSize)size {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
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
    CGFloat y = 14;
    const CGFloat rowHeight = 34;
    const CGFloat labelX = 20;
    const CGFloat labelW = 130;
    const CGFloat controlX = 156;

    NSTextField *heading = [NSTextField wrappingLabelWithString:
        @"Changes take effect immediately for new previews — no rebuild "
        @"needed."];
    heading.font = [NSFont systemFontOfSize:12];
    heading.textColor = [NSColor secondaryLabelColor];
    heading.frame = NSMakeRect(labelX, y, w - 40, 32);
    [content addSubview:heading];
    y += 44;

    // Font
    NSTextField *fontLabel = [NSTextField labelWithString:@"Font:"];
    fontLabel.frame = NSMakeRect(labelX, y + 3, labelW, 20);
    [content addSubview:fontLabel];
    self.fontField = [[NSComboBox alloc] initWithFrame:NSMakeRect(controlX, y, 280, 24)];
    [self.fontField addItemsWithObjectValues:@[
        @"Menlo", @"Monaco", @"SF Mono", @"Courier New", @"Consolas",
        @"Fira Code", @"JetBrains Mono", @"Source Code Pro", @"Andale Mono",
    ]];
    self.fontField.completes = NO;
    [content addSubview:self.fontField];
    y += rowHeight;

    // Font size
    NSTextField *sizeLabel = [NSTextField labelWithString:@"Font size:"];
    sizeLabel.frame = NSMakeRect(labelX, y + 3, labelW, 20);
    [content addSubview:sizeLabel];
    self.fontSizeField = [[NSTextField alloc] initWithFrame:NSMakeRect(controlX, y, 50, 24)];
    self.fontSizeField.formatter = [self integerFormatterWithMin:6 max:72];
    [content addSubview:self.fontSizeField];
    self.fontSizeStepper = [[NSStepper alloc] initWithFrame:NSMakeRect(controlX + 54, y, 19, 24)];
    self.fontSizeStepper.minValue = 6;
    self.fontSizeStepper.maxValue = 72;
    self.fontSizeStepper.increment = 1;
    self.fontSizeStepper.target = self;
    self.fontSizeStepper.action = @selector(fontSizeStepperChanged:);
    [content addSubview:self.fontSizeStepper];
    y += rowHeight;

    // Light theme
    NSTextField *lightLabel = [NSTextField labelWithString:@"Light theme:"];
    lightLabel.frame = NSMakeRect(labelX, y + 3, labelW, 20);
    [content addSubview:lightLabel];
    self.lightThemePopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(controlX, y, 220, 24) pullsDown:NO];
    [self.lightThemePopup addItemsWithTitles:[QLCCTheme lightThemeNames]];
    [content addSubview:self.lightThemePopup];
    y += rowHeight;

    // Dark theme
    NSTextField *darkLabel = [NSTextField labelWithString:@"Dark theme:"];
    darkLabel.frame = NSMakeRect(labelX, y + 3, labelW, 20);
    [content addSubview:darkLabel];
    self.darkThemePopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(controlX, y, 220, 24) pullsDown:NO];
    [self.darkThemePopup addItemsWithTitles:[QLCCTheme darkThemeNames]];
    [content addSubview:self.darkThemePopup];
    y += rowHeight;

    // Show line numbers
    self.lineNumbersCheckbox = [NSButton checkboxWithTitle:@"Show line numbers"
                                                      target:nil
                                                      action:NULL];
    self.lineNumbersCheckbox.frame = NSMakeRect(controlX, y, 260, 20);
    [content addSubview:self.lineNumbersCheckbox];
    y += rowHeight;

    // Gutter width (gap between line numbers and code)
    NSTextField *gutterLabel = [NSTextField wrappingLabelWithString:@"Line number gap (px):"];
    gutterLabel.frame = NSMakeRect(labelX, y - 6, labelW, 34);
    [content addSubview:gutterLabel];
    self.gutterWidthField = [[NSTextField alloc] initWithFrame:NSMakeRect(controlX, y, 50, 24)];
    self.gutterWidthField.formatter = [self integerFormatterWithMin:0 max:200];
    [content addSubview:self.gutterWidthField];
    self.gutterWidthStepper = [[NSStepper alloc] initWithFrame:NSMakeRect(controlX + 54, y, 19, 24)];
    self.gutterWidthStepper.minValue = 0;
    self.gutterWidthStepper.maxValue = 200;
    self.gutterWidthStepper.increment = 1;
    self.gutterWidthStepper.target = self;
    self.gutterWidthStepper.action = @selector(gutterWidthStepperChanged:);
    [content addSubview:self.gutterWidthStepper];
    y += rowHeight;

    // Wrap long lines
    self.wrapCheckbox = [NSButton checkboxWithTitle:@"Wrap long lines"
                                               target:nil
                                               action:NULL];
    self.wrapCheckbox.frame = NSMakeRect(controlX, y, 260, 20);
    [content addSubview:self.wrapCheckbox];
    y += rowHeight;

    // Tab width
    NSTextField *tabLabel = [NSTextField labelWithString:@"Tab width:"];
    tabLabel.frame = NSMakeRect(labelX, y + 3, labelW, 20);
    [content addSubview:tabLabel];
    self.tabWidthField = [[NSTextField alloc] initWithFrame:NSMakeRect(controlX, y, 50, 24)];
    self.tabWidthField.formatter = [self integerFormatterWithMin:1 max:16];
    [content addSubview:self.tabWidthField];
    self.tabWidthStepper = [[NSStepper alloc] initWithFrame:NSMakeRect(controlX + 54, y, 19, 24)];
    self.tabWidthStepper.minValue = 1;
    self.tabWidthStepper.maxValue = 16;
    self.tabWidthStepper.increment = 1;
    self.tabWidthStepper.target = self;
    self.tabWidthStepper.action = @selector(tabWidthStepperChanged:);
    [content addSubview:self.tabWidthStepper];
    y += rowHeight;

    // Max file size
    NSTextField *maxLabel = [NSTextField wrappingLabelWithString:@"Max file size (MB, 0 = no limit):"];
    maxLabel.frame = NSMakeRect(labelX, y - 6, labelW, 34);
    [content addSubview:maxLabel];
    self.maxFileSizeField = [[NSTextField alloc] initWithFrame:NSMakeRect(controlX, y, 70, 24)];
    self.maxFileSizeField.formatter = [self integerFormatterWithMin:0 max:4096];
    [content addSubview:self.maxFileSizeField];
    y += rowHeight;

    // First-run troubleshooting hint (this pane is the app's front door).
    NSTextField *hint = [NSTextField wrappingLabelWithString:
        @"If previews don’t appear at all, enable “QLCodePreview Extension” "
        @"in System Settings → General → Login Items & Extensions → "
        @"Quick Look."];
    hint.font = [NSFont systemFontOfSize:11];
    hint.textColor = [NSColor secondaryLabelColor];
    hint.frame = NSMakeRect(labelX, y + 6, w - 40, 44);
    [content addSubview:hint];
}

- (NSNumberFormatter *)integerFormatterWithMin:(NSInteger)min max:(NSInteger)max {
    NSNumberFormatter *f = [[NSNumberFormatter alloc] init];
    f.numberStyle = NSNumberFormatterNoStyle;
    f.minimum = @(min);
    f.maximum = @(max);
    f.allowsFloats = NO;
    return f;
}

- (void)fontSizeStepperChanged:(NSStepper *)sender {
    self.fontSizeField.integerValue = sender.integerValue;
}

- (void)tabWidthStepperChanged:(NSStepper *)sender {
    self.tabWidthField.integerValue = sender.integerValue;
}

- (void)gutterWidthStepperChanged:(NSStepper *)sender {
    self.gutterWidthField.integerValue = sender.integerValue;
}

#pragma mark - Preferences

- (void)loadFromPreferences {
    QLCCConfiguration *config = [QLCCConfiguration currentConfiguration];

    self.fontField.stringValue = config.font;
    self.fontSizeField.integerValue = (NSInteger)config.fontSize;
    self.fontSizeStepper.integerValue = (NSInteger)config.fontSize;

    if (![self.lightThemePopup itemWithTitle:config.lightTheme]) {
        [self.lightThemePopup addItemWithTitle:config.lightTheme];
    }
    [self.lightThemePopup selectItemWithTitle:config.lightTheme];

    if (![self.darkThemePopup itemWithTitle:config.darkTheme]) {
        [self.darkThemePopup addItemWithTitle:config.darkTheme];
    }
    [self.darkThemePopup selectItemWithTitle:config.darkTheme];

    self.lineNumbersCheckbox.state = config.showLineNumbers ? NSControlStateValueOn : NSControlStateValueOff;
    self.gutterWidthField.integerValue = (NSInteger)config.lineNumberGutterWidth;
    self.gutterWidthStepper.integerValue = (NSInteger)config.lineNumberGutterWidth;
    self.wrapCheckbox.state = config.wrapLines ? NSControlStateValueOn : NSControlStateValueOff;

    self.tabWidthField.integerValue = (NSInteger)config.tabWidth;
    self.tabWidthStepper.integerValue = (NSInteger)config.tabWidth;

    unsigned long long mb = config.maxFileSize / (1024ULL * 1024ULL);
    self.maxFileSizeField.integerValue = (NSInteger)mb;
}

- (NSString *)save {
    NSString *font = [self.fontField.stringValue stringByTrimmingCharactersInSet:
                           [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (font.length == 0) font = @"Menlo";
    NSUserDefaults *suite = [QLCCConfiguration sharedDefaults];

    [suite setObject:font forKey:@"font"];

    NSInteger fontSize = self.fontSizeField.integerValue;
    if (fontSize < 6) fontSize = 10;
    [suite setObject:@(fontSize) forKey:@"fontSizePoints"];

    NSString *lightTheme = self.lightThemePopup.titleOfSelectedItem ?: @"edit-xcode";
    NSString *darkTheme = self.darkThemePopup.titleOfSelectedItem ?: @"darkplus";
    [suite setObject:lightTheme forKey:@"lightTheme"];
    [suite setObject:darkTheme forKey:@"darkTheme"];
    // Clear any legacy pinned "hlTheme" override — otherwise it silently
    // shadows the light/dark choices above (see QLCCConfiguration).
    [suite removeObjectForKey:@"hlTheme"];

    NSInteger tabWidth = self.tabWidthField.integerValue;
    if (tabWidth < 1) tabWidth = 4;
    BOOL lineNumbers = self.lineNumbersCheckbox.state == NSControlStateValueOn;
    BOOL wrap = self.wrapCheckbox.state == NSControlStateValueOn;
    NSMutableString *flags = [NSMutableString string];
    if (lineNumbers) [flags appendString:@"-l "];
    if (wrap) [flags appendString:@"-W "];
    [flags appendFormat:@"-t %ld ", (long)tabWidth];
    [suite setObject:flags forKey:@"extraHLFlags"];

    NSInteger gutterWidth = self.gutterWidthField.integerValue;
    if (gutterWidth < 0) gutterWidth = 10;
    [suite setObject:@(gutterWidth) forKey:@"lineNumberGutterWidth"];

    NSInteger mb = self.maxFileSizeField.integerValue;
    if (mb < 0) mb = 0;
    unsigned long long bytes = (unsigned long long)mb * 1024ULL * 1024ULL;
    [suite setObject:@(bytes) forKey:@"maxFileSize"];

    [suite synchronize];
    return @"Saved";
}

@end
