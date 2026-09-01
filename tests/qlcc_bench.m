//
//  qlcc_bench.m
//  Steady-state render benchmark for QLCCHighlighter. Not a test — it
//  makes no pass/fail assertions. Compiled by build.sh alongside the
//  self-tests but only RUN when QLCC_BENCH=1 is set in the environment,
//  so `QLCC_BENCH=1 ./build.sh` prints render timings for the two
//  workloads that matter: code-heavy and comment-heavy 2 MB sources.
//
//  Numbers are workload- and machine-dependent; compare runs against the
//  same binary family, before/after a change (see docs/PERF-AUDIT-TODO.md
//  for the history of measured deltas).
//
#import <Foundation/Foundation.h>
#import "QLCCConfiguration.h"
#import "QLCCTheme.h"
#import "QLCCHighlighter.h"

static NSString *makeSource(NSArray<NSString *> *lines, NSUInteger targetBytes) {
    NSMutableString *s = [NSMutableString stringWithCapacity:targetBytes];
    while (s.length < targetBytes) {
        for (NSString *l in lines) {
            [s appendFormat:@"%@\n", l];
            if (s.length >= targetBytes) break;
        }
    }
    return s;
}

static double bench(NSString *label, NSString *source) {
    QLCCConfiguration *cfg = [QLCCConfiguration currentConfiguration];
    cfg.showLineNumbers = NO;
    cfg.wrapLines = NO;
    QLCCTheme *theme = [QLCCTheme themeNamed:@"darkplus" preferDark:YES];
    QLCCHighlighter *h = [[QLCCHighlighter alloc] initWithTheme:theme configuration:cfg];
    (void)[h htmlPreviewForSource:source pathExtension:@"m"];  // warm caches
    double best = DBL_MAX;
    for (int i = 0; i < 3; i++) {
        double t0 = CFAbsoluteTimeGetCurrent();
        (void)[h htmlPreviewForSource:source pathExtension:@"m"];
        double ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000.0;
        if (ms < best) best = ms;
    }
    printf("%-28s %7.1f ms\n", label.UTF8String, best);
    return best;
}

int main(void) {
    @autoreleasepool {
        NSArray *code = @[
            @"    // Set up the window controller and register observers.",
            @"    NSString *title = @\"QLCodePreview - settings\";",
            @"    if (self.window == nil && count > 0x1F && ratio >= 0.75f) {",
            @"    for (NSUInteger i = 0; i < 128; i++) total += (i * 3) % 7;",
            @"",
        ];
        NSArray *comment = @[
            @"    /* Configure the preview window: size, position, and the",
            @"       set of file types the handler should claim. */",
            @"    int x = 1; /* inline note */ int y = 2;",
            @"    NSString *s = @\"value\"; // trailing note",
            @"    /* Another multi-line comment block that spans a couple of",
            @"       lines to give the lazy star something to chew on. */",
            @"    if (x > 0 && y < 10) { total += x * y; }",
        ];
        bench(@"code-heavy 2 MB", makeSource(code, 2 * 1024 * 1024));
        bench(@"comment-heavy 2 MB", makeSource(comment, 2 * 1024 * 1024));
        return 0;
    }
}
