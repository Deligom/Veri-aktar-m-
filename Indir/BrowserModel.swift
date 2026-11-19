import SwiftUI
import WebKit

/// Sekmeleri, kısayolları, geçmişi ve indirme başlatmayı yöneten model.
@MainActor
final class BrowserModel: ObservableObject {
    @Published private(set) var tabs: [BrowserTab] = []
    @Published var currentID = UUID()
    @Published var toast: String?
    @Published var showTabs = false
    @Published var showHistory = false
    @Published private(set) var history: [HistoryEntry] = []
    @Published var bookmarks: [Bookmark] = [] {
        didSet { saveBookmarks() }
    }

    private var userAgent: String?
    private static let bookmarksKey = "bookmarks.v1"
    private static let sessionKey = "session.v1"

    private static var historyURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("history.json")
    }

    var current: BrowserTab {
        tabs.first { $0.id == currentID } ?? tabs[0]
    }

    init() {
        loadBookmarks()
        loadHistory()
        restoreSession()
        if tabs.isEmpty {
            let t = makeTab()
            tabs = [t]
            currentID = t.id
        }
        current.activate()
        current.webView.evaluateJavaScript("navigator.userAgent") { [weak self] result, _ in
            self?.userAgent = result as? String
        }
    }

    // MARK: Sekmeler

    private func makeTab() -> BrowserTab {
        let t = BrowserTab()
        t.owner = self
        return t
    }

    @discardableResult
    func newTab(url: URL? = nil) -> BrowserTab {
        current.captureSnapshot()
        let t = makeTab()
        if let i = tabs.firstIndex(where: { $0.id == currentID }) {
            tabs.insert(t, at: i + 1)
        } else {
            tabs.append(t)
        }
        if let url { t.load(url) }
        currentID = t.id
        saveSession()
        return t
    }

    func select(_ t: BrowserTab) {
        currentID = t.id
        t.activate()
        saveSession()
    }

    func close(_ t: BrowserTab) {
        guard let i = tabs.firstIndex(where: { $0.id == t.id }) else { return }
        t.webView.stopLoading()
        tabs.remove(at: i)
        if tabs.isEmpty {
            let n = makeTab()
            tabs = [n]
            currentID = n.id
        } else if currentID == t.id {
            currentID = tabs[min(i, tabs.count - 1)].id
            current.activate()
        }
        saveSession()
    }

    func closeAll() {
        for t in tabs { t.webView.stopLoading() }
        let n = makeTab()
        tabs = [n]
        currentID = n.id
        saveSession()
    }

    func saveSession() {
        let list: [[String: String]] = tabs.compactMap { t in
            guard !t.showStart || t.pendingURL != nil, let url = t.displayURL else { return nil }
            return ["url": url.absoluteString, "title": t.displayTitle]
        }
        let index = tabs.filter { !$0.showStart || $0.pendingURL != nil }
            .firstIndex { $0.id == currentID } ?? 0
        UserDefaults.standard.set(["tabs": list, "index": index] as [String: Any], forKey: Self.sessionKey)
    }

    private func restoreSession() {
        guard let dict = UserDefaults.standard.dictionary(forKey: Self.sessionKey),
              let list = dict["tabs"] as? [[String: String]], !list.isEmpty else { return }
        for entry in list.prefix(20) {
            guard let s = entry["url"], let url = URL(string: s) else { continue }
            let t = makeTab()
            t.pendingURL = url
            t.restoredTitle = entry["title"]
            t.showStart = false
            tabs.append(t)
        }
        let index = dict["index"] as? Int ?? 0
        if !tabs.isEmpty { currentID = tabs[min(max(0, index), tabs.count - 1)].id }
    }

    // MARK: Gezinme

    func open(_ input: String) {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let url = Self.resolve(text) else { return }
        current.load(url)
    }

    static func resolve(_ text: String) -> URL? {
        let lower = text.lowercased()
        if (lower.hasPrefix("http://") || lower.hasPrefix("https://")), !text.contains(" "),
           let u = URL(string: text), u.host != nil {
            return u
        }
        if !text.contains(" "), text.contains("."), let u = URL(string: "https://" + text), u.host != nil {
            return u
        }
        // Yapıştırılan bir cümlenin içindeki bağlantıyı bul
        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue),
           let match = detector.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           let u = match.url, let scheme = u.scheme?.lowercased(), scheme == "http" || scheme == "https" {
            return u
        }
        var comps = URLComponents(string: "https://www.google.com/search")!
        comps.queryItems = [URLQueryItem(name: "q", value: text)]
        return comps.url
    }

    func flash(_ message: String) {
        withAnimation { toast = message }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            guard let self, self.toast == message else { return }
            withAnimation { self.toast = nil }
        }
    }

    // MARK: Geçmiş

    func recordVisit(url: URL, title: String) {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return }
        if let first = history.first, first.url == url.absoluteString {
            if !title.isEmpty { history[0].title = title }
            history[0].date = Date()
        } else {
            history.insert(HistoryEntry(title: title, url: url.absoluteString, date: Date()), at: 0)
        }
        if history.count > 1000 { history.removeLast(history.count - 1000) }
        saveHistory()
    }

    func deleteHistory(_ entry: HistoryEntry) {
        history.removeAll { $0.id == entry.id }
        saveHistory()
    }

    func clearHistory() {
        history.removeAll()
        saveHistory()
    }

    private func loadHistory() {
        if let data = try? Data(contentsOf: Self.historyURL),
           let list = try? JSONDecoder().decode([HistoryEntry].self, from: data) {
            history = list
        }
    }

    private func saveHistory() {
        if let data = try? JSONEncoder().encode(history) {
            try? data.write(to: Self.historyURL, options: .atomic)
        }
    }

    // MARK: Kısayollar

    private func loadBookmarks() {
        if let data = UserDefaults.standard.data(forKey: Self.bookmarksKey),
           let list = try? JSONDecoder().decode([Bookmark].self, from: data) {
            bookmarks = list
        } else {
            bookmarks = [
                Bookmark(title: "Google", url: "https://www.google.com"),
                Bookmark(title: "Vimeo", url: "https://vimeo.com"),
                Bookmark(title: "Dailymotion", url: "https://www.dailymotion.com"),
                Bookmark(title: "Pinterest", url: "https://www.pinterest.com"),
                Bookmark(title: "Reddit", url: "https://www.reddit.com"),
            ]
        }
    }

    private func saveBookmarks() {
        if let data = try? JSONEncoder().encode(bookmarks) {
            UserDefaults.standard.set(data, forKey: Self.bookmarksKey)
        }
    }

    func addBookmark(_ tab: BrowserTab) {
        guard !tab.showStart, let url = tab.currentURL else { return }
        if bookmarks.contains(where: { $0.url == url.absoluteString }) {
            flash("Bu sayfa zaten kısayollarda")
            return
        }
        let name = tab.title.isEmpty ? (url.host ?? url.absoluteString) : tab.title
        bookmarks.append(Bookmark(title: String(name.prefix(30)), url: url.absoluteString))
        flash("Kısayollara eklendi")
    }

    func removeBookmark(_ b: Bookmark) {
        bookmarks.removeAll { $0.id == b.id }
    }

    // MARK: İndirme

    func headers(url: URL, page: URL?) async -> [String: String] {
        var h: [String: String] = [:]
        if let ua = userAgent { h["User-Agent"] = ua }
        if let page { h["Referer"] = page.absoluteString }
        let cookies = await WKWebsiteDataStore.default().httpCookieStore.allCookies()
        let host = (url.host ?? "").lowercased()
        let matching = cookies.filter { c in
            var d = c.domain.lowercased()
            if d.hasPrefix(".") { d.removeFirst() }
            return host == d || host.hasSuffix("." + d)
        }
        for (k, v) in HTTPCookie.requestHeaderFields(with: matching) { h[k] = v }
        return h
    }

    func download(_ m: DetectedMedia) {
        Task { @MainActor in
            let h = await self.headers(url: m.url, page: m.pageURL)
            var name = m.displayName
            if m.height > 0 { name += " (\(m.qualityBadge))" }
            DownloadManager.shared.start(url: m.url, title: name, pageURL: m.pageURL,
                                         kind: m.kind, headers: h, hlsBitrate: m.hlsBitrate)
            self.flash("İndirme başladı")
        }
    }
}
