//
//  QLCodePreviewProvider.m
//  QLCodePreview
//

// Foundation only — no AppKit. The extension renders HTML replies; it
// needs nothing from AppKit, and skipping it avoids loading/registering
// the framework's classes in the extension process at launch.
@import Foundation;
@import UniformTypeIdentifiers;
@import QuickLookUI;

#import "QLCodePreviewProvider.h"
#import "QLCCConfiguration.h"
#import "QLCCTheme.h"
#import "QLCCHighlighter.h"
#import "QLCCLogging.h"

@interface QLCodePreviewProvider () <QLPreviewingController>
@end

@implementation QLCodePreviewProvider

/// Required by <QLPreviewingController>. Returns a data-based (HTML) preview
/// for the file described by `request`.
- (void)providePreviewForFileRequest:(QLFilePreviewRequest *)request
                   completionHandler:(void (^)(QLPreviewReply *_Nullable,
                                               NSError *_Nullable))handler {
    if (handler == NULL) {
        return;
    }

    // The pipeline creates several file-sized temporaries (escaped copies,
    // intermediate HTML, the UTF-8 data) and most Foundation methods used
    // along the way return autoreleased objects. Draining them here, at
    // the end of the request, keeps them from lingering in whatever pool
    // Quick Look owns on this thread until its next drain.
    @autoreleasepool {
        NSURL *fileURL = request.fileURL;
        if (fileURL == nil) {
            handler(nil, [self errorWithCode:NSFileReadInvalidFileNameError
                                      reason:@"No file URL in the preview request"]);
            return;
        }

        // Honour the optional maxFileSize cap the user configured (default: off).
        QLCCConfiguration *config = [QLCCConfiguration currentConfiguration];

        NSString *source = [self readSourceAtURL:fileURL configuration:config];
        if (source == nil) {
            handler(nil, [self errorWithCode:NSFileReadUnknownError
                                      reason:@"Could not read file as text"]);
            return;
        }

        QLCCTheme *theme = [QLCCTheme themeNamed:config.effectiveThemeName
                                       preferDark:config.isDarkMode];
        QLCCHighlighter *highlighter =
            [[QLCCHighlighter alloc] initWithTheme:theme configuration:config];

        NSString *pathExt = [self effectiveExtensionForURL:fileURL];
        NSString *html =
            [highlighter htmlPreviewForSource:source pathExtension:pathExt];
        if (html.length == 0) {
            // Fall back to a minimal document so the preview never fails hard.
            html = [@"<!DOCTYPE html><html><head><meta charset=\"UTF-8\">"
                    @"</head><body><pre></pre></body></html>" copy];
        }

        NSData *data = [html dataUsingEncoding:NSUTF8StringEncoding];
        NSString *title = fileURL.lastPathComponent ?: @"";

        // The content size is only a loading hint for HTML previews; Quick Look
        // reflows HTML to the panel. We mirror the legacy generator's 800x800.
        QLPreviewReply *reply = [[QLPreviewReply alloc]
            initWithDataOfContentType:UTTypeHTML
                         contentSize:CGSizeMake(800, 800)
                    dataCreationBlock:^NSData *_Nullable(QLPreviewReply *_Nonnull reply,
                                                         NSError **_Nullable error) {
            reply.title = title;
            return data;
        }];

        QLCCLog(@"Previewed %@ (%lu bytes) as %@",
                fileURL.lastPathComponent, (unsigned long)data.length, pathExt);
        handler(reply, nil);
    }
}

#pragma mark - Helpers

/// The "extension" QLCCHighlighter should key off, accounting for dotfiles.
///
/// `NSURL.pathExtension` returns "" for a single-dot hidden file like
/// ".bashrc" or ".gitconfig" — Foundation only treats a *second* dot as a
/// real extension separator (".mise.toml" still correctly yields "toml").
/// Several of QLCCHighlighter's built-in language mappings are exactly
/// these single-dot dotfile names (bashrc, zshrc, bash_profile, profile,
/// gitconfig, editorconfig, ebuild, eclass, ...), so without this fallback
/// they'd never resolve to anything but the plain "text" default.
- (NSString *)effectiveExtensionForURL:(NSURL *)url {
    NSString *ext = url.pathExtension;
    if (ext.length > 0) return ext;

    NSString *name = url.lastPathComponent ?: @"";
    if (name.length > 1 && [name hasPrefix:@"."]) {
        NSRange rest = NSMakeRange(1, name.length - 1);
        if ([name rangeOfString:@"." options:0 range:rest].location == NSNotFound) {
            return [name substringFromIndex:1];
        }
    }
    // No pathExtension and not a dotfile: fall back to the lowercased
    // filename so dotless convention files — Makefile, GNUmakefile,
    // Rakefile, Dockerfile, … — can resolve via the language map's
    // filename keys (e.g. "makefile" -> make). Unknown names simply miss
    // the map and stay "text", identical to the old `return @""`.
    return name.length > 0 ? name.lowercaseString : @"";
}

/// Read (up to `maxFileSize`) the file at `url` as text, auto-detecting the
/// encoding and falling back to UTF-8 (then lossy UTF-8) so we always return
/// *something* for binary-ish inputs.
- (nullable NSString *)readSourceAtURL:(NSURL *)url
                         configuration:(QLCCConfiguration *)config {
    // Honour the byte cap before we even try to decode. By default
    // (kQLCCDefaultMaxFileSize, applied in +currentConfiguration) this is a
    // ~4 MB safety net so a multi-MB file can't hang the Quick Look thread;
    // a user-set value overrides it, and 0 disables the cap.
    if (config.maxFileSize > 0) {
        NSError *attrErr = nil;
        NSDictionary *attrs = [NSFileManager.defaultManager attributesOfItemAtPath:url.path
                                                                             error:&attrErr];
        unsigned long long size = [attrs[NSFileSize] unsignedLongLongValue];
        if (size > config.maxFileSize) {
            // Read only the prefix we're allowed to show.
            return [self readPrefixAtURL:url maxBytes:(NSUInteger)config.maxFileSize];
        }
    }

    NSError *readErr = nil;
    NSStringEncoding used = 0;
    NSString *content = [NSString stringWithContentsOfURL:url
                                            usedEncoding:&used
                                                   error:&readErr];
    if (content) return content;

    content = [NSString stringWithContentsOfURL:url
                                       encoding:NSUTF8StringEncoding
                                          error:&readErr];
    if (content) return content;

    // Last resort: lossy UTF-8 so binary files still preview as text-ish.
    NSData *raw = [NSData dataWithContentsOfURL:url];
    if (raw == nil) return nil;
    return [[NSString alloc] initWithData:raw
                                 encoding:NSASCIIStringEncoding];
}

/// Read at most `maxBytes` bytes from `url` and decode as UTF-8 (lossy).
- (nullable NSString *)readPrefixAtURL:(NSURL *)url maxBytes:(NSUInteger)maxBytes {
    NSFileHandle *handle = [NSFileHandle fileHandleForReadingFromURL:url error:NULL];
    if (handle == nil) return nil;
    NSData *chunk = (maxBytes == 0) ? [handle readDataToEndOfFile]
                                    : [handle readDataOfLength:maxBytes];
    [handle closeFile];
    if (chunk.length == 0) return nil;
    // A prefix read (we hit the byte cap) can split a multi-byte UTF-8
    // sequence mid-code-point: strict UTF-8 decoding then returns nil and
    // we'd fall through to the lossy ASCII branch, producing mojibake
    // ("café" -> "cafÃ©") or failing outright. Walk the tail back to the
    // last complete UTF-8 sequence before decoding.
    if (maxBytes > 0 && chunk.length == maxBytes) {
        NSData *trimmed = [QLCodePreviewProvider trimTruncatedUTF8SuffixFromData:chunk];
        if (trimmed) chunk = trimmed;
    }
    // Try UTF-8, then fall back to lossy ASCII.
    return [[NSString alloc] initWithData:chunk encoding:NSUTF8StringEncoding]
        ?: [[NSString alloc] initWithData:chunk encoding:NSASCIIStringEncoding];
}

/// Drop trailing bytes so `data` ends on a complete UTF-8 code-point
/// boundary. Returns nil when no trim is needed (the data already ends on a
/// complete sequence — including plain ASCII — or is empty). Only the
/// truncation case is handled; genuinely malformed bytes are left for the
/// caller's UTF-8/ASCII fallback to deal with.
+ (nullable NSData *)trimTruncatedUTF8SuffixFromData:(NSData *)data {
    NSUInteger len = data.length;
    if (len == 0) return nil;
    const uint8_t *bytes = data.bytes;
    if ((bytes[len - 1] & 0x80) == 0) return nil;  // ends on ASCII: complete

    // Find the lead byte of the final sequence, skipping 10xxxxxx
    // continuation bytes (at most 3, since UTF-8 sequences are <= 4 bytes).
    NSUInteger start = len - 1;
    while (start > 0 && (bytes[start - 1] & 0xC0) == 0x80 && (len - start) < 4) {
        start--;
    }
    uint8_t lead = bytes[start];
    NSUInteger expected = 0;
    if      ((lead & 0xE0) == 0xC0) expected = 2;  // 110xxxxx
    else if ((lead & 0xF0) == 0xE0) expected = 3;  // 1110xxxx
    else if ((lead & 0xF8) == 0xF0) expected = 4;  // 11110xxx
    NSUInteger actual = len - start;
    // Only trim an *incomplete* (truncated) sequence; a complete one (or an
    // invalid lead byte we can't reason about) is left untouched.
    if (expected == 0 || expected <= actual) return nil;
    return [data subdataWithRange:NSMakeRange(0, start)];
}

- (NSError *)errorWithCode:(NSInteger)code reason:(NSString *)reason {
    return [NSError errorWithDomain:NSCocoaErrorDomain
                                code:code
                            userInfo:@{NSLocalizedDescriptionKey : reason}];
}

@end
