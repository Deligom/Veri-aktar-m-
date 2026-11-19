import Foundation
import AVFoundation
import Photos
import UIKit

/// İndirmeleri yönetir.
/// - Doğrudan dosyalar arka plan URLSession ile iner (ekran kapalıyken de sürer).
///   Site arka plan isteğini reddederse bir kez normal oturumla yeniden denenir.
/// - HLS akışları HLSDownloader ile parça parça indirilip MP4'e birleştirilir.
/// Durum değişiklikleri hep ana iş parçacığında yapılır.
final class DownloadManager: NSObject, ObservableObject {
    static let shared = DownloadManager()

    @Published private(set) var items: [DownloadItem] = []
    @Published var message: String?

    var backgroundCompletionHandlers: [String: () -> Void] = [:]

    private var fileSession: URLSession!
    private var tasks: [UUID: URLSessionTask] = [:]
    private var jobs: [UUID: Task<Void, Never>] = [:]
    private var pendingErrors: [UUID: String] = [:]
    private var needsFallback = Set<UUID>()
    private var pendingFiles: [UUID: (url: URL, ext: String)] = [:]
    private var lastTick: [UUID: Date] = [:]
    private var reservedNames = Set<String>()
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

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

    var totalSizeText: String {
        let total = items.compactMap { fileURL($0) }
            .compactMap { try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize }
            .reduce(0, +)
        return ByteCountFormatter.string(fromByteCount: Int64(total), countStyle: .file)
    }

    private override init() {
        super.init()
        load()
        let fc = URLSessionConfiguration.background(withIdentifier: "indir.files")
        fc.httpShouldSetCookies = false
        fc.isDiscretionary = false
        fc.sessionSendsLaunchEvents = true
        fileSession = URLSession(configuration: fc, delegate: self, delegateQueue: .main)
        reconnect()
        cleanTemporary()
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
        jobs[id]?.cancel()
        jobs[id] = nil
        fail(id, "İptal edildi")
        refreshActivity()
    }

    func delete(_ id: UUID) {
        tasks[id]?.cancel()
        tasks[id] = nil
        jobs[id]?.cancel()
        jobs[id] = nil
        if let item = item(id), let url = fileURL(item) {
            try? FileManager.default.removeItem(at: url)
        }
        items.removeAll { $0.id == id }
        save()
        refreshActivity()
    }

    func clearFailed() {
        for item in items where item.state == .failed { delete(item.id) }
    }

    func deleteAll() {
        for item in items { delete(item.id) }
        // Listede olmayan artık dosyaları da temizle
        if let files = try? FileManager.default.contentsOfDirectory(at: Self.documents, includingPropertiesForKeys: nil) {
            for f in files { try? FileManager.default.removeItem(at: f) }
        }
        cleanTemporary()
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
                    self.message = "Fotoğraflar izni yok. Ayarlar > Indir > Fotoğraflar bölümünden izin verin."
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
                        if UserDefaults.standard.bool(forKey: "deleteAfterSave") {
                            self.delete(id)
                        }
                        if announce { self.message = "Fotoğraflar'a kaydedildi" }
                    } else if announce {
                        self.message = "Bu video Fotoğraflar'a kaydedilemedi (biçim desteklenmiyor olabilir). Dosyalar uygulamasında Indir klasöründen erişebilirsiniz."
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
            startHLS(item)
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
        refreshActivity()
        let auto = UserDefaults.standard.object(forKey: "autoSavePhotos") as? Bool ?? true
        if auto, let item = item(id), let url = fileURL(item),
           ["mp4", "mov", "m4v"].contains(url.pathExtension.lowercased()) {
            saveToPhotos(id, announce: false)
        }
    }

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

    /// Bir dosyayı İndirilenler klasörüne güzel bir adla taşır ve kaydı tamamlar.
    private func store(_ id: UUID, from temp: URL, ext: String) {
        let title = item(id)?.title ?? "video"
        let dest = uniqueURL(base: title, ext: ext)
        do {
            try FileManager.default.moveItem(at: temp, to: dest)
            update(id) {
                $0.fileName = dest.lastPathComponent
                $0.receivedBytes = Int64((try? dest.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            }
            reservedNames.remove(dest.lastPathComponent)
            finish(id)
        } catch {
            reservedNames.remove(dest.lastPathComponent)
            fail(id, "Dosya kaydedilemedi: \(error.localizedDescription)")
        }
    }

    /// Uygulama kapanıp açıldığında arka planda süren dosya indirmelerini yeniden eşleştirir.
    private func reconnect() {
        fileSession.getAllTasks { all in
            DispatchQueue.main.async {
                var live = Set<UUID>()
                for t in all {
                    if let d = t.taskDescription, let id = UUID(uuidString: d) {
                        live.insert(id)
                        self.tasks[id] = t
                    }
                }
                for item in self.items where item.state == .downloading || item.state == .converting {
                    if item.kind == .hls || !live.contains(item.id) {
                        self.update(item.id) {
                            $0.state = .failed
                            $0.errorMessage = "İndirme yarıda kaldı. Tekrar denemek için basılı tutun."
                        }
                    }
                }
                self.save()
            }
        }
    }

    private func cleanTemporary() {
        let tmp = FileManager.default.temporaryDirectory
        if let list = try? FileManager.default.contentsOfDirectory(at: tmp, includingPropertiesForKeys: nil) {
            for u in list where u.lastPathComponent.hasPrefix("hls-") && jobs.isEmpty {
                try? FileManager.default.removeItem(at: u)
            }
        }
    }

    /// Akış indirilirken ekranın kilitlenmesini engeller; uygulama arka plana geçerse kısa süre daha çalışır.
    private func refreshActivity() {
        let active = !jobs.isEmpty
        UIApplication.shared.isIdleTimerDisabled = active
        if active, backgroundTask == .invalid {
            backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "indir.hls") { [weak self] in
                guard let self else { return }
                UIApplication.shared.endBackgroundTask(self.backgroundTask)
                self.backgroundTask = .invalid
            }
        } else if !active, backgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
        }
    }

    // MARK: - HLS

    private func startHLS(_ item: DownloadItem) {
        let id = item.id
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("hls-\(id.uuidString)")
        let downloader = HLSDownloader(source: item.sourceURL, bitrate: item.hlsBitrate,
                                       headers: item.headers, workDir: work)
        downloader.onProgress = { [weak self] p in
            DispatchQueue.main.async {
                guard let self, self.shouldTick(id) || p >= 1 else { return }
                self.update(id) { $0.progress = p }
            }
        }
        downloader.onConverting = { [weak self] in
            DispatchQueue.main.async {
                guard let self, self.item(id)?.state == .downloading else { return }
                self.update(id) {
                    $0.state = .converting
                    $0.progress = 1
                }
            }
        }
        jobs[id] = Task.detached { [weak self] in
            do {
                let out = try await downloader.run()
                await MainActor.run {
                    guard let self else { return }
                    self.jobs[id] = nil
                    self.store(id, from: out, ext: "mp4")
                    try? FileManager.default.removeItem(at: work)
                    self.refreshActivity()
                }
            } catch {
                let text = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                let cancelled = error is CancellationError
                await MainActor.run {
                    guard let self else { return }
                    self.jobs[id] = nil
                    try? FileManager.default.removeItem(at: work)
                    if !cancelled { self.fail(id, text) }
                    self.refreshActivity()
                }
            }
        }
        refreshActivity()
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

    // MARK: - Yedek indirme (arka plan oturumu reddedilirse)

    private func fallbackDownload(_ id: UUID) {
        guard let item = item(id) else { return }
        update(id) {
            $0.state = .downloading
            $0.errorMessage = nil
            $0.progress = 0
        }
        var req = URLRequest(url: item.sourceURL, timeoutInterval: 60)
        for (k, v) in item.headers { req.setValue(v, forHTTPHeaderField: k) }
        jobs[id] = Task.detached { [weak self] in
            do {
                let (temp, resp) = try await URLSession.shared.download(for: req)
                let http = resp as? HTTPURLResponse
                let ok = (200..<300).contains(http?.statusCode ?? 200)
                    && !(resp.mimeType ?? "").lowercased().hasPrefix("text/html")
                let ext = DownloadManager.fileExtension(response: resp, url: item.sourceURL)
                // Geçici dosya bu blok bitince silinebileceği için hemen taşı
                let keep = FileManager.default.temporaryDirectory.appendingPathComponent("dl-\(id.uuidString).\(ext)")
                try? FileManager.default.removeItem(at: keep)
                try FileManager.default.moveItem(at: temp, to: keep)
                await MainActor.run {
                    guard let self else { return }
                    self.jobs[id] = nil
                    if ok {
                        self.store(id, from: keep, ext: ext)
                    } else {
                        try? FileManager.default.removeItem(at: keep)
                        self.fail(id, "Site bu videonun indirilmesine izin vermiyor (\(http?.statusCode ?? 0)). Videoyu oynatıp yeniden deneyin.")
                    }
                    self.refreshActivity()
                }
            } catch {
                let text = error.localizedDescription
                let cancelled = error is CancellationError || (error as NSError).code == NSURLErrorCancelled
                await MainActor.run {
                    guard let self else { return }
                    self.jobs[id] = nil
                    if !cancelled { self.fail(id, text) }
                    self.refreshActivity()
                }
            }
        }
        refreshActivity()
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
            if [401, 403, 410].contains(http.statusCode) {
                needsFallback.insert(id)
            } else {
                pendingErrors[id] = "Sunucu indirmeyi reddetti (\(http.statusCode))"
            }
            return
        }
        if let mime = downloadTask.response?.mimeType?.lowercased(), mime.hasPrefix("text/html") {
            pendingErrors[id] = "Video yerine web sayfası geldi; bu site doğrudan indirmeye izin vermiyor"
            return
        }
        let ext = Self.fileExtension(response: downloadTask.response, url: downloadTask.originalRequest?.url)
        // Konum bu metot dönünce silinir; hemen geçici bir yere taşı
        let keep = FileManager.default.temporaryDirectory.appendingPathComponent("dl-\(id.uuidString).\(ext)")
        try? FileManager.default.removeItem(at: keep)
        do {
            try FileManager.default.moveItem(at: location, to: keep)
            pendingFiles[id] = (keep, ext)
        } catch {
            pendingErrors[id] = "Dosya kaydedilemedi: \(error.localizedDescription)"
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let id = task.itemID else { return }
        tasks[id] = nil
        lastTick[id] = nil

        if let error = error as NSError? {
            pendingErrors[id] = nil
            needsFallback.remove(id)
            if error.code == NSURLErrorCancelled {
                if item(id)?.state == .downloading { fail(id, "İptal edildi") }
            } else {
                fail(id, error.localizedDescription)
            }
            return
        }
        if needsFallback.remove(id) != nil {
            fallbackDownload(id)
            return
        }
        if let text = pendingErrors.removeValue(forKey: id) {
            fail(id, text)
            return
        }
        if let file = pendingFiles.removeValue(forKey: id) {
            store(id, from: file.url, ext: file.ext)
        } else {
            fail(id, "İndirilen dosya bulunamadı")
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        if let ident = session.configuration.identifier,
           let handler = backgroundCompletionHandlers.removeValue(forKey: ident) {
            handler()
        }
    }
}
