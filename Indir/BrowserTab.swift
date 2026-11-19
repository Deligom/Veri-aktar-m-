import SwiftUI
import WebKit
import Combine

/// Tek bir tarayıcı sekmesi: kendi WKWebView'ı ve sayfada bulunan videolar.
@MainActor
final class BrowserTab: NSObject, ObservableObject, Identifiable {
    let id = UUID()
    let webView: WKWebView
    let isPrivate: Bool
    weak var owner: BrowserModel?

    @Published var currentURL: URL?
    @Published var title = ""
    @Published var progress: Double = 0
    @Published var isLoading = false
    @Published var canGoBack = false
    @Published var canGoForward = false

    @Published var media: [DetectedMedia] = []
    @Published var checking = 0
    @Published var showStart = true
    @Published var showMediaSheet = false
    @Published var snapshot: UIImage?

    var pendingURL: URL?
    var restoredTitle: String?

    private var seen = Set<String>()
    private var generation = 0
    private var hasMaster = false
    private var openSheetWhenFound = false

    var displayURL: URL? { currentURL ?? pendingURL }

    var displayTitle: String {
        if showStart && pendingURL == nil { return "Başlangıç" }
        if !title.isEmpty { return title }
        if let t = restoredTitle, !t.isEmpty { return t }
        return displayURL?.host ?? "Yeni sekme"
    }

    init(isPrivate: Bool = false) {
        self.isPrivate = isPrivate
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = .all
        // Gizli sekme: çerez, önbellek ve site verileri yalnızca bellekte tutulur, kapanınca silinir
        config.websiteDataStore = isPrivate ? .nonPersistent() : .default()
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
    }

    // MARK: Gezinme

    func load(_ url: URL) {
        pendingURL = nil
        showStart = false
        webView.load(URLRequest(url: url))
    }

    /// Oturumdan geri yüklenen sekme ilk seçildiğinde sayfasını yükler.
    func activate() {
        if let u = pendingURL { load(u) }
    }

    func goBack() { showStart = false; webView.goBack() }
    func goForward() { showStart = false; webView.goForward() }
    func goHome() { showStart = true }

    func captureSnapshot() {
        guard !showStart else { snapshot = nil; return }
        webView.takeSnapshot(with: nil) { [weak self] image, _ in
            if let image { self?.snapshot = image }
        }
    }

    // MARK: Video yakalama

    private func resetMedia() {
        generation += 1
        media.removeAll()
        seen.removeAll()
        checking = 0
        hasMaster = false
    }

    func detected(url: URL, isHLS: Bool, title: String, page: URL?) {
        let key = url.absoluteString
        guard !seen.contains(key), let owner else { return }
        seen.insert(key)
        checking += 1
        let gen = generation
        Task { @MainActor in
            defer { if gen == self.generation { self.checking = max(0, self.checking - 1) } }
            let headers = await owner.headers(url: url, page: page,
                                              store: self.webView.configuration.websiteDataStore)
            if isHLS {
                guard let variants = await MediaProbe.resolveHLS(url, headers: headers),
                      gen == self.generation else { return }
                if variants.first?.isMaster == true {
                    if !self.hasMaster {
                        self.hasMaster = true
                        self.media.removeAll { $0.kind == .hls && $0.hlsBitrate == nil }
                    }
                    for v in variants {
                        self.add(DetectedMedia(url: url, kind: .hls, title: title, pageURL: page,
                                               height: v.height, size: v.estimatedSize,
                                               sizeIsEstimate: true, hlsBitrate: v.bandwidth))
                    }
                } else if !self.hasMaster {
                    self.add(DetectedMedia(url: url, kind: .hls, title: title, pageURL: page))
                }
            } else {
                guard let info = await MediaProbe.probeFile(url, headers: headers),
                      gen == self.generation else { return }
                self.add(DetectedMedia(url: url, kind: .file, title: title, pageURL: page,
                                       height: MediaProbe.heightFromURL(url), size: info.size,
                                       ext: MediaProbe.extLabel(mime: info.mime, url: url)))
            }
        }
    }

    /// Aynı videonun tekrarlarını eler: aynı boyutta dosya, aynı kalitede akış.
    private func add(_ m: DetectedMedia) {
        if m.kind == .file, let s = m.size,
           media.contains(where: { $0.kind == .file && $0.size == s }) { return }
        if m.height > 0, let i = media.firstIndex(where: { $0.height == m.height }) {
            let existing = media[i]
            if m.kind == .hls { return }                       // aynı kalitede gerçek dosya varsa akışı alma
            if existing.kind == .hls { media.remove(at: i) }   // dosya akıştan iyidir
            else if (existing.size ?? 0) >= (m.size ?? 0) { return }
            else { media.remove(at: i) }
        }
        media.append(m)
        media.sort { a, b in
            if a.height != b.height { return a.height > b.height }
            return (a.size ?? 0) > (b.size ?? 0)
        }
        if media.count > 30 { media.removeLast(media.count - 30) }
        if openSheetWhenFound {
            openSheetWhenFound = false
            showMediaSheet = true
        }
    }
}

// MARK: - WebKit delegeleri

extension BrowserTab: WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              let s = body["url"] as? String,
              let url = URL(string: s),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return }
        let type = ((body["type"] as? String) ?? "").lowercased()
        let isHLS = type.contains("mpegurl") || url.absoluteString.lowercased().contains(".m3u8")
        var t = (body["title"] as? String) ?? ""
        if t.isEmpty { t = webView.title ?? "" }
        let page = (body["page"] as? String).flatMap { URL(string: $0) } ?? webView.url
        detected(url: url, isHLS: isHLS, title: t, page: page)
    }
}

extension BrowserTab: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        resetMedia()
        showStart = false
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if !isPrivate, let url = webView.url { owner?.recordVisit(url: url, title: webView.title ?? "") }
        owner?.saveSession()
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
            openSheetWhenFound = true
            detected(url: url, isHLS: isHLS, title: name.isEmpty ? (webView.title ?? "") : name,
                     page: webView.url ?? url)
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
        owner?.flash("Sayfa açılamadı: \(e.localizedDescription)")
    }
}

extension BrowserTab: WKUIDelegate {
    /// Kullanıcının dokunduğu "yeni pencere" bağlantıları yeni sekmede açılır; kendiliğinden açılan pencereler engellenir.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil, navigationAction.navigationType == .linkActivated,
           let url = navigationAction.request.url {
            owner?.newTab(url: url, isPrivate: isPrivate)
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
