import SwiftUI
import LocalAuthentication

// MARK: - Uygulama kilidi

@MainActor
final class AppLock: ObservableObject {
    @Published var locked: Bool
    private var authenticating = false
    private var shouldAutoPrompt: Bool

    static var enabled: Bool { UserDefaults.standard.bool(forKey: "appLock") }

    init() {
        locked = Self.enabled
        shouldAutoPrompt = Self.enabled
    }

    func lockIfNeeded() {
        if Self.enabled {
            locked = true
            shouldAutoPrompt = true
        }
    }

    /// Arka plandan dönünce bir kez kendiliğinden Face ID sorar (vazgeçilirse tekrar tekrar sormaz).
    func autoUnlock() {
        guard locked, shouldAutoPrompt else { return }
        shouldAutoPrompt = false
        unlock()
    }

    func unlock() {
        guard locked, !authenticating else { return }
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            locked = false    // cihazda şifre yoksa kilitli kalmasın
            return
        }
        authenticating = true
        context.evaluatePolicy(.deviceOwnerAuthentication,
                               localizedReason: "Indir'i açmak için kimliğinizi doğrulayın") { ok, _ in
            DispatchQueue.main.async {
                self.authenticating = false
                if ok { self.locked = false }
            }
        }
    }
}

struct LockScreen: View {
    @EnvironmentObject var lock: AppLock

    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()
            VStack(spacing: 16) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 52))
                    .foregroundColor(Theme.accent)
                Text("Indir kilitli").font(.title3.bold())
                Button {
                    lock.unlock()
                } label: {
                    Label("Kilidi aç", systemImage: "faceid")
                        .padding(.horizontal, 24)
                        .padding(.vertical, 12)
                        .background(Capsule().fill(Theme.accent))
                        .foregroundColor(.white)
                }
            }
        }
    }
}

// MARK: - Ayarlar

struct SettingsView: View {
    @EnvironmentObject var browser: BrowserModel
    @EnvironmentObject var downloads: DownloadManager

    @AppStorage("appLock") private var appLock = false
    @AppStorage("saveHistory") private var saveHistory = true
    @AppStorage("restoreTabs") private var restoreTabs = true
    @AppStorage("autoSavePhotos") private var autoSave = true
    @AppStorage("deleteAfterSave") private var deleteAfterSave = false

    @State private var pending: PendingAction?
    @State private var info: String?
    @State private var working = false

    enum PendingAction: String, Identifiable {
        case history, siteData, downloads, reset
        var id: String { rawValue }

        var title: String {
            switch self {
            case .history: return "Tüm tarama geçmişi silinsin mi?"
            case .siteData: return "Çerezler ve site verileri silinsin mi? Sitelerdeki oturumlarınız kapanır."
            case .downloads: return "İndirilen tüm videolar uygulamadan silinsin mi? Fotoğraflar'a kaydedilenler silinmez."
            case .reset: return "Her şey sıfırlansın mı? Geçmiş, çerezler, sekmeler, kısayollar, ayarlar ve indirilen videolar silinir."
            }
        }

        var button: String {
            switch self {
            case .history: return "Geçmişi temizle"
            case .siteData: return "Site verilerini temizle"
            case .downloads: return "İndirmeleri sil"
            case .reset: return "Her şeyi sıfırla"
            }
        }
    }

    private var version: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        return v
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle(isOn: $appLock) {
                        Label("Face ID ile kilitle", systemImage: "faceid")
                    }
                    Toggle(isOn: $saveHistory) {
                        Label("Geçmişi kaydet", systemImage: "clock.arrow.circlepath")
                    }
                    Toggle(isOn: $restoreTabs) {
                        Label("Sekmeleri hatırla", systemImage: "square.on.square")
                    }
                    .onChange(of: restoreTabs) { _ in browser.saveSession() }
                } header: {
                    Text("Gizlilik")
                } footer: {
                    Text("Kilit açıkken uygulama her açılışta Face ID ister ve uygulama değiştiricide içerik gizlenir. Gizli sekmeler (⋯ menüsü → Yeni gizli sekme) geçmişe, çerezlere ve sekme listesine hiçbir şey bırakmaz.")
                }

                Section("Verileri temizle") {
                    Button { pending = .history } label: {
                        Label("Geçmişi temizle", systemImage: "trash")
                    }
                    .disabled(browser.history.isEmpty)
                    Button { pending = .siteData } label: {
                        Label("Çerezleri ve site verilerini temizle", systemImage: "globe.badge.chevron.backward")
                    }
                    Button {
                        Task {
                            working = true
                            await browser.clearCache()
                            working = false
                            info = "Önbellek temizlendi"
                        }
                    } label: {
                        Label("Önbelleği temizle", systemImage: "internaldrive")
                    }
                }

                Section {
                    Toggle(isOn: $autoSave) {
                        Label("Fotoğraflar'a otomatik kaydet", systemImage: "photo.on.rectangle")
                    }
                    Toggle(isOn: $deleteAfterSave) {
                        Label("Kaydedince uygulamadan sil", systemImage: "arrow.down.app")
                    }
                    .disabled(!autoSave)
                    LabeledContent {
                        Text(downloads.totalSizeText)
                    } label: {
                        Label("Kaplanan alan", systemImage: "chart.pie")
                    }
                    Button(role: .destructive) { pending = .downloads } label: {
                        Label("Tüm indirmeleri sil", systemImage: "trash")
                    }
                    .disabled(downloads.items.isEmpty)
                } header: {
                    Text("İndirmeler")
                } footer: {
                    Text("\"Kaydedince uygulamadan sil\" açıksa video Fotoğraflar'a geçtikten sonra uygulamadaki kopyası silinir ve telefonda yer kaplamaz.")
                }

                Section("Kısayollar") {
                    Button {
                        browser.restoreDefaultBookmarks()
                        info = "Varsayılan kısayollar geri yüklendi"
                    } label: {
                        Label("Varsayılan kısayolları geri yükle", systemImage: "arrow.uturn.backward")
                    }
                }

                Section {
                    Button(role: .destructive) { pending = .reset } label: {
                        Label("Her şeyi sıfırla", systemImage: "exclamationmark.triangle")
                    }
                } footer: {
                    Text("Uygulama ilk kurulduğu hâline döner. Fotoğraflar'a kaydettiğiniz videolar silinmez.")
                }

                Section("Hakkında") {
                    LabeledContent("Sürüm", value: version)
                }
            }
            .navigationTitle("Ayarlar")
            .overlay {
                if working {
                    ProgressView().padding(24).background(RoundedRectangle(cornerRadius: 14).fill(.ultraThinMaterial))
                }
            }
            .confirmationDialog(pending?.title ?? "", isPresented: Binding(
                get: { pending != nil },
                set: { if !$0 { pending = nil } }
            ), titleVisibility: .visible, presenting: pending) { action in
                Button(action.button, role: .destructive) { perform(action) }
                Button("Vazgeç", role: .cancel) {}
            }
            .alert(info ?? "", isPresented: Binding(
                get: { info != nil },
                set: { if !$0 { info = nil } }
            )) {
                Button("Tamam", role: .cancel) {}
            }
        }
    }

    private func perform(_ action: PendingAction) {
        switch action {
        case .history:
            browser.clearHistory()
            info = "Geçmiş temizlendi"
        case .siteData:
            Task {
                working = true
                await browser.clearWebsiteData()
                working = false
                info = "Çerezler ve site verileri temizlendi"
            }
        case .downloads:
            downloads.deleteAll()
            info = "İndirmeler silindi"
        case .reset:
            Task {
                working = true
                await browser.resetEverything()
                working = false
                info = "Uygulama sıfırlandı"
            }
        }
    }
}
