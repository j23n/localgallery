import SwiftUI
import UIKit

/// In-app log viewer. Reads from `LogStore.shared`, which the `TeeLogger`
/// wrapper in `Logging.swift` populates from every `Log.<category>.<level>`
/// call. Supports level filter, text search, follow-tail toggle, copy, and
/// share-as-file. Reachable from Settings → Developer.
struct LogsView: View {
    @State private var filterLevel: LogStore.Entry.Level? = nil
    @State private var searchText = ""
    @State private var isFollowing = true
    @State private var showCopyAlert = false
    @State private var logStore = LogStore.shared

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    private var filteredEntries: [LogStore.Entry] {
        logStore.entries.filter { entry in
            if let level = filterLevel, entry.level != level { return false }
            if !searchText.isEmpty {
                let needle = searchText.lowercased()
                return entry.message.lowercased().contains(needle)
                    || entry.category.lowercased().contains(needle)
            }
            return true
        }
    }

    private var levelColors: [LogStore.Entry.Level: Color] {
        [.debug: .blue, .info: .green, .warning: .orange, .error: .red]
    }

    var body: some View {
        contentBody
            .navigationTitle("Logs")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always),
                        prompt: "Filter by message or category")
            .onAppear { isFollowing = true }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { actionsMenu }
            }
            .alert("Copied", isPresented: $showCopyAlert) {
                Button("OK") {}
            } message: { Text("Logs copied to clipboard") }
    }

    private var actionsMenu: some View {
        Menu {
            Button {
                isFollowing.toggle()
            } label: {
                Label(isFollowing ? "Stop auto-scrolling" : "Auto-scroll to latest",
                      systemImage: isFollowing ? "arrow.down.circle.fill" : "arrow.down.circle")
            }
            Menu {
                Button {
                    filterLevel = nil
                } label: {
                    HStack {
                        if filterLevel == nil { Image(systemName: "checkmark") }
                        Text("All")
                    }
                }
                Divider()
                ForEach(LogStore.Entry.Level.allCases, id: \.self) { level in
                    Button {
                        filterLevel = level
                    } label: {
                        HStack {
                            if filterLevel == level { Image(systemName: "checkmark") }
                            Text(level.displayName)
                        }
                    }
                }
            } label: {
                Label("Filter level", systemImage: "line.3.horizontal.decrease.circle")
            }
            Divider()
            Button {
                UIPasteboard.general.string = logStore.asText
                showCopyAlert = true
            } label: { Label("Copy", systemImage: "doc.on.doc") }
            Button {
                presentShareSheet()
            } label: { Label("Share", systemImage: "square.and.arrow.up") }
            Divider()
            Button(role: .destructive) {
                logStore.clear()
            } label: { Label("Clear logs", systemImage: "trash") }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
    }

    @ViewBuilder
    private var contentBody: some View {
        if filteredEntries.isEmpty {
            ContentUnavailableView {
                Label(searchText.isEmpty ? "No Logs" : "No Matching Logs",
                      systemImage: "doc.text.magnifyingglass")
            } description: {
                Text(searchText.isEmpty
                     ? "Logs will appear here as the app runs."
                     : "Try a different search term or filter.")
            }
        } else {
            logsList
        }
    }

    @ViewBuilder
    private var logsList: some View {
        ScrollViewReader { proxy in
            List(filteredEntries, id: \.id) { entry in
                logListRow(for: entry)
                    .id(entry.id)
                    .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
            }
            .listStyle(.plain)
            .onChange(of: filteredEntries.count) { _, _ in
                if isFollowing, let last = filteredEntries.last {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
            .onChange(of: isFollowing) { _, following in
                if following, let last = filteredEntries.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }

    private func logListRow(for entry: LogStore.Entry) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(levelColors[entry.level] ?? .gray)
                .frame(width: 7, height: 7)
                .padding(.top, 6)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(Self.timeFormatter.string(from: entry.timestamp))
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.secondary)

                    Text(entry.category)
                        .font(.system(size: 10.5, weight: .semibold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 3))

                    if entry.repeatCount > 1 {
                        Text("×\(entry.repeatCount)")
                            .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.orange)
                    }

                    Spacer()

                    Text(entry.level.displayName)
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(levelColors[entry.level] ?? .gray)
                }

                Text(entry.message)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func presentShareSheet() {
        let text = logStore.asText
        let stamp = Date().formatted(.iso8601.year().month().day().dateSeparator(.dash))
        let fileName = "localgallery-logs-\(stamp).txt"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        guard (try? text.write(to: url, atomically: true, encoding: .utf8)) != nil else { return }
        ShareSheet.present(items: [url])
    }
}

#Preview {
    NavigationStack { LogsView() }
}
