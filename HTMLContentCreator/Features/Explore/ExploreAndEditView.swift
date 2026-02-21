import AppKit
import SwiftUI

struct ExploreAndEditView: View {
    @EnvironmentObject private var appState: AppState

    @State private var selectedFilename: String?
    @State private var pendingDeletionFilename: String?

    var body: some View {
        HSplitView {
            leftColumn
                .frame(minWidth: 320, idealWidth: 360, maxWidth: 420)

            rightColumn
                .frame(minWidth: 520)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            syncSelectionIfNeeded()
        }
        .onChange(of: appState.editorItems) { _, _ in
            syncSelectionIfNeeded()
        }
        .alert(
            "Delete capture?",
            isPresented: Binding(
                get: { pendingDeletionFilename != nil },
                set: { shouldPresent in
                    if !shouldPresent {
                        pendingDeletionFilename = nil
                    }
                }
            ),
            actions: {
                Button("Cancel", role: .cancel) {
                    pendingDeletionFilename = nil
                }
                Button("Delete", role: .destructive) {
                    guard let pendingDeletionFilename else { return }
                    Task {
                        let fallback = CaptureHistoryItem(
                            filename: pendingDeletionFilename,
                            fileURL: appState.editorImageURL(filename: pendingDeletionFilename),
                            modifiedAt: Date()
                        )
                        let item = appState.historyItems.first(where: { $0.filename == pendingDeletionFilename }) ?? fallback
                        await appState.deleteHistoryItem(item)
                    }
                    self.pendingDeletionFilename = nil
                }
            },
            message: {
                if let pendingDeletionFilename {
                    Text("Delete \(pendingDeletionFilename)?")
                }
            }
        )
    }

    private var leftColumn: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Explore and Edit")
                    .font(.title2.weight(.semibold))

                Spacer()

                Button("Reload") {
                    Task {
                        await appState.refreshEditorState()
                    }
                }
                .accessibilityIdentifier("explore.reload.button")
                .disabled(appState.editorState == .loading || appState.editorState == .saving)

                Button("Save") {
                    Task {
                        await appState.saveEditorState()
                    }
                }
                .accessibilityIdentifier("explore.save.button")
                .disabled(appState.editorState == .loading || appState.editorState == .saving)

            }

            editorStatusView

            if appState.editorItems.isEmpty {
                Spacer()
                Text("No captures to edit for this project.")
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                List(selection: $selectedFilename) {
                    ForEach(appState.editorItems) { item in
                        editorRow(item)
                            .tag(item.filename)
                            .contextMenu {
                                Button("Delete Capture", role: .destructive) {
                                    pendingDeletionFilename = item.filename
                                }
                            }
                    }
                    .onMove { source, destination in
                        appState.moveEditorItems(from: source, to: destination)
                    }
                }
                .listStyle(.inset)
                .accessibilityIdentifier("explore.items.list")
            }
        }
        .padding(4)
    }

    @ViewBuilder
    private var rightColumn: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let item = selectedEditorItem {
                Text("Slide details")
                    .font(.title2.weight(.semibold))

                if let image = NSImage(contentsOf: appState.editorImageURL(filename: item.filename)) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: 420)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
                        )
                } else {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.secondary.opacity(0.12))
                        .frame(maxWidth: .infinity, maxHeight: 420)
                        .overlay(
                            Text("Preview unavailable")
                                .foregroundStyle(.secondary)
                        )
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text(item.filename)
                        .font(.headline)
                    Link(item.sourceURL.absoluteString, destination: item.sourceURL)
                        .font(.footnote)
                        .lineLimit(2)
                    if let capturedAt = item.capturedAt {
                        Text("Captured: \(Self.dateFormatter.string(from: capturedAt))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Notes")
                        .font(.headline)
                    TextEditor(text: noteBinding(for: item.filename))
                        .font(.body.monospaced())
                        .frame(minHeight: 160)
                        .accessibilityIdentifier("explore.note.editor")
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                        )
                }

                Text("Tip: markdown supports *bold*, _italic_, and - list items.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Spacer()
                Text("Select a capture from the list to preview and edit notes.")
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(4)
    }

    private func editorRow(_ item: AppState.EditorItem) -> some View {
        HStack(spacing: 10) {
            if let image = NSImage(contentsOf: appState.editorImageURL(filename: item.filename)) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 64, height: 40)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                    )
            } else {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.secondary.opacity(0.15))
                    .frame(width: 64, height: 40)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("\(appState.captureIDFromFilename(item.filename)) - \(appState.domainFromFilename(item.filename))")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(item.filename)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var editorStatusView: some View {
        switch appState.editorState {
        case .idle:
            Text("Editor not loaded yet.")
                .foregroundStyle(.secondary)
        case .loading:
            HStack(spacing: 8) {
                ProgressView()
                Text("Loading editor data...")
            }
            .foregroundStyle(.secondary)
        case .saving:
            HStack(spacing: 8) {
                ProgressView()
                Text("Saving order and notes...")
            }
            .foregroundStyle(.secondary)
        case .failed(let message):
            Text("Editor error: \(message)")
                .foregroundStyle(.red)
        case .ready:
            Text("Drag rows to reorder slides. Save to persist changes.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var selectedEditorItem: AppState.EditorItem? {
        guard let selectedFilename else { return nil }
        return appState.editorItems.first(where: { $0.filename == selectedFilename })
    }

    private func syncSelectionIfNeeded() {
        guard !appState.editorItems.isEmpty else {
            selectedFilename = nil
            return
        }

        if let selectedFilename,
           appState.editorItems.contains(where: { $0.filename == selectedFilename }) {
            return
        }

        selectedFilename = appState.editorItems.first?.filename
    }

    private func noteBinding(for filename: String) -> Binding<String> {
        Binding(
            get: {
                appState.editorItems.first(where: { $0.filename == filename })?.note ?? ""
            },
            set: { newValue in
                appState.updateEditorNote(filename: filename, note: newValue)
            }
        )
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}
