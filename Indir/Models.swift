import SwiftUI

enum Theme {
    static let accent = Color(red: 0.93, green: 0.22, blue: 0.38)
}

enum MediaKind: String, Codable {
    case file   // doğrudan dosya (mp4, mov, webm...)
    case hls    // akış (m3u8), indirilince MP4'e çevrilir
}

/// Kontrol edilmiş, indirilebilir bir video seçeneği.
struct DetectedMedia: Identifiable, Hashable {
    let id = UUID()
    let url: URL
    let kind: MediaKind
    var title: String
    var pageURL: URL?
    var height: Int = 0
    var size: Int64?
    var sizeIsEstimate = false
    var hlsBitrate: Double?
    var ext = "MP4"

    var displayName: String {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { return t }
        let last = url.deletingPathExtension().lastPathComponent
        return last.isEmpty ? (url.host ?? "Video") : last
    }

    var qualityBadge: String {
        if height >= 2160 { return "4K" }
        if height > 0 { return "\(height)p" }
        return ext
    }

    var detailLabel: String {
        [ext, url.host ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    var sizeLabel: String? {
        guard let size, size > 0 else { return nil }
        return (sizeIsEstimate ? "~" : "") + ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }
}

struct Bookmark: Codable, Identifiable, Hashable {
    var id = UUID()
    var title: String
    var url: String
}

struct HistoryEntry: Codable, Identifiable, Hashable {
    var id = UUID()
    var title: String
    var url: String
    var date: Date
}

enum DownloadState: String, Codable {
    case downloading, converting, done, failed
}

struct DownloadItem: Codable, Identifiable, Equatable {
    var id = UUID()
    var title: String
    var sourceURL: URL
    var pageURL: URL?
    var kind: MediaKind
    var headers: [String: String] = [:]
    var hlsBitrate: Double?
    var fileName: String?
    var packagePath: String?
    var state: DownloadState = .downloading
    var progress: Double = 0
    var receivedBytes: Int64 = 0
    var totalBytes: Int64 = 0
    var errorMessage: String?
    var createdAt = Date()
    var savedToPhotos = false
}

extension Notification.Name {
    static let showDownloads = Notification.Name("indir.showDownloads")
}
