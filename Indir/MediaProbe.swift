import Foundation

/// Yakalanan adresleri indirmeden önce dener: gerçekten video mu, boyutu ne, hangi kaliteler var?
enum MediaProbe {
    struct FileInfo {
        let size: Int64?
        let mime: String
    }

    struct Variant {
        let bandwidth: Double?
        let height: Int
        let estimatedSize: Int64?
        let isMaster: Bool
    }

    static func request(_ url: URL, headers: [String: String]) -> URLRequest {
        var r = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 12)
        for (k, v) in headers { r.setValue(v, forHTTPHeaderField: k) }
        return r
    }

    /// İlk 2 baytı isteyerek dosyanın açılıp açılmadığını ve toplam boyutunu öğrenir.
    static func probeFile(_ url: URL, headers: [String: String]) async -> FileInfo? {
        var req = request(url, headers: headers)
        req.setValue("bytes=0-1", forHTTPHeaderField: "Range")
        guard let result = try? await URLSession.shared.bytes(for: req) else { return nil }
        result.0.task.cancel()
        guard let http = result.1 as? HTTPURLResponse,
              http.statusCode == 200 || http.statusCode == 206 else { return nil }
        let mime = (http.mimeType ?? "").lowercased()
        if mime.hasPrefix("text/") || mime.contains("json") || mime.contains("xml")
            || mime.hasPrefix("image/") || mime.contains("javascript") || mime.contains("mpegurl") {
            return nil
        }
        var size: Int64?
        if let range = http.value(forHTTPHeaderField: "Content-Range"),
           let total = range.split(separator: "/").last, let n = Int64(total) {
            size = n
        } else if http.statusCode == 200, http.expectedContentLength > 0 {
            size = http.expectedContentLength
        }
        if let s = size, s < 50_000 { return nil }   // reklam/önizleme kırıntıları
        return FileInfo(size: size, mime: mime)
    }

    static func fetchPlaylist(_ url: URL, headers: [String: String]) async -> String? {
        guard let result = try? await URLSession.shared.data(for: request(url, headers: headers)),
              let http = result.1 as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              result.0.count < 3_000_000,
              let text = String(data: result.0, encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(["\u{FEFF}"]))
        return trimmed.hasPrefix("#EXTM3U") ? trimmed : nil
    }

    /// m3u8'i çözer. Ana listeyse her kalite için bir seçenek döner (boyut tahminiyle).
    static func resolveHLS(_ url: URL, headers: [String: String]) async -> [Variant]? {
        guard let text = await fetchPlaylist(url, headers: headers) else { return nil }
        let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }

        guard text.contains("#EXT-X-STREAM-INF") else {
            // Tek kaliteli medya listesi
            return [Variant(bandwidth: nil, height: 0, estimatedSize: nil, isMaster: false)]
        }

        struct Raw { let bw: Double; let avg: Double?; let height: Int; let uri: URL }
        var raws: [Raw] = []
        var i = 0
        while i < lines.count {
            let line = lines[i]
            if line.hasPrefix("#EXT-X-STREAM-INF:") {
                let attrs = String(line.dropFirst("#EXT-X-STREAM-INF:".count))
                var j = i + 1
                while j < lines.count, lines[j].isEmpty || lines[j].hasPrefix("#") { j += 1 }
                if j < lines.count,
                   let uri = URL(string: lines[j], relativeTo: url)?.absoluteURL,
                   let bw = number(attrs, "BANDWIDTH") {
                    raws.append(Raw(bw: bw, avg: number(attrs, "AVERAGE-BANDWIDTH"), height: height(attrs), uri: uri))
                }
                i = j
            }
            i += 1
        }
        if raws.contains(where: { $0.height > 0 }) { raws.removeAll { $0.height == 0 } }  // yalnız ses olanlar
        guard !raws.isEmpty else { return nil }

        var duration: Double?
        if let first = raws.first, let t = await fetchPlaylist(first.uri, headers: headers) {
            duration = totalDuration(t)
        }

        var best: [Int: Raw] = [:]
        for r in raws {
            if let cur = best[r.height], cur.bw >= r.bw { continue }
            best[r.height] = r
        }
        return best.values
            .sorted { $0.height > $1.height }
            .map { r in
                let rate = r.avg ?? r.bw
                return Variant(bandwidth: r.bw, height: r.height,
                               estimatedSize: duration.map { Int64($0 * rate / 8) },
                               isMaster: true)
            }
    }

    static func totalDuration(_ text: String) -> Double? {
        var total = 0.0
        for line in text.components(separatedBy: .newlines) where line.hasPrefix("#EXTINF:") {
            let value = line.dropFirst("#EXTINF:".count).split(separator: ",").first.map(String.init) ?? ""
            total += Double(value.trimmingCharacters(in: .whitespaces)) ?? 0
        }
        return total > 0 ? total : nil
    }

    /// Dosya yolundaki "720p", "1080" gibi ifadelerden kaliteyi tahmin eder.
    static func heightFromURL(_ url: URL) -> Int {
        let path = url.path
        guard let r = path.range(of: "(?<![0-9])(2160|1440|1080|720|540|480|360|240)p?(?![0-9])",
                                 options: .regularExpression) else { return 0 }
        return Int(path[r].trimmingCharacters(in: CharacterSet(charactersIn: "p"))) ?? 0
    }

    static func extLabel(mime: String, url: URL) -> String {
        let map = ["video/mp4": "MP4", "video/quicktime": "MOV", "video/webm": "WEBM",
                   "video/x-matroska": "MKV", "video/3gpp": "3GP", "video/x-m4v": "M4V"]
        if let e = map[mime] { return e }
        let e = url.pathExtension.uppercased()
        return ["MP4", "M4V", "MOV", "WEBM", "MKV", "3GP"].contains(e) ? e : "MP4"
    }

    private static func number(_ attrs: String, _ key: String) -> Double? {
        guard let r = attrs.range(of: "(?:^|,)\(key)=[0-9.]+", options: .regularExpression) else { return nil }
        let s = attrs[r]
        guard let eq = s.firstIndex(of: "=") else { return nil }
        return Double(s[s.index(after: eq)...])
    }

    private static func height(_ attrs: String) -> Int {
        guard let r = attrs.range(of: "RESOLUTION=[0-9]+x[0-9]+", options: .regularExpression) else { return 0 }
        return Int(attrs[r].split(separator: "x").last ?? "") ?? 0
    }
}
