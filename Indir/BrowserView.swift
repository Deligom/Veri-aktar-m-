import SwiftUI
import WebKit

struct WebViewContainer: UIViewRepresentable {
    let webView: WKWebView
    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

struct BrowserView: View {
    @EnvironmentObject var browser: BrowserModel

    var body: some View {
        BrowserContent(tab: browser.current)
            .id(browser.currentID)
            .overlay(alignment: .top) { ToastView() }
            .sheet(isPresented: $browser.showTabs) {
                TabsView().environmentObject(browser)
            }
            .sheet(isPresented: $browser.showHistory) {
                HistoryView().environmentObject(browser)
            }
    }
}

struct BrowserContent: View {
    @EnvironmentObject var browser: BrowserModel
    @ObservedObject var tab: BrowserTab
    @State private var address = ""
    @FocusState private var addressFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            addressBar
            ZStack(alignment: .bottomTrailing) {
                WebViewContainer(webView: tab.webView)
                if tab.showStart {
                    StartPage { open($0) }
                        .transition(.opacity)
                } else {
                    detectButton.padding(18)
                }
            }
            bottomBar
        }
        .sheet(isPresented: $tab.showMediaSheet) {
            MediaSheet(tab: tab).environmentObject(browser)
        }
        .onAppear { syncAddress() }
        .onChange(of: tab.currentURL) { _ in if !addressFocused { syncAddress() } }
        .onChange(of: tab.showStart) { _ in if !addressFocused { syncAddress() } }
    }

    private func syncAddress() {
        address = tab.showStart ? "" : (tab.displayURL?.absoluteString ?? "")
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
                    Image(systemName: tab.isPrivate ? "eye.slash.fill" : "magnifyingglass")
                        .foregroundColor(tab.isPrivate ? Theme.accent : .secondary)
                    TextField(tab.isPrivate ? "Gizli sekme — ara veya adres yaz" : "Ara veya adres yaz", text: $address)
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
                        syncAddress()
                    }
                } else if !tab.showStart {
                    Button {
                        if tab.isLoading { tab.webView.stopLoading() } else { tab.webView.reload() }
                    } label: {
                        Image(systemName: tab.isLoading ? "xmark" : "arrow.clockwise")
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            ProgressView(value: tab.progress)
                .progressViewStyle(.linear)
                .tint(Theme.accent)
                .frame(height: 2)
                .opacity(tab.isLoading && !tab.showStart ? 1 : 0)
        }
        .background(Color(.systemBackground))
    }

    // MARK: İndirme düğmesi

    private var detectButton: some View {
        Button {
            if !tab.media.isEmpty {
                tab.showMediaSheet = true
            } else if tab.checking > 0 {
                browser.flash("Videolar kontrol ediliyor…")
            } else {
                tab.rescan()
                browser.flash("Sayfa yeniden taranıyor… Videoyu oynatmayı deneyin.")
            }
        } label: {
            ZStack(alignment: .topTrailing) {
                ZStack {
                    Circle().fill(tab.media.isEmpty ? Color.gray.opacity(0.8) : Theme.accent)
                    if tab.media.isEmpty && tab.checking > 0 {
                        ProgressView().tint(.white)
                    } else {
                        Image(systemName: "arrow.down.to.line")
                            .font(.title2.weight(.bold))
                            .foregroundColor(.white)
                    }
                }
                .frame(width: 60, height: 60)
                .shadow(color: .black.opacity(0.25), radius: 6, y: 3)
                if !tab.media.isEmpty {
                    Text("\(tab.media.count)")
                        .font(.caption.bold())
                        .foregroundColor(Theme.accent)
                        .frame(minWidth: 22, minHeight: 22)
                        .background(Circle().fill(Color.white))
                        .offset(x: 4, y: -4)
                }
            }
        }
        .animation(.spring(), value: tab.media.count)
    }

    // MARK: Alt çubuk

    private var bottomBar: some View {
        HStack {
            barButton("chevron.left", enabled: tab.canGoBack) { tab.goBack() }
            barButton("chevron.right", enabled: tab.canGoForward) { tab.goForward() }
            barButton("house", enabled: !tab.showStart) { tab.goHome() }

            Button {
                tab.captureSnapshot()
                browser.showTabs = true
            } label: {
                ZStack {
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(lineWidth: 1.8)
                        .frame(width: 23, height: 23)
                    Text("\(browser.tabs.count)")
                        .font(.caption2.bold())
                }
                .frame(maxWidth: .infinity)
            }

            Menu {
                Button { browser.newTab() } label: {
                    Label("Yeni sekme", systemImage: "plus.square.on.square")
                }
                Button { browser.newTab(isPrivate: true) } label: {
                    Label("Yeni gizli sekme", systemImage: "eye.slash")
                }
                Button { browser.showHistory = true } label: {
                    Label("Geçmiş", systemImage: "clock.arrow.circlepath")
                }
                if !tab.showStart, let url = tab.currentURL {
                    Divider()
                    Button { browser.addBookmark(tab) } label: {
                        Label("Kısayollara ekle", systemImage: "star")
                    }
                    ShareLink(item: url) {
                        Label("Paylaş", systemImage: "square.and.arrow.up")
                    }
                    Button {
                        UIPasteboard.general.string = url.absoluteString
                        browser.flash("Bağlantı kopyalandı")
                    } label: {
                        Label("Bağlantıyı kopyala", systemImage: "doc.on.doc")
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle").font(.title3).frame(maxWidth: .infinity)
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
}

// MARK: - Bildirim

struct ToastView: View {
    @EnvironmentObject var browser: BrowserModel

    var body: some View {
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

                Text("Kısayol eklemek için bir sayfadayken ⋯ menüsünden \"Kısayollara ekle\"ye dokunun. Silmek için kısayola basılı tutun.")
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
    @ObservedObject var tab: BrowserTab
    @Environment(\.dismiss) private var dismiss

    private var sameTitle: Bool {
        Set(tab.media.map { $0.displayName }).count <= 1
    }

    var body: some View {
        NavigationStack {
            List {
                if sameTitle, let first = tab.media.first {
                    Section {
                        HStack(spacing: 12) {
                            Image(systemName: "play.rectangle.fill")
                                .font(.title)
                                .foregroundColor(Theme.accent)
                            Text(first.displayName)
                                .font(.headline)
                                .lineLimit(3)
                        }
                        .padding(.vertical, 4)
                    }
                }
                Section {
                    ForEach(tab.media) { m in
                        Button {
                            browser.download(m, from: tab)
                            dismiss()
                        } label: {
                            MediaRow(media: m, showTitle: !sameTitle)
                        }
                        .contextMenu {
                            Button { UIPasteboard.general.string = m.url.absoluteString } label: {
                                Label("Bağlantıyı kopyala", systemImage: "doc.on.doc")
                            }
                        }
                    }
                    if tab.checking > 0 {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Diğer seçenekler kontrol ediliyor…")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                    }
                } header: {
                    Text("Kalite seçin")
                } footer: {
                    Text("~ işaretli boyutlar tahminidir. Akış olarak yayınlanan videolar indirildikten sonra MP4'e çevrilir.")
                }
            }
            .navigationTitle("Videoyu indir")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Kapat") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        tab.rescan()
                    } label: {
                        Label("Yeniden tara", systemImage: "arrow.clockwise")
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

struct MediaRow: View {
    let media: DetectedMedia
    let showTitle: Bool

    var body: some View {
        HStack(spacing: 12) {
            Text(media.qualityBadge)
                .font(.subheadline.bold())
                .foregroundColor(.white)
                .frame(width: 62, height: 38)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.accent))
            VStack(alignment: .leading, spacing: 2) {
                if showTitle {
                    Text(media.displayName)
                        .font(.subheadline)
                        .foregroundColor(.primary)
                        .lineLimit(1)
                }
                Text(media.detailLabel)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Text(media.sizeLabel ?? "Boyut ?")
                .font(.subheadline.weight(.semibold))
                .foregroundColor(media.sizeLabel == nil ? .secondary : .primary)
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 28))
                .foregroundColor(Theme.accent)
        }
        .padding(.vertical, 4)
    }
}
