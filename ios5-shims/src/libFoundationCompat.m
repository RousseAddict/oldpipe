// libFoundationCompat — Foundation compatibility shim for iOS 5.
//
// Swift 5.1.5's libswiftFoundation imports NSUUID, which does not exist before
// iOS 6. This dylib re-exports Foundation (everything iOS 5 has passes straight
// through) and adds a full NSUUID implemented over libSystem's uuid(3) API.
// libswiftFoundation's LC_LOAD_DYLIB on Foundation is repointed here with
// install_name_tool -change, preserving its two-level-namespace ordinals.
//
// The @interface comes from the iOS 15.2 SDK header — we only supply the
// @implementation (plus its single ivar), so the declaration the rest of the
// world compiles against and the one we define are guaranteed identical.
//
// Manual retain/release (no ARC): matches the iOS 5 runtime and keeps the
// bridging behaviour of a real immutable Foundation value type.

#import <Foundation/Foundation.h>
#include <uuid/uuid.h>
#include <string.h>

@implementation NSUUID {
    uuid_t _uuid;
}

+ (BOOL)supportsSecureCoding { return YES; }

+ (instancetype)UUID { return [[[self alloc] init] autorelease]; }

- (instancetype)init {
    self = [super init];
    if (self) { uuid_generate_random(_uuid); }
    return self;
}

// Returns nil on an unparseable string, like the real NSUUID.
- (instancetype)initWithUUIDString:(NSString *)string {
    self = [super init];
    if (self) {
        const char *s = [string UTF8String];
        if (s == NULL || uuid_parse((char *)s, _uuid) != 0) {
            [self release];
            return nil;
        }
    }
    return self;
}

- (instancetype)initWithUUIDBytes:(const unsigned char *)bytes {
    self = [super init];
    if (self) {
        if (bytes) { memcpy(_uuid, bytes, sizeof(uuid_t)); }
        else { uuid_clear(_uuid); }
    }
    return self;
}

- (void)getUUIDBytes:(unsigned char *)uuid { memcpy(uuid, _uuid, sizeof(uuid_t)); }

// NSUUID's canonical form is UPPERCASE; Swift's UUID.uuidString relies on it.
- (NSString *)UUIDString {
    uuid_string_t buf;
    uuid_unparse_upper(_uuid, buf);
    return [NSString stringWithUTF8String:buf];
}

- (NSComparisonResult)compare:(NSUUID *)otherUUID {
    if (otherUUID == nil) { return NSOrderedDescending; }
    uuid_t o;
    [otherUUID getUUIDBytes:o];
    int r = memcmp(_uuid, o, sizeof(uuid_t));
    return (r < 0) ? NSOrderedAscending : (r > 0) ? NSOrderedDescending : NSOrderedSame;
}

- (BOOL)isEqual:(id)other {
    if (other == self) { return YES; }
    if (![other isKindOfClass:[NSUUID class]]) { return NO; }
    uuid_t o;
    [(NSUUID *)other getUUIDBytes:o];
    return memcmp(_uuid, o, sizeof(uuid_t)) == 0;
}

// FNV-1a over the 16 raw bytes — equal UUIDs must hash equally.
- (NSUInteger)hash {
    NSUInteger h = 2166136261u;
    for (int i = 0; i < 16; i++) {
        h ^= (NSUInteger)_uuid[i];
        h *= 16777619u;
    }
    return h;
}

// Immutable, so a copy can just be another reference.
- (id)copyWithZone:(NSZone *)zone { (void)zone; return [self retain]; }

- (NSString *)description { return [self UUIDString]; }

- (void)encodeWithCoder:(NSCoder *)coder {
    [coder encodeObject:[NSData dataWithBytes:_uuid length:sizeof(uuid_t)]
                 forKey:@"NS.uuidbytes"];
}

- (instancetype)initWithCoder:(NSCoder *)coder {
    self = [super init];
    if (self) {
        NSData *d = [coder decodeObjectForKey:@"NS.uuidbytes"];
        if ([d length] == sizeof(uuid_t)) { memcpy(_uuid, [d bytes], sizeof(uuid_t)); }
        else { uuid_clear(_uuid); }
    }
    return self;
}
@end
