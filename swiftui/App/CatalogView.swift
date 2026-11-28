import CatalogCore
import SwiftUI

struct CatalogView: View {
    @State private var query = ""

    var body: some View {
        TabView {
            NavigationStack {
                List {
                    ForEach(CatalogGroup.allCases) { group in
                        let entries = filteredEntries.filter { $0.group == group }
                        if !entries.isEmpty {
                            Section(group.rawValue) {
                                ForEach(entries) { entry in
                                    NavigationLink(value: entry.id) {
                                        CatalogRow(entry: entry)
                                    }
                                }
                            }
                        }
                    }
                }
                .overlay {
                    if filteredEntries.isEmpty {
                        ContentUnavailableView.search(text: query)
                    }
                }
                .navigationTitle("できること")
                .searchable(text: $query, prompt: "目的や機能で探す")
                .navigationDestination(for: SampleID.self) { id in
                    if let entry = CatalogEntry.all.first(where: { $0.id == id }) {
                        CatalogDetail(entry: entry)
                    }
                }
            }
            .tabItem { Label("サンプル", systemImage: "list.bullet.rectangle") }

            NavigationStack {
                DiagnosticsView()
            }
            .tabItem { Label("診断", systemImage: "waveform.path.ecg") }
        }
    }

    private var filteredEntries: [CatalogEntry] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return CatalogEntry.all.filter { term.isEmpty || $0.searchText.localizedStandardContains(term) }
    }
}

private struct CatalogRow: View {
    let entry: CatalogEntry

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: entry.icon)
                .foregroundStyle(Color.accentColor)
                .frame(width: 34, height: 34)
                .background(Color.accentColor.opacity(0.13), in: RoundedRectangle(cornerRadius: 8))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.title).font(.headline)
                Text(entry.purpose).font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct CatalogDetail: View {
    let entry: CatalogEntry
    @Environment(\.diagnostics) private var diagnostics

    var body: some View {
        List {
            Section("試せること") { Text(entry.description) }
            Section("利用条件") {
                Label(entry.mode.rawValue, systemImage: entry.mode.icon)
                Text(entry.requirements).foregroundStyle(.secondary)
            }
            Section {
                NavigationLink("サンプルを開く") {
                    entry.screen
                        .task { await diagnostics?.record(sample: entry.id, action: .open, outcome: .success) }
                }
            }
        }
        .navigationTitle(entry.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    CatalogView()
}
