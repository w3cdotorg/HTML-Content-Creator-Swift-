import SwiftUI

struct ProjectsView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Projects")
                    .font(.largeTitle.weight(.semibold))

                Text("Choose an active project, create a new one, and set the shared title used in HTML and PDF output.")
                    .foregroundStyle(.secondary)

                GroupBox("Project Management") {
                    VStack(alignment: .leading, spacing: 12) {
                        Picker("Active project", selection: $appState.activeProject) {
                            ForEach(appState.projects, id: \.self) { project in
                                Text(project).tag(project)
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(maxWidth: 320)
                        .disabled(appState.startupState != .ready)
                        .accessibilityIdentifier("projects.active.picker")

                        HStack(spacing: 10) {
                            TextField("New project (e.g. client-a)", text: $appState.newProjectInput)
                                .textFieldStyle(.roundedBorder)
                                .accessibilityIdentifier("projects.new.textfield")

                            Button("Create") {
                                Task {
                                    await appState.createProjectFromInput()
                                }
                            }
                            .accessibilityIdentifier("projects.create.button")
                            .disabled(appState.startupState != .ready)
                        }

                        HStack(spacing: 10) {
                            TextField("Project title for HTML/PDF", text: $appState.projectTitleInput)
                                .textFieldStyle(.roundedBorder)
                                .accessibilityIdentifier("projects.title.textfield")

                            Button("Save Title") {
                                Task {
                                    await appState.saveProjectTitle()
                                }
                            }
                            .accessibilityIdentifier("projects.title.save.button")
                            .disabled(appState.startupState != .ready)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                GroupBox("Project Summary") {
                    VStack(alignment: .leading, spacing: 8) {
                        summaryRow(label: "Active project", value: appState.activeProject)
                        summaryRow(label: "Captures", value: "\(appState.historyItems.count)")
                        summaryRow(label: "HTML generated", value: formattedDate(appState.lastHTMLGeneratedAt))
                        summaryRow(label: "PDF generated", value: formattedDate(appState.lastPDFGeneratedAt))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                GroupBox("App Status") {
                    VStack(alignment: .leading, spacing: 8) {
                        switch appState.startupState {
                        case .idle:
                            Text("Bootstrap not started")
                        case .starting:
                            Text("Preparing workspace directories")
                        case .ready:
                            Text("Workspace ready")
                        case .failed(let message):
                            Text("Startup failed: \(message)")
                                .foregroundStyle(.red)
                        }

                        Text("Workspace root: \(appState.workspaceRootPath)")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
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

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}
