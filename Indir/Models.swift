import SwiftUI

enum Theme {
    static let accent = Color(red: 0.93, green: 0.22, blue: 0.38)
}

enum MediaKind: String, Codable {
    case file   // doğrudan dosya (mp4, mov, webm...)
    case hls    // akış (m3u8)
}

/// Tarayıcıda yakalanan bir video adresi.
struct DetectedMedia: Identifiable, Hashable {
    var id: String { url.absoluteString }
    let url: URL
    let kind: MediaKind
    var title: String
    var pageURL: URL?
    var foundAt = Date()

    var displayName: String {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { return t }
        let last = url.deletingPathExtension().lastPathComponent
        return last.isEmpty ? (url.host ?? "Video") : last
    }

    var formatLabel: String {
        if kind == .hls { return "Akış (HLS)" }
        let ext = url.pathExtension.uppercased()
        return ext.isEmpty ? "Video" : ext
    }
}

struct Bookmark: Codable, Identifiable, Hashable {
    var id = UUID()
    var title: String
    var url: String
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
