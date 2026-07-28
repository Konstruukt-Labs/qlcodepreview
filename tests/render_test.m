//
//  render_test.m
//  Standalone test harness that drives the real QLCCHighlighter against a
//  file on disk and prints the generated HTML. Used to validate the
//  tokeniser/renderer without spinning up Quick Look.
//
#import <Foundation/Foundation.h>
#import "QLCCConfiguration.h"
#import "QLCCTheme.h"
#import "QLCCHighlighter.h"

int main(int argc, char *argv[]) {
    @autoreleasepool {
        if (argc < 2) {
            fprintf(stderr, "usage: render_test <file> [theme] [dark=1]\n");
            return 2;
        }
        NSURL *url = [NSURL fileURLWithPath:@(argv[1])];
        NSStringEncoding enc = 0;
        NSString *src = [NSString stringWithContentsOfURL:url
                                            usedEncoding:&enc error:NULL];
        if (!src) {
            src = [NSString stringWithContentsOfURL:url
                                          encoding:NSUTF8StringEncoding error:NULL];
        }
        if (!src) {
            fprintf(stderr, "could not read %s\n", argv[1]);
            return 1;
        }

        QLCCConfiguration *cfg = [QLCCConfiguration currentConfiguration];
        // Environment overrides (handy for testing without touching defaults):
        char *eLn = getenv("QLCC_LN");   if (eLn) cfg.showLineNumbers = atoi(eLn) != 0;
        char *eTab = getenv("QLCC_TAB"); if (eTab) cfg.tabWidth = (NSUInteger)MAX(1, atoi(eTab));
        char *eWrap = getenv("QLCC_WRAP"); if (eWrap) cfg.wrapLines = atoi(eWrap) != 0;
        QLCCTheme *theme = [QLCCTheme themeNamed:(argc > 2 ? @(argv[2]) : cfg.effectiveThemeName)
                                      preferDark:(argc > 3 ? YES : cfg.isDarkMode)];
        QLCCHighlighter *h = [[QLCCHighlighter alloc] initWithTheme:theme
                                                      configuration:cfg];
        NSString *html = [h htmlPreviewForSource:src
                                   pathExtension:url.pathExtension];
        fputs(html.UTF8String, stdout);
        fputc('\n', stdout);
        return 0;
    }
}
