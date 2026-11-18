import SwiftUI
import WebKit

struct WebViewContainer: UIViewRepresentable {
    let webView: WKWebView
    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

struct BrowserView: View {
    @EnvironmentObject var browser: BrowserModel
    @EnvironmentObject var downloads: DownloadManager
    @State private var address = ""
    @FocusState private var addressFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            addressBar
            ZStack(alignment: .bottomTrailing) {
                WebViewContainer(webView: browser.webView)
                if browser.showStart {
                    StartPage { open($0) }
                        .transition(.opacity)
                } else {
                    detectButton.padding(18)
                }
            }
            bottomBar
        }
        .overlay(alignment: .top) { toastView }
        .sheet(isPresented: $browser.showMediaSheet) {
            MediaSheet()
                .environmentObject(browser)
                .environmentObject(downloads)
        }
        .onChange(of: browser.currentURL) { url in
            if !addressFocused { address = url?.absoluteString ?? "" }
        }
        .onChange(of: browser.showStart) { start in
            if start { address = "" } else if !addressFocused { address = browser.currentURL?.absoluteString ?? "" }
        }
    }

    private func open(_ text: String) {
        addressFocused = false
        browser.open(text)
    }

    // MARK: Adres çubuğu

    private var addressBar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundColor(.secondary)
                    TextField("Ara veya adres yaz", text: $address)
                        .keyboardType(.webSearch)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.go)
                        .focused($addressFocused)
                        .onSubmit { open(address) }
                    if addressFocused && !address.isEmpty {
                        Button { address = "" } label: {
                            Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 9)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color(.secondarySystemBackground)))

                if addressFocused {
                    Button("Vazgeç") {
                        addressFocused = false
                        address = browser.showStart ? "" : (browser.currentURL?.absoluteString ?? "")
                    }
                } else if !browser.showStart {
                    Button {
                        browser.isLoading ? browser.stop() : browser.reload()
                    } label: {
                        Image(systemName: browser.isLoading ? "xmark" : "arrow.clockwise")
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            ProgressView(value: browser.progress)
                .progressViewStyle(.linear)
                .tint(Theme.accent)
                .frame(height: 2)
                .opacity(browser.isLoading && !browser.showStart ? 1 : 0)
        }
        .background(Color(.systemBackground))
    }

    // MARK: İndirme düğmesi

    private var detectButton: some View {
        Button {
            if browser.media.isEmpty {
                browser.flash("Henüz video bulunamadı. Videoyu oynatmayı deneyin.")
            } else {
                browser.showMediaSheet = true
            }
        } label: {
            ZStack(alignment: .topTrailing) {
                Image(systemName: "arrow.down.to.line")
                    .font(.title2.weight(.bold))
                    .foregroundColor(.white)
                    .frame(width: 60, height: 60)
                    .background(Circle().fill(browser.media.isEmpty ? Color.gray.opacity(0.8) : Theme.accent))
                    .shadow(color: .black.opacity(0.25), radius: 6, y: 3)
                if !browser.media.isEmpty {
                    Text("\(browser.media.count)")
                        .font(.caption.bold())
                        .foregroundColor(Theme.accent)
                        .frame(minWidth: 22, minHeight: 22)
                        .background(Circle().fill(Color.white))
                        .offset(x: 4, y: -4)
                }
            }
        }
        .animation(.spring(), value: browser.media.count)
    }

    // MARK: Alt çubuk

    private var bottomBar: some View {
        HStack {
            barButton("chevron.left", enabled: browser.canGoBack) { browser.goBack() }
            barButton("chevron.right", enabled: browser.canGoForward) { browser.goForward() }
            barButton("house", enabled: !browser.showStart) { browser.goHome() }
            barButton("star", enabled: !browser.showStart) { browser.addCurrentBookmark() }
            if let url = browser.currentURL, !browser.showStart {
                ShareLink(item: url) {
                    Image(systemName: "square.and.arrow.up").font(.title3).frame(maxWidth: .infinity)
                }
            } else {
                barButton("square.and.arrow.up", enabled: false) {}
            }
        }
        .padding(.vertical, 8)
        .background(Color(.systemBackground).shadow(color: .black.opacity(0.06), radius: 1, y: -1))
    }

    private func barButton(_ icon: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.title3).frame(maxWidth: .infinity)
        }
        .disabled(!enabled)
    }

    // MARK: Bildirim

    @ViewBuilder private var toastView: some View {
        if let text = browser.toast {
            HStack(spacing: 10) {
                Text(text).font(.subheadline.weight(.medium)).foregroundColor(.white)
                if text == "İndirme başladı" {
                    Button("Görüntüle") {
                        NotificationCenter.default.post(name: .showDownloads, object: nil)
                    }
                    .font(.subheadline.bold())
                    .foregroundColor(.white)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Capsule().fill(Color.black.opacity(0.8)))
            .padding(.top, 64)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}

// MARK: - Başlangıç sayfası

struct StartPage: View {
    @EnvironmentObject var browser: BrowserModel
    let onOpen: (String) -> Void

    private let palette: [Color] = [
        Color(red: 0.93, green: 0.22, blue: 0.38), Color(red: 0.20, green: 0.55, blue: 0.95),
        Color(red: 0.15, green: 0.70, blue: 0.55), Color(red: 0.98, green: 0.60, blue: 0.15),
        Color(red: 0.55, green: 0.35, blue: 0.90), Color(red: 0.10, green: 0.65, blue: 0.80),
    ]

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 60))
                    .foregroundColor(Theme.accent)
                    .padding(.top, 36)
                Text("Video İndirici").font(.title2.bold())
                Text("Bir siteye girin, videoyu oynatın ve sağ alttaki indirme düğmesine dokunun.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)

                PasteButton(payloadType: String.self) { strings in
                    guard let s = strings.first else { return }
                    DispatchQueue.main.async { onOpen(s) }
                }
                .tint(Theme.accent)
                .labelStyle(.titleAndIcon)

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 76), spacing: 12)], spacing: 18) {
                    ForEach(Array(browser.bookmarks.enumerated()), id: \.element.id) { index, b in
                        Button { onOpen(b.url) } label: {
                            VStack(spacing: 6) {
                                Text(String(b.title.prefix(1)).uppercased())
                                    .font(.title2.bold())
                                    .foregroundColor(.white)
                                    .frame(width: 56, height: 56)
                                    .background(RoundedRectangle(cornerRadius: 15).fill(palette[index % palette.count]))
                                Text(b.title)
                                    .font(.caption)
                                    .foregroundColor(.primary)
                                    .lineLimit(1)
                            }
                        }
                        .contextMenu {
                            Button(role: .destructive) { browser.removeBookmark(b) } label: {
                                Label("Kısayolu sil", systemImage: "trash")
                            }
                        }
                    }
                }
                .padding(.horizontal, 20)

                Text("Kısayol eklemek için bir sayfadayken ☆ düğmesine dokunun. Silmek için kısayola basılı tutun.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                    .padding(.bottom, 24)
            }
            .frame(maxWidth: .infinity)
        }
        .background(Color(.systemBackground))
    }
}

// MARK: - Bulunan videolar

struct MediaSheet: View {
    @EnvironmentObject var browser: BrowserModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(browser.media) { m in
                        MediaRow(media: m) {
                            browser.download(m)
                            dismiss()
                        }
                    }
                } footer: {
                    Text("Birden fazla seçenek varsa genellikle boyutu en büyük olan en yüksek kalitedir. Bağlantıyı kopyalamak için satıra basılı tutun.")
                }
            }
            .navigationTitle("Bulunan videolar")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Kapat") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Temizle") {
                        browser.media.removeAll()
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

struct MediaRow: View {
    @EnvironmentObject var browser: BrowserModel
    let media: DetectedMedia
    let onDownload: () -> Void
    @State private var size: Int64?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: media.kind == .hls ? "dot.radiowaves.left.and.right" : "film")
                .font(.title3)
                .foregroundColor(Theme.accent)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 3) {
                Text(media.displayName)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                HStack(spacing: 6) {
                    Text(media.formatLabel)
                    if let size {
                        Text("· " + ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                    }
                    Text("· " + (media.url.host ?? ""))
                }
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(1)
            }
            Spacer(minLength: 4)
            Button(action: onDownload) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 30))
                    .foregroundColor(Theme.accent)
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 4)
        .contextMenu {
            Button { UIPasteboard.general.string = media.url.absoluteString } label: {
                Label("Bağlantıyı kopyala", systemImage: "doc.on.doc")
            }
        }
        .task {
            if media.kind == .file { size = await browser.contentLength(media) }
        }
    }
}
