import SwiftUI
import WebKit
import Combine

/// WKWebView'ı yöneten, sayfadaki videoları toplayan model.
@MainActor
final class BrowserModel: NSObject, ObservableObject {
    let webView: WKWebView

    @Published var currentURL: URL?
    @Published var title = ""
    @Published var progress: Double = 0
    @Published var isLoading = false
    @Published var canGoBack = false
    @Published var canGoForward = false

    @Published var media: [DetectedMedia] = []
    @Published var showMediaSheet = false
    @Published var showStart = true
    @Published var toast: String?

    @Published var bookmarks: [Bookmark] = [] {
        didSet { saveBookmarks() }
    }

    private var userAgent: String?
    private static let bookmarksKey = "bookmarks.v1"

    override init() {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = .all
        let controller = WKUserContentController()
        controller.addUserScript(WKUserScript(source: DetectorScript.source,
                                              injectionTime: .atDocumentStart,
                                              forMainFrameOnly: false))
        config.userContentController = controller
        webView = WKWebView(frame: .zero, configuration: config)
        super.init()

        controller.add(WeakScriptHandler(self), name: "indir")
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true

        webView.publisher(for: \.url).assign(to: &$currentURL)
        webView.publisher(for: \.title).map { $0 ?? "" }.assign(to: &$title)
        webView.publisher(for: \.estimatedProgress).assign(to: &$progress)
        webView.publisher(for: \.isLoading).assign(to: &$isLoading)
        webView.publisher(for: \.canGoBack).assign(to: &$canGoBack)
        webView.publisher(for: \.canGoForward).assign(to: &$canGoForward)

        webView.evaluateJavaScript("navigator.userAgent") { [weak self] result, _ in
            self?.userAgent = result as? String
        }
        loadBookmarks()
    }

    // MARK: - Gezinme

    func open(_ input: String) {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let url = Self.resolve(text) else { return }
        showStart = false
        webView.load(URLRequest(url: url))
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

    func goBack() { showStart = false; webView.goBack() }
    func goForward() { showStart = false; webView.goForward() }
    func reload() { webView.reload() }
    func stop() { webView.stopLoading() }
    func goHome() { showStart = true }

    func flash(_ message: String) {
        withAnimation { toast = message }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            guard let self, self.toast == message else { return }
            withAnimation { self.toast = nil }
        }
    }

    // MARK: - Yer imleri

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

    func addCurrentBookmark() {
        guard !showStart, let url = currentURL else { return }
        if bookmarks.contains(where: { $0.url == url.absoluteString }) {
            flash("Bu sayfa zaten kısayollarda")
            return
        }
        let name = title.isEmpty ? (url.host ?? url.absoluteString) : title
        bookmarks.append(Bookmark(title: String(name.prefix(30)), url: url.absoluteString))
        flash("Kısayollara eklendi")
    }

    func removeBookmark(_ b: Bookmark) {
        bookmarks.removeAll { $0.id == b.id }
    }

    // MARK: - Videolar

    func add(_ m: DetectedMedia) {
        if media.contains(where: { $0.url == m.url }) { return }
        media.insert(m, at: 0)
        if media.count > 40 { media.removeLast(media.count - 40) }
    }

    func headers(for m: DetectedMedia) async -> [String: String] {
        var h: [String: String] = [:]
        if let ua = userAgent { h["User-Agent"] = ua }
        if let page = m.pageURL { h["Referer"] = page.absoluteString }
        let cookies = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
        let host = (m.url.host ?? "").lowercased()
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
            let h = await self.headers(for: m)
            DownloadManager.shared.start(url: m.url, title: m.displayName, pageURL: m.pageURL,
                                         kind: m.kind, headers: h)
            self.flash("İndirme başladı")
        }
    }

    /// Dosya boyutunu öğrenmeye çalışır (HEAD, olmazsa 1 baytlık Range isteği).
    func contentLength(_ m: DetectedMedia) async -> Int64? {
        let h = await headers(for: m)
        var req = URLRequest(url: m.url)
        req.timeoutInterval = 10
        for (k, v) in h { req.setValue(v, forHTTPHeaderField: k) }
        req.httpMethod = "HEAD"
        if let result = try? await URLSession.shared.data(for: req),
           let http = result.1 as? HTTPURLResponse,
           (200..<300).contains(http.statusCode),
           http.expectedContentLength > 0,
           !(http.mimeType ?? "").hasPrefix("text") {
            return http.expectedContentLength
        }
        req.httpMethod = "GET"
        req.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        if let result = try? await URLSession.shared.data(for: req),
           let http = result.1 as? HTTPURLResponse,
           let range = http.value(forHTTPHeaderField: "Content-Range"),
           let total = range.split(separator: "/").last,
           let n = Int64(total) {
            return n
        }
        return nil
    }
}

// MARK: - WebKit delegeleri

extension BrowserModel: WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              let s = body["url"] as? String,
              let url = URL(string: s),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return }
        let type = ((body["type"] as? String) ?? "").lowercased()
        let isHLS = url.path.lowercased().hasSuffix(".m3u8") || type.contains("mpegurl")
            || url.absoluteString.lowercased().contains(".m3u8")
        var title = (body["title"] as? String) ?? ""
        if title.isEmpty { title = webView.title ?? "" }
        let page = (body["page"] as? String).flatMap { URL(string: $0) } ?? webView.url
        add(DetectedMedia(url: url, kind: isHLS ? .hls : .file, title: title, pageURL: page))
    }
}

extension BrowserModel: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        media.removeAll()
        showStart = false
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        let resp = navigationResponse.response
        let mime = (resp.mimeType ?? "").lowercased()
        var attachment = false
        if let http = resp as? HTTPURLResponse,
           let cd = http.value(forHTTPHeaderField: "Content-Disposition"),
           cd.lowercased().contains("attachment") {
            attachment = true
        }
        let isVideo = mime.hasPrefix("video/") || mime.contains("mpegurl")
        if navigationResponse.isForMainFrame, let url = resp.url,
           isVideo || attachment || !navigationResponse.canShowMIMEType {
            let isHLS = mime.contains("mpegurl") || url.pathExtension.lowercased() == "m3u8"
            let name = resp.suggestedFilename.map { ($0 as NSString).deletingPathExtension } ?? ""
            add(DetectedMedia(url: url, kind: isHLS ? .hls : .file,
                              title: name.isEmpty ? (webView.title ?? "") : name,
                              pageURL: webView.url ?? url))
            showMediaSheet = true
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        report(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        report(error)
    }

    private func report(_ error: Error) {
        let e = error as NSError
        if e.code == NSURLErrorCancelled || e.code == 102 || e.code == 204 { return }
        flash("Sayfa açılamadı: \(e.localizedDescription)")
    }
}

extension BrowserModel: WKUIDelegate {
    /// Açılır pencereleri engelle; kullanıcının dokunduğu "yeni sekme" bağlantılarını aynı sayfada aç.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil, navigationAction.navigationType == .linkActivated {
            webView.load(navigationAction.request)
        }
        return nil
    }
}

/// WKUserContentController betik işleyicisini güçlü tuttuğu için döngüyü kıran ara sınıf.
@MainActor
final class WeakScriptHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ target: WKScriptMessageHandler) { self.target = target }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(userContentController, didReceive: message)
    }
}
