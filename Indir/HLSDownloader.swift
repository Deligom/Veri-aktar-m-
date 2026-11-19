import Foundation
import AVFoundation
import CommonCrypto

/// HLS (m3u8) akışını parça parça indirip tek bir MP4 dosyası üretir.
/// - MPEG-TS parçaları TSRemuxer ile, fMP4 parçaları uç uca eklenerek birleştirilir.
/// - Ayrı ses akışı varsa görüntüyle birleştirilir.
/// - AES-128 ile şifrelenmiş akışlar çözülür. DRM (SAMPLE-AES/FairPlay) desteklenmez.
final class HLSDownloader {
    struct HLSError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private struct Key: Hashable {
        let url: URL
        let iv: Data?
    }

    private struct Segment {
        let url: URL
        let range: String?
        let key: Key?
        let sequence: Int
    }

    private struct MediaPlaylist {
        var segments: [Segment] = []
        var mapURL: URL?
        var mapRange: String?
    }

    private enum TrackOutput {
        case muxed(URL)       // TS'den üretilmiş MP4 (görüntü ve/veya ses)
        case fragmented(URL)  // fMP4 parçaları uç uca eklenmiş
        case audioFile(URL)   // ADTS AAC dosyası
    }

    let source: URL
    let bitrate: Double?
    let headers: [String: String]
    let workDir: URL
    var onProgress: ((Double) -> Void)?
    var onConverting: (() -> Void)?

    private var keyCache: [URL: Data] = [:]
    private var totalSegments = 0
    private var doneSegments = 0

    init(source: URL, bitrate: Double?, headers: [String: String], workDir: URL) {
        self.source = source
        self.bitrate = bitrate
        self.headers = headers
        self.workDir = workDir
    }

    // MARK: Ana akış

    func run() async throws -> URL {
        try? FileManager.default.removeItem(at: workDir)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)

        let text = try await fetchText(source)
        var videoURL = source
        var audioURL: URL?
        if text.contains("#EXT-X-STREAM-INF") {
            (videoURL, audioURL) = try pickVariant(master: text, base: source)
        }

        let videoPlaylist = try parseMedia(try await fetchText(videoURL), base: videoURL)
        var audioPlaylist: MediaPlaylist?
        if let audioURL, audioURL != videoURL {
            audioPlaylist = try? parseMedia(try await fetchText(audioURL), base: audioURL)
        }
        guard !videoPlaylist.segments.isEmpty else { throw HLSError(message: "Akışta indirilecek parça yok") }
        totalSegments = videoPlaylist.segments.count + (audioPlaylist?.segments.count ?? 0)

        let video = try await downloadTrack(videoPlaylist, name: "video")
        var audio: TrackOutput?
        if let audioPlaylist, !audioPlaylist.segments.isEmpty {
            audio = try? await downloadTrack(audioPlaylist, name: "audio")
        }

        onConverting?()
        let final = workDir.appendingPathComponent("final.mp4")
        try? FileManager.default.removeItem(at: final)

        switch (video, audio) {
        case (.muxed(let v), nil):
            return v
        case (.fragmented(let v), nil):
            if (try? await Self.exportPassthrough(AVURLAsset(url: v), to: final)) != nil { return final }
            return v
        case (let v, let a?):
            let vURL = Self.url(of: v)
            let aURL = Self.url(of: a)
            do {
                try await Self.mux(video: vURL, audio: aURL, to: final)
                return final
            } catch {
                // Ses eklenemezse en azından görüntüyü ver
                if case .muxed(let u) = v { return u }
                if (try? await Self.exportPassthrough(AVURLAsset(url: vURL), to: final)) != nil { return final }
                return vURL
            }
        default:
            throw HLSError(message: "Akış birleştirilemedi")
        }
    }

    private static func url(of t: TrackOutput) -> URL {
        switch t {
        case .muxed(let u), .fragmented(let u), .audioFile(let u): return u
        }
    }

    // MARK: Ana liste

    private func pickVariant(master: String, base: URL) throws -> (URL, URL?) {
        let lines = master.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        struct V { let bw: Double; let height: Int; let audio: String?; let url: URL }
        var variants: [V] = []
        var audioGroups: [String: [(url: URL, isDefault: Bool)]] = [:]
        var i = 0
        while i < lines.count {
            let line = lines[i]
            if line.hasPrefix("#EXT-X-MEDIA:"), attr(line, "TYPE") == "AUDIO",
               let group = attr(line, "GROUP-ID"), let uri = attr(line, "URI"),
               let u = URL(string: uri, relativeTo: base)?.absoluteURL {
                audioGroups[group, default: []].append((u, attr(line, "DEFAULT") == "YES"))
            } else if line.hasPrefix("#EXT-X-STREAM-INF:") {
                var j = i + 1
                while j < lines.count, lines[j].isEmpty || lines[j].hasPrefix("#") { j += 1 }
                if j < lines.count, let u = URL(string: lines[j], relativeTo: base)?.absoluteURL {
                    let bw = Double(attr(line, "BANDWIDTH") ?? "") ?? 0
                    let res = attr(line, "RESOLUTION") ?? ""
                    let h = Int(res.split(separator: "x").last ?? "") ?? 0
                    variants.append(V(bw: bw, height: h, audio: attr(line, "AUDIO"), url: u))
                }
                i = j
            }
            i += 1
        }
        guard !variants.isEmpty else { throw HLSError(message: "Akışta kalite seçeneği bulunamadı") }
        let withVideo = variants.filter { $0.height > 0 }
        let pool = withVideo.isEmpty ? variants : withVideo
        let chosen: V
        if let bitrate, let exact = pool.first(where: { $0.bw == bitrate }) {
            chosen = exact
        } else {
            chosen = pool.max { $0.bw < $1.bw }!
        }
        var audioURL: URL?
        if let g = chosen.audio, let list = audioGroups[g] {
            audioURL = (list.first { $0.isDefault } ?? list.first)?.url
        }
        return (chosen.url, audioURL)
    }

    // MARK: Medya listesi

    private func parseMedia(_ text: String, base: URL) throws -> MediaPlaylist {
        var pl = MediaPlaylist()
        var sequence = 0
        var key: Key?
        var pendingRange: String?
        var lastRangeEnd: [URL: Int64] = [:]
        var index = 0

        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("#EXT-X-MEDIA-SEQUENCE:") {
                sequence = Int(line.dropFirst("#EXT-X-MEDIA-SEQUENCE:".count)) ?? 0
            } else if line.hasPrefix("#EXT-X-KEY:") {
                let method = attr(line, "METHOD") ?? "NONE"
                switch method {
                case "NONE":
                    key = nil
                case "AES-128":
                    guard let uri = attr(line, "URI"), let u = URL(string: uri, relativeTo: base)?.absoluteURL else {
                        throw HLSError(message: "Şifreleme anahtarı bulunamadı")
                    }
                    key = Key(url: u, iv: attr(line, "IV").flatMap(Self.hexData))
                default:
                    throw HLSError(message: "Bu video kopya korumalı (DRM); indirilemez.")
                }
            } else if line.hasPrefix("#EXT-X-MAP:") {
                if let uri = attr(line, "URI") {
                    pl.mapURL = URL(string: uri, relativeTo: base)?.absoluteURL
                    if let br = attr(line, "BYTERANGE") { pl.mapRange = Self.rangeHeader(br, previousEnd: 0).header }
                }
            } else if line.hasPrefix("#EXT-X-BYTERANGE:") {
                pendingRange = String(line.dropFirst("#EXT-X-BYTERANGE:".count))
            } else if !line.hasPrefix("#") {
                guard let u = URL(string: line, relativeTo: base)?.absoluteURL else { continue }
                var header: String?
                if let br = pendingRange {
                    let r = Self.rangeHeader(br, previousEnd: lastRangeEnd[u] ?? 0)
                    header = r.header
                    lastRangeEnd[u] = r.end
                    pendingRange = nil
                }
                pl.segments.append(Segment(url: u, range: header, key: key, sequence: sequence + index))
                index += 1
            }
        }
        return pl
    }

    /// "uzunluk@başlangıç" biçimini HTTP Range başlığına çevirir.
    private static func rangeHeader(_ spec: String, previousEnd: Int64) -> (header: String, end: Int64) {
        let parts = spec.split(separator: "@")
        let length = Int64(parts.first ?? "") ?? 0
        let start = parts.count > 1 ? (Int64(parts[1]) ?? 0) : previousEnd
        return ("bytes=\(start)-\(start + length - 1)", start + length)
    }

    // MARK: Parçaları indirme

    private func downloadTrack(_ pl: MediaPlaylist, name: String) async throws -> TrackOutput {
        if let mapURL = pl.mapURL {
            // fMP4: başlangıç parçası + medya parçaları uç uca
            let out = workDir.appendingPathComponent("\(name).mp4")
            FileManager.default.createFile(atPath: out.path, contents: nil)
            let handle = try FileHandle(forWritingTo: out)
            defer { try? handle.close() }
            var initData = try await fetch(mapURL, range: pl.mapRange)
            if let k = pl.segments.first?.key, pl.mapRange == nil {
                initData = (try? await decrypt(initData, key: k, sequence: 0)) ?? initData
            }
            try handle.write(contentsOf: initData)
            try await forEachSegment(pl.segments) { data in try handle.write(contentsOf: data) }
            return .fragmented(out)
        }

        // İlk parçaya bakıp türünü anla
        let first = try await segmentData(pl.segments[0])
        let bytes = [UInt8](first.prefix(400))
        let stripped = Self.stripID3(first)
        let isTS = bytes.count > 188 && bytes[0] == 0x47 && bytes[188] == 0x47
        let isADTS = stripped.count > 2 && stripped[stripped.startIndex] == 0xFF
            && (stripped[stripped.startIndex + 1] & 0xF0) == 0xF0

        if !isTS && isADTS {
            let out = workDir.appendingPathComponent("\(name).aac")
            FileManager.default.createFile(atPath: out.path, contents: nil)
            let handle = try FileHandle(forWritingTo: out)
            defer { try? handle.close() }
            try handle.write(contentsOf: stripped)
            markDone()
            try await forEachSegment(Array(pl.segments.dropFirst())) { data in
                try handle.write(contentsOf: Self.stripID3(data))
            }
            return .audioFile(out)
        }

        guard isTS else { throw HLSError(message: "Bu akış biçimi desteklenmiyor") }
        let out = workDir.appendingPathComponent("\(name).mp4")
        let remuxer = TSRemuxer(outputURL: out)
        try remuxer.append(segment: first)
        markDone()
        try await forEachSegment(Array(pl.segments.dropFirst())) { data in
            try remuxer.append(segment: data)
        }
        onConverting?()
        try await remuxer.finish()
        return .muxed(out)
    }

    /// Parçaları 4'erli gruplar halinde paralel indirir, sırayla işler.
    private func forEachSegment(_ segments: [Segment], handle: (Data) throws -> Void) async throws {
        var index = 0
        while index < segments.count {
            try Task.checkCancellation()
            let batch = Array(segments[index..<min(index + 4, segments.count)])
            // Anahtarları paralel indirmeden önce sırayla al (önbellek tek iş parçacığından yazılsın)
            for seg in batch {
                if let k = seg.key, keyCache[k.url] == nil { keyCache[k.url] = try await fetch(k.url) }
            }
            let results = try await withThrowingTaskGroup(of: (Int, Data).self) { group -> [Data] in
                for (n, seg) in batch.enumerated() {
                    group.addTask { (n, try await self.segmentData(seg)) }
                }
                var collected = [Data?](repeating: nil, count: batch.count)
                for try await (n, data) in group { collected[n] = data }
                return collected.compactMap { $0 }
            }
            for data in results {
                try handle(data)
                markDone()
            }
            index += batch.count
        }
    }

    private func markDone() {
        doneSegments += 1
        if totalSegments > 0 { onProgress?(min(1, Double(doneSegments) / Double(totalSegments))) }
    }

    private func segmentData(_ seg: Segment) async throws -> Data {
        let data = try await fetch(seg.url, range: seg.range)
        if let k = seg.key { return try await decrypt(data, key: k, sequence: seg.sequence) }
        return data
    }

    // MARK: Ağ

    private func fetch(_ url: URL, range: String? = nil) async throws -> Data {
        var lastError: Error?
        for attempt in 0..<3 {
            try Task.checkCancellation()
            var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
            for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
            if let range { req.setValue(range, forHTTPHeaderField: "Range") }
            do {
                let (data, resp) = try await URLSession.shared.data(for: req)
                if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    throw HLSError(message: "Sunucu parçayı reddetti (\(http.statusCode))")
                }
                return data
            } catch {
                if error is CancellationError { throw error }
                lastError = error
                try? await Task.sleep(nanoseconds: UInt64(attempt + 1) * 700_000_000)
            }
        }
        throw lastError ?? HLSError(message: "Parça indirilemedi")
    }

    private func fetchText(_ url: URL) async throws -> String {
        let data = try await fetch(url)
        guard let text = String(data: data, encoding: .utf8) else { throw HLSError(message: "Akış listesi okunamadı") }
        let trimmed = text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(["\u{FEFF}"]))
        guard trimmed.hasPrefix("#EXTM3U") else { throw HLSError(message: "Geçersiz akış listesi") }
        return trimmed
    }

    // MARK: Şifre çözme

    private func decrypt(_ data: Data, key: Key, sequence: Int) async throws -> Data {
        let keyData: Data
        if let cached = keyCache[key.url] {
            keyData = cached
        } else {
            keyData = try await fetch(key.url)
            keyCache[key.url] = keyData
        }
        guard keyData.count == 16 else { throw HLSError(message: "Şifreleme anahtarı geçersiz") }
        var iv = key.iv ?? Data()
        if iv.count != 16 {
            var seq = UInt64(sequence).bigEndian
            iv = Data(count: 8)
            withUnsafeBytes(of: &seq) { iv.append(contentsOf: $0) }
        }
        return try Self.aesDecrypt(data, key: keyData, iv: iv)
    }

    private static func aesDecrypt(_ data: Data, key: Data, iv: Data) throws -> Data {
        var out = Data(count: data.count + kCCBlockSizeAES128)
        let outCapacity = out.count
        var moved = 0
        let status = out.withUnsafeMutableBytes { o in
            data.withUnsafeBytes { d in
                key.withUnsafeBytes { k in
                    iv.withUnsafeBytes { v in
                        CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES),
                                CCOptions(kCCOptionPKCS7Padding),
                                k.baseAddress, key.count, v.baseAddress,
                                d.baseAddress, data.count,
                                o.baseAddress, outCapacity, &moved)
                    }
                }
            }
        }
        guard status == CCCryptorStatus(kCCSuccess) else { throw HLSError(message: "Akışın şifresi çözülemedi") }
        out.removeSubrange(moved..<out.count)
        return out
    }

    // MARK: Yardımcılar

    private func attr(_ line: String, _ name: String) -> String? {
        let pattern = "(?:^|[:,])\(name)=(\"[^\"]*\"|[^,]*)"
        guard let r = line.range(of: pattern, options: .regularExpression) else { return nil }
        var value = String(line[r])
        if let eq = value.firstIndex(of: "=") { value = String(value[value.index(after: eq)...]) }
        return value.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
    }

    private static func hexData(_ s: String) -> Data? {
        var hex = s.lowercased()
        if hex.hasPrefix("0x") { hex.removeFirst(2) }
        guard hex.count % 2 == 0 else { return nil }
        var data = Data()
        var idx = hex.startIndex
        while idx < hex.endIndex {
            let next = hex.index(idx, offsetBy: 2)
            guard let byte = UInt8(hex[idx..<next], radix: 16) else { return nil }
            data.append(byte)
            idx = next
        }
        return data
    }

    /// Ses parçalarının başındaki ID3 etiketini atar.
    private static func stripID3(_ data: Data) -> Data {
        let b = [UInt8](data.prefix(10))
        guard b.count == 10, b[0] == 0x49, b[1] == 0x44, b[2] == 0x33 else { return data }
        let size = (Int(b[6] & 0x7F) << 21) | (Int(b[7] & 0x7F) << 14) | (Int(b[8] & 0x7F) << 7) | Int(b[9] & 0x7F)
        let skip = 10 + size
        return skip < data.count ? data.subdata(in: (data.startIndex + skip)..<data.endIndex) : data
    }

    // MARK: Birleştirme

    static func mux(video: URL, audio: URL, to out: URL) async throws {
        let comp = AVMutableComposition()
        let va = AVURLAsset(url: video)
        let aa = AVURLAsset(url: audio)
        guard let vt = try await va.loadTracks(withMediaType: .video).first else {
            throw HLSError(message: "Görüntü bulunamadı")
        }
        let vRange = try await vt.load(.timeRange)
        let cv = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        try cv?.insertTimeRange(vRange, of: vt, at: .zero)
        if let t = try? await vt.load(.preferredTransform) { cv?.preferredTransform = t }

        let audioTracks = (try? await aa.loadTracks(withMediaType: .audio)) ?? []
        if let at = audioTracks.first {
            let aRange = try await at.load(.timeRange)
            let duration = CMTimeMinimum(aRange.duration, vRange.duration)
            let ca = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
            try ca?.insertTimeRange(CMTimeRange(start: aRange.start, duration: duration), of: at, at: .zero)
        }
        try await exportPassthrough(comp, to: out)
    }

    static func exportPassthrough(_ asset: AVAsset, to out: URL) async throws {
        try? FileManager.default.removeItem(at: out)
        guard let ex = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            throw HLSError(message: "Dışa aktarma başlatılamadı")
        }
        guard ex.supportedFileTypes.contains(.mp4) else { throw HLSError(message: "MP4 olarak kaydedilemiyor") }
        ex.outputURL = out
        ex.outputFileType = .mp4
        ex.shouldOptimizeForNetworkUse = true
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            ex.exportAsynchronously { c.resume() }
        }
        guard ex.status == .completed else {
            throw HLSError(message: ex.error?.localizedDescription ?? "Dışa aktarma başarısız")
        }
    }
}
