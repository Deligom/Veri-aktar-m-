import Foundation
import AVFoundation
import CoreMedia
import AudioToolbox

/// MPEG-TS parçalarındaki H.264 görüntü ve AAC sesi, yeniden kodlamadan MP4 kabına taşır.
/// Parçalar sırayla `append` ile verilir, en sonda `finish` çağrılır.
final class TSRemuxer {
    enum RemuxError: LocalizedError {
        case unsupported(String)
        case writer(String)
        var errorDescription: String? {
            switch self {
            case .unsupported(let s), .writer(let s): return s
            }
        }
    }

    private struct Sample {
        let isVideo: Bool
        let data: Data
        var pts: Int64      // 90 kHz
        var dts: Int64
        let key: Bool
    }

    private let outputURL: URL

    // TS durumu (parçalar arasında korunur)
    private var pmtPID: Int?
    private var videoPID: Int?
    private var audioPID: Int?
    private var videoIsHEVC = false
    private var pes: [Int: [UInt8]] = [:]
    private var sps: Data?
    private var pps: Data?
    private var sawKeyframe = false
    private var base: Int64?

    // Yazıcı
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var videoFormat: CMVideoFormatDescription?
    private var audioFormat: CMAudioFormatDescription?
    private var held: [Sample] = []
    private var sessionStarted = false
    private var pendingVideo: Sample?
    private var pendingAudio: Sample?
    private var lastDTS: [Bool: Int64] = [:]
    private var lastDuration: [Bool: Int64] = [true: 3000, false: 1920]
    private var offset: Int64 = 0

    // Yazılmayı bekleyen hazır örnekler. Yazıcı ses ve görüntünün zamanca iç içe gelmesini ister;
    // hangisi kabul ediliyorsa ondan verilir, böylece ikisi birbirini beklerken kilitlenmez.
    private var videoQueue: [(sb: CMSampleBuffer, dts: Int64)] = []
    private var audioQueue: [(sb: CMSampleBuffer, dts: Int64)] = []
    private var videoFinished = false
    private var audioFinished = false

    init(outputURL: URL) {
        self.outputURL = outputURL
    }

    // MARK: Genel

    func append(segment: Data) throws {
        var samples: [Sample] = []
        parse([UInt8](segment), into: &samples)
        for pid in Array(pes.keys) {
            if let buf = pes[pid], !buf.isEmpty { handlePES(pid: pid, buf, into: &samples) }
            pes[pid] = nil
        }
        if videoIsHEVC {
            throw RemuxError.unsupported("Bu video H.265 (HEVC) biçiminde yayınlanıyor; şimdilik desteklenmiyor.")
        }
        try write(samples)
    }

    func finish() async throws {
        if writer == nil {
            guard !held.isEmpty else { throw RemuxError.unsupported("Akışta video bulunamadı.") }
            try setupWriter()
            let h = held
            held = []
            try write(h)
        }
        guard let w = writer else { throw RemuxError.unsupported("Akışta video bulunamadı.") }
        if let p = pendingVideo, let input = videoInput { try appendSample(p, duration: lastDuration[true] ?? 3000, input: input) }
        if let p = pendingAudio, let input = audioInput { try appendSample(p, duration: lastDuration[false] ?? 1920, input: input) }
        pendingVideo = nil
        pendingAudio = nil
        try drain(final: true)
        if !videoFinished { videoInput?.markAsFinished() }
        if !audioFinished { audioInput?.markAsFinished() }
        await w.finishWriting()
        guard w.status == .completed else {
            throw RemuxError.writer("MP4 yazılamadı: \(w.error?.localizedDescription ?? "bilinmeyen hata")")
        }
    }

    // MARK: TS ayrıştırma

    private func parse(_ b: [UInt8], into out: inout [Sample]) {
        var i = 0
        while i + 188 <= b.count {
            guard b[i] == 0x47 else { i += 1; continue }
            let p = i
            i += 188
            let pusi = b[p + 1] & 0x40 != 0
            let pid = (Int(b[p + 1] & 0x1F) << 8) | Int(b[p + 2])
            let afc = (b[p + 3] >> 4) & 0x3
            if afc == 0 || afc == 2 { continue }
            var off = p + 4
            if afc == 3 { off += 1 + Int(b[p + 4]) }
            guard off < p + 188 else { continue }
            let payload = b[off..<(p + 188)]

            if pid == 0 {
                if pusi { parsePAT(Array(payload)) }
                continue
            }
            if let pmt = pmtPID, pid == pmt {
                if pusi { parsePMT(Array(payload)) }
                continue
            }
            guard pid == videoPID || pid == audioPID else { continue }
            if pusi {
                if let buf = pes[pid], !buf.isEmpty { handlePES(pid: pid, buf, into: &out) }
                pes[pid] = Array(payload)
            } else if pes[pid] != nil {
                pes[pid]?.append(contentsOf: payload)
            }
        }
    }

    private func parsePAT(_ p: [UInt8]) {
        guard !p.isEmpty else { return }
        var i = 1 + Int(p[0])
        guard i + 8 <= p.count else { return }
        let sectionLength = (Int(p[i + 1] & 0x0F) << 8) | Int(p[i + 2])
        let end = min(p.count, i + 3 + sectionLength - 4)
        i += 8
        while i + 4 <= end {
            let program = (Int(p[i]) << 8) | Int(p[i + 1])
            let pid = (Int(p[i + 2] & 0x1F) << 8) | Int(p[i + 3])
            if program != 0 { pmtPID = pid; return }
            i += 4
        }
    }

    private func parsePMT(_ p: [UInt8]) {
        guard !p.isEmpty else { return }
        var i = 1 + Int(p[0])
        guard i + 12 <= p.count else { return }
        let sectionLength = (Int(p[i + 1] & 0x0F) << 8) | Int(p[i + 2])
        let end = min(p.count, i + 3 + sectionLength - 4)
        let programInfoLength = (Int(p[i + 10] & 0x0F) << 8) | Int(p[i + 11])
        i += 12 + programInfoLength
        while i + 5 <= end {
            let type = p[i]
            let pid = (Int(p[i + 1] & 0x1F) << 8) | Int(p[i + 2])
            let esInfo = (Int(p[i + 3] & 0x0F) << 8) | Int(p[i + 4])
            switch type {
            case 0x1B: if videoPID == nil { videoPID = pid }
            case 0x24: if videoPID == nil { videoPID = pid; videoIsHEVC = true }
            case 0x0F: if audioPID == nil { audioPID = pid }
            default: break
            }
            i += 5 + esInfo
        }
    }

    private func handlePES(pid: Int, _ b: [UInt8], into out: inout [Sample]) {
        guard b.count > 9, b[0] == 0, b[1] == 0, b[2] == 1 else { return }
        let flags = b[7]
        let start = 9 + Int(b[8])
        guard start < b.count else { return }
        guard flags & 0x80 != 0, b.count >= 14 else { return }
        let pts = readTimestamp(b, 9)
        let dts = (flags & 0x40 != 0 && b.count >= 19) ? readTimestamp(b, 14) : pts
        let payload = Array(b[start...])
        if pid == videoPID {
            handleVideo(payload, pts: unwrap(pts), dts: unwrap(dts), into: &out)
        } else {
            handleAudio(payload, pts: unwrap(pts), into: &out)
        }
    }

    private func readTimestamp(_ b: [UInt8], _ i: Int) -> Int64 {
        (Int64(b[i] & 0x0E) << 29) | (Int64(b[i + 1]) << 22) | (Int64(b[i + 2] & 0xFE) << 14)
            | (Int64(b[i + 3]) << 7) | (Int64(b[i + 4]) >> 1)
    }

    /// 33 bitlik saat taşmasını düzeltir.
    private func unwrap(_ v: Int64) -> Int64 {
        if base == nil { base = v }
        if let b = base, v < b - (Int64(1) << 32) { return v + (Int64(1) << 33) }
        return v
    }

    // MARK: H.264

    private func handleVideo(_ es: [UInt8], pts: Int64, dts: Int64, into out: inout [Sample]) {
        guard !videoIsHEVC else { return }
        var avcc = Data()
        var key = false
        for nal in splitAnnexB(es) where !nal.isEmpty {
            let type = nal[nal.startIndex] & 0x1F
            switch type {
            case 7: sps = Data(nal); continue
            case 8: pps = Data(nal); continue
            case 9: continue    // erişim birimi ayırıcı
            case 5: key = true
            default: break
            }
            var len = UInt32(nal.count).bigEndian
            withUnsafeBytes(of: &len) { avcc.append(contentsOf: $0) }
            avcc.append(contentsOf: nal)
        }
        guard !avcc.isEmpty else { return }
        if videoFormat == nil, let sps, let pps { videoFormat = makeH264Format(sps: sps, pps: pps) }
        guard videoFormat != nil else { return }
        if !sawKeyframe {
            guard key else { return }
            sawKeyframe = true
        }
        out.append(Sample(isVideo: true, data: avcc, pts: pts, dts: min(dts, pts), key: key))
    }

    private func splitAnnexB(_ b: [UInt8]) -> [ArraySlice<UInt8>] {
        var result: [ArraySlice<UInt8>] = []
        var i = 0
        var start = -1
        let n = b.count
        func close(_ endIndex: Int) {
            guard start >= 0 else { return }
            var end = endIndex
            while end > start && b[end - 1] == 0 { end -= 1 }
            if end > start { result.append(b[start..<end]) }
        }
        while i + 2 < n {
            if b[i] == 0 && b[i + 1] == 0 && b[i + 2] == 1 {
                close(i)
                i += 3
                start = i
                continue
            }
            i += 1
        }
        close(n)
        return result
    }

    private func makeH264Format(sps: Data, pps: Data) -> CMVideoFormatDescription? {
        var fmt: CMVideoFormatDescription?
        let status: OSStatus = sps.withUnsafeBytes { s in
            pps.withUnsafeBytes { p in
                guard let sp = s.bindMemory(to: UInt8.self).baseAddress,
                      let pp = p.bindMemory(to: UInt8.self).baseAddress else { return -1 }
                let pointers: [UnsafePointer<UInt8>] = [sp, pp]
                let sizes: [Int] = [sps.count, pps.count]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault, parameterSetCount: 2,
                    parameterSetPointers: pointers, parameterSetSizes: sizes,
                    nalUnitHeaderLength: 4, formatDescriptionOut: &fmt)
            }
        }
        return status == noErr ? fmt : nil
    }

    // MARK: AAC (ADTS)

    private func handleAudio(_ es: [UInt8], pts: Int64, into out: inout [Sample]) {
        let rates = [96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350]
        var i = 0
        var frame = 0
        while i + 7 <= es.count {
            guard es[i] == 0xFF, es[i + 1] & 0xF0 == 0xF0 else { i += 1; continue }
            let headerLen = (es[i + 1] & 0x01) == 1 ? 7 : 9
            let objectType = Int((es[i + 2] >> 6) & 0x3) + 1
            let freqIndex = Int((es[i + 2] >> 2) & 0xF)
            let channels = Int(((es[i + 2] & 0x1) << 2) | ((es[i + 3] >> 6) & 0x3))
            let frameLen = (Int(es[i + 3] & 0x3) << 11) | (Int(es[i + 4]) << 3) | Int(es[i + 5] >> 5)
            guard freqIndex < rates.count, frameLen > headerLen, i + frameLen <= es.count else { break }
            let rate = rates[freqIndex]
            if audioFormat == nil {
                audioFormat = makeAACFormat(objectType: objectType, freqIndex: freqIndex, rate: rate, channels: channels)
            }
            let t = pts + Int64((Double(frame) * 1024.0 * 90000.0 / Double(rate)).rounded())
            out.append(Sample(isVideo: false, data: Data(es[(i + headerLen)..<(i + frameLen)]), pts: t, dts: t, key: true))
            frame += 1
            i += frameLen
        }
    }

    private func makeAACFormat(objectType: Int, freqIndex: Int, rate: Int, channels: Int) -> CMAudioFormatDescription? {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: Float64(rate), mFormatID: kAudioFormatMPEG4AAC, mFormatFlags: 0,
            mBytesPerPacket: 0, mFramesPerPacket: 1024, mBytesPerFrame: 0,
            mChannelsPerFrame: UInt32(max(1, channels)), mBitsPerChannel: 0, mReserved: 0)
        // AudioSpecificConfig
        let asc: [UInt8] = [
            UInt8(((objectType & 0x1F) << 3) | ((freqIndex >> 1) & 0x7)),
            UInt8(((freqIndex & 0x1) << 7) | ((channels & 0xF) << 3)),
        ]
        var fmt: CMAudioFormatDescription?
        let status = asc.withUnsafeBytes { ptr in
            CMAudioFormatDescriptionCreate(
                allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0, layout: nil,
                magicCookieSize: asc.count, magicCookie: ptr.baseAddress,
                extensions: nil, formatDescriptionOut: &fmt)
        }
        return status == noErr ? fmt : nil
    }

    // MARK: Yazma

    private var formatsReady: Bool {
        (videoPID == nil || videoFormat != nil) && (audioPID == nil || audioFormat != nil)
    }

    private func setupWriter() throws {
        try? FileManager.default.removeItem(at: outputURL)
        let w: AVAssetWriter
        do {
            w = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        } catch {
            throw RemuxError.writer("MP4 dosyası oluşturulamadı: \(error.localizedDescription)")
        }
        if let vf = videoFormat {
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: vf)
            input.expectsMediaDataInRealTime = false
            if w.canAdd(input) { w.add(input); videoInput = input }
        }
        if let af = audioFormat {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: af)
            input.expectsMediaDataInRealTime = false
            if w.canAdd(input) { w.add(input); audioInput = input }
        }
        guard videoInput != nil || audioInput != nil else {
            throw RemuxError.unsupported("Akışta desteklenen görüntü ya da ses bulunamadı.")
        }
        guard w.startWriting() else {
            throw RemuxError.writer("MP4 yazımı başlatılamadı: \(w.error?.localizedDescription ?? "")")
        }
        writer = w
    }

    private func write(_ incoming: [Sample]) throws {
        if writer == nil {
            held.append(contentsOf: incoming)
            guard formatsReady, !held.isEmpty else { return }
            try setupWriter()
            let all = held
            held = []
            try writeSorted(all)
        } else {
            try writeSorted(incoming)
        }
    }

    private func writeSorted(_ samples: [Sample]) throws {
        let sorted = samples.sorted { $0.dts < $1.dts }
        for var s in sorted {
            // Zaman çizgisini sürekli tut: yayın kesintilerinde (reklam, yeni klip, sunucu
            // değişimi) zaman damgaları ileri ya da geri sıçrayabilir. 2 saniyeden büyük ileri
            // ya da 1 saniyeden büyük geri sıçramaları kapat; yoksa son kare dakikalarca donar.
            s.pts += offset
            s.dts += offset
            if let last = lastDTS[s.isVideo] {
                let expected = last + (lastDuration[s.isVideo] ?? (s.isVideo ? 3000 : 1920))
                let delta = s.dts - expected
                if delta > 180_000 || delta < -90_000 {
                    offset -= delta
                    s.pts -= delta
                    s.dts -= delta
                }
            }
            if let last = lastDTS[s.isVideo], s.dts <= last {
                let fix = last + 1 - s.dts
                s.dts += fix
                s.pts = max(s.pts, s.dts)
            }
            lastDTS[s.isVideo] = s.dts

            guard let input = s.isVideo ? videoInput : audioInput else { continue }
            if !sessionStarted, let w = writer {
                w.startSession(atSourceTime: CMTime(value: s.pts, timescale: 90_000))
                sessionStarted = true
            }
            if s.isVideo {
                if let p = pendingVideo {
                    let d = s.dts - p.dts
                    if d > 0 { lastDuration[true] = d }
                    try appendSample(p, duration: d > 0 ? d : (lastDuration[true] ?? 3000), input: input)
                }
                pendingVideo = s
            } else {
                if let p = pendingAudio {
                    let d = s.dts - p.dts
                    if d > 0 { lastDuration[false] = d }
                    try appendSample(p, duration: d > 0 ? d : (lastDuration[false] ?? 1920), input: input)
                }
                pendingAudio = s
            }
        }
        try drain(final: false)
    }

    private func appendSample(_ s: Sample, duration: Int64, input: AVAssetWriterInput) throws {
        guard let format: CMFormatDescription = s.isVideo ? videoFormat : audioFormat,
              let sb = makeSampleBuffer(s, duration: duration, format: format) else { return }
        if s.isVideo {
            videoQueue.append((sb, s.dts))
        } else {
            audioQueue.append((sb, s.dts))
        }
    }

    /// Kuyruktaki örnekleri yazıcıya verir. `final` değilse yazıcı başka veri beklediğinde
    /// geri döner (sonraki parçayla devam edilir); `final` ise hepsi yazılana kadar sürer.
    private func drain(final: Bool) throws {
        var idle = 0
        while !videoQueue.isEmpty || !audioQueue.isEmpty {
            if writer?.status == .failed {
                throw RemuxError.writer("MP4 yazılamadı: \(writer?.error?.localizedDescription ?? "")")
            }
            if final {
                // Bitmiş kanalı kapat ki diğeri onu beklemesin
                if videoQueue.isEmpty, !videoFinished, let v = videoInput { v.markAsFinished(); videoFinished = true }
                if audioQueue.isEmpty, !audioFinished, let a = audioInput { a.markAsFinished(); audioFinished = true }
            }
            var pickVideo: Bool?
            let videoReady = !videoQueue.isEmpty && videoInput?.isReadyForMoreMediaData == true
            let audioReady = !audioQueue.isEmpty && audioInput?.isReadyForMoreMediaData == true
            if videoReady && audioReady {
                pickVideo = videoQueue[0].dts <= audioQueue[0].dts
            } else if videoReady {
                pickVideo = true
            } else if audioReady {
                pickVideo = false
            }

            if let isVideo = pickVideo, let input = isVideo ? videoInput : audioInput {
                let item = isVideo ? videoQueue.removeFirst() : audioQueue.removeFirst()
                if !input.append(item.sb) {
                    throw RemuxError.writer("MP4 yazılamadı: \(writer?.error?.localizedDescription ?? "örnek eklenemedi")")
                }
                idle = 0
                continue
            }

            // Hiçbiri kabul edilmiyor
            if !final && idle > 100 {
                // Bir kanal uzun süre hiç veri getirmiyorsa (ör. ses kesildi) onu kapat, bellek şişmesin
                if videoQueue.count > 4000, audioQueue.isEmpty, !audioFinished, let a = audioInput {
                    a.markAsFinished(); audioFinished = true; idle = 0; continue
                }
                if audioQueue.count > 8000, videoQueue.isEmpty, !videoFinished, let v = videoInput {
                    v.markAsFinished(); videoFinished = true; idle = 0; continue
                }
                return
            }
            usleep(2000)
            idle += 1
            if idle > 15000 { throw RemuxError.writer("MP4 yazıcısı yanıt vermiyor") }
        }
    }

    private func makeSampleBuffer(_ s: Sample, duration: Int64, format: CMFormatDescription) -> CMSampleBuffer? {
        let len = s.data.count
        guard len > 0 else { return nil }
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: len,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
            dataLength: len, flags: 0, blockBufferOut: &block) == noErr, let block else { return nil }
        let copied: OSStatus = s.data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return -1 }
            return CMBlockBufferReplaceDataBytes(with: base, blockBuffer: block,
                                                 offsetIntoDestination: 0, dataLength: len)
        }
        guard copied == noErr else { return nil }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: max(1, duration), timescale: 90_000),
            presentationTimeStamp: CMTime(value: s.pts, timescale: 90_000),
            decodeTimeStamp: s.isVideo ? CMTime(value: s.dts, timescale: 90_000) : .invalid)
        var size = len
        var sb: CMSampleBuffer?
        guard CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
            sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sb) == noErr,
              let sb else { return nil }

        if s.isVideo && !s.key,
           let attachments = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict,
                                 Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return sb
    }
}
