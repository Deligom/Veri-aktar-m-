import SwiftUI
import AVFoundation

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        DownloadManager.shared.backgroundCompletionHandlers[identifier] = completionHandler
    }
}

@main
struct IndirApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var downloads = DownloadManager.shared
    @StateObject private var browser = BrowserModel()
    @StateObject private var lock = AppLock()
    @State private var tab = 0
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Sessiz modda da videonun sesi çıksın
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
    }

    var body: some Scene {
        WindowGroup {
            ZStack {
                TabView(selection: $tab) {
                    BrowserView()
                        .tabItem { Label("Tarayıcı", systemImage: "globe") }
                        .tag(0)
                    DownloadsView()
                        .tabItem { Label("İndirilenler", systemImage: "arrow.down.circle") }
                        .badge(downloads.activeCount)
                        .tag(1)
                    SettingsView()
                        .tabItem { Label("Ayarlar", systemImage: "gearshape") }
                        .tag(2)
                }

                // Kilit açıksa: kilit ekranı; uygulama değiştiricide içeriği gizle
                if lock.locked || (AppLock.enabled && scenePhase != .active) {
                    LockScreen()
                        .transition(.opacity)
                }
            }
            .tint(Theme.accent)
            .environmentObject(downloads)
            .environmentObject(browser)
            .environmentObject(lock)
            .onAppear { lock.autoUnlock() }
            .onChange(of: scenePhase) { phase in
                switch phase {
                case .background:
                    browser.saveSession()
                    lock.lockIfNeeded()
                case .active:
                    lock.autoUnlock()
                default:
                    browser.saveSession()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .showDownloads)) { _ in
                tab = 1
            }
            .alert(downloads.message ?? "", isPresented: Binding(
                get: { downloads.message != nil },
                set: { if !$0 { downloads.message = nil } }
            )) {
                Button("Tamam", role: .cancel) {}
            }
        }
    }
}
