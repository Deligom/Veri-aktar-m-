import SwiftUI

// MARK: - Sekmeler

struct TabsView: View {
    @EnvironmentObject var browser: BrowserModel
    @Environment(\.dismiss) private var dismiss
    @State private var confirmCloseAll = false

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)],
                          spacing: 14) {
                    ForEach(browser.tabs) { t in
                        TabCard(tab: t, selected: t.id == browser.currentID,
                                onSelect: {
                                    browser.select(t)
                                    dismiss()
                                },
                                onClose: {
                                    withAnimation { browser.close(t) }
                                })
                    }
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("\(browser.tabs.count) sekme")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Tümünü kapat") { confirmCloseAll = true }
                        .foregroundColor(.red)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Bitti") { dismiss() }
                }
                ToolbarItem(placement: .bottomBar) {
                    Button {
                        browser.newTab()
                        dismiss()
                    } label: {
                        Label("Yeni sekme", systemImage: "plus")
                            .labelStyle(.titleAndIcon)
                    }
                }
            }
            .confirmationDialog("Tüm sekmeler kapatılsın mı?", isPresented: $confirmCloseAll,
                                titleVisibility: .visible) {
                Button("Tümünü kapat", role: .destructive) {
                    browser.closeAll()
                    dismiss()
                }
            }
        }
    }
}

struct TabCard: View {
    @ObservedObject var tab: BrowserTab
    let selected: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            // Kartın kendisi: dokununca sekmeye geç
            Button(action: onSelect) {
                VStack(spacing: 0) {
                    HStack {
                        Text(tab.displayTitle)
                            .font(.caption.weight(.semibold))
                            .foregroundColor(.primary)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.leading, 8)
                    .padding(.trailing, 40)   // kapatma düğmesine yer bırak
                    .frame(height: 34)
                    .background(Color(.secondarySystemBackground))

                    ZStack(alignment: .top) {
                        Color(.systemBackground)
                        if let img = tab.snapshot {
                            Image(uiImage: img)
                                .resizable()
                                .scaledToFill()
                        } else {
                            VStack(spacing: 6) {
                                Image(systemName: tab.showStart ? "house" : "globe")
                                    .font(.largeTitle)
                                if let host = tab.displayURL?.host, !tab.showStart {
                                    Text(host).font(.caption2).lineLimit(1)
                                }
                            }
                            .foregroundColor(.secondary)
                            .frame(maxHeight: .infinity)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 190)
                    .clipped()
                }
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(selected ? Theme.accent : Color.secondary.opacity(0.25),
                                lineWidth: selected ? 3 : 1)
                )
            }
            .buttonStyle(.plain)

            // Ayrı kapatma düğmesi (kartın üstünde, geniş dokunma alanı)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.footnote.bold())
                    .foregroundColor(.secondary)
                    .frame(width: 44, height: 34)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Sekmeyi kapat")
        }
        .contextMenu {
            Button(action: onSelect) {
                Label("Sekmeyi aç", systemImage: "arrow.up.forward.square")
            }
            Button(role: .destructive, action: onClose) {
                Label("Sekmeyi kapat", systemImage: "xmark")
            }
        }
    }
}

// MARK: - Geçmiş

struct HistoryView: View {
    @EnvironmentObject var browser: BrowserModel
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var confirmClear = false

    private var filtered: [HistoryEntry] {
        guard !query.isEmpty else { return browser.history }
        return browser.history.filter {
            $0.title.localizedCaseInsensitiveContains(query) || $0.url.localizedCaseInsensitiveContains(query)
        }
    }

    private var groups: [(title: String, items: [HistoryEntry])] {
        let cal = Calendar.current
        let dict = Dictionary(grouping: filtered) { cal.startOfDay(for: $0.date) }
        return dict.keys.sorted(by: >).map { day in (Self.dayLabel(day), dict[day] ?? []) }
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "tr_TR")
        f.dateFormat = "d MMMM yyyy, EEEE"
        return f
    }()

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "tr_TR")
        f.dateFormat = "HH:mm"
        return f
    }()

    private static func dayLabel(_ day: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(day) { return "Bugün" }
        if cal.isDateInYesterday(day) { return "Dün" }
        return dayFormatter.string(from: day)
    }

    var body: some View {
        NavigationStack {
            List {
                if filtered.isEmpty {
                    Text(query.isEmpty ? "Geçmiş boş" : "Sonuç bulunamadı")
                        .foregroundColor(.secondary)
                }
                ForEach(groups, id: \.title) { group in
                    Section(group.title) {
                        ForEach(group.items) { entry in
                            Button {
                                browser.open(entry.url)
                                dismiss()
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.title.isEmpty ? entry.url : entry.title)
                                        .font(.subheadline)
                                        .foregroundColor(.primary)
                                        .lineLimit(1)
                                    Text("\(Self.timeFormatter.string(from: entry.date)) · \(URL(string: entry.url)?.host ?? entry.url)")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)
                                }
                            }
                            .swipeActions {
                                Button(role: .destructive) { browser.deleteHistory(entry) } label: {
                                    Label("Sil", systemImage: "trash")
                                }
                            }
                            .contextMenu {
                                Button {
                                    if let u = URL(string: entry.url) { browser.newTab(url: u) }
                                    dismiss()
                                } label: {
                                    Label("Yeni sekmede aç", systemImage: "plus.square.on.square")
                                }
                                Button { UIPasteboard.general.string = entry.url } label: {
                                    Label("Bağlantıyı kopyala", systemImage: "doc.on.doc")
                                }
                            }
                        }
                    }
                }
            }
            .searchable(text: $query, prompt: "Geçmişte ara")
            .navigationTitle("Geçmiş")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Kapat") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Temizle") { confirmClear = true }
                        .disabled(browser.history.isEmpty)
                }
            }
            .confirmationDialog("Tüm geçmiş silinsin mi?", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("Geçmişi temizle", role: .destructive) { browser.clearHistory() }
            }
        }
    }
}
