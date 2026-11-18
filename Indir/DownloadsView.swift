import SwiftUI
import AVKit

struct DownloadsView: View {
    @EnvironmentObject var downloads: DownloadManager
    @AppStorage("autoSavePhotos") private var autoSave = true
    @State private var playing: DownloadItem?

    var body: some View {
        NavigationStack {
            Group {
                if downloads.items.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "tray")
                            .font(.system(size: 48))
                            .foregroundColor(.secondary)
                        Text("Henüz indirme yok").font(.headline)
                        Text("Tarayıcıdan bir video indirdiğinizde burada görünür.")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 40)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(downloads.items) { item in
                            DownloadRow(item: item)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    if item.state == .done { playing = item }
                                }
                                .swipeActions(edge: .trailing) {
                                    Button(role: .destructive) { downloads.delete(item.id) } label: {
                                        Label("Sil", systemImage: "trash")
                                    }
                                }
                                .swipeActions(edge: .leading) {
                                    if item.state == .done {
                                        Button { downloads.saveToPhotos(item.id, announce: true) } label: {
                                            Label("Fotoğraflar", systemImage: "photo.on.rectangle")
                                        }
                                        .tint(.blue)
                                    }
                                }
                                .contextMenu { menu(for: item) }
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("İndirilenler")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Toggle("Fotoğraflar'a otomatik kaydet", isOn: $autoSave)
                        Button(role: .destructive) { downloads.clearFailed() } label: {
                            Label("Başarısızları temizle", systemImage: "xmark.bin")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        }
        .fullScreenCover(item: $playing) { item in
            if let url = downloads.fileURL(item) {
                PlayerView(url: url)
            }
        }
        .onAppear { downloads.pruneMissing() }
    }

    @ViewBuilder private func menu(for item: DownloadItem) -> some View {
        switch item.state {
        case .done:
            Button { playing = item } label: { Label("Oynat", systemImage: "play.fill") }
            Button { downloads.saveToPhotos(item.id, announce: true) } label: {
                Label("Fotoğraflar'a kaydet", systemImage: "photo.on.rectangle")
            }
            if let url = downloads.fileURL(item) {
                ShareLink(item: url) { Label("Paylaş", systemImage: "square.and.arrow.up") }
            }
        case .downloading:
            Button(role: .destructive) { downloads.cancel(item.id) } label: {
                Label("İptal et", systemImage: "stop.circle")
            }
        case .converting:
            EmptyView()
        case .failed:
            Button { downloads.retry(item.id) } label: {
                Label("Tekrar dene", systemImage: "arrow.clockwise")
            }
        }
        Button { UIPasteboard.general.string = item.sourceURL.absoluteString } label: {
            Label("Video bağlantısını kopyala", systemImage: "doc.on.doc")
        }
        Button(role: .destructive) { downloads.delete(item.id) } label: {
            Label("Sil", systemImage: "trash")
        }
    }
}

struct DownloadRow: View {
    @EnvironmentObject var downloads: DownloadManager
    let item: DownloadItem

    var body: some View {
        HStack(spacing: 12) {
            Thumbnail(url: item.state == .done ? downloads.fileURL(item) : nil)
                .frame(width: 100, height: 62)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 5) {
                Text(item.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                status
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder private var status: some View {
        switch item.state {
        case .downloading:
            ProgressView(value: item.progress).tint(Theme.accent)
            Text(progressText).font(.caption).foregroundColor(.secondary)
        case .converting:
            HStack(spacing: 6) {
                ProgressView().scaleEffect(0.7)
                Text("MP4'e dönüştürülüyor…")
            }
            .font(.caption)
            .foregroundColor(.secondary)
        case .done:
            HStack(spacing: 4) {
                Text(sizeText)
                if item.savedToPhotos {
                    Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                    Text("Fotoğraflar'da")
                }
            }
            .font(.caption)
            .foregroundColor(.secondary)
        case .failed:
            Text(item.errorMessage ?? "Başarısız")
                .font(.caption)
                .foregroundColor(.red)
                .lineLimit(3)
        }
    }

    private var progressText: String {
        let pct = "%\(Int(item.progress * 100))"
        if item.kind == .file, item.receivedBytes > 0 {
            let got = ByteCountFormatter.string(fromByteCount: item.receivedBytes, countStyle: .file)
            if item.totalBytes > 0 {
                let total = ByteCountFormatter.string(fromByteCount: item.totalBytes, countStyle: .file)
                return "\(pct) · \(got) / \(total)"
            }
            return got
        }
        return pct
    }

    private var sizeText: String {
        guard let url = downloads.fileURL(item),
              let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else { return "Tamamlandı" }
        return ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file) + " · " + url.pathExtension.uppercased()
    }
}

struct Thumbnail: View {
    let url: URL?
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Color(.secondarySystemBackground)
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: "film").foregroundColor(.secondary)
            }
        }
        .task(id: url) {
            guard let url else { return }
            image = await Self.make(url)
        }
    }

    static func make(_ url: URL) async -> UIImage? {
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 300, height: 300)
        for seconds in [1.0, 0.0] {
            if let result = try? await gen.image(at: CMTime(seconds: seconds, preferredTimescale: 600)) {
                return UIImage(cgImage: result.image)
            }
        }
        return nil
    }
}

struct PlayerView: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.ignoresSafeArea()
            if let player {
                VideoPlayer(player: player).ignoresSafeArea()
            }
            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 34))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .black.opacity(0.5))
            }
            .padding()
        }
        .onAppear {
            let p = AVPlayer(url: url)
            player = p
            p.play()
        }
        .onDisappear { player?.pause() }
    }
}
