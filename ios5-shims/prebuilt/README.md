# Vendored Swift runtime for iOS 5

`libswiftCore-ios5.dylib` is **not built by this repository**. It is taken from a
third-party release, and this file records exactly what it is and why we ship it.

| | |
|---|---|
| File | `libswiftCore-ios5.dylib` |
| Size | 5,483,248 bytes, armv7 (thin) |
| LC_UUID | `1DB65335-0B58-36A9-A0B0-45ED222433DD` |
| SHA-256 | `6f4e16a746b22dcda78f1d23d6fb231683bbc2c4c0c5989fcb766a3b041f26bf` |
| Exports | 13,077 symbols |
| Source | `oldpipe-ios5.ipa`, from the `ios5-v1.0` release of https://github.com/zirk-a/oldpipe |

## Why a third-party runtime at all

Swift tags every one of its classes by setting the low bit of `class_t.data`.
Every Objective-C runtime from iOS 6 onwards masks that bit off before
dereferencing the pointer; **objc4-493.9, the one iOS 5 ships, does not**
(`CLASS_FAST_FLAGS_VIA_RW_DATA` is 0). It dies inside its own initialiser on the
first class it walks. `strip-swift-class-bit.py` clears the bit to get past that.

Clearing it creates the opposite problem: the Swift runtime tests the same bit to
decide whether a class is a Swift class, so stock libswiftCore then treats our
classes as pure Objective-C and aborts in
`swift_dynamicCastClassImpl` (`Casting.cpp:279`).

One field, two runtimes, opposite expectations. Three ways out were tried:

1. **Re-set the bit at runtime**, after libobjc has walked the classes. Fails:
   Objective-C realizes classes lazily, so this only defers the same bad pointer
   to the first time UIKit touches a view controller.
2. **Hide the runtime's classes from Objective-C** instead of stripping them, by
   zeroing `__objc_classlist`. Fails: Swift bridges its own objects into
   Objective-C (`_SwiftNativeNSString` and friends), so those classes must be
   realizable. Two variants, both SIGBUS before the app delegate is created.
3. **Binary-patch stock libswiftCore.** Not possible: the test is
   `Data & __swift_classIsSwiftMask`, inlined at hundreds of sites, and no value
   of that exported global works — 0 makes every Swift class look Objective-C,
   and anything matching a real pointer makes `UIView` look like a Swift class.

This build is a from-source rebuild of the Swift 5.1.5 standard library that
solves it properly, with a side table: a `__swift5_ios5cls` section plus
`swift_ios5_registerSwiftClass` / `swift_ios5_isSwiftClass` /
`swift_ios5_registeredClassCount`, driven by a dyld add-image callback
(`addImageIOS5DualView`). Swift learns which classes are Swift classes without
reading the bit, so the bit can stay clear for Objective-C.

## Licence and provenance

The Swift standard library is Apache-2.0 with the Runtime Library Exception. The
author's modifications to it are not stated anywhere in their repository or
release notes. We did not build this and cannot audit it fully.

Scanned before use: no `dlopen`, `exec` or `system` imports, and the only
URL-shaped string in it is the Apple plist DTD. Its build paths are still
embedded and name an on-device Swift toolchain
(`.../r4r6d32-ios5-private-runtime/r32d15r5b11-native-swift515-compiler-foundation/`).

## Replacing it

This is the one borrowed piece; everything else in the port is ours. To remove
the dependency, build the 5.1.5 standard library for armv7/iphoneos with a
minimum version of 5.0, patch `ClassMetadata::isTypeMetadata()` to consult a side
table rather than the bit, and extend `strip-swift-class-bit.py` to emit that
table as it clears each bit.

## Verifying

```
nm -arch armv7 -gU libswiftCore-ios5.dylib | grep -c swift_ios5   # 3
shasum -a 256 libswiftCore-ios5.dylib
```
