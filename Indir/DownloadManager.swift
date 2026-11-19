import Foundation
import AVFoundation
import Photos
import UIKit

/// İndirmeleri yönetir. Doğrudan dosyalar için arka plan URLSession,
/// HLS (m3u8) akışları için AVAssetDownloadURLSession kullanır; akışlar sonra MP4'e çevrilir.
/// Tüm delege çağrıları ana kuyrukta gelir.
final class DownloadManager: NSObject, ObservableObject {
    static let shared = DownloadManager()

    @Published private(set) var items: [DownloadItem] = []
    @Published var message: String?

    var backgroundCompletionHandlers: [String: () -> Void] = [:]

    private var fileSession: URLSession!
    private var hlsSession: AVAssetDownloadURLSession!
    private var tasks: [UUID: URLSessionTask] = [:]
    private var pendingErrors: [UUID: String] = [:]
    private var lastTick: [UUID: Date] = [:]
    private var reservedNames = Set<String>()

    static var documents: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    private static var indexURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("downloads.json")
    }

    var activeCount: Int {
        items.filter { $0.state == .downloading || $0.state == .converting }.count
    }

    private override init() {
        super.init()
        load()

        let fc = URLSessionConfiguration.background(withIdentifier: "indir.files")
        fc.httpShouldSetCookies = false
        fc.isDiscretionary = false
        fc.sessionSendsLaunchEvents = true
        fileSession = URLSession(configuration: fc, delegate: self, delegateQueue: .main)

        let hc = URLSessionConfiguration.background(withIdentifier: "indir.hls")
        hc.isDiscretionary = false
        hc.sessionSendsLaunchEvents = true
        hlsSession = AVAssetDownloadURLSession(configuration: hc, assetDownloadDelegate: self, delegateQueue: .main)

        reconnect()
    }

    // MARK: - Genel işlemler

    func start(url: URL, title: String, pageURL: URL?, kind: MediaKind, headers: [String: String],
               hlsBitrate: Double? = nil) {
        var item = DownloadItem(title: title, sourceURL: url, pageURL: pageURL, kind: kind, headers: headers)
        item.hlsBitrate = hlsBitrate
        items.insert(item, at: 0)
        launch(item)
        save()
    }

    func retry(_ id: UUID) {
        update(id) {
            $0.state = .downloading
            $0.progress = 0
            $0.receivedBytes = 0
            $0.totalBytes = 0
            $0.errorMessage = nil
        }
        if let item = item(id) { launch(item) }
        save()
    }

    func cancel(_ id: UUID) {
        tasks[id]?.cancel()
        tasks[id] = nil
        fail(id, "İptal edildi")
    }

    func delete(_ id: UUID) {
        tasks[id]?.cancel()
        tasks[id] = nil
        if let item = item(id) {
            if let url = fileURL(item) { try? FileManager.default.removeItem(at: url) }
            if let pkg = packageURL(item) { try? FileManager.default.removeItem(at: pkg) }
        }
        items.removeAll { $0.id == id }
        save()
    }

    func clearFailed() {
        for item in items where item.state == .failed {
            delete(item.id)
        }
    }

    func fileURL(_ item: DownloadItem) -> URL? {
        guard let name = item.fileName else { return nil }
        let url = Self.documents.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Dosyalar uygulamasından silinen videoları listeden çıkarır.
    func pruneMissing() {
        let before = items.count
        items.removeAll { $0.state == .done && fileURL($0) == nil }
        if items.count != before { save() }
    }

    func saveToPhotos(_ id: UUID, announce: Bool) {
        guard let item = item(id), let url = fileURL(item) else { return }
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                DispatchQueue.main.async {
                    self.message = "Fotoğraflar izni yok. Ayarlar > İndir > Fotoğraflar bölümünden izin verin."
                }
                return
            }
            PHPhotoLibrary.shared().performChanges({
                _ = PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
            }) { ok, _ in
                DispatchQueue.main.async {
                    if ok {
                        self.update(id) { $0.savedToPhotos = true }
                        self.save()
                        if announce { self.message = "Fotoğraflar'a kaydedildi" }
                    } else if announce {
                        self.message = "Bu video Fotoğraflar'a kaydedilemedi (biçim desteklenmiyor olabilir). Dosyalar uygulamasında İndir klasöründen erişebilirsiniz."
                    }
                }
            }
        }
    }

    // MARK: - İç işleyiş

    private func item(_ id: UUID) -> DownloadItem? {
        items.first { $0.id == id }
    }

    private func update(_ id: UUID, _ body: (inout DownloadItem) -> Void) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        body(&items[i])
    }

    private func packageURL(_ item: DownloadItem) -> URL? {
        guard let p = item.packagePath else { return nil }
        let url = p.hasPrefix("/") ? URL(fileURLWithPath: p)
            : URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(p)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private func launch(_ item: DownloadItem) {
        switch item.kind {
        case .file:
            var req = URLRequest(url: item.sourceURL)
            for (k, v) in item.headers { req.setValue(v, forHTTPHeaderField: k) }
            let task = fileSession.downloadTask(with: req)
            task.taskDescription = item.id.uuidString
            tasks[item.id] = task
            task.resume()
        case .hls:
            var options: [String: Any] = ["AVURLAssetHTTPHeaderFieldsKey": item.headers]
            if let ua = item.headers["User-Agent"] {
                options[AVURLAssetHTTPUserAgentKey] = ua
            }
            let asset = AVURLAsset(url: item.sourceURL, options: options)
            let name = item.title.isEmpty ? "Video" : String(item.title.prefix(60))
            guard let task = hlsSession.makeAssetDownloadTask(
                asset: asset, assetTitle: name, assetArtworkData: nil,
                options: [AVAssetDownloadTaskMinimumRequiredMediaBitrateKey: item.hlsBitrate ?? 100_000_000]
            ) else {
                fail(item.id, "Akış indirmesi başlatılamadı")
                return
            }
            task.taskDescription = item.id.uuidString
            tasks[item.id] = task
            task.resume()
        }
    }

    private func fail(_ id: UUID, _ text: String) {
        update(id) {
            $0.state = .failed
            $0.errorMessage = text
        }
        save()
    }

    private func finish(_ id: UUID) {
        update(id) {
            $0.state = .done
            $0.progress = 1
            $0.errorMessage = nil
        }
        save()
        let auto = UserDefaults.standard.object(forKey: "autoSavePhotos") as? Bool ?? true
        if auto, let item = item(id), let url = fileURL(item),
           ["mp4", "mov", "m4v"].contains(url.pathExtension.lowercased()) {
            saveToPhotos(id, announce: false)
        }
    }

    /// Ana kuyruğu boğmamak için ilerleme güncellemelerini seyreltir.
    private func shouldTick(_ id: UUID) -> Bool {
        let now = Date()
        if let last = lastTick[id], now.timeIntervalSince(last) < 0.3 { return false }
        lastTick[id] = now
        return true
    }

    private func uniqueURL(base: String, ext: String) -> URL {
        var name = base.replacingOccurrences(of: "[/\\\\:*?\"<>|\\r\\n\\t]", with: "-", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { name = "video" }
        if name.count > 80 { name = String(name.prefix(80)) }
        var candidate = "\(name).\(ext)"
        var n = 2
        while reservedNames.contains(candidate)
                || FileManager.default.fileExists(atPath: Self.documents.appendingPathComponent(candidate).path) {
            candidate = "\(name) (\(n)).\(ext)"
            n += 1
        }
        reservedNames.insert(candidate)
        return Self.documents.appendingPathComponent(candidate)
    }

    static func fileExtension(response: URLResponse?, url: URL?) -> String {
        let mimeMap = [
            "video/mp4": "mp4", "video/quicktime": "mov", "video/webm": "webm",
            "video/x-matroska": "mkv", "video/3gpp": "3gp", "video/x-m4v": "m4v",
            "audio/mpeg": "mp3", "audio/mp4": "m4a",
        ]
        if let m = response?.mimeType?.lowercased(), let e = mimeMap[m] { return e }
        let known = ["mp4", "m4v", "mov", "webm", "mkv", "3gp", "avi", "flv", "mp3", "m4a"]
        if let e = url?.pathExtension.lowercased(), known.contains(e) { return e }
        if let s = response?.suggestedFilename {
            let e = (s as NSString).pathExtension.lowercased()
            if !e.isEmpty, e.count <= 5 { return e }
        }
        return "mp4"
    }

    /// Uygulama kapanıp açıldığında arka planda süren görevleri yeniden eşleştirir.
    private func reconnect() {
        let group = DispatchGroup()
        var live = Set<UUID>()
        for session in [fileSession!, hlsSession! as URLSession] {
            group.enter()
            session.getAllTasks { all in
                DispatchQueue.main.async {
                    for t in all {
                        if let d = t.taskDescription, let id = UUID(uuidString: d) {
                            live.insert(id)
                            self.tasks[id] = t
                        }
                    }
                    group.leave()
                }
            }
        }
        group.notify(queue: .main) {
            for item in self.items {
                if item.state == .downloading, !live.contains(item.id) {
                    self.update(item.id) {
                        $0.state = .failed
                        $0.errorMessage = "İndirme yarıda kaldı"
                    }
                } else if item.state == .converting {
                    if let pkg = self.packageURL(item) {
                        self.convert(item.id, package: pkg)
                    } else {
                        self.update(item.id) {
                            $0.state = .failed
                            $0.errorMessage = "Dönüştürme yarıda kaldı"
                        }
                    }
                }
            }
            self.save()
        }
    }

    // MARK: - HLS → MP4

    private func convert(_ id: UUID, package: URL) {
        update(id) {
            $0.state = .converting
            $0.progress = 1
        }
        save()
        guard let item = item(id) else { return }
        let asset = AVURLAsset(url: package)
        export(asset: asset, title: item.title,
               presets: [AVAssetExportPresetPassthrough, AVAssetExportPresetHighestQuality]) { result in
            DispatchQueue.main.async {
                switch result {
                case .success(let url):
                    try? FileManager.default.removeItem(at: package)
                    self.update(id) {
                        $0.fileName = url.lastPathComponent
                        $0.packagePath = nil
                    }
                    self.finish(id)
                case .failure(let text):
                    self.fail(id, text.message)
                }
            }
        }
    }

    struct ExportError: Error { let message: String }

    private func export(asset: AVAsset, title: String, presets: [String],
                        completion: @escaping (Result<URL, ExportError>) -> Void) {
        guard let preset = presets.first else {
            completion(.failure(ExportError(message: "Video MP4'e dönüştürülemedi")))
            return
        }
        let rest = Array(presets.dropFirst())
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            export(asset: asset, title: title, presets: rest, completion: completion)
            return
        }
        let type: AVFileType
        if session.supportedFileTypes.contains(.mp4) {
            type = .mp4
        } else if session.supportedFileTypes.contains(.mov) {
            type = .mov
        } else {
            export(asset: asset, title: title, presets: rest, completion: completion)
            return
        }
        let dest = uniqueURL(base: title, ext: type == .mp4 ? "mp4" : "mov")
        try? FileManager.default.removeItem(at: dest)
        session.outputURL = dest
        session.outputFileType = type
        session.shouldOptimizeForNetworkUse = true
        session.exportAsynchronously {
            DispatchQueue.main.async {
                self.reservedNames.remove(dest.lastPathComponent)
                if session.status == .completed {
                    completion(.success(dest))
                } else {
                    try? FileManager.default.removeItem(at: dest)
                    if rest.isEmpty {
                        let reason = session.error?.localizedDescription ?? "bilinmeyen hata"
                        completion(.failure(ExportError(message: "Dönüştürülemedi: \(reason)")))
                    } else {
                        self.export(asset: asset, title: title, presets: rest, completion: completion)
                    }
                }
            }
        }
    }

    // MARK: - Kayıt

    private func load() {
        guard let data = try? Data(contentsOf: Self.indexURL),
              let list = try? JSONDecoder().decode([DownloadItem].self, from: data) else { return }
        items = list
        items.removeAll { $0.state == .done && fileURL($0) == nil }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(items) {
            try? data.write(to: Self.indexURL, options: .atomic)
        }
    }
}

private extension URLSessionTask {
    var itemID: UUID? { taskDescription.flatMap { UUID(uuidString: $0) } }
}

// MARK: - Dosya indirme delegesi

extension DownloadManager: URLSessionDownloadDelegate {
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let id = downloadTask.itemID, shouldTick(id) else { return }
        update(id) {
            $0.receivedBytes = totalBytesWritten
            $0.totalBytes = max(0, totalBytesExpectedToWrite)
            $0.progress = totalBytesExpectedToWrite > 0
                ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite) : 0
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let id = downloadTask.itemID else { return }
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            pendingErrors[id] = "Sunucu indirmeyi reddetti (\(http.statusCode))"
            return
        }
        if let mime = downloadTask.response?.mimeType?.lowercased(), mime.hasPrefix("text/html") {
            pendingErrors[id] = "Video yerine web sayfası geldi; bu site doğrudan indirmeye izin vermiyor"
            return
        }
        let title = item(id)?.title ?? "video"
        let ext = Self.fileExtension(response: downloadTask.response, url: downloadTask.originalRequest?.url)
        let dest = uniqueURL(base: title, ext: ext)
        do {
            try FileManager.default.moveItem(at: location, to: dest)
            update(id) {
                $0.fileName = dest.lastPathComponent
                $0.receivedBytes = Int64((try? dest.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            }
        } catch {
            pendingErrors[id] = "Dosya kaydedilemedi: \(error.localizedDescription)"
        }
        reservedNames.remove(dest.lastPathComponent)
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        if let ident = session.configuration.identifier,
           let handler = backgroundCompletionHandlers.removeValue(forKey: ident) {
            handler()
        }
    }
}

// MARK: - HLS delegesi ve ortak tamamlanma

extension DownloadManager: AVAssetDownloadDelegate {
    func urlSession(_ session: URLSession, assetDownloadTask: AVAssetDownloadTask, didLoad timeRange: CMTimeRange,
                    totalTimeRangesLoaded loadedTimeRanges: [NSValue], timeRangeExpectedToLoad: CMTimeRange) {
        guard let id = assetDownloadTask.itemID, shouldTick(id) else { return }
        var loaded = 0.0
        for v in loadedTimeRanges { loaded += CMTimeGetSeconds(v.timeRangeValue.duration) }
        let total = CMTimeGetSeconds(timeRangeExpectedToLoad.duration)
        update(id) { $0.progress = total > 0 ? min(1, loaded / total) : 0 }
    }

    func urlSession(_ session: URLSession, assetDownloadTask: AVAssetDownloadTask, didFinishDownloadingTo location: URL) {
        guard let id = assetDownloadTask.itemID else { return }
        // Uygulama kabının yolu güncellemelerde değişebildiği için ana dizine göre göreli sakla.
        let home = NSHomeDirectory()
        var path = location.path
        if path.hasPrefix(home + "/") { path = String(path.dropFirst(home.count + 1)) }
        update(id) { $0.packagePath = path }
        save()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let id = task.itemID else { return }
        tasks[id] = nil
        lastTick[id] = nil
        let isHLS = task is AVAssetDownloadTask

        if let error = error as NSError? {
            pendingErrors[id] = nil
            if isHLS, let item = item(id), let pkg = packageURL(item) {
                try? FileManager.default.removeItem(at: pkg)
            }
            if error.code == NSURLErrorCancelled {
                if item(id)?.state == .downloading { fail(id, "İptal edildi") }
            } else {
                fail(id, error.localizedDescription)
            }
            return
        }
        if let text = pendingErrors.removeValue(forKey: id) {
            fail(id, text)
            return
        }
        if isHLS {
            guard let item = item(id), let pkg = packageURL(item) else {
                fail(id, "İndirilen akış bulunamadı")
                return
            }
            convert(id, package: pkg)
        } else {
            finish(id)
        }
    }
}
