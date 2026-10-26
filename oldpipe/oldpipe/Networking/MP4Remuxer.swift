import Foundation

// MARK: - MP4Remuxer
//
// Offline HLS bundle -> one flat .mp4, so a downloaded video can be saved to the Photos library.
// UISaveVideoAtPathToSavedPhotosAlbum only takes a single MP4/MOV file, and every download
// above the muxed 360p is stored as index.m3u8 + seg<i>.ts (see DownloadManager).
//
// The input is ALWAYS a bundle written by HLSTransmuxer, so this only has to read what its
// TSWriter produces:
//   video — one PES per access unit, PTS+DTS, Annex-B: an AUD first, the avcC's SPS/PPS
//           re-inserted on sync samples (random_access_indicator set), then the sample's own
//           NALs untouched.
//   audio — one PES per AAC frame, PTS only, a 7-byte ADTS header in front.
// Undoing exactly those insertions gives back the original DASH samples byte for byte, which
// is what the build-server round-trip test checks against the googlevideo source.
//
// Output: ftyp, mdat, moov. The mdat is streamed to disk one segment at a time — a 1080p file
// is hundreds of MB against a 512 MB phone — and moov goes last, which is also what
// AVAssetWriter and the Camera write. It is built as "<out>.part" and renamed only once
// complete, so a half-written file can never reach Photos.
//
// PURE data-in/data-out like HLSTransmuxer: no UIKit, no networking. POSIX stdio rather than
// FileHandle.write, which raises an uncatchable ObjC exception when the disk fills up.
//
// All timestamp arithmetic is Int64: Int is 32 bits on armv7 and 90 kHz PTS values are 33.

final class MP4Remuxer {

    // Segments listed in the bundle's playlist (0 = no readable playlist).
    static func segmentCount(bundleDir: String) -> Int {
        let path = (bundleDir as NSString).appendingPathComponent("index.m3u8")
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return 0 }
        var n = 0
        for line in text.split(separator: "\n") where line.hasPrefix("seg") && line.hasSuffix(".ts") {
            n += 1
        }
        return n
    }

    // Remux the bundle in `bundleDir` into `outPath`. `maxSegments` stops early — the Photos
    // compatibility probe converts only the first segment. `progress(done, total)` runs on the
    // calling thread after each segment. Returns nil on success, otherwise a short reason for
    // the debug log; a failed or cancelled run leaves no file behind.
    static func remux(bundleDir: String, outPath: String, maxSegments: Int = Int.max,
                      progress: ((Int, Int) -> Void)? = nil,
                      shouldAbort: () -> Bool = { false }) -> String? {
        let total = min(segmentCount(bundleDir: bundleDir), maxSegments)
        guard total > 0 else { return "no segments" }
        let part = outPath + ".part"
        unlink(part)
        guard let file = MP4File(path: part) else { return "cannot create output" }
        let session = RemuxSession(file: file)

        var failure: String?
        for i in 0..<total {
            if shouldAbort() { failure = "cancelled"; break }
            let segPath = (bundleDir as NSString).appendingPathComponent("seg\(i).ts")
            failure = autoreleasepool { () -> String? in
                guard let data = try? Data(contentsOf: URL(fileURLWithPath: segPath), options: .alwaysMapped)
                else { return "missing seg\(i).ts" }
                return session.addSegment(data, index: i)
            }
            if failure != nil { break }
            progress?(i + 1, total)
        }
        if failure == nil { failure = session.finish() }
        let closed = file.close()
        if failure == nil && !closed { failure = "write failed (disk full?)" }
        if failure == nil && rename(part, outPath) != 0 { failure = "rename failed" }
        if failure != nil { unlink(part) }
        return failure
    }
}

// MARK: - Output file

private final class MP4File {
    private let fp: UnsafeMutablePointer<FILE>
    private(set) var position: Int64 = 0
    private(set) var failed = false

    init?(path: String) {
        guard let f = fopen(path, "wb") else { return nil }
        fp = f
    }

    func write(_ b: UnsafeBufferPointer<UInt8>) {
        guard !failed, let base = b.baseAddress, b.count > 0 else { return }
        if fwrite(base, 1, b.count, fp) != b.count { failed = true }
        position += Int64(b.count)
    }

    func write(_ b: [UInt8]) { b.withUnsafeBufferPointer { write($0) } }

    // Overwrite 4 bytes at `offset` — the mdat size, only known once every segment is in.
    func patch32(_ v: UInt32, at offset: Int64) {
        guard !failed else { return }
        let b: [UInt8] = [UInt8(v >> 24), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]
        if fseeko(fp, offset, SEEK_SET) != 0 || fwrite(b, 1, 4, fp) != 4 || fseeko(fp, 0, SEEK_END) != 0 {
            failed = true
        }
    }

    // false if any write failed, a full disk included.
    func close() -> Bool {
        let flushed = fflush(fp) == 0
        return fclose(fp) == 0 && flushed && !failed
    }
}

// MARK: - Box builder (big-endian, sizes patched on end())

private struct BoxBuilder {
    var bytes: [UInt8] = []
    private var open: [Int] = []

    mutating func u8(_ v: Int) { bytes.append(UInt8(truncatingIfNeeded: v)) }
    mutating func u16(_ v: Int) { u8(v >> 8); u8(v) }
    mutating func u32(_ v: Int64) {
        let x = UInt32(truncatingIfNeeded: v)
        bytes.append(UInt8(x >> 24)); bytes.append(UInt8((x >> 16) & 0xFF))
        bytes.append(UInt8((x >> 8) & 0xFF)); bytes.append(UInt8(x & 0xFF))
    }
    mutating func zeros(_ n: Int) { bytes.append(contentsOf: [UInt8](repeating: 0, count: n)) }
    mutating func raw(_ b: [UInt8]) { bytes.append(contentsOf: b) }
    mutating func fourCC(_ s: String) { bytes.append(contentsOf: Array(s.utf8)) }

    mutating func begin(_ type: String) {
        open.append(bytes.count)
        u32(0)
        fourCC(type)
    }

    mutating func beginFull(_ type: String, version: Int = 0, flags: Int = 0) {
        begin(type)
        u8(version); u8(flags >> 16); u8(flags >> 8); u8(flags)
    }

    mutating func end() {
        let start = open.removeLast()
        let size = UInt32(bytes.count - start)
        bytes[start] = UInt8(size >> 24)
        bytes[start + 1] = UInt8((size >> 16) & 0xFF)
        bytes[start + 2] = UInt8((size >> 8) & 0xFF)
        bytes[start + 3] = UInt8(size & 0xFF)
    }

    mutating func identityMatrix() {
        for v: Int64 in [0x0001_0000, 0, 0, 0, 0x0001_0000, 0, 0, 0, 0x4000_0000] { u32(v) }
    }
}

// MARK: - The remux itself

private let aacRates: [Int64] = [96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050,
                                 16000, 12000, 11025, 8000, 7350]
private let movieTimescale: Int64 = 600   // what Apple's own writers use for mvhd

private struct VideoSample { let size: Int; let dts: Int64; let pts: Int64; let sync: Bool }
private struct AudioFrame { let size: Int; let pts: Int64 }
private struct Chunk { let offset: Int64; let count: Int }

private final class RemuxSession {
    private let file: MP4File
    private let mdatOffset: Int64

    // Read from the PAT/PMT rather than assuming TSWriter's 256/257.
    private var pmtPID = -1, videoPID = -1, audioPID = -1

    // Whole-file sample tables — small (a 3.5 min 1080p30 video is ~6k frames).
    private var sps: [[UInt8]] = [], pps: [[UInt8]] = []
    private var vSizes: [UInt32] = [], vDTS: [Int64] = [], vPTS: [Int64] = []
    private var vSyncNumbers: [Int64] = []          // 1-based, for stss
    private var vChunks: [Chunk] = []

    private var aProfile = -1, aFreqIndex = -1, aChannels = -1
    private var aSizes: [UInt32] = []
    private var aChunks: [Chunk] = []
    private var aFirstPTS: Int64 = 0                // continuity origin: first frame SEEN
    private var aSeen: Int64 = 0                    // frames seen, the trimmed ones included
    private var aMediaTime: Int64 = 0               // audio elst media_time, in samples
    private var aEmptyEdit90: Int64 = 0             // silence before a late audio start
    private var aMaxFrame = 0
    private var aBytes: Int64 = 0
    private var started = false

    // Per-segment scratch, reused with keepingCapacity so a segment costs no reallocation.
    private var pesV: [UInt8] = [], pesA: [UInt8] = []
    private var pesVRandomAccess = false
    private var segV: [UInt8] = [], segA: [UInt8] = []
    private var segVSamples: [VideoSample] = [], segAFrames: [AudioFrame] = []

    init(file: MP4File) {
        self.file = file
        var b = BoxBuilder()
        b.begin("ftyp")   // byte-for-byte what AVAssetExportSession writes
        b.fourCC("mp42"); b.u32(1)
        b.fourCC("isom"); b.fourCC("mp41"); b.fourCC("mp42")
        b.end()
        file.write(b.bytes)
        mdatOffset = file.position
        file.write([0, 0, 0, 0, 0x6D, 0x64, 0x61, 0x74])   // "mdat", size patched in finish()
    }

    // MARK: Segment in

    func addSegment(_ data: Data, index: Int) -> String? {
        guard data.count > 0, data.count % 188 == 0 else { return "seg\(index): not whole TS packets" }
        segV.removeAll(keepingCapacity: true)
        segA.removeAll(keepingCapacity: true)
        segVSamples.removeAll(keepingCapacity: true)
        segAFrames.removeAll(keepingCapacity: true)
        segV.reserveCapacity(data.count)

        var failure = data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> String? in
            return demux(raw.bindMemory(to: UInt8.self))
        }
        // Video PES are unbounded (length 0) and end only where the next one starts, so the
        // segment's last frame is still pending here. Dropping it would also corrupt every
        // B-frame that references it.
        if failure == nil { failure = flushVideo() }
        if failure == nil { failure = flushAudio() }
        if let f = failure { return "seg\(index): \(f)" }
        guard !segVSamples.isEmpty else { return "seg\(index): no video" }
        if !started {
            if let f = alignStart() { return "seg\(index): \(f)" }
            started = true
        }
        if let f = writeInterleaved() { return "seg\(index): \(f)" }
        return file.failed ? "write failed (disk full?)" : nil
    }

    private func demux(_ p: UnsafeBufferPointer<UInt8>) -> String? {
        var off = 0
        while off < p.count {
            guard p[off] == 0x47 else { return "lost TS sync" }
            let b1 = p[off + 1]
            let pusi = b1 & 0x40 != 0
            let pid = Int(b1 & 0x1F) << 8 | Int(p[off + 2])
            let afc = (p[off + 3] >> 4) & 0x3
            let end = off + 188
            var pos = off + 4
            var randomAccess = false
            if afc & 0x2 != 0 {
                let afLen = Int(p[pos])
                guard afLen <= 183 else { return "bad adaptation field" }
                if afLen > 0 { randomAccess = p[pos + 1] & 0x40 != 0 }
                pos += 1 + afLen   // skips TSWriter's stuffing along with the flags
            }
            off = end
            guard afc & 0x1 != 0, pos < end else { continue }
            let payload = UnsafeBufferPointer(rebasing: p[pos..<end])
            if pid == 0 {
                if pusi { parsePAT(payload) }
            } else if pid == pmtPID {
                if pusi { parsePMT(payload) }
            } else if pid == videoPID {
                if pusi {
                    if let f = flushVideo() { return f }
                    pesVRandomAccess = randomAccess
                }
                if pusi || !pesV.isEmpty { pesV.append(contentsOf: payload) }
            } else if pid == audioPID {
                if pusi, let f = flushAudio() { return f }
                if pusi || !pesA.isEmpty { pesA.append(contentsOf: payload) }
            }
        }
        return nil
    }

    // PSI sections fit in one packet here: TSWriter writes each as a single packet.
    private func parsePAT(_ b: UnsafeBufferPointer<UInt8>) {
        let o = 1 + Int(b[0])                       // pointer_field
        guard b.count >= o + 12, b[o] == 0x00 else { return }
        let sectionLen = Int(b[o + 1] & 0x0F) << 8 | Int(b[o + 2])
        let end = min(b.count, o + 3 + sectionLen - 4)
        var q = o + 8
        while q + 4 <= end {
            let program = Int(b[q]) << 8 | Int(b[q + 1])
            if program != 0 { pmtPID = Int(b[q + 2] & 0x1F) << 8 | Int(b[q + 3]) }
            q += 4
        }
    }

    private func parsePMT(_ b: UnsafeBufferPointer<UInt8>) {
        let o = 1 + Int(b[0])
        guard b.count >= o + 12, b[o] == 0x02 else { return }
        let sectionLen = Int(b[o + 1] & 0x0F) << 8 | Int(b[o + 2])
        let end = min(b.count, o + 3 + sectionLen - 4)
        let programInfoLen = Int(b[o + 10] & 0x0F) << 8 | Int(b[o + 11])
        var q = o + 12 + programInfoLen
        while q + 5 <= end {
            let streamType = b[q]
            let pid = Int(b[q + 1] & 0x1F) << 8 | Int(b[q + 2])
            let esInfoLen = Int(b[q + 3] & 0x0F) << 8 | Int(b[q + 4])
            if streamType == 0x1B && videoPID < 0 { videoPID = pid }
            if streamType == 0x0F && audioPID < 0 { audioPID = pid }
            q += 5 + esInfoLen
        }
    }

    // MARK: Elementary streams

    private func flushVideo() -> String? {
        guard !pesV.isEmpty else { return nil }
        defer { pesV.removeAll(keepingCapacity: true) }
        return pesV.withUnsafeBufferPointer { b -> String? in
            guard let h = pesHeader(b) else { return "bad video PES" }
            let sampleStart = segV.count
            // TSWriter puts SPS/PPS in front of every keyframe; they belong in avcC, not in
            // the sample. Only the run straight after the AUD is stripped — parameter sets the
            // encoder itself placed further in are the sample's own and stay.
            var stripping = pesVRandomAccess
            var newSPS: [[UInt8]] = [], newPPS: [[UInt8]] = []
            var hasIDR = false
            for (i, r) in nalRanges(b, from: h.start).enumerated() {
                let type = b[r.lowerBound] & 0x1F
                if i == 0 && type == 9 { continue }          // TSWriter's access-unit delimiter
                if stripping && (type == 7 || type == 8) {
                    if type == 7 { newSPS.append(Array(b[r])) } else { newPPS.append(Array(b[r])) }
                    continue
                }
                stripping = false
                if type == 5 { hasIDR = true }
                let n = r.count
                segV.append(UInt8(truncatingIfNeeded: n >> 24))
                segV.append(UInt8(truncatingIfNeeded: n >> 16))
                segV.append(UInt8(truncatingIfNeeded: n >> 8))
                segV.append(UInt8(truncatingIfNeeded: n))
                segV.append(contentsOf: UnsafeBufferPointer(rebasing: b[r]))
            }
            if pesVRandomAccess {
                guard !newSPS.isEmpty, !newPPS.isEmpty else { return "keyframe without SPS/PPS" }
                if sps.isEmpty {
                    sps = newSPS
                    pps = newPPS
                } else if newSPS != sps || newPPS != pps {
                    return "SPS/PPS change mid-stream"   // one avcC cannot describe that
                }
            }
            // stss comes from the TS flag (it mirrors the source's own sync table); an IDR
            // disagreeing with it means we misread something, and a wrong stss gives black
            // video until the next keyframe.
            if hasIDR != pesVRandomAccess { return "keyframe flag disagrees with the frame" }
            if !started && segVSamples.isEmpty && !hasIDR { return "does not start on a keyframe" }
            let size = segV.count - sampleStart
            guard size > 0 else { return "empty video frame" }
            segVSamples.append(VideoSample(size: size, dts: h.dts, pts: h.pts, sync: pesVRandomAccess))
            return nil
        }
    }

    private func flushAudio() -> String? {
        guard !pesA.isEmpty else { return nil }
        defer { pesA.removeAll(keepingCapacity: true) }
        return pesA.withUnsafeBufferPointer { b -> String? in
            guard let h = pesHeader(b) else { return "bad audio PES" }
            let declared = Int(b[4]) << 8 | Int(b[5])
            let end = declared > 0 ? min(b.count, 6 + declared) : b.count
            var o = h.start
            var k: Int64 = 0
            while o + 7 <= end {
                guard b[o] == 0xFF, b[o + 1] & 0xF6 == 0xF0 else { return "bad ADTS header" }
                guard b[o + 6] & 0x03 == 0 else { return "multi-block ADTS" }
                let headerLen = b[o + 1] & 0x01 != 0 ? 7 : 9
                let lenHi = Int(b[o + 3] & 0x03) << 11
                let lenLo = Int(b[o + 4]) << 3 | Int(b[o + 5] >> 5)
                let frameLen = lenHi | lenLo
                guard frameLen > headerLen, o + frameLen <= end else { return "bad ADTS length" }
                let profile = Int(b[o + 2] >> 6)
                let freqIndex = Int((b[o + 2] >> 2) & 0x0F)
                let channels = Int(b[o + 2] & 0x01) << 2 | Int(b[o + 3] >> 6)
                if aFreqIndex < 0 {
                    guard freqIndex < aacRates.count, channels > 0 else { return "unsupported AAC config" }
                    aProfile = profile
                    aFreqIndex = freqIndex
                    aChannels = channels
                } else if profile != aProfile || freqIndex != aFreqIndex || channels != aChannels {
                    return "AAC config changes mid-stream"
                }
                let pts = h.pts + k * 1024 * 90000 / aacRates[aFreqIndex]
                segA.append(contentsOf: UnsafeBufferPointer(rebasing: b[(o + headerLen)..<(o + frameLen)]))
                segAFrames.append(AudioFrame(size: frameLen - headerLen, pts: pts))
                o += frameLen
                k += 1
            }
            return nil
        }
    }

    // MARK: Timeline

    // Line the tracks up the way the original DASH file did: its video track's edit list starts
    // presentation at the first displayed frame (skipping the B-frame delay) and its audio
    // starts at 0, both against the same zero — which in our TS is the first video DTS.
    // (HLSTransmuxer drops that edit list, so HLS playback runs audio about a frame early; the
    // exported file gets the original sync back.)
    private func alignStart() -> String? {
        guard let first = segAFrames.first else { return "no audio" }
        let rate = aacRates[aFreqIndex]
        let origin = segVSamples[0].dts
        aFirstPTS = first.pts
        if first.pts < origin {
            // Audio starts before the video: drop the whole frames that end before it and let
            // the elst skip the remainder.
            let samples = (origin - first.pts) * rate / 90000
            let drop = Int(samples / 1024)
            guard drop < segAFrames.count else { return "audio ends before video starts" }
            aMediaTime = samples % 1024
            if drop > 0 {
                var bytes = 0
                for f in segAFrames[0..<drop] { bytes += f.size }
                segA.removeFirst(bytes)
                segAFrames.removeFirst(drop)
                aSeen = Int64(drop)
            }
        } else if (first.pts - origin) * rate / 90000 > 1024 {
            aEmptyEdit90 = first.pts - origin   // more than a frame late: keep the gap
        }
        return nil
    }

    // ~1 s chunks, video then audio, alternating — Apple's own writer interleaves the same way,
    // so playback never seeks far between the tracks.
    private func writeInterleaved() -> String? {
        let rate = aacRates[aFreqIndex]
        var vi = 0, ai = 0, vByte = 0, aByte = 0
        var windowEnd = segVSamples[0].dts + 90000
        while vi < segVSamples.count || ai < segAFrames.count {
            let v0 = vi, vb0 = vByte
            while vi < segVSamples.count && segVSamples[vi].dts < windowEnd {
                let s = segVSamples[vi]
                if let last = vDTS.last, s.dts <= last { return "video timestamps go backwards" }
                vSizes.append(UInt32(s.size))
                vDTS.append(s.dts)
                vPTS.append(s.pts)
                if s.sync { vSyncNumbers.append(Int64(vSizes.count)) }
                vByte += s.size
                vi += 1
            }
            if vi > v0 {
                vChunks.append(Chunk(offset: file.position, count: vi - v0))
                segV.withUnsafeBufferPointer { file.write(UnsafeBufferPointer(rebasing: $0[vb0..<vByte])) }
            }

            let a0 = ai, ab0 = aByte
            while ai < segAFrames.count && segAFrames[ai].pts < windowEnd {
                let f = segAFrames[ai]
                // One stts entry of 1024s is only true if the frames are back to back.
                let expected = aFirstPTS + aSeen * 1024 * 90000 / rate
                guard abs(f.pts - expected) <= 2 else { return "audio gap at frame \(aSeen)" }
                aSeen += 1
                aSizes.append(UInt32(f.size))
                aMaxFrame = max(aMaxFrame, f.size)
                aBytes += Int64(f.size)
                aByte += f.size
                ai += 1
            }
            if ai > a0 {
                aChunks.append(Chunk(offset: file.position, count: ai - a0))
                segA.withUnsafeBufferPointer { file.write(UnsafeBufferPointer(rebasing: $0[ab0..<aByte])) }
            }

            if vi == v0 && ai == a0 {
                // Nothing in this window — jump to whichever track comes next.
                let nextV = vi < segVSamples.count ? segVSamples[vi].dts : Int64.max
                let nextA = ai < segAFrames.count ? segAFrames[ai].pts : Int64.max
                windowEnd = min(nextV, nextA) + 90000
            } else {
                windowEnd += 90000
            }
        }
        return nil
    }

    // MARK: moov

    func finish() -> String? {
        let vCount = vSizes.count, aCount = aSizes.count
        guard vCount > 0, aCount > 0, let sps0 = sps.first, sps0.count >= 4, !pps.isEmpty
        else { return "nothing to write" }
        guard let dims = spsDimensions(sps0) else { return "unreadable SPS" }

        let mdatSize = file.position - mdatOffset
        guard mdatSize <= Int64(UInt32.max) else { return "over 4 GB" }
        file.patch32(UInt32(mdatSize), at: mdatOffset)

        // Video timing, 90 kHz. The last frame repeats the previous frame's duration.
        var deltas = [Int64](repeating: 0, count: vCount)
        for i in 0..<vCount {
            if i + 1 < vCount { deltas[i] = vDTS[i + 1] - vDTS[i] }
            else { deltas[i] = vCount > 1 ? deltas[i - 1] : 3000 }
        }
        let vMediaDur = vDTS[vCount - 1] - vDTS[0] + deltas[vCount - 1]
        var minOffset = Int64.max, minPTS = Int64.max, maxPTS = Int64.min
        for i in 0..<vCount {
            minOffset = min(minOffset, vPTS[i] - vDTS[i])
            minPTS = min(minPTS, vPTS[i])
            maxPTS = max(maxPTS, vPTS[i])
        }
        // ctts v0 is unsigned (negative offsets are not safe on iOS 5): shift them all up and
        // let the edit list absorb the shift.
        let cttsShift = max(0, -minOffset)
        let vMediaTime = minPTS - vDTS[0] + cttsShift
        // First displayed frame to the end of the last one. With B-frames this reaches past
        // Σstts by the reorder delay — YouTube's own DASH edit list does exactly the same.
        let vPresented = maxPTS + deltas[vCount - 1] - minPTS
        let vEditDur = vPresented * movieTimescale / 90000

        // Audio timing, in samples.
        let rate = aacRates[aFreqIndex]
        let aMediaDur = Int64(aCount) * 1024
        let aEmptyDur = aEmptyEdit90 * movieTimescale / 90000
        let aEditDur = (aMediaDur - aMediaTime) * movieTimescale / rate
        let aTotal = aEmptyDur + aEditDur
        let movieDur = max(vEditDur, aTotal)

        // Structural self-check: tables that disagree play on a Mac and fail on old iOS.
        var vInChunks = 0, aInChunks = 0
        for c in vChunks { vInChunks += c.count }
        for c in aChunks { aInChunks += c.count }
        let dataEnd = mdatOffset + mdatSize
        let offsetsOK = (vChunks + aChunks).allSatisfy { $0.offset >= mdatOffset + 8 && $0.offset < dataEnd }
        guard vInChunks == vCount, aInChunks == aCount, offsetsOK,
              vSyncNumbers.first == 1, vMediaTime >= 0, vEditDur > 0, aEditDur > 0
        else { return "inconsistent sample tables" }

        let now = Int64(Date().timeIntervalSince1970) + 2_082_844_800   // seconds since 1904
        var m = BoxBuilder()
        m.begin("moov")

        m.beginFull("mvhd")
        m.u32(now); m.u32(now); m.u32(movieTimescale); m.u32(movieDur)
        m.u32(0x0001_0000); m.u16(0x0100); m.zeros(10)
        m.identityMatrix()
        m.zeros(24); m.u32(3)
        m.end()

        // Video track
        m.begin("trak")
        writeTkhd(&m, id: 1, duration: vEditDur, audio: false, width: dims.width, height: dims.height, now: now)
        writeEdts(&m, emptyDur: 0, editDur: vEditDur, mediaTime: vMediaTime)
        m.begin("mdia")
        writeMdhd(&m, timescale: 90000, duration: vMediaDur, now: now)
        writeHdlr(&m, type: "vide", name: "VideoHandler")
        m.begin("minf")
        m.beginFull("vmhd", flags: 1); m.zeros(8); m.end()
        writeDinf(&m)
        m.begin("stbl")
        m.beginFull("stsd"); m.u32(1)
        m.begin("avc1")
        m.zeros(6); m.u16(1); m.zeros(16)
        m.u16(dims.width); m.u16(dims.height)
        m.u32(0x0048_0000); m.u32(0x0048_0000); m.u32(0)
        m.u16(1); m.zeros(32); m.u16(0x0018); m.u16(0xFFFF)
        m.begin("avcC")   // no High-profile extension bytes: older readers predate them
        m.u8(1); m.u8(Int(sps0[1])); m.u8(Int(sps0[2])); m.u8(Int(sps0[3])); m.u8(0xFF)
        m.u8(0xE0 | sps.count)
        for s in sps { m.u16(s.count); m.raw(s) }
        m.u8(pps.count)
        for p in pps { m.u16(p.count); m.raw(p) }
        m.end()
        m.end()   // avc1
        m.end()   // stsd
        writeRuns(&m, "stts", deltas)
        var offsets = [Int64](repeating: 0, count: vCount)
        var anyOffset = false
        for i in 0..<vCount {
            offsets[i] = vPTS[i] - vDTS[i] + cttsShift
            if offsets[i] != 0 { anyOffset = true }
        }
        if anyOffset { writeRuns(&m, "ctts", offsets) }
        m.beginFull("stss"); m.u32(Int64(vSyncNumbers.count))
        for n in vSyncNumbers { m.u32(n) }
        m.end()
        writeChunkTables(&m, sizes: vSizes, chunks: vChunks)
        m.end(); m.end(); m.end()   // stbl, minf, mdia
        m.end()   // trak

        // Audio track
        m.begin("trak")
        writeTkhd(&m, id: 2, duration: aTotal, audio: true, width: 0, height: 0, now: now)
        writeEdts(&m, emptyDur: aEmptyDur, editDur: aEditDur, mediaTime: aMediaTime)
        m.begin("mdia")
        writeMdhd(&m, timescale: rate, duration: aMediaDur, now: now)
        writeHdlr(&m, type: "soun", name: "SoundHandler")
        m.begin("minf")
        m.beginFull("smhd"); m.zeros(4); m.end()
        writeDinf(&m)
        m.begin("stbl")
        m.beginFull("stsd"); m.u32(1)
        m.begin("mp4a")
        m.zeros(6); m.u16(1); m.zeros(8)
        m.u16(aChannels == 7 ? 8 : aChannels); m.u16(16); m.u16(0); m.u16(0)
        m.u32(rate << 16)
        let avgBitrate = aBytes * 8 * rate / aMediaDur
        m.beginFull("esds")
        m.u8(0x03); m.u8(25); m.u16(0); m.u8(0)                 // ES_Descriptor
        m.u8(0x04); m.u8(17); m.u8(0x40)                        // DecoderConfig, MPEG-4 audio
        m.u8(0x15)                                              // streamType 5 << 2 | reserved 1
        m.u8(aMaxFrame >> 16); m.u8(aMaxFrame >> 8); m.u8(aMaxFrame)
        m.u32(avgBitrate); m.u32(avgBitrate)
        let objectType = aProfile + 1
        m.u8(0x05); m.u8(2)                                     // AudioSpecificConfig
        m.u8(objectType << 3 | aFreqIndex >> 1)
        m.u8((aFreqIndex & 1) << 7 | aChannels << 3)
        m.u8(0x06); m.u8(1); m.u8(0x02)                         // SLConfig
        m.end()   // esds
        m.end()   // mp4a
        m.end()   // stsd
        m.beginFull("stts"); m.u32(1); m.u32(Int64(aCount)); m.u32(1024); m.end()
        writeChunkTables(&m, sizes: aSizes, chunks: aChunks)
        m.end(); m.end(); m.end()   // stbl, minf, mdia
        m.end()   // trak

        m.end()   // moov
        file.write(m.bytes)
        return file.failed ? "write failed (disk full?)" : nil
    }

    private func writeTkhd(_ m: inout BoxBuilder, id: Int64, duration: Int64, audio: Bool,
                           width: Int, height: Int, now: Int64) {
        m.beginFull("tkhd", flags: 3)   // enabled + in movie; a disabled track is ignored
        m.u32(now); m.u32(now); m.u32(id); m.u32(0); m.u32(duration)
        m.zeros(8); m.u16(0); m.u16(0); m.u16(audio ? 0x0100 : 0); m.u16(0)
        m.identityMatrix()
        m.u32(Int64(width) << 16); m.u32(Int64(height) << 16)
        m.end()
    }

    // media_time is in the track's own timescale, the durations in the movie's.
    private func writeEdts(_ m: inout BoxBuilder, emptyDur: Int64, editDur: Int64, mediaTime: Int64) {
        m.begin("edts")
        m.beginFull("elst")
        m.u32(emptyDur > 0 ? 2 : 1)
        if emptyDur > 0 { m.u32(emptyDur); m.u32(-1); m.u32(0x0001_0000) }
        m.u32(editDur); m.u32(mediaTime); m.u32(0x0001_0000)
        m.end()
        m.end()
    }

    private func writeMdhd(_ m: inout BoxBuilder, timescale: Int64, duration: Int64, now: Int64) {
        m.beginFull("mdhd")
        m.u32(now); m.u32(now); m.u32(timescale); m.u32(duration)
        m.u16(0x55C4); m.u16(0)   // language "und"
        m.end()
    }

    private func writeHdlr(_ m: inout BoxBuilder, type: String, name: String) {
        m.beginFull("hdlr")
        m.u32(0); m.fourCC(type); m.zeros(12)
        m.fourCC(name); m.u8(0)
        m.end()
    }

    private func writeDinf(_ m: inout BoxBuilder) {
        m.begin("dinf")
        m.beginFull("dref"); m.u32(1)
        m.beginFull("url ", flags: 1); m.end()   // flag 1: the media is in this file
        m.end()
        m.end()
    }

    // stts / ctts: run-length (count, value) pairs.
    private func writeRuns(_ m: inout BoxBuilder, _ type: String, _ values: [Int64]) {
        var runs: [(count: Int64, value: Int64)] = []
        for v in values {
            if let last = runs.last, last.value == v { runs[runs.count - 1].count += 1 }
            else { runs.append((1, v)) }
        }
        m.beginFull(type); m.u32(Int64(runs.count))
        for r in runs { m.u32(r.count); m.u32(r.value) }
        m.end()
    }

    private func writeChunkTables(_ m: inout BoxBuilder, sizes: [UInt32], chunks: [Chunk]) {
        // stsc: a new entry only where samples-per-chunk changes.
        var stsc: [(first: Int64, count: Int)] = []
        for (i, c) in chunks.enumerated() where stsc.last?.count != c.count {
            stsc.append((Int64(i + 1), c.count))
        }
        m.beginFull("stsc"); m.u32(Int64(stsc.count))
        for e in stsc { m.u32(e.first); m.u32(Int64(e.count)); m.u32(1) }
        m.end()
        m.beginFull("stsz"); m.u32(0); m.u32(Int64(sizes.count))
        for s in sizes { m.u32(Int64(s)) }
        m.end()
        m.beginFull("stco"); m.u32(Int64(chunks.count))
        for c in chunks { m.u32(c.offset) }
        m.end()
    }
}

// MARK: - PES / NAL helpers

// PTS (and DTS when present) plus where the elementary stream starts.
private func pesHeader(_ b: UnsafeBufferPointer<UInt8>) -> (pts: Int64, dts: Int64, start: Int)? {
    guard b.count >= 14, b[0] == 0, b[1] == 0, b[2] == 1 else { return nil }
    let flags = b[7] >> 6
    let headerLen = Int(b[8])
    let start = 9 + headerLen
    guard flags & 0x2 != 0, headerLen >= 5, b.count >= start else { return nil }
    let pts = pesTimestamp(b, 9)
    if flags == 3 {
        guard headerLen >= 10 else { return nil }
        return (pts, pesTimestamp(b, 14), start)
    }
    return (pts, pts, start)
}

private func pesTimestamp(_ b: UnsafeBufferPointer<UInt8>, _ o: Int) -> Int64 {
    let hi = Int64((b[o] >> 1) & 0x07) << 30
    let mid = Int64(b[o + 1]) << 22 | Int64(b[o + 2] >> 1) << 15
    let lo = Int64(b[o + 3]) << 7 | Int64(b[o + 4] >> 1)
    return hi | mid | lo
}

// NAL units between Annex-B start codes. A NAL never ends in a zero byte (it ends with the
// rbsp stop bit), so zeros in front of a start code belong to the start code — which is what
// makes a 4-byte 00 00 00 01 come apart cleanly.
private func nalRanges(_ b: UnsafeBufferPointer<UInt8>, from: Int) -> [Range<Int>] {
    var out: [Range<Int>] = []
    var start = -1
    var i = from
    let n = b.count
    func close(_ end: Int) {
        var e = end
        while e > start && b[e - 1] == 0 { e -= 1 }
        if e > start { out.append(start..<e) }
    }
    while i + 2 < n {
        if b[i + 2] > 1 { i += 3; continue }   // no start code can begin at i, i+1 or i+2
        if b[i] == 0 && b[i + 1] == 0 && b[i + 2] == 1 {
            if start >= 0 { close(i) }
            start = i + 3
            i += 3
        } else {
            i += 1
        }
    }
    if start >= 0 && start < n { close(n) }
    return out
}

// MARK: - SPS -> display size

private struct BitReader {
    private let b: [UInt8]
    private var pos = 0
    private(set) var ok = true

    init(_ b: [UInt8]) { self.b = b }

    mutating func bit() -> Int {
        guard pos < b.count * 8 else { ok = false; return 0 }
        let v = Int(b[pos >> 3] >> UInt8(7 - (pos & 7))) & 1
        pos += 1
        return v
    }

    mutating func bits(_ n: Int) -> Int {
        var v = 0
        for _ in 0..<n { v = v << 1 | bit() }
        return v
    }

    // Exp-Golomb. Every field read here is small, so >16 leading zeros means garbage.
    mutating func ue() -> Int {
        var zeros = 0
        while bit() == 0 {
            zeros += 1
            if zeros > 16 || !ok { ok = false; return 0 }
        }
        return (1 << zeros) - 1 + bits(zeros)
    }

    mutating func se() -> Int {
        let k = ue()
        return k & 1 != 0 ? (k + 1) / 2 : -(k / 2)
    }
}

// The cropped picture size from an SPS NAL (header byte included). The TS does not carry the
// original avc1 width/height, and tkhd/avc1 must state them.
private func spsDimensions(_ nal: [UInt8]) -> (width: Int, height: Int)? {
    var rbsp: [UInt8] = []
    rbsp.reserveCapacity(nal.count)
    var zeros = 0
    for byte in nal.dropFirst() {                 // emulation prevention: 00 00 03 -> 00 00
        if zeros >= 2 && byte == 3 { zeros = 0; continue }
        zeros = byte == 0 ? zeros + 1 : 0
        rbsp.append(byte)
    }
    var r = BitReader(rbsp)
    let profile = r.bits(8)
    _ = r.bits(16)                                // constraint flags, level
    _ = r.ue()                                    // seq_parameter_set_id
    var chromaFormat = 1, separatePlanes = 0
    if [100, 110, 122, 244, 44, 83, 86, 118, 128, 138, 139, 134, 135].contains(profile) {
        chromaFormat = r.ue()
        if chromaFormat == 3 { separatePlanes = r.bit() }
        _ = r.ue(); _ = r.ue(); _ = r.bit()       // bit depths, qpprime bypass
        if r.bit() == 1 {                         // seq_scaling_matrix_present: skip the lists
            for i in 0..<(chromaFormat == 3 ? 12 : 8) {
                guard r.bit() == 1 else { continue }
                var last = 8, next = 8
                for _ in 0..<(i < 6 ? 16 : 64) {
                    if next != 0 { next = (last + r.se() + 256) % 256 }
                    if next != 0 { last = next }
                }
            }
        }
    }
    _ = r.ue()                                    // log2_max_frame_num_minus4
    let pocType = r.ue()
    if pocType == 0 {
        _ = r.ue()
    } else if pocType == 1 {
        _ = r.bit(); _ = r.se(); _ = r.se()
        let n = r.ue()
        guard n < 256 else { return nil }
        for _ in 0..<n { _ = r.se() }
    }
    _ = r.ue(); _ = r.bit()                       // max_num_ref_frames, gaps allowed
    let widthMbs = r.ue() + 1
    let heightUnits = r.ue() + 1
    let frameMbsOnly = r.bit()
    if frameMbsOnly == 0 { _ = r.bit() }
    _ = r.bit()                                   // direct_8x8_inference
    var left = 0, right = 0, top = 0, bottom = 0
    if r.bit() == 1 { left = r.ue(); right = r.ue(); top = r.ue(); bottom = r.ue() }
    guard r.ok else { return nil }
    let chromaArrayType = separatePlanes == 1 ? 0 : chromaFormat
    let cropX = (chromaArrayType == 1 || chromaArrayType == 2) ? 2 : 1
    let cropY = (chromaArrayType == 1 ? 2 : 1) * (2 - frameMbsOnly)
    let width = widthMbs * 16 - (left + right) * cropX
    let height = (2 - frameMbsOnly) * heightUnits * 16 - (top + bottom) * cropY
    guard width > 0, height > 0 else { return nil }
    return (width, height)
}
