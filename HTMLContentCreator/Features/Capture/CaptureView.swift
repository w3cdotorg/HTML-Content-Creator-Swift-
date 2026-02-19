import SwiftUI
import UniformTypeIdentifiers

struct CaptureView: View {
    @EnvironmentObject private var appState: AppState
    @State private var showingBatchFileImporter = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Capture")
                    .font(.largeTitle.weight(.semibold))

                Text("Capture the current URL using a fixed 1920x1080 viewport with the native WebKit engine.")
                    .foregroundStyle(.secondary)

                GroupBox("URL") {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle("Block ads and consent banners (MVP)", isOn: $appState.captureContentBlockingEnabled)
                            .toggleStyle(.switch)

                        Text("Uses native WebKit content rules before the existing JavaScript cleanup fallback.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)

                        TextField("https://example.com", text: $appState.captureURLInput)
                            .textFieldStyle(.roundedBorder)

                        HStack(spacing: 10) {
                            Button("Capture (1920x1080)") {
                                Task {
                                    await appState.captureCurrentURL()
                                }
                            }
                            .disabled(appState.startupState != .ready || appState.captureState == .capturing || appState.isBatchCaptureRunning)

                            if appState.captureState == .capturing {
                                ProgressView()
                            }
                        }

                        captureStatusView
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                GroupBox("Batch Capture (.txt/.csv)") {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 10) {
                            Button("Import URL List…") {
                                showingBatchFileImporter = true
                            }
                            .disabled(appState.captureState == .capturing)

                            Button("Start Batch Capture") {
                                Task {
                                    await appState.startBatchCapture()
                                }
                            }
                            .disabled(!appState.canStartBatchCapture)

                            Button("Clear List") {
                                appState.clearBatchCaptureList()
                            }
                            .disabled(appState.batchCaptureURLs.isEmpty || appState.isBatchCaptureRunning)
                        }

                        if !appState.batchCaptureURLs.isEmpty {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Loaded \(appState.batchCaptureURLs.count) URL(s).")
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(.secondary)

                                ForEach(Array(appState.batchCaptureURLs.prefix(5).enumerated()), id: \.offset) { index, value in
                                    Text("\(index + 1). \(value)")
                                        .font(.footnote)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                        .textSelection(.enabled)
                                }

                                if appState.batchCaptureURLs.count > 5 {
                                    Text("+ \(appState.batchCaptureURLs.count - 5) more URL(s)")
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }

                        batchCaptureStatusView
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                GroupBox("Preview") {
                    VStack(alignment: .leading, spacing: 10) {
                        if let image = appState.previewImage {
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
                            Text("No capture preview yet.")
                                .foregroundStyle(.secondary)
                        }

                        if let preview = appState.previewState {
                            Text("Filename: \(preview.filename)")
                                .font(.footnote)
                            Text("Path: \(preview.fileURL.path)")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)

                            if let source = preview.sourceURL {
                                Link(source.absoluteString, destination: source)
                                    .font(.footnote)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
        .fileImporter(
            isPresented: $showingBatchFileImporter,
            allowedContentTypes: [.plainText, .commaSeparatedText, .text],
            allowsMultipleSelection: false
        ) { result in
            handleBatchFileImport(result)
        }
    }

    @ViewBuilder
    private var captureStatusView: some View {
        switch appState.captureState {
        case .idle:
            Text("Waiting for capture.")
                .foregroundStyle(.secondary)
        case .capturing:
            Text("Capturing page with WebKit...")
                .foregroundStyle(.secondary)
        case .succeeded(let filename):
            Text("Capture saved: \(filename)")
                .foregroundStyle(.green)
        case .failed(let message):
            Text("Capture error: \(message)")
                .foregroundStyle(.red)
        }
    }

    @ViewBuilder
    private var batchCaptureStatusView: some View {
        switch appState.batchCaptureState {
        case .idle:
            Text("Import a .txt or .csv list to capture multiple URLs in sequence.")
                .foregroundStyle(.secondary)
        case .ready(let sourceName, let totalURLs, let ignoredLines, let duplicateURLs):
            Text("Ready: \(totalURLs) URL(s) loaded from \(sourceName). Ignored lines: \(ignoredLines). Duplicates: \(duplicateURLs).")
                .foregroundStyle(.secondary)
        case .running(let current, let total, let succeeded, let failed, let currentURL):
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(
                    value: Double(succeeded + failed),
                    total: Double(max(total, 1))
                )
                Text("Running \(current)/\(total): \(currentURL)")
                    .font(.footnote)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("Succeeded: \(succeeded) · Failed: \(failed)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        case .completed(let sourceName, let total, let succeeded, let failed):
            Text("Batch completed for \(sourceName): \(succeeded)/\(total) succeeded, \(failed) failed.")
                .foregroundStyle(failed == 0 ? .green : .orange)
        case .failed(let message):
            Text("Batch import error: \(message)")
                .foregroundStyle(.red)
        }
    }

    private func handleBatchFileImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let fileURL = urls.first else { return }
            let hasSecurityScope = fileURL.startAccessingSecurityScopedResource()
            Task {
                defer {
                    if hasSecurityScope {
                        fileURL.stopAccessingSecurityScopedResource()
                    }
                }
                await appState.importBatchCaptureList(from: fileURL)
            }
        case .failure(let error):
            if let cocoaError = error as? CocoaError, cocoaError.code == .userCancelled {
                return
            }
            appState.notifyInfo("File import failed: \(error.localizedDescription)")
        }
    }
}
