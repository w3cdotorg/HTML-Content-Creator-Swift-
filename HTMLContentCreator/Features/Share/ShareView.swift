import SwiftUI

struct ShareView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Share")
                    .font(.largeTitle.weight(.semibold))

                Text("Generate and open HTML/PDF outputs. Review project readiness before sharing.")
                    .foregroundStyle(.secondary)

                GroupBox("Preflight") {
                    VStack(alignment: .leading, spacing: 10) {
                        summaryRow(label: "Project", value: appState.activeProject)
                        summaryRow(label: "Captures", value: "\(appState.historyItems.count)")
                        summaryRow(label: "Project title", value: appState.projectTitleInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Untitled" : appState.projectTitleInput)
                        summaryRow(label: "Last HTML build", value: formattedDate(appState.lastHTMLGeneratedAt))
                        summaryRow(label: "Last PDF build", value: formattedDate(appState.lastPDFGeneratedAt))

                        if preflightIssues.isEmpty {
                            HStack(spacing: 6) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                                Text("No blocking issues detected.")
                                    .foregroundStyle(.secondary)
                            }
                            .font(.footnote)
                        } else {
                            ForEach(preflightIssues) { issue in
                                HStack(alignment: .top, spacing: 8) {
                                    Image(systemName: issue.kind.symbol)
                                        .foregroundStyle(issue.kind.color)
                                    Text(issue.message)
                                        .font(.footnote)
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                GroupBox("Actions") {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 10) {
                            Button("Generate HTML") {
                                Task {
                                    await appState.generateHTMLForActiveProject()
                                }
                            }
                            .disabled(appState.startupState != .ready || appState.htmlGenerationState == .generating)

                            Button("Open HTML") {
                                appState.openGeneratedHTML()
                            }
                            .disabled(appState.generatedHTMLURL == nil)

                            if appState.htmlGenerationState == .generating {
                                ProgressView()
                            }
                        }

                        htmlStatusView

                        HStack(spacing: 10) {
                            Button("Generate PDF") {
                                Task {
                                    await appState.exportPDFForActiveProject()
                                }
                            }
                            .disabled(appState.startupState != .ready || appState.pdfExportState == .exporting)

                            Button("Open PDF") {
                                appState.openGeneratedPDF()
                            }
                            .disabled(appState.generatedPDFURL == nil)

                            if appState.pdfExportState == .exporting {
                                ProgressView()
                            }
                        }

                        pdfStatusView

                        if let shareURL = appState.generatedPDFURL ?? appState.generatedHTMLURL {
                            ShareLink(item: shareURL) {
                                Label("Share…", systemImage: "square.and.arrow.up")
                            }
                        } else {
                            Button {
                                appState.notifyInfo("Generate HTML or PDF before sharing.")
                            } label: {
                                Label("Share…", systemImage: "square.and.arrow.up")
                            }
                            .disabled(true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
    }

    private func summaryRow(label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 130, alignment: .leading)
            Text(value)
        }
    }

    private func formattedDate(_ date: Date?) -> String {
        guard let date else { return "Not generated" }
        return Self.dateFormatter.string(from: date)
    }

    @ViewBuilder
    private var htmlStatusView: some View {
        switch appState.htmlGenerationState {
        case .idle:
            if let htmlURL = appState.generatedHTMLURL {
                Text("HTML ready: \(htmlURL.lastPathComponent)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        case .generating:
            Text("Generating HTML from captures, order, and notes...")
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
    }

    @ViewBuilder
    private var pdfStatusView: some View {
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

    private var preflightIssues: [PreflightIssue] {
        var issues: [PreflightIssue] = []

        if appState.historyItems.isEmpty {
            issues.append(
                PreflightIssue(
                    kind: .warning,
                    message: "No captures found for this project."
                )
            )
        }

        if case .failed(let message) = appState.htmlGenerationState {
            issues.append(
                PreflightIssue(
                    kind: .error,
                    message: "Latest HTML generation failed: \(message)"
                )
            )
        }

        if case .failed(let message) = appState.pdfExportState {
            issues.append(
                PreflightIssue(
                    kind: .error,
                    message: "Latest PDF export failed: \(message)"
                )
            )
        }

        return issues
    }

    private struct PreflightIssue: Identifiable {
        let id = UUID()
        let kind: Kind
        let message: String

        enum Kind {
            case warning
            case error

            var symbol: String {
                switch self {
                case .warning:
                    return "exclamationmark.triangle.fill"
                case .error:
                    return "xmark.octagon.fill"
                }
            }

            var color: Color {
                switch self {
                case .warning:
                    return .orange
                case .error:
                    return .red
                }
            }
        }
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}
