import AppKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var appState: AppState

    @State private var selectedSection: SidebarSection? = .projects
    @State private var window: NSWindow?

    var body: some View {
        NavigationSplitView {
            List(SidebarSection.allCases, selection: $selectedSection) { section in
                HStack(spacing: 8) {
                    Label(section.title, systemImage: section.systemImage)
                    Spacer()
                    sidebarPills(for: section)
                }
                .tag(section)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 220, ideal: 240)
        } detail: {
            VStack(alignment: .leading, spacing: 12) {
                if let feedback = appState.feedback {
                    FeedbackBanner(feedback: feedback) {
                        appState.clearFeedback()
                    }
                }

                detailView(for: selectedSection ?? .projects)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(20)
            .background(
                WindowAccessor(window: $window)
                    .frame(width: 0, height: 0)
            )
        }
        .navigationTitle("HTML Content Creator · \(appState.activeProject)")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    handleToolbarCaptureAction()
                } label: {
                    Image(systemName: "camera")
                }
                .help("Capture clipboard URL or open Capture")
                .disabled(appState.startupState != .ready || appState.captureState == .capturing)

                Button {
                    selectedSection = .share
                    Task {
                        await appState.exportPDFForActiveProject()
                    }
                } label: {
                    Label("PDF", systemImage: "doc.richtext")
                }
                .disabled(appState.startupState != .ready || appState.pdfExportState == .exporting)

                if let shareURL = appState.generatedPDFURL ?? appState.generatedHTMLURL {
                    ShareLink(item: shareURL) {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .help("Share latest generated output")
                } else {
                    Button {
                        appState.notifyInfo("Generate HTML or PDF before sharing.")
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .help("Share")
                    .disabled(true)
                }
            }
        }
        .frame(minWidth: 1120, minHeight: 760)
        .onChange(of: appState.activeProject) { _, newValue in
            Task {
                await appState.selectProject(newValue)
            }
            updateWindowTitle()
        }
        .onChange(of: window) { _, _ in
            updateWindowTitle()
        }
        .onAppear {
            updateWindowTitle()
        }
    }

    @ViewBuilder
    private func detailView(for section: SidebarSection) -> some View {
        switch section {
        case .projects:
            ProjectsView()
        case .capture:
            CaptureView()
        case .exploreAndEdit:
            ExploreAndEditView()
        case .share:
            ShareView()
        }
    }

    @ViewBuilder
    private func sidebarPills(for section: SidebarSection) -> some View {
        switch section {
        case .share:
            if appState.generatedHTMLURL != nil {
                StatusPill(text: "HTML")
            }
            if appState.generatedPDFURL != nil {
                StatusPill(text: "PDF")
            }
        default:
            EmptyView()
        }
    }

    private func updateWindowTitle() {
        window?.title = "HTML Content Creator · \(appState.activeProject)"
    }

    private func handleToolbarCaptureAction() {
        selectedSection = .capture

        guard let clipboardURL = clipboardHTTPURLString() else {
            return
        }

        appState.captureURLInput = clipboardURL
        Task {
            await appState.captureCurrentURL()
        }
    }

    private func clipboardHTTPURLString() -> String? {
        guard
            let rawValue = NSPasteboard.general.string(forType: .string)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            !rawValue.isEmpty,
            let url = URL(string: rawValue),
            let scheme = url.scheme?.lowercased(),
            scheme == "http" || scheme == "https"
        else {
            return nil
        }

        return rawValue
    }
}
