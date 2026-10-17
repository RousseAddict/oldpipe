// libCoreFoundationCompat — CoreFoundation compatibility shim for iOS 5.
//
// Swift 5.1.5's libswiftFoundation imports NSURLPathKey, which iOS 5's
// CoreFoundation does not export (the key arrived with OS X 10.8 / iOS 8).
// This dylib re-exports CoreFoundation so everything iOS 5 does have passes
// straight through, and adds the one missing constant. libswiftFoundation's
// LC_LOAD_DYLIB on CoreFoundation is then repointed here with
// install_name_tool -change, preserving its two-level-namespace ordinals.
//
// The constant's VALUE is "_NSURLPathKey" (with the leading underscore) — that
// is the literal Apple stores in the CFURL property table, not the symbol name.

#import <Foundation/Foundation.h>

NSString * const NSURLPathKey = @"_NSURLPathKey";
