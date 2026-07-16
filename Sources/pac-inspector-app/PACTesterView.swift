import AppKit
import RCSPACFileParser
import SwiftUI
import UniformTypeIdentifiers

/// State for the standalone PAC Tester section — deliberately independent
/// of `AppModel`'s `pacURL`/`fetchedPACText`/`pacAnalysis` (which are paired
/// 1:1 with the HAR-coverage-diff feature), so this works with no HAR (and
/// no HAR-paired PAC) loaded at all.
@MainActor
@Observable
final class PACTesterModel {
    var sourceText = ""
    var sourceLabel: String?
    var engine: PACEngine?
    var compileError: String?
    var isBusy = false

    var singleInput = ""
    var results: [PACTestResult] = []
    var batchInputText = ""
    var isRunningBatch = false
    var highlightedLine: Int?

    var clientIPOverride = ""
    var useNowOverride = false
    var nowOverride = Date()
    var defaultProxyText = ""

    var pacURLString = ""
    var currentPACURL: URL?
    var autoRefreshSeconds = 0
    var urlLoadNote: String?

    var lineCount: Int { sourceText.isEmpty ? 0 : sourceText.components(separatedBy: "\n").count }
    var sourceLines: [String] { sourceText.components(separatedBy: "\n") }

    private var isProgrammaticSourceUpdate = false
    private var refreshTask: Task<Void, Never>?

    // MARK: - Compile

    func compile() {
        compileError = nil
        guard !sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            engine = nil
            return
        }
        do {
            let newEngine = try PACEngine(source: sourceText)
            engine = newEngine
            results = []
            highlightedLine = nil
            Task { await applySettings() }
        } catch let error as PACEngineError {
            engine = nil
            compileError = error.errorDescription
        } catch {
            engine = nil
            compileError = error.localizedDescription
        }
    }

    private func applySettings() async {
        guard let engine else { return }
        let ip = clientIPOverride.trimmingCharacters(in: .whitespaces)
        await engine.setClientIPOverride(ip.isEmpty ? nil : ip)
        await engine.setNowOverride(useNowOverride ? nowOverride : nil)
        let proxy = defaultProxyText.trimmingCharacters(in: .whitespaces)
        await engine.setDefaultProxyText(proxy.isEmpty ? "PROXY proxy.example.com:8080" : proxy)
    }

    func applySettingsNow() {
        Task { await applySettings() }
    }

    // MARK: - Source loading

    private func setSourceProgrammatically(_ text: String) {
        isProgrammaticSourceUpdate = true
        sourceText = text
    }

    /// Called from the source `TextEditor`'s `onChange`. Distinguishes a
    /// genuine hand-edit (which should cancel auto-refresh, mirroring the
    /// sister browser tool) from our own programmatic updates after a file
    /// or URL load.
    func handleSourceTextChanged() {
        if isProgrammaticSourceUpdate {
            isProgrammaticSourceUpdate = false
            return
        }
        guard currentPACURL != nil else { return }
        stopAutoRefresh()
        currentPACURL = nil
        autoRefreshSeconds = 0
        urlLoadNote = "Auto-refresh stopped — content edited manually."
    }

    func loadFile() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = ["pac", "js", "txt"].compactMap { UTType(filenameExtension: $0) }
        guard panel.runModal() == .OK, let url = panel.url else { return }

        stopAutoRefresh()
        currentPACURL = nil
        urlLoadNote = nil
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            sourceLabel = url.lastPathComponent
            setSourceProgrammatically(text)
            compile()
        } catch {
            compileError = "Could not read file: \(error.localizedDescription)"
        }
    }

    func loadFromURL() {
        let trimmed = pacURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            compileError = "Enter a valid http:// or https:// URL."
            return
        }
        Task { await fetchFromURL(url) }
    }

    func loadFromSavedURL(_ saved: SavedPACURL) {
        pacURLString = saved.urlString
        loadFromURL()
    }

    func refreshNow() {
        guard let currentPACURL else { return }
        Task { await fetchFromURL(currentPACURL) }
    }

    private func fetchFromURL(_ url: URL) async {
        isBusy = true
        defer { isBusy = false }
        do {
            let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData)
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                compileError = "Failed to load PAC: HTTP \(http.statusCode)"
                return
            }
            guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
                compileError = "Could not decode PAC file content."
                return
            }
            sourceLabel = url.absoluteString
            setSourceProgrammatically(text)
            currentPACURL = url
            compile()
            let stamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
            urlLoadNote = "Last fetched at \(stamp)."
        } catch {
            compileError = "Failed to fetch PAC: \(error.localizedDescription)"
        }
    }

    func setAutoRefresh(seconds: Int) {
        autoRefreshSeconds = seconds
        stopAutoRefresh()
        guard seconds > 0, currentPACURL != nil else { return }
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(seconds))
                if Task.isCancelled { break }
                guard let self, let url = self.currentPACURL else { break }
                await self.fetchFromURL(url)
            }
        }
    }

    private func stopAutoRefresh() {
        refreshTask?.cancel()
        refreshTask = nil
    }

    // MARK: - Testing

    func testOne() {
        guard let engine, !singleInput.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        let input = singleInput
        Task {
            await applySettings()
            let result = await engine.evaluate(input)
            results.append(result)
            highlightedLine = result.matchedLine
        }
    }

    func runBatch() {
        guard let engine else { return }
        let lines = batchInputText
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return }

        clearResults()
        isRunningBatch = true
        Task {
            await applySettings()
            let batchResults = await engine.evaluateBatch(lines)
            results = batchResults
            highlightedLine = batchResults.last?.matchedLine
            isRunningBatch = false
        }
    }

    func clearResults() {
        results = []
        highlightedLine = nil
    }

    func copyAllSuggestedRules() {
        var seen = Set<String>()
        let lines = results.compactMap(\.suggestedRule).filter { seen.insert($0).inserted }
        copyToPasteboard(lines.joined(separator: "\n"))
    }

    func copyResultsAsCSV() {
        func csv(_ s: String) -> String { "\"\(s.replacingOccurrences(of: "\"", with: "\"\""))\"" }
        let header = "Input,Host,Result,Matched Line,Type"
        let rows = results.map { result -> String in
            let type = result.error != nil ? "Error" : (result.isFallback ? "Fallback" : "Explicit")
            let line = result.matchedLine.map { "L\($0)" } ?? "—"
            let value = result.error ?? result.value ?? "(undefined)"
            return [csv(result.rawInput), csv(result.host), csv(value), csv(line), csv(type)].joined(separator: ",")
        }
        copyToPasteboard(([header] + rows).joined(separator: "\n"))
    }

    private func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

struct PACTesterView: View {
    @Bindable var model: PACTesterModel
    let savedPACURLs: [SavedPACURL]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                sectionHeader(
                    "PAC Tester",
                    subtitle: "Load a PAC file and test real hosts/URLs against its actual FindProxyForURL logic — works with no HAR loaded."
                )

                sourceCard

                if let compileError = model.compileError {
                    cardShell(tone: .red) {
                        Label(compileError, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }

                if model.engine != nil {
                    testSettingsCard
                    singleTestCard
                    batchTestCard
                    if !model.results.isEmpty {
                        resultsCard
                    }
                    sourceViewCard
                }
            }
            .padding(28)
        }
        .scrollIndicators(.visible)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var sourceCard: some View {
        cardShell(tone: .blue) {
            VStack(alignment: .leading, spacing: 14) {
                sectionHeader("1. Load PAC", subtitle: model.sourceLabel ?? "No PAC loaded yet")

                HStack {
                    Button("Choose File…") { model.loadFile() }
                    if model.isBusy { ProgressView().controlSize(.small) }
                    Spacer()
                }

                HStack {
                    TextField("https://proxy.corp.com/proxy.pac", text: $model.pacURLString)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { model.loadFromURL() }
                    Button("Load from URL") { model.loadFromURL() }
                }

                HStack(spacing: 14) {
                    Button("Refresh Now") { model.refreshNow() }
                        .disabled(model.currentPACURL == nil)

                    Picker("Auto-refresh", selection: Binding(
                        get: { model.autoRefreshSeconds },
                        set: { model.setAutoRefresh(seconds: $0) }
                    )) {
                        Text("Off").tag(0)
                        Text("Every 30s").tag(30)
                        Text("Every 1 min").tag(60)
                        Text("Every 5 min").tag(300)
                        Text("Every 15 min").tag(900)
                    }
                    .frame(width: 260)
                    .disabled(model.currentPACURL == nil)

                    if let note = model.urlLoadNote {
                        Text(note).font(.caption).foregroundStyle(.secondary)
                    }
                }

                if !savedPACURLs.isEmpty {
                    Divider()
                    Text("Saved PAC URLs").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(savedPACURLs) { saved in
                        HStack {
                            Text(saved.name).font(.subheadline)
                            Text(saved.urlString).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            Spacer()
                            Button("Load") { model.loadFromSavedURL(saved) }
                                .controlSize(.small)
                        }
                    }
                }

                Divider()
                Text("Or paste/edit PAC content directly:").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $model.sourceText)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 140, maxHeight: 220)
                    .background(Color.black.opacity(0.2), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .onChange(of: model.sourceText) { _, _ in model.handleSourceTextChanged() }

                Button("Compile PAC") { model.compile() }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private var testSettingsCard: some View {
        cardShell(tone: .purple) {
            VStack(alignment: .leading, spacing: 14) {
                sectionHeader("2. Test settings", subtitle: "Optional overrides for the PAC's helper functions")

                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Default proxy for suggested rules").font(.caption).foregroundStyle(.secondary)
                        TextField("e.g. PROXY proxy.corp.com:8080", text: $model.defaultProxyText)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { model.applySettingsNow() }
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Simulate client IP for myIpAddress()").font(.caption).foregroundStyle(.secondary)
                        TextField("e.g. 10.1.2.3 (blank = this machine's IP)", text: $model.clientIPOverride)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { model.applySettingsNow() }
                    }
                }

                HStack(spacing: 12) {
                    Toggle("Simulate date/time for weekdayRange/dateRange/timeRange", isOn: $model.useNowOverride)
                    if model.useNowOverride {
                        DatePicker("", selection: $model.nowOverride)
                            .labelsHidden()
                    }
                }
                .onChange(of: model.useNowOverride) { _, _ in model.applySettingsNow() }
                .onChange(of: model.nowOverride) { _, _ in model.applySettingsNow() }

                Text("isInNet/dnsResolve/isResolvable/myIpAddress use this machine's own DNS resolver and network interface — not a public DNS-over-HTTPS service — so results reflect any VPN/internal DNS zones this machine can see.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var singleTestCard: some View {
        cardShell(tone: .green) {
            VStack(alignment: .leading, spacing: 10) {
                sectionHeader("3. Test one", subtitle: "example.com or https://example.com/path")
                HStack {
                    TextField("Host or URL", text: $model.singleInput)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { model.testOne() }
                    Button("Test") { model.testOne() }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.singleInput.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private var batchTestCard: some View {
        cardShell(tone: .orange) {
            VStack(alignment: .leading, spacing: 10) {
                sectionHeader("4. Batch test", subtitle: "One domain or URL per line")
                TextEditor(text: $model.batchInputText)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 100, maxHeight: 160)
                    .background(Color.black.opacity(0.2), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                HStack {
                    Button("Run Batch") { model.runBatch() }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.isRunningBatch || model.batchInputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("Clear Results") { model.clearResults() }
                    if model.isRunningBatch { ProgressView().controlSize(.small) }
                }
            }
        }
    }

    private var resultsCard: some View {
        let suggestions = Array(Set(model.results.compactMap(\.suggestedRule))).sorted()
        return cardShell(tone: .teal) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    sectionHeader("Results", subtitle: "\(model.results.count) test\(model.results.count == 1 ? "" : "s") run")
                    Spacer()
                    Button("Copy Suggested Rules") { model.copyAllSuggestedRules() }
                        .disabled(suggestions.isEmpty)
                    Button("Copy as CSV") { model.copyResultsAsCSV() }
                }

                VStack(alignment: .leading, spacing: 8) {
                    ForEach(model.results.reversed()) { result in
                        resultRow(result)
                        Divider()
                    }
                }

                if !suggestions.isEmpty {
                    Text("All suggested rules").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ruleScrollList(lines: suggestions)
                }
            }
        }
    }

    private func resultRow(_ result: PACTestResult) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(result.rawInput)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                    Text(result.host)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Text(result.error ?? result.value ?? "(undefined)")
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: 260, alignment: .leading)
                Text(result.matchedLine.map { "L\($0)" } ?? "—")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                resultPill(result)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                if let line = result.matchedLine { model.highlightedLine = line }
            }

            if let suggestion = result.suggestedRule {
                Text(suggestion)
                    .font(.system(.caption, design: .monospaced))
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
        }
        .padding(.vertical, 4)
    }

    private func resultPill(_ result: PACTestResult) -> some View {
        let (label, color): (String, Color) = result.error != nil
            ? ("Error", .red)
            : result.isFallback ? ("Fallback", .yellow) : ("Explicit", .green)
        return Text(label)
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.22), in: Capsule())
            .foregroundStyle(color)
    }

    private var sourceViewCard: some View {
        let defaultLineNote = model.engine?.defaultLine.map { ", assumed fallback at line \($0)" } ?? ""
        return cardShell(tone: .gray) {
            VStack(alignment: .leading, spacing: 10) {
                sectionHeader("PAC source", subtitle: "\(model.lineCount) lines\(defaultLineNote)")
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(model.sourceLines.enumerated()), id: \.offset) { index, line in
                                let lineNumber = index + 1
                                HStack(alignment: .top, spacing: 12) {
                                    Text("\(lineNumber)")
                                        .font(.system(.caption, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                        .frame(width: 36, alignment: .trailing)
                                    Text(line.isEmpty ? " " : line)
                                        .font(.system(.caption, design: .monospaced))
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(model.highlightedLine == lineNumber ? Color.accentColor.opacity(0.35) : Color.clear)
                                .id(lineNumber)
                            }
                        }
                    }
                    .frame(maxHeight: 320)
                    .background(Color.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .onChange(of: model.highlightedLine) { _, newValue in
                        guard let newValue else { return }
                        withAnimation { proxy.scrollTo(newValue, anchor: .center) }
                    }
                }
            }
        }
    }
}
