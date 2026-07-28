//
//  QLCCConfiguration.h
//  QLCodePreview
//
//  Reads the user's rendering preferences from a shared App Group preference
//  suite (kQLCCAppGroup). Both the host app (its Preferences and Custom File
//  Types windows) and the Quick Look preview extension read and write
//  through the same NSUserDefaults suite, so the data lives in the App Group
//  container both processes are entitled to. We also honour the system 
//  Dark Mode setting.
//
//  The extension is sandboxed; the host is not. Both carry the
//  com.apple.security.application-groups entitlement for kQLCCAppGroup, which
//  is what lets NSUserDefaults(suiteName:) resolve to the shared container
//  from either side.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// The App Group identifier whose NSUserDefaults suite stores all rendering
/// preferences, shared between the host app and the Quick Look extension via
/// +[QLCCConfiguration sharedDefaults].
extern NSString *const kQLCCAppGroup;

/// Preference key for the user's custom extension→language overrides (see
/// QLCCConfiguration.customLanguageMap below). Shared with the host app's
/// "Custom File Types" UI, which writes to this same key/suite so the
/// override takes effect immediately, no rebuild required.
extern NSString *const kQLCCCustomLanguageMapKey;

/// Built-in safety-net byte cap applied to previews when the user hasn't set
/// `maxFileSize`. Large enough to show realistic source files
/// in full, small enough that a stray multi-MB/minified file can't hang the
/// Quick Look preview thread. A user setting `maxFileSize = 0` explicitly
/// disables any cap (power-user escape hatch).
extern const unsigned long long kQLCCDefaultMaxFileSize;

@interface QLCCConfiguration : NSObject

/// Font family name (default: `Menlo`).
@property (nonatomic, copy) NSString *font;

/// Font size in points (default: `10`).
@property (nonatomic) CGFloat fontSize;

/// Theme name to use in light mode (default: `edit-xcode`).
@property (nonatomic, copy) NSString *lightTheme;

/// Theme name to use in dark mode (default: `darkplus`).
@property (nonatomic, copy) NSString *darkTheme;

/// `YES` when the system appearance is Dark (honours `AppleInterfaceStyle`).
@property (nonatomic, getter=isDarkMode) BOOL darkMode;

/// `YES` to prefix each line with its line number (highlight `-l` flag).
@property (nonatomic) BOOL showLineNumbers;

/// Horizontal gap, in points, between the line-number gutter and the code
/// (default: `10`). Only meaningful when `showLineNumbers` is `YES`.
@property (nonatomic) CGFloat lineNumberGutterWidth;

/// Number of spaces to expand each tab to (highlight `-t` flag, default `4`).
@property (nonatomic) NSUInteger tabWidth;

/// `YES` to soft-wrap long lines (highlight `-W` flag).
@property (nonatomic) BOOL wrapLines;

/// Soft cap, in bytes, on how much of a file we are willing to render. A
/// value of 0 means "no cap" (highlight `maxFileSize` setting). When the
/// user hasn't set one, `currentConfiguration` defaults to
/// `kQLCCDefaultMaxFileSize` (a built-in safety net).
@property (nonatomic) unsigned long long maxFileSize;

/// User-defined extension→language overrides, e.g. `{"install": "php"}`.
/// Keys are lowercased file extensions with no leading dot; values must be
/// one of QLCCHighlighter.supportedLanguageNames (unrecognised values are
/// harmless - QLCCHighlighter falls back to plain text). Set from the host
/// app's "Custom File Types" window; consulted before the built-in
/// extension map in QLCCHighlighter.
@property (nonatomic, copy) NSDictionary<NSString *, NSString *> *customLanguageMap;

/// Convenience: the theme name that should actually be used given the
/// current appearance.
- (NSString *)effectiveThemeName;

/// The shared App Group preference suite (NSUserDefaults initialised with
/// kQLCCAppGroup). Both the host app and the sandboxed Quick Look extension
/// read and write rendering preferences through this, so the data is visible
/// to both without any foreign-domain entitlement.
+ (NSUserDefaults *)sharedDefaults;

/// Build a configuration from the current user preferences + appearance.
+ (instancetype)currentConfiguration;

@end

NS_ASSUME_NONNULL_END
