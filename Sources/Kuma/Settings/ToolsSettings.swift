import AppKit
import KumaCore
import SwiftUI

private enum ToolSelection: Hashable {
    case tool(Tool)
    case custom(String)
}

struct ToolsSettings: View {
    @ObservedObject var model: AppModel
    @State private var selection: ToolSelection? = .tool(.claude)

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 200)
            Divider()
            Group {
                switch selection {
                case .tool(let tool):
                    ToolDetail(model: model, tool: tool).id(tool)
                case .custom(let id):
                    if let custom = model.settings.customSummarizers.first(where: { $0.id == id }) {
                        CustomCommandDetail(model: model, original: custom).id(id)
                    } else {
                        placeholder
                    }
                case nil:
                    placeholder
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(height: 460)
    }

    private var placeholder: some View {
        Text("Select a tool").foregroundStyle(.secondary)
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            List(selection: $selection) {
                Section("Tools") {
                    ForEach(Tool.watchable, id: \.self) { tool in
                        let status = model.toolStatus[tool] ?? ToolStatus(binaryFound: false, hookInstalled: false)
                        HStack(spacing: 8) {
                            Image(systemName: tool.symbol)
                                .foregroundStyle(KumaTheme.purple)
                                .frame(width: 18)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(tool.displayName)
                                Text(status.hookInstalled ? "Watching" : (status.binaryFound ? "Not watching" : "Not installed"))
                                    .font(.caption)
                                    .foregroundStyle(status.hookInstalled ? Color.green : Color.secondary)
                            }
                        }
                        .padding(.vertical, 2)
                        .tag(ToolSelection.tool(tool))
                    }
                }
                if !model.settings.customSummarizers.isEmpty {
                    Section("Custom commands") {
                        ForEach(model.settings.customSummarizers) { custom in
                            HStack(spacing: 8) {
                                Image(systemName: "terminal")
                                    .foregroundStyle(KumaTheme.purple)
                                    .frame(width: 18)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(custom.name.isEmpty ? "Untitled" : custom.name)
                                    Text(custom.command.isEmpty ? "No command" : URL(fileURLWithPath: custom.command).lastPathComponent)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(.vertical, 2)
                            .tag(ToolSelection.custom(custom.id))
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            Divider()
            HStack(spacing: 2) {
                Button { addCustom() } label: { Image(systemName: "plus").frame(width: 24, height: 22) }
                    .help("Add a custom summary command")
                Button {
                    if case .custom(let id) = selection {
                        model.deleteCustomSummarizer(id)
                        selection = .tool(.claude)
                    }
                } label: { Image(systemName: "minus").frame(width: 24, height: 22) }
                    .disabled(!isCustomSelected)
                    .help("Delete this custom command")
                Spacer()
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
        }
    }

    private var isCustomSelected: Bool {
        if case .custom = selection { return true }
        return false
    }

    private func addCustom() {
        let custom = CustomSummarizer(name: "New command", command: "", arguments: "-p {prompt} --model {model}")
        model.saveCustomSummarizer(custom)
        selection = .custom(custom.id)
    }
}

private struct ToolDetail: View {
    @ObservedObject var model: AppModel
    let tool: Tool
    @State private var command = ""
    @State private var summaryModel = ""
    @State private var testResult: String?
    @State private var testing = false

    var body: some View {
        let status = model.toolStatus[tool] ?? ToolStatus(binaryFound: false, hookInstalled: false)
        Form {
            Section {
                HStack(spacing: 10) {
                    Image(systemName: tool.symbol)
                        .font(.title3)
                        .foregroundStyle(KumaTheme.purple)
                        .frame(width: 26)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(tool.displayName).font(.headline)
                        Text(status.hookInstalled ? "Kuma hears every session from this tool." : "Install hooks so Kuma hears these sessions.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if model.toolBusy.contains(tool) {
                        ProgressView().controlSize(.small)
                    } else if status.hookInstalled {
                        Button("Remove hooks") { model.uninstallHooks(tool) }
                    } else {
                        Button("Install hooks") { model.installHooks(tool) }
                            .disabled(!status.binaryFound)
                    }
                }
                .padding(.vertical, 2)
                Picker("Summarize with", selection: Binding(
                    get: { model.settings.summarizerRoutes[tool.rawValue] ?? tool.rawValue },
                    set: { model.setSummarizerRoute(tool, target: $0) }
                )) {
                    Text("\(tool.displayName) (same tool)").tag(tool.rawValue)
                    Divider()
                    ForEach(Tool.watchable.filter { $0 != tool }, id: \.self) { other in
                        Text(other.displayName).tag(other.rawValue)
                    }
                    if !model.settings.customSummarizers.isEmpty {
                        Divider()
                        ForEach(model.settings.customSummarizers) { custom in
                            Text(custom.name.isEmpty ? "Untitled" : custom.name).tag(custom.id)
                        }
                    }
                }
                Text("Writes the spoken summaries for \(tool.displayName) sessions. If it fails, Kuma tries your other installed tools.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("\(tool.displayName) command") {
                LabeledContent("Command") {
                    HStack(spacing: 6) {
                        TextField("Command", text: $command, prompt: Text(model.detectedPath(tool) ?? "Not found"))
                            .labelsHidden()
                            .font(.system(.callout, design: .monospaced))
                            .onSubmit { model.setCommandPath(tool, path: command) }
                        Button("Choose...") {
                            if let path = ExecutablePicker.choose() {
                                command = path
                                model.setCommandPath(tool, path: path)
                            }
                        }
                    }
                }
                if let warning = commandWarning {
                    Text(warning)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                LabeledContent("Model") {
                    HStack(spacing: 6) {
                        TextField("Model", text: $summaryModel, prompt: Text(tool == .claude ? "haiku" : "Tool default"))
                            .labelsHidden()
                        if let suggestions = ToolDetail.suggestions[tool] {
                            Menu {
                                ForEach(suggestions, id: \.self) { name in
                                    Button(name) { summaryModel = name }
                                }
                            } label: {
                                Image(systemName: "list.bullet")
                            }
                            .menuStyle(.borderlessButton)
                            .fixedSize()
                            .help("Common models")
                        }
                    }
                }
                HStack(spacing: 8) {
                    if let testResult {
                        Text(testResult)
                            .font(.caption)
                            .foregroundStyle(testResult.hasPrefix("Replied") ? Color.green : Color.orange)
                            .lineLimit(2)
                    }
                    Spacer()
                    if testing { ProgressView().controlSize(.small) }
                    Button("Test") { runTest() }
                        .disabled(testing || (model.detectedPath(tool) == nil && command.isEmpty))
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            command = model.settings.commandPaths[tool.rawValue] ?? ""
            summaryModel = model.settings.summaryModels[tool.rawValue] ?? ""
        }
        .onChange(of: summaryModel) { _, value in model.setSummaryModel(tool, model: value) }
        .onChange(of: command) { _, value in
            if value.isEmpty { model.setCommandPath(tool, path: "") }
        }
        .onDisappear { model.setCommandPath(tool, path: command) }
    }

    static let suggestions: [Tool: [String]] = [
        .claude: ["haiku", "sonnet", "opus"],
        .codex: ["gpt-5-codex", "gpt-5"],
    ]

    private var commandWarning: String? {
        let trimmed = command.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            return model.detectedPath(tool) == nil ? "\(tool.displayName) was not found. Choose its command to use it for summaries." : nil
        }
        return FileManager.default.isExecutableFile(atPath: (trimmed as NSString).expandingTildeInPath) ? nil : "This file is not executable. Kuma uses the detected command instead."
    }

    private func runTest() {
        model.setCommandPath(tool, path: command)
        testing = true
        testResult = nil
        Task { @MainActor in
            testResult = await model.testSummarizer(tool: tool)
            testing = false
        }
    }
}

private struct CustomCommandDetail: View {
    @ObservedObject var model: AppModel
    let original: CustomSummarizer
    @State private var draft = CustomSummarizer(name: "", command: "")
    @State private var testResult: String?
    @State private var testing = false

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $draft.name)
                LabeledContent("Command") {
                    HStack(spacing: 6) {
                        TextField("Command", text: $draft.command, prompt: Text("Path or name"))
                            .labelsHidden()
                            .font(.system(.callout, design: .monospaced))
                        Button("Choose...") {
                            if let path = ExecutablePicker.choose() { draft.command = path }
                        }
                    }
                }
                TextField("Arguments", text: $draft.arguments, prompt: Text("-p {prompt} --model {model}"))
                    .font(.system(.callout, design: .monospaced))
                TextField("Model", text: $draft.model, prompt: Text("Optional"))
                Text("{prompt} becomes the summary request and {model} the model. Without {prompt}, the request is added at the end. The command should print the summary.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                HStack(spacing: 8) {
                    if let testResult {
                        Text(testResult)
                            .font(.caption)
                            .foregroundStyle(testResult.hasPrefix("Replied") ? Color.green : Color.orange)
                            .lineLimit(2)
                    } else {
                        Text(usedBy.isEmpty ? "Not used yet. Pick it under a tool's Summarize with." : "Summarizes \(usedBy) sessions.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if testing { ProgressView().controlSize(.small) }
                    Button("Test") { runTest() }
                        .disabled(testing || draft.command.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { draft = original }
        .onChange(of: draft) { _, value in
            if value != original { model.saveCustomSummarizer(value) }
        }
    }

    private var usedBy: String {
        Tool.watchable
            .filter { model.settings.summarizerRoutes[$0.rawValue] == draft.id }
            .map(\.displayName)
            .joined(separator: ", ")
    }

    private func runTest() {
        testing = true
        testResult = nil
        let custom = draft
        Task { @MainActor in
            testResult = await model.testSummarizer(custom: custom)
            testing = false
        }
    }
}

enum ExecutablePicker {
    @MainActor
    static func choose() -> String? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.treatsFilePackagesAsDirectories = true
        panel.message = "Choose the command line tool Kuma should run"
        panel.prompt = "Choose"
        panel.directoryURL = URL(fileURLWithPath: "/opt/homebrew/bin")
        NSApp.activate(ignoringOtherApps: true)
        return panel.runModal() == .OK ? panel.url?.path : nil
    }
}
