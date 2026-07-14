import Foundation

// MARK: - HLSTransmuxer
//
// YouTube DASH (fragmented MP4) -> MPEG-TS transmuxer for >360p streaming on iOS 6/7.
//
// Why this exists: anonymous innertube only serves >360p as SEPARATE video-only + audio-only
// DASH fMP4 adaptiveFormats (itag 136 = 720p H.264, 140 = AAC). AVPlayer has no equivalent of
// ExoPlayer's MergingMediaSource, and iOS 6 cannot play fMP4 at all (fMP4-in-HLS is iOS 10+).
// The one native path that CAN mux two elementary streams for old AVPlayer is HLS with
// MPEG-TS segments — so StreamProxy serves a local VOD playlist whose segments are transmuxed
// on the fly by this class: one HLS segment per video DASH fragment (~5.6s), video AVCC ->
// Annex-B, AAC -> ADTS, both interleaved by DTS into a TS segment.
//
// This class is PURE data-in/data-out (no networking, no UI):
//   parse(videoHead:audioHead:)  — parse init+sidx of both streams (bytes 0...indexRange.end)
//   playlist(_:)                 — build the VOD .m3u8 from the video sidx
//   videoRange/audioRange(_:seg:)— absolute byte ranges StreamProxy must fetch per segment
//   muxSegment(_:seg:videoBlob:audioBlob:) — transmux one segment to TS
//
// Prototype validated 2026-07-13: ffmpeg decodes the output with zero errors (A/V sync,
// CTS/B-frames, exact durations) AND a static bundle of these segments plays on an iOS 6
// device via StreamProxy. All failure paths return nil (never crash — this runs inside the
// proxy's connection threads serving AVPlayer).

// MARK: - Byte reading helpers (fileprivate — don't leak a generic-sounding Data extension)

fileprivate extension Data {
    func be16(_ o: Int) -> Int { Int(self[startIndex + o]) << 8 | Int(self[startIndex + o + 1]) }
    func be32(_ o: Int) -> UInt32 {
        var v: UInt32 = 0
        for i in 0..<4 { v = v << 8 | UInt32(self[startIndex + o + i]) }
        return v
    }
    func be64(_ o: Int) -> UInt64 {
        var v: UInt64 = 0
        for i in 0..<8 { v = v << 8 | UInt64(self[startIndex + o + i]) }
        return v
    }
    func fourCC(_ o: Int) -> String {
        String(bytes: self[(startIndex + o)..<(startIndex + o + 4)], encoding: .isoLatin1) ?? "????"
    }
    func sub(_ o: Int, _ len: Int) -> Data {
        subdata(in: (startIndex + o)..<(startIndex + o + len))
    }
}

// MARK: - MP4 box iteration

private struct MP4Box { let type: String; let payload: Data; let fileOffset: Int; let fullSize: Int }

private func mp4Boxes(in data: Data, baseOffset: Int = 0) -> [MP4Box] {
    var out: [MP4Box] = []
    var off = 0
    while off + 8 <= data.count {
        var size = Int(data.be32(off))
        let type = data.fourCC(off + 4)
        var hdr = 8
        if size == 1 {
            guard off + 16 <= data.count else { break }
            size = Int(data.be64(off + 8)); hdr = 16
        }
        if size < hdr || off + size > data.count { break }
        out.append(MP4Box(type: type, payload: data.sub(off + hdr, size - hdr),
                          fileOffset: baseOffset + off, fullSize: size))
        off += size
    }
    return out
}

private func findMP4Box(_ data: Data, _ path: [String]) -> MP4Box? {
    var current = data
    for (i, name) in path.enumerated() {
        guard let b = mp4Boxes(in: current).first(where: { $0.type == name }) else { return nil }
        if i == path.count - 1 { return b }
        current = b.payload
    }
    return nil
}

// MARK: - sidx (segment index: per-fragment byte ranges + durations)

private struct SidxEntry { let offset: Int64; let size: Int; let duration: Int64 }
private struct Sidx { let timescale: Int64; let entries: [SidxEntry]; let startTimes: [Int64] }

private func parseSidx(_ box: MP4Box, boxEndFileOffset: Int64) -> Sidx? {
    let d = box.payload
    guard d.count >= 12 else { return nil }
    let version = d[d.startIndex]
    var o = 4          // version+flags
    o += 4             // reference_ID
    let timescale = Int64(d.be32(o)); o += 4
    var earliest: Int64
    var firstOffset: Int64
    if version == 0 {
        guard d.count >= o + 8 else { return nil }
        earliest = Int64(d.be32(o)); o += 4
        firstOffset = Int64(d.be32(o)); o += 4
    } else {
        guard d.count >= o + 16 else { return nil }
        earliest = Int64(bitPattern: d.be64(o)); o += 8
        firstOffset = Int64(bitPattern: d.be64(o)); o += 8
    }
    o += 2             // reserved
    guard d.count >= o + 2 else { return nil }
    let count = d.be16(o); o += 2
    guard d.count >= o + count * 12 else { return nil }
    var entries: [SidxEntry] = []
    var startTimes: [Int64] = []
    var byteCursor = boxEndFileOffset + firstOffset
    var t = earliest
    for _ in 0..<count {
        let refSize = Int(d.be32(o) & 0x7FFF_FFFF)
        let dur = Int64(d.be32(o + 4))
        o += 12
        entries.append(SidxEntry(offset: byteCursor, size: refSize, duration: dur))
        startTimes.append(t)
        byteCursor += Int64(refSize)
        t += dur
    }
    guard timescale > 0, !entries.isEmpty else { return nil }
    return Sidx(timescale: timescale, entries: entries, startTimes: startTimes)
}

// MARK: - init segment parsing

private struct TrexDefaults { var duration: UInt32 = 0; var size: UInt32 = 0; var flags: UInt32 = 0 }

private struct VideoInitInfo {
    let timescale: Int64
    let sps: [Data]
    let pps: [Data]
    let nalLengthSize: Int
    let defaults: TrexDefaults
}

private struct AudioInitInfo {
    let timescale: Int64
    let aacProfile: Int      // ADTS profile field = AudioObjectType - 1
    let freqIndex: Int
    let channelConfig: Int
    let defaults: TrexDefaults
}

private func parseTrex(_ initData: Data) -> TrexDefaults {
    var d = TrexDefaults()
    if let trex = findMP4Box(initData, ["moov", "mvex", "trex"]), trex.payload.count >= 24 {
        let p = trex.payload
        // ver/flags(4) trackid(4) default_sample_description_index(4) duration(4) size(4) flags(4)
        d.duration = p.be32(12); d.size = p.be32(16); d.flags = p.be32(20)
    }
    return d
}

private func mdhdTimescale(_ initData: Data) -> Int64? {
    guard let mdhd = findMP4Box(initData, ["moov", "trak", "mdia", "mdhd"]), mdhd.payload.count >= 16 else { return nil }
    let p = mdhd.payload
    let ver = p[p.startIndex]
    if ver == 1 { guard p.count >= 24 else { return nil }; return Int64(p.be32(20)) }
    return Int64(p.be32(12))
}

private func parseVideoInit(_ initData: Data) -> VideoInitInfo? {
    guard let ts = mdhdTimescale(initData), ts > 0 else { return nil }
    guard let stsd = findMP4Box(initData, ["moov", "trak", "mdia", "minf", "stbl", "stsd"]),
          stsd.payload.count > 8 else { return nil }
    // stsd payload: ver/flags(4) entry_count(4) then entries
    guard let avc1 = mp4Boxes(in: stsd.payload.sub(8, stsd.payload.count - 8)).first,
          avc1.type == "avc1" || avc1.type == "avc3",
          avc1.payload.count > 78 else { return nil }
    // avc1: 78 bytes of SampleEntry+VisualSampleEntry fields, then child boxes
    let children = mp4Boxes(in: avc1.payload.sub(78, avc1.payload.count - 78))
    guard let avcC = children.first(where: { $0.type == "avcC" }), avcC.payload.count >= 7 else { return nil }
    let c = avcC.payload
    let nalLen = Int(c[c.startIndex + 4] & 0x03) + 1
    var o = 5
    let numSPS = Int(c[c.startIndex + o] & 0x1F); o += 1
    var sps: [Data] = []
    for _ in 0..<numSPS {
        guard c.count >= o + 2 else { return nil }
        let l = c.be16(o); o += 2
        guard c.count >= o + l else { return nil }
        sps.append(c.sub(o, l)); o += l
    }
    guard c.count >= o + 1 else { return nil }
    let numPPS = Int(c[c.startIndex + o]); o += 1
    var pps: [Data] = []
    for _ in 0..<numPPS {
        guard c.count >= o + 2 else { return nil }
        let l = c.be16(o); o += 2
        guard c.count >= o + l else { return nil }
        pps.append(c.sub(o, l)); o += l
    }
    guard !sps.isEmpty, !pps.isEmpty else { return nil }
    return VideoInitInfo(timescale: ts, sps: sps, pps: pps, nalLengthSize: nalLen,
                         defaults: parseTrex(initData))
}

private func parseAudioInit(_ initData: Data) -> AudioInitInfo? {
    guard let ts = mdhdTimescale(initData), ts > 0 else { return nil }
    guard let stsd = findMP4Box(initData, ["moov", "trak", "mdia", "minf", "stbl", "stsd"]),
          stsd.payload.count > 8 else { return nil }
    guard let mp4a = mp4Boxes(in: stsd.payload.sub(8, stsd.payload.count - 8)).first,
          mp4a.type == "mp4a", mp4a.payload.count > 28 else { return nil }
    // mp4a: 28 bytes AudioSampleEntry fields, then child boxes (esds)
    let children = mp4Boxes(in: mp4a.payload.sub(28, mp4a.payload.count - 28))
    guard let esds = children.first(where: { $0.type == "esds" }) else { return nil }
    let e = esds.payload
    // skip ver/flags(4), then walk descriptors to DecoderSpecificInfo (tag 0x05)
    var o = 4
    func readDescriptor() -> (tag: Int, len: Int)? {
        guard e.count >= o + 2 else { return nil }
        let tag = Int(e[e.startIndex + o]); o += 1
        var len = 0
        for _ in 0..<4 {
            guard e.count >= o + 1 else { return nil }
            let b = Int(e[e.startIndex + o]); o += 1
            len = len << 7 | (b & 0x7F)
            if b & 0x80 == 0 { break }
        }
        return (tag, len)
    }
    var asc: Data?
    // ES_Descriptor (0x03): ES_ID(2) flags(1), then DecoderConfigDescriptor (0x04):
    // objectType(1) streamType/bufferSize(4) maxBitrate(4) avgBitrate(4), then DecSpecificInfo (0x05)
    if let d0 = readDescriptor(), d0.tag == 0x03 {
        o += 3
        if let d1 = readDescriptor(), d1.tag == 0x04 {
            o += 13
            if let d2 = readDescriptor(), d2.tag == 0x05, e.count >= o + d2.len {
                asc = e.sub(o, d2.len)
            }
        }
    }
    guard let cfg = asc, cfg.count >= 2 else { return nil }
    let b0 = Int(cfg[cfg.startIndex]), b1 = Int(cfg[cfg.startIndex + 1])
    let aot = b0 >> 3
    let freqIndex = (b0 & 0x07) << 1 | (b1 >> 7)
    let chan = (b1 >> 3) & 0x0F
    guard freqIndex != 15 else { return nil }   // explicit sample rate in ASC — not supported
    return AudioInitInfo(timescale: ts, aacProfile: max(0, aot - 1), freqIndex: freqIndex,
                         channelConfig: chan, defaults: parseTrex(initData))
}

// MARK: - fragment (moof/mdat) parsing

private struct FragSample {
    let data: Data
    let dts: Int64        // in track timescale
    let ctsOffset: Int64  // composition offset (pts = dts + cts)
    let duration: Int64
    let isSync: Bool
}

// Parse every moof/mdat pair in `blob`. Returns nil on structural corruption (better to fail
// the HTTP request than serve a broken TS segment to AVPlayer).
private func parseFragments(_ blob: Data, defaults: TrexDefaults) -> [FragSample]? {
    var samples: [FragSample] = []
    for box in mp4Boxes(in: blob) where box.type == "moof" {
        let moofStart = box.fileOffset  // relative to blob start
        guard let traf = mp4Boxes(in: box.payload).first(where: { $0.type == "traf" }) else { continue }
        var baseDecode: Int64 = 0
        var tfhdDefaultDur = defaults.duration
        var tfhdDefaultSize = defaults.size
        var tfhdDefaultFlags = defaults.flags
        let baseDataOffset: Int64 = Int64(moofStart)  // default-base-is-moof (YouTube always)
        for child in mp4Boxes(in: traf.payload) {
            let p = child.payload
            switch child.type {
            case "tfhd":
                guard p.count >= 8 else { return nil }
                let flags = p.be32(0) & 0x00FF_FFFF
                var o = 8 // ver/flags + track_ID
                // Explicit base_data_offset would break the default-base-is-moof assumption.
                if flags & 0x01 != 0 { return nil }
                if flags & 0x02 != 0 { o += 4 }
                if flags & 0x08 != 0 { guard p.count >= o + 4 else { return nil }; tfhdDefaultDur = p.be32(o); o += 4 }
                if flags & 0x10 != 0 { guard p.count >= o + 4 else { return nil }; tfhdDefaultSize = p.be32(o); o += 4 }
                if flags & 0x20 != 0 { guard p.count >= o + 4 else { return nil }; tfhdDefaultFlags = p.be32(o); o += 4 }
            case "tfdt":
                guard p.count >= 8 else { return nil }
                let ver = p[p.startIndex]
                if ver == 1 {
                    guard p.count >= 12 else { return nil }
                    baseDecode = Int64(bitPattern: p.be64(4))
                } else {
                    baseDecode = Int64(p.be32(4))
                }
            case "trun":
                guard p.count >= 8 else { return nil }
                let ver = p[p.startIndex]
                let flags = p.be32(0) & 0x00FF_FFFF
                let count = Int(p.be32(4))
                var o = 8
                var dataOffset: Int64 = 0
                if flags & 0x001 != 0 { guard p.count >= o + 4 else { return nil }; dataOffset = Int64(Int32(bitPattern: p.be32(o))); o += 4 }
                var firstSampleFlags: UInt32?
                if flags & 0x004 != 0 { guard p.count >= o + 4 else { return nil }; firstSampleFlags = p.be32(o); o += 4 }
                var pos = baseDataOffset + dataOffset  // relative to blob start
                var dts = baseDecode
                for i in 0..<count {
                    var dur = Int64(tfhdDefaultDur)
                    var size = Int(tfhdDefaultSize)
                    var sflags = tfhdDefaultFlags
                    var cts: Int64 = 0
                    if flags & 0x100 != 0 { guard p.count >= o + 4 else { return nil }; dur = Int64(p.be32(o)); o += 4 }
                    if flags & 0x200 != 0 { guard p.count >= o + 4 else { return nil }; size = Int(p.be32(o)); o += 4 }
                    if flags & 0x400 != 0 { guard p.count >= o + 4 else { return nil }; sflags = p.be32(o); o += 4 }
                    if flags & 0x800 != 0 {
                        guard p.count >= o + 4 else { return nil }
                        cts = ver == 0 ? Int64(p.be32(o)) : Int64(Int32(bitPattern: p.be32(o)))
                        o += 4
                    }
                    if i == 0, let f = firstSampleFlags { sflags = f }
                    guard size >= 0, pos >= 0, Int(pos) + size <= blob.count else { return nil }
                    let isSync = (sflags & 0x0001_0000) == 0
                    samples.append(FragSample(data: blob.sub(Int(pos), size), dts: dts,
                                              ctsOffset: cts, duration: dur, isSync: isSync))
                    pos += Int64(size)
                    dts += dur
                }
            default: break
            }
        }
    }
    return samples
}

// MARK: - Annex-B / ADTS conversion

private func annexB(_ sample: FragSample, nalLengthSize: Int, sps: [Data], pps: [Data]) -> Data {
    var out = Data()
    let start: [UInt8] = [0, 0, 0, 1]
    // Access-unit delimiter (required by Apple's TS consumers)
    out.append(contentsOf: start); out.append(contentsOf: [0x09, 0xF0])
    if sample.isSync {
        for s in sps { out.append(contentsOf: start); out.append(s) }
        for p in pps { out.append(contentsOf: start); out.append(p) }
    }
    let d = sample.data
    var o = 0
    while o + nalLengthSize <= d.count {
        var len = 0
        for i in 0..<nalLengthSize { len = len << 8 | Int(d[d.startIndex + o + i]) }
        o += nalLengthSize
        guard o + len <= d.count else { break }
        out.append(contentsOf: start)
        out.append(d.sub(o, len))
        o += len
    }
    return out
}

private func adtsFrame(_ frame: Data, profile: Int, freqIndex: Int, channels: Int) -> Data {
    let len = frame.count + 7
    var h = [UInt8](repeating: 0, count: 7)
    h[0] = 0xFF
    h[1] = 0xF1  // MPEG-4, layer 0, no CRC
    // Split into explicitly typed sub-expressions — the combined shift/or expression makes
    // the Swift 5.6 type-checker give up ("unable to type-check in reasonable time").
    let b2: Int = ((profile & 3) << 6) | ((freqIndex & 0xF) << 2) | ((channels >> 2) & 1)
    let b3: Int = ((channels & 3) << 6) | ((len >> 11) & 3)
    let b5: Int = ((len & 7) << 5) | 0x1F
    h[2] = UInt8(b2)
    h[3] = UInt8(b3)
    h[4] = UInt8((len >> 3) & 0xFF)
    h[5] = UInt8(b5)
    h[6] = 0xFC
    var out = Data(h)
    out.append(frame)
    return out
}

// MARK: - MPEG-TS writer

private let mpegCRCTable: [UInt32] = {
    var table = [UInt32](repeating: 0, count: 256)
    for i in 0..<256 {
        var crc = UInt32(i) << 24
        for _ in 0..<8 { crc = (crc & 0x8000_0000) != 0 ? (crc << 1) ^ 0x04C1_1DB7 : crc << 1 }
        table[i] = crc
    }
    return table
}()

private func mpegCRC32(_ data: Data) -> UInt32 {
    var crc: UInt32 = 0xFFFF_FFFF
    for b in data { crc = (crc << 8) ^ mpegCRCTable[Int((crc >> 24) ^ UInt32(b)) & 0xFF] }
    return crc
}

private final class TSWriter {
    var out = Data()
    private var cc: [Int: UInt8] = [:]  // continuity counter per PID
    let pmtPID = 4096, videoPID = 256, audioPID = 257
    var ok = true                        // flipped false if a packet ever mis-sizes

    private func nextCC(_ pid: Int) -> UInt8 {
        let v = cc[pid] ?? 0
        cc[pid] = (v + 1) & 0x0F
        return v
    }

    private func psi(_ pid: Int, table: Data) {
        var payload = Data([0x00])  // pointer_field
        payload.append(table)
        let crc = mpegCRC32(table)
        payload.append(contentsOf: [UInt8(crc >> 24 & 0xFF), UInt8(crc >> 16 & 0xFF),
                                    UInt8(crc >> 8 & 0xFF), UInt8(crc & 0xFF)])
        var pkt = Data([0x47, UInt8(0x40 | (pid >> 8)), UInt8(pid & 0xFF), UInt8(0x10 | nextCC(pid))])
        pkt.append(payload)
        while pkt.count < 188 { pkt.append(0xFF) }
        out.append(pkt)
    }

    func writePAT() {
        // section_length = 5 (fixed after len) + 4 (program) + 4 (CRC) = 13
        let table = Data([0x00, 0xB0, 0x0D, 0x00, 0x01, 0xC1, 0x00, 0x00,
                          0x00, 0x01, UInt8(0xE0 | (pmtPID >> 8)), UInt8(pmtPID & 0xFF)])
        psi(0, table: table)
    }

    func writePMT() {
        var t = Data([0x02, 0xB0, 0x00 /* len patched below */, 0x00, 0x01, 0xC1, 0x00, 0x00,
                      UInt8(0xE0 | (videoPID >> 8)), UInt8(videoPID & 0xFF), 0xF0, 0x00])
        // streams: H.264 on videoPID, ADTS AAC on audioPID
        t.append(contentsOf: [0x1B, UInt8(0xE0 | (videoPID >> 8)), UInt8(videoPID & 0xFF), 0xF0, 0x00])
        t.append(contentsOf: [0x0F, UInt8(0xE0 | (audioPID >> 8)), UInt8(audioPID & 0xFF), 0xF0, 0x00])
        let sectionLen = t.count - 3 + 4  // after length field, + CRC
        t[t.startIndex + 2] = UInt8(sectionLen & 0xFF)
        t[t.startIndex + 1] = UInt8(0xB0 | (sectionLen >> 8))
        psi(pmtPID, table: t)
    }

    private func encodePTS(_ prefix: UInt8, _ ts: Int64) -> [UInt8] {
        let t = UInt64(bitPattern: ts) & 0x1_FFFF_FFFF
        return [
            UInt8(UInt64(prefix) << 4 | (t >> 30) << 1 | 1),
            UInt8((t >> 22) & 0xFF),
            UInt8(((t >> 14) & 0xFE) | 1),
            UInt8((t >> 7) & 0xFF),
            UInt8(((t << 1) & 0xFE) | 1),
        ]
    }

    // One PES packet, split across 188-byte TS packets. PCR/RAI go on the first packet.
    func writePES(pid: Int, streamId: UInt8, pts: Int64, dts: Int64?, payload: Data,
                  randomAccess: Bool, pcr: Int64?) {
        var pes = Data([0x00, 0x00, 0x01, streamId])
        var hdr = Data()
        let ptsDtsFlags: UInt8 = dts != nil ? 0xC0 : 0x80
        var tsBytes = encodePTS(dts != nil ? 3 : 2, pts)
        if let d = dts { tsBytes += encodePTS(1, d) }
        hdr.append(contentsOf: [0x80, ptsDtsFlags, UInt8(tsBytes.count)])
        hdr.append(contentsOf: tsBytes)
        let pesLen = hdr.count + payload.count
        if streamId == 0xE0 || pesLen > 0xFFFF {
            pes.append(contentsOf: [0x00, 0x00])  // unbounded (video)
        } else {
            pes.append(contentsOf: [UInt8(pesLen >> 8), UInt8(pesLen & 0xFF)])
        }
        pes.append(hdr)
        pes.append(payload)

        var off = 0
        var first = true
        while off < pes.count {
            var pkt = Data(capacity: 188)
            let remaining = pes.count - off
            var adaptation = Data()
            if first && (pcr != nil || randomAccess) {
                var flags: UInt8 = 0
                if randomAccess { flags |= 0x40 }
                var af = Data([flags])
                if let pcrV = pcr {
                    flags |= 0x10
                    af = Data([flags])
                    let base = UInt64(bitPattern: pcrV) & 0x1_FFFF_FFFF
                    af.append(contentsOf: [
                        UInt8((base >> 25) & 0xFF), UInt8((base >> 17) & 0xFF),
                        UInt8((base >> 9) & 0xFF), UInt8((base >> 1) & 0xFF),
                        UInt8(((base & 1) << 7) | 0x7E), 0x00,
                    ])
                }
                adaptation = af
            }
            var capacity = 184 - (adaptation.isEmpty ? 0 : adaptation.count + 1)
            if remaining < capacity {
                // Need stuffing: grow the adaptation field to fill the packet exactly.
                let stuff = capacity - remaining
                if adaptation.isEmpty {
                    adaptation = Data([0x00])
                    var need = stuff - 2  // AF length byte + flags byte consumed 2 of the gap
                    if need < 0 {
                        // Gap of exactly 1 byte: AF with length 0 (no flags byte).
                        pkt = Data([0x47, UInt8((first ? 0x40 : 0x00) | (pid >> 8)), UInt8(pid & 0xFF),
                                    UInt8(0x30 | nextCC(pid)), 0x00])
                        pkt.append(pes.sub(off, remaining))
                        if pkt.count != 188 { ok = false; return }
                        out.append(pkt)
                        off += remaining
                        first = false
                        continue
                    }
                    while need > 0 { adaptation.append(0xFF); need -= 1 }
                } else {
                    for _ in 0..<stuff { adaptation.append(0xFF) }
                }
                capacity = remaining
            }
            let hasAF = !adaptation.isEmpty
            pkt = Data([0x47, UInt8((first ? 0x40 : 0x00) | (pid >> 8)), UInt8(pid & 0xFF),
                        UInt8((hasAF ? 0x30 : 0x10) | nextCC(pid))])
            if hasAF {
                pkt.append(UInt8(adaptation.count))
                pkt.append(adaptation)
            }
            let n = min(capacity, remaining)
            pkt.append(pes.sub(off, n))
            if pkt.count != 188 { ok = false; return }   // never serve a corrupt segment
            out.append(pkt)
            off += n
            first = false
        }
    }
}

// MARK: - Public API

// Parsed init + sidx state for one video+audio stream pair. Opaque to callers — created by
// HLSTransmuxer.parse and passed back into playlist/range/mux calls. Immutable → safe to
// share across StreamProxy's concurrent connection threads without locking.
struct HLSStreamInfo {
    fileprivate let vInit: VideoInitInfo
    fileprivate let aInit: AudioInitInfo
    fileprivate let vSidx: Sidx
    fileprivate let aSidx: Sidx

    var segmentCount: Int { return vSidx.entries.count }
}

final class HLSTransmuxer {

    // 1s guard so DTS (= PTS - CTS offset) never goes negative on the first samples.
    private static let ptsOffset: Int64 = 90000

    // Parse the head (bytes 0...indexRange.end — init segment + sidx) of both streams.
    static func parse(videoHead: Data, audioHead: Data) -> HLSStreamInfo? {
        guard let vInit = parseVideoInit(videoHead) else { return nil }
        guard let aInit = parseAudioInit(audioHead) else { return nil }
        guard let vBox = mp4Boxes(in: videoHead).first(where: { $0.type == "sidx" }),
              let vSidx = parseSidx(vBox, boxEndFileOffset: Int64(vBox.fileOffset + vBox.fullSize)) else { return nil }
        guard let aBox = mp4Boxes(in: audioHead).first(where: { $0.type == "sidx" }),
              let aSidx = parseSidx(aBox, boxEndFileOffset: Int64(aBox.fileOffset + aBox.fullSize)) else { return nil }
        return HLSStreamInfo(vInit: vInit, aInit: aInit, vSidx: vSidx, aSidx: aSidx)
    }

    // VOD playlist: one segment per video DASH fragment; ENDLIST → AVPlayer seeks natively.
    static func playlist(_ info: HLSStreamInfo) -> String {
        let sidx = info.vSidx
        var m3u8 = "#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-PLAYLIST-TYPE:VOD\n"
        // Integer ceil — Double.rounded(.up) + Int(Double) interpolation renders "?" on the
        // 5.1.5 runtime shipped for iOS 6 (broken playlist → AVError -11800). Int64 math is safe.
        var target = 0
        for e in sidx.entries {
            let d = Int((e.duration + sidx.timescale - 1) / sidx.timescale)
            if d > target { target = d }
        }
        if target < 1 { target = 6 }
        m3u8 += "#EXT-X-TARGETDURATION:\(target)\n#EXT-X-MEDIA-SEQUENCE:0\n"
        for (i, e) in sidx.entries.enumerated() {
            m3u8 += String(format: "#EXTINF:%.5f,\n", Double(e.duration) / Double(sidx.timescale))
            m3u8 += "seg\(i).ts\n"
        }
        m3u8 += "#EXT-X-ENDLIST\n"
        return m3u8
    }

    // Absolute byte range of the video DASH fragment backing segment `seg`.
    static func videoRange(_ info: HLSStreamInfo, seg: Int) -> (start: Int64, end: Int64)? {
        guard seg >= 0, seg < info.vSidx.entries.count else { return nil }
        let e = info.vSidx.entries[seg]
        return (e.offset, e.offset + Int64(e.size) - 1)
    }

    // Absolute byte range covering every audio fragment overlapping segment `seg`'s time window.
    static func audioRange(_ info: HLSStreamInfo, seg: Int) -> (start: Int64, end: Int64)? {
        guard seg >= 0, seg < info.vSidx.entries.count else { return nil }
        let (a0, a1) = audioWindow(info, seg: seg)
        var first = -1, last = -1
        for (i, st) in info.aSidx.startTimes.enumerated() {
            let en = st + info.aSidx.entries[i].duration
            if en > a0 && st < a1 { if first < 0 { first = i }; last = i }
        }
        guard first >= 0 else { return nil }
        let start = info.aSidx.entries[first].offset
        let end = info.aSidx.entries[last].offset + Int64(info.aSidx.entries[last].size) - 1
        return (start, end)
    }

    // Transmux one segment: video fragment blob + audio blob (the ranges above) -> MPEG-TS.
    static func muxSegment(_ info: HLSStreamInfo, seg: Int, videoBlob: Data, audioBlob: Data) -> Data? {
        guard seg >= 0, seg < info.vSidx.entries.count else { return nil }
        guard let vSamples = parseFragments(videoBlob, defaults: info.vInit.defaults), !vSamples.isEmpty else { return nil }
        guard let aSamplesAll = parseFragments(audioBlob, defaults: info.aInit.defaults) else { return nil }
        // Trim audio to the video window — the fetched audio fragments straddle the segment
        // boundary; without the trim, boundary samples would be duplicated across segments.
        let (a0, a1) = audioWindow(info, seg: seg)
        let aSamples = aSamplesAll.filter { $0.dts >= a0 && $0.dts < a1 }
        guard !aSamples.isEmpty else { return nil }

        let w = TSWriter()
        w.writePAT()
        w.writePMT()

        // Interleave video and audio access units by DTS (90kHz) — players expect roughly
        // monotonic muxing; big A/V gaps stall AVPlayer's demuxer buffers.
        struct Item { let dts90: Int64; let write: (TSWriter) -> Void }
        var items: [Item] = []
        let vts = info.vSidx.timescale
        for s in vSamples {
            let dts90 = s.dts * 90000 / vts + ptsOffset
            let pts90 = (s.dts + s.ctsOffset) * 90000 / vts + ptsOffset
            let es = annexB(s, nalLengthSize: info.vInit.nalLengthSize, sps: info.vInit.sps, pps: info.vInit.pps)
            let sync = s.isSync
            items.append(Item(dts90: dts90) { tw in
                tw.writePES(pid: tw.videoPID, streamId: 0xE0, pts: pts90, dts: dts90, payload: es,
                            randomAccess: sync, pcr: dts90 - 9000)
            })
        }
        let ats = info.aSidx.timescale
        for s in aSamples {
            let pts90 = s.dts * 90000 / ats + ptsOffset
            let es = adtsFrame(s.data, profile: info.aInit.aacProfile,
                               freqIndex: info.aInit.freqIndex, channels: info.aInit.channelConfig)
            items.append(Item(dts90: pts90) { tw in
                tw.writePES(pid: tw.audioPID, streamId: 0xC0, pts: pts90, dts: nil, payload: es,
                            randomAccess: false, pcr: nil)
            })
        }
        items.sort { $0.dts90 < $1.dts90 }
        for item in items { item.write(w) }
        guard w.ok else { return nil }
        return w.out
    }

    // Segment `seg`'s time window converted to the AUDIO track's timescale.
    private static func audioWindow(_ info: HLSStreamInfo, seg: Int) -> (Int64, Int64) {
        let t0 = info.vSidx.startTimes[seg]
        let t1 = t0 + info.vSidx.entries[seg].duration
        let a0 = t0 * info.aSidx.timescale / info.vSidx.timescale
        let a1 = t1 * info.aSidx.timescale / info.vSidx.timescale
        return (a0, a1)
    }
}
