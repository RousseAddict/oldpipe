import Foundation

// MARK: - CastMessage
// Minimal hand-rolled protobuf codec for the Chromecast CASTV2 wire protocol.
// We only need the `extensions.api.cast_channel.CastMessage` message — a fixed,
// tiny schema — so a full protobuf runtime (a 3rd-party lib requiring a security
// scan under org policy) is unnecessary. Encode/decode by hand.
//
// CastMessage fields (proto2):
//   1  protocol_version  enum   (varint)  — always 0 (CASTV2_1_0)
//   2  source_id         string
//   3  destination_id    string
//   4  namespace         string
//   5  payload_type      enum   (varint)  — 0 = STRING, 1 = BINARY
//   6  payload_utf8      string           — the JSON payload
//   7  payload_binary    bytes            — unused here
//
// Frames on the socket are: UInt32 big-endian length prefix + serialized bytes.

struct CastMessage {
    var sourceId: String
    var destinationId: String
    var namespace: String
    var payloadUtf8: String

    // MARK: Encode

    // Serialize to the raw protobuf bytes (no length prefix).
    func serialized() -> [UInt8] {
        var out = [UInt8]()
        // field 1: protocol_version = 0 (varint)
        out.append(0x08); appendVarint(0, to: &out)
        // field 2: source_id (string)
        appendStringField(2, sourceId, to: &out)
        // field 3: destination_id (string)
        appendStringField(3, destinationId, to: &out)
        // field 4: namespace (string)
        appendStringField(4, namespace, to: &out)
        // field 5: payload_type = 0 (STRING) (varint)
        out.append(0x28); appendVarint(0, to: &out)
        // field 6: payload_utf8 (string)
        appendStringField(6, payloadUtf8, to: &out)
        return out
    }

    // Serialize with the 4-byte big-endian length prefix (what goes on the wire).
    func framed() -> Data {
        let body = serialized()
        var frame = [UInt8]()
        let n = UInt32(body.count)
        frame.append(UInt8((n >> 24) & 0xFF))
        frame.append(UInt8((n >> 16) & 0xFF))
        frame.append(UInt8((n >> 8) & 0xFF))
        frame.append(UInt8(n & 0xFF))
        frame.append(contentsOf: body)
        return Data(frame)
    }

    private func appendStringField(_ field: Int, _ value: String, to out: inout [UInt8]) {
        let bytes = Array(value.utf8)
        let tag = UInt64((field << 3) | 2)   // wire type 2 = length-delimited
        appendVarint(tag, to: &out)
        appendVarint(UInt64(bytes.count), to: &out)
        out.append(contentsOf: bytes)
    }

    private func appendVarint(_ v: UInt64, to out: inout [UInt8]) {
        var value = v
        repeat {
            var b = UInt8(value & 0x7F)
            value >>= 7
            if value != 0 { b |= 0x80 }
            out.append(b)
        } while value != 0
    }

    // MARK: Decode

    // Parse a single serialized CastMessage (no length prefix) from `bytes`.
    static func parse(_ bytes: [UInt8]) -> CastMessage? {
        var i = 0
        var src = "", dst = "", ns = "", payload = ""
        while i < bytes.count {
            guard let (tag, next) = readVarint(bytes, i) else { return nil }
            i = next
            let field = Int(tag >> 3)
            let wire = Int(tag & 0x7)
            switch wire {
            case 0:   // varint — skip the value (protocol_version / payload_type)
                guard let (_, n2) = readVarint(bytes, i) else { return nil }
                i = n2
            case 2:   // length-delimited
                guard let (len, n2) = readVarint(bytes, i) else { return nil }
                i = n2
                let end = i + Int(len)
                guard end <= bytes.count else { return nil }
                let slice = Array(bytes[i..<end])
                i = end
                let str = String(bytes: slice, encoding: .utf8) ?? ""
                switch field {
                case 2: src = str
                case 3: dst = str
                case 4: ns = str
                case 6: payload = str
                default: break
                }
            default:
                return nil   // unexpected wire type
            }
        }
        return CastMessage(sourceId: src, destinationId: dst, namespace: ns, payloadUtf8: payload)
    }

    private static func readVarint(_ bytes: [UInt8], _ start: Int) -> (UInt64, Int)? {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        var i = start
        while i < bytes.count {
            let b = bytes[i]
            result |= UInt64(b & 0x7F) << shift
            i += 1
            if (b & 0x80) == 0 { return (result, i) }
            shift += 7
            if shift >= 64 { return nil }
        }
        return nil   // truncated
    }
}

// MARK: - CASTV2 namespaces / constants
enum CastNS {
    static let connection = "urn:x-cast:com.google.cast.tp.connection"
    static let heartbeat  = "urn:x-cast:com.google.cast.tp.heartbeat"
    static let receiver   = "urn:x-cast:com.google.cast.receiver"
    static let media      = "urn:x-cast:com.google.cast.media"
}
