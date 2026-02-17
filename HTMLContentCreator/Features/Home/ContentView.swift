import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var appState: AppState
    @State private var pendingDeletion: CaptureHistoryItem?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("HTML Content Creator")
                    .font(.largeTitle)
                    .fontWeight(.semibold)

                Text("Phase 7 native UI: projects, capture, history, editor, HTML generation and PDF export.")
                    .foregroundStyle(.secondary)

                if let feedback = appState.feedback {
                    HStack(spacing: 10) {
                        Text(feedback.message)
                            .font(.subheadline)
                        Spacer()
                        Button("Dismiss") {
                            appState.clearFeedback()
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(10)
                    .background(feedbackColor(for: feedback.kind).opacity(0.16))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(feedbackColor(for: feedback.kind).opacity(0.5), lineWidth: 1)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }

                GroupBox("Startup") {
                    VStack(alignment: .leading, spacing: 8) {
                        switch appState.startupState {
                        case .idle:
                            Text("- Bootstrap not started")
                        case .starting:
                            Text("- Preparing workspace directories")
                        case .ready:
                            Text("- Workspace ready")
                        case .failed(let message):
                            Text("- Startup failed: \(message)")
                                .foregroundStyle(.red)
                        }

                        Text("- Workspace root: \(appState.workspaceRootPath)")
                        Text("- old/ preserved as read-only reference")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                GroupBox("Projects") {
                    VStack(alignment: .leading, spacing: 10) {
                        Picker("Active project", selection: $appState.activeProject) {
                            ForEach(appState.projects, id: \.self) { project in
                                Text(project).tag(project)
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(maxWidth: 320)
                        .disabled(appState.startupState != .ready)

                        HStack(spacing: 8) {
                            TextField("New project (e.g. client-a)", text: $appState.newProjectInput)
                                .textFieldStyle(.roundedBorder)
                            Button("Create") {
                                Task {
                                    await appState.createProjectFromInput()
                                }
                            }
                            .disabled(appState.startupState != .ready)
                        }

                        HStack(spacing: 8) {
                            TextField("Optional HTML title", text: $appState.projectTitleInput)
                                .textFieldStyle(.roundedBorder)
                            Button("Save Title") {
                                Task {
                                    await appState.saveProjectTitle()
                                }
                            }
                            .disabled(appState.startupState != .ready)
                        }

                        HStack(spacing: 8) {
                            Button("Generate HTML") {
                                Task {
                                    await appState.generateHTMLForActiveProject()
                                }
                            }
                            .disabled(appState.startupState != .ready || appState.htmlGenerationState == .generating)

                            if appState.htmlGenerationState == .generating {
                                ProgressView()
                            }

                            Button("Explorer les captures") {
                                appState.openGeneratedHTML()
                            }
                            .disabled(appState.generatedHTMLURL == nil)

                            Button("Export PDF") {
                                Task {
                                    await appState.exportPDFForActiveProject()
                                }
                            }
                            .disabled(appState.startupState != .ready || appState.pdfExportState == .exporting)

                            if appState.pdfExportState == .exporting {
                                ProgressView()
                            }

                            Button("Ouvrir PDF") {
                                appState.openGeneratedPDF()
                            }
                            .disabled(appState.generatedPDFURL == nil)
                        }

                        switch appState.htmlGenerationState {
                        case .idle:
                            if let htmlURL = appState.generatedHTMLURL {
                                Text("HTML ready: \(htmlURL.lastPathComponent)")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        case .generating:
                            Text("Generating HTML from captures, order and notes...")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        case .succeeded(let filename):
                            Text("HTML generated: \(filename)")
                                .font(.footnote)
                                .foregroundStyle(.green)
                        case .failed(let message):
                            Text("HTML generation error: \(message)")
                                .font(.footnote)
                                .foregroundStyle(.red)
                        }

                        switch appState.pdfExportState {
                        case .idle:
                            if let pdfURL = appState.generatedPDFURL {
                                Text("PDF ready: \(pdfURL.lastPathComponent)")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        case .exporting:
                            Text("Exporting PDF deck...")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        case .succeeded(let filename):
                            Text("PDF exported: \(filename)")
                                .font(.footnote)
                                .foregroundStyle(.green)
                        case .failed(let message):
                            Text("PDF export error: \(message)")
                                .font(.footnote)
                                .foregroundStyle(.red)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                GroupBox("Capture") {
                    VStack(alignment: .leading, spacing: 10) {
                        TextField("https://example.com", text: $appState.captureURLInput)
                            .textFieldStyle(.roundedBorder)

                        HStack(spacing: 12) {
                            Button("Capture (1920x1080)") {
                                Task {
                                    await appState.captureCurrentURL()
                                }
                            }
                            .disabled(appState.startupState != .ready || appState.captureState == .capturing)

                            if appState.captureState == .capturing {
                                ProgressView()
                            }
                        }

                        switch appState.captureState {
                        case .idle:
                            Text("- Waiting for capture.")
                                .foregroundStyle(.secondary)
                        case .capturing:
                            Text("- Capturing page with WebKit...")
                        case .succeeded(let filename):
                            Text("- Capture saved: \(filename)")
                                .foregroundStyle(.green)
                        case .failed(let message):
                            Text("- Capture error: \(message)")
                                .foregroundStyle(.red)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                GroupBox("Preview") {
                    VStack(alignment: .leading, spacing: 10) {
                        if let image = appState.previewImage {
                            Image(nsImage: image)
                                .resizable()
                                .scaledToFit()
                                .frame(maxWidth: .infinity, maxHeight: 360)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12)
                                        .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
                                )
                        } else {
                            Text("No capture preview yet.")
                                .foregroundStyle(.secondary)
                        }

                        if let preview = appState.previewState {
                            Text("Filename: \(preview.filename)")
                            Text("Path: \(preview.fileURL.path)")
                                .font(.footnote)
                                .textSelection(.enabled)
                            if let source = preview.sourceURL {
                                Text("Source: \(source.absoluteString)")
                                    .font(.footnote)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                GroupBox("History") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Project: \(appState.activeProject)")
                                .font(.headline)
                            Spacer()
                            Button("Refresh") {
                                Task {
                                    await appState.refreshHistory()
                                }
                            }
                            .disabled(appState.startupState != .ready)
                        }

                        switch appState.historyState {
                        case .idle:
                            Text("History not loaded yet.")
                                .foregroundStyle(.secondary)
                        case .loading:
                            HStack {
                                ProgressView()
                                Text("Loading history...")
                            }
                        case .failed(let message):
                            Text("History error: \(message)")
                                .foregroundStyle(.red)
                        case .loaded:
                            if appState.historyItems.isEmpty {
                                Text("No saved captures for this project.")
                                    .foregroundStyle(.secondary)
                            } else {
                                LazyVStack(alignment: .leading, spacing: 8) {
                                    ForEach(appState.historyItems) { item in
                                        HStack(alignment: .top, spacing: 12) {
                                            VStack(alignment: .leading, spacing: 4) {
                                                Text("\(appState.captureIDFromFilename(item.filename)) - \(appState.domainFromFilename(item.filename))")
                                                    .font(.headline)
                                                Text(item.filename)
                                                    .font(.footnote)
                                                    .foregroundStyle(.secondary)
                                                Text(Self.historyDateFormatter.string(from: item.modifiedAt))
                                                    .font(.caption)
                                                    .foregroundStyle(.secondary)
                                            }

                                            Spacer()

                                            Button("Preview") {
                                                appState.previewHistoryItem(item)
                                            }
                                            .buttonStyle(.bordered)

                                            Button("Delete") {
                                                pendingDeletion = item
                                            }
                                            .buttonStyle(.borderedProminent)
                                            .tint(.red)
                                        }
                                        .padding(.vertical, 4)
                                        Divider()
                                    }
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                GroupBox("Editor (Order + Notes)") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Project: \(appState.activeProject)")
                                .font(.headline)
                            Spacer()
                            Button("Reload") {
                                Task {
                                    await appState.refreshEditorState()
                                }
                            }
                            .disabled(appState.startupState != .ready || appState.editorState == .loading || appState.editorState == .saving)

                            Button("Save order + notes") {
                                Task {
                                    await appState.saveEditorState()
                                }
                            }
                            .disabled(appState.startupState != .ready || appState.editorState == .loading || appState.editorState == .saving)
                        }

                        switch appState.editorState {
                        case .idle:
                            Text("Editor not loaded yet.")
                                .foregroundStyle(.secondary)
                        case .loading:
                            HStack {
                                ProgressView()
                                Text("Loading editor data...")
                            }
                        case .saving:
                            HStack {
                                ProgressView()
                                Text("Saving order and notes...")
                            }
                        case .failed(let message):
                            Text("Editor error: \(message)")
                                .foregroundStyle(.red)
                        case .ready:
                            if appState.editorItems.isEmpty {
                                Text("No captures to edit for this project.")
                                    .foregroundStyle(.secondary)
                            } else {
                                LazyVStack(alignment: .leading, spacing: 10) {
                                    ForEach(appState.editorItems) { item in
                                        VStack(alignment: .leading, spacing: 8) {
                                            HStack(alignment: .top, spacing: 10) {
                                                VStack(alignment: .leading, spacing: 4) {
                                                    Text("\(appState.captureIDFromFilename(item.filename)) - \(appState.domainFromFilename(item.filename))")
                                                        .font(.headline)
                                                    Text(item.filename)
                                                        .font(.footnote)
                                                        .foregroundStyle(.secondary)
                                                    Text(item.sourceURL.absoluteString)
                                                        .font(.caption)
                                                        .foregroundStyle(.secondary)
                                                        .textSelection(.enabled)
                                                }

                                                Spacer()

                                                VStack(spacing: 6) {
                                                    Button("↑") {
                                                        appState.moveEditorItemUp(filename: item.filename)
                                                    }
                                                    .buttonStyle(.bordered)
                                                    .disabled(appState.editorState == .saving)

                                                    Button("↓") {
                                                        appState.moveEditorItemDown(filename: item.filename)
                                                    }
                                                    .buttonStyle(.bordered)
                                                    .disabled(appState.editorState == .saving)
                                                }
                                            }

                                            TextEditor(text: noteBinding(for: item.filename))
                                                .frame(minHeight: 86)
                                                .font(.body.monospaced())
                                                .disabled(appState.editorState == .saving)

                                            Text("Markdown simple: *gras*, _italique_, listes avec - item.")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                        .padding(10)
                                        .background(Color.secondary.opacity(0.08))
                                        .clipShape(RoundedRectangle(cornerRadius: 10))
                                    }
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(20)
        .frame(minWidth: 980, minHeight: 760)
        .onChange(of: appState.activeProject) { _, newValue in
            Task {
                await appState.selectProject(newValue)
            }
        }
        .alert(
            "Delete capture?",
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { shouldPresent in
                    if !shouldPresent { pendingDeletion = nil }
                }
            ),
            actions: {
                Button("Cancel", role: .cancel) {
                    pendingDeletion = nil
                }
                Button("Delete", role: .destructive) {
                    guard let pendingDeletion else { return }
                    Task {
                        await appState.deleteHistoryItem(pendingDeletion)
                    }
                    self.pendingDeletion = nil
                }
            },
            message: {
                if let pendingDeletion {
                    Text("Delete \(pendingDeletion.filename)?")
                }
            }
        )
    }

    private func feedbackColor(for kind: AppState.InlineFeedback.Kind) -> Color {
        switch kind {
        case .success:
            return .green
        case .error:
            return .red
        case .info:
            return .blue
        }
    }

    private static let historyDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

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
}
