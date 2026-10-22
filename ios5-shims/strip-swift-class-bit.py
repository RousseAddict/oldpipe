#!/usr/bin/env python3
"""
strip-swift-class-bit.py — clear Swift's "is-Swift" tag bit from every ObjC
class structure in a thin 32-bit Mach-O, so iOS 5's Objective-C runtime can
read them.

WHY THIS EXISTS
Swift 5 stores `class_ro_t* | 1` in class_t.data, the low bit marking the class
as Swift. Every runtime from iOS 6 onwards masks that bit off before using the
pointer. iOS 5's does not. From objc4-493.9, which is the iOS 5 runtime:

    runtime/objc-runtime-new.h:278
        #define CLASS_FAST_FLAGS_VIA_RW_DATA 0
    runtime/objc-runtime-new.h:287
        class_rw_t *data() const {
        #if CLASS_FAST_FLAGS_VIA_RW_DATA
            return (class_rw_t *)(data_NEVER_USE & ~3UL);
        #else
            return (class_rw_t *)data_NEVER_USE;     // <- no mask
        #endif
        }

The masking accessor is present but compiled out; it is switched on in objc4-532
(iOS 6), which is exactly why our iOS 6/7/8 builds have never shown this.

The consequence is immediate rather than subtle. objc-os.m:780 `_objc_init` is a
library constructor, and it registers map_images with batch=1, so dyld walks
every already-loaded image's classes from inside that constructor. The first
statement of that loop (objc-runtime-new.mm:2792) is `getName(classlist[i])`,
and getName on an unrealized class does:

    return ((const class_ro_t *)cls->data())->name;

With the bit still set that reads `name` through `ro + 1`, i.e. one byte off, so
it yields roughly (name >> 8) — a few KB into __PAGEZERO on any image this size.
That pointer goes straight to strdup and the process dies with SIGSEGV inside
libobjc's initializer, before a single line of app code. It is also why the
OBJC_PRINT_* variables printed nothing: libobjc never got far enough.

zirk-a's working iOS 5 build has this bit cleared on all 47 of its classes,
which is what put us onto it.

CAVEAT
Stripping alone is not the whole story. The Swift runtime tests that same bit to
decide whether a class is a Swift class, so a stripped binary needs a
libswiftCore that recovers Swift-ness some other way. zirk-a's rebuilt
libswiftCore does exactly that, via __swift5_ios5cls and
swift_ios5_registerSwiftClass / initializeIOS5DualViewClassLookup, registering
images through a dyld add-image callback. Run this against a stock libswiftCore
and the launch will get past _objc_init and then misbehave later.

Idempotent: re-running on an already-stripped binary reports 0 changes.
Must run BEFORE codesigning, since it rewrites bytes in __DATA.
"""
import struct, sys

LC_SEGMENT = 0x1
CLASS_T_DATA_OFF = 16          # isa, superclass, cache, vtable, data
CLASS_T_ISA_OFF  = 0           # isa points at the metaclass, same layout


def slices(data):
    """File offsets of every 32-bit little-endian Mach-O in the file.

    The app binary is thin armv7, but the Swift runtime dylibs we ship are fat
    (armv7 + armv7s + arm64). Only armv7 is ever used on an iPhone 4, but every
    32-bit slice is patched anyway: it costs nothing and avoids leaving a
    half-treated binary behind."""
    magic = struct.unpack_from('>I', data, 0)[0]
    if magic in (0xcafebabe, 0xbebafeca):                 # FAT_MAGIC / swapped
        n = struct.unpack_from('>I', data, 4)[0]
        out = []
        for i in range(n):
            off, size = struct.unpack_from('>II', data, 8 + i * 20 + 8)
            if struct.unpack_from('<I', data, off)[0] == 0xfeedface:
                out.append(off)
        return out
    if struct.unpack_from('<I', data, 0)[0] == 0xfeedface:
        return [0]
    return []                                              # 64-bit only: nothing to do


def parse(data, base=0):
    ncmds = struct.unpack_from('<I', data, base + 16)[0]
    off, segs, sects = base + 28, [], {}
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack_from('<II', data, off)
        if cmd == LC_SEGMENT:
            vmaddr, vmsize, fileoff, filesize = struct.unpack_from('<IIII', data, off + 24)
            nsects = struct.unpack_from('<I', data, off + 48)[0]
            segs.append((vmaddr, vmsize, fileoff + base, filesize))
            so = off + 56
            for _ in range(nsects):
                name = data[so:so + 16].rstrip(b'\0').decode('ascii', 'replace')
                addr, size, foff = struct.unpack_from('<III', data, so + 32)
                sects[name] = (addr, size, foff + base)
                so += 68
        off += cmdsize
    return segs, sects


def main():
    if len(sys.argv) != 2:
        sys.exit("usage: strip-swift-class-bit.py <thin-macho>")
    path = sys.argv[1]
    data = bytearray(open(path, 'rb').read())
    total_stripped = total_clean = 0
    found = False
    for base in slices(data):
        segs, sects = parse(data, base)
        if '__objc_classlist' not in sects:
            continue
        found = True
        st, cl = strip_slice(data, segs, sects)
        total_stripped += st
        total_clean += cl
    if not found:
        print("  no __objc_classlist in any slice; nothing to do")
        return
    open(path, 'wb').write(data)
    print("  bits-stripped=%d  already-clean=%d" % (total_stripped, total_clean))
    return

def strip_slice(data, segs, sects):
    def to_fileoff(vmaddr):
        for vm, vmsize, fo, fsize in segs:
            # __PAGEZERO and __LINKEDIT are excluded by the filesize check
            if vm <= vmaddr < vm + vmsize and fsize and vmaddr - vm < fsize:
                return fo + (vmaddr - vm)
        return None

    addr, size, foff = sects['__objc_classlist']
    n = size // 4
    ptrs = struct.unpack_from('<%dI' % n, data, foff)

    stripped = already = unresolved = 0
    for cls in ptrs:
        # strip the class itself and its metaclass
        targets = [cls + CLASS_T_DATA_OFF]
        iso = to_fileoff(cls + CLASS_T_ISA_OFF)
        if iso is not None:
            meta = struct.unpack_from('<I', data, iso)[0]
            if meta:
                targets.append(meta + CLASS_T_DATA_OFF)
        for t in targets:
            fo = to_fileoff(t)
            if fo is None:
                unresolved += 1
                continue
            word = struct.unpack_from('<I', data, fo)[0]
            if word & 1:
                struct.pack_into('<I', data, fo, word & ~1)
                stripped += 1
            else:
                already += 1

    if unresolved:
        print("  WARNING: %d class pointers fell outside any mapped segment" % unresolved)
    return stripped, already


if __name__ == '__main__':
    main()
