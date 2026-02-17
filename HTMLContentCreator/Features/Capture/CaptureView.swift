import SwiftUI

struct CaptureView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Capture")
                    .font(.largeTitle.weight(.semibold))

                Text("Capture the current URL using a fixed 1920x1080 viewport with the native WebKit engine.")
                    .foregroundStyle(.secondary)

                GroupBox("URL") {
                    VStack(alignment: .leading, spacing: 12) {
                        TextField("https://example.com", text: $appState.captureURLInput)
                            .textFieldStyle(.roundedBorder)

                        HStack(spacing: 10) {
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

                        captureStatusView
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
}
