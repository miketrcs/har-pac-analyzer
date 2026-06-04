import AppKit
import RCSPACFileParser
import SwiftUI
import UniformTypeIdentifiers

struct SavedPACURL: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var urlString: String
}

@main
struct PACInspectorApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup("HAR & PAC Analyzer") {
            ContentView(model: model)
                .frame(minWidth: 940, minHeight: 680)
        }
        .defaultSize(width: 1340, height: 860)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("File") {
                Button("Open HAR…") { model.chooseHAR() }
                    .keyboardShortcut("o", modifiers: .command)
                Button("Open PAC File…") { model.choosePAC() }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                Divider()
                Button("Reload Analysis") { model.reload() }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(model.harURL == nil)
                Divider()
                Button("Export Report…") { model.exportReport() }
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(model.report == nil)
            }
            CommandGroup(replacing: .appInfo) {
                Button("About HAR & PAC Analyzer") {
                    NSApp.orderFrontStandardAboutPanel(options: [
                        .applicationName: "HAR & PAC Analyzer" as NSString,
                        .applicationVersion: "1.0" as NSString,
                        .credits: NSAttributedString(
                            string: "Network & Technology Services\nRutherford County Schools",
                            attributes: [.font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)]
                        ),
                        NSApplication.AboutPanelOptionKey(rawValue: "Copyright"): "© 2026 Rutherford County Schools" as NSString
                    ])
                }
            }
        }
    }
}

@MainActor
@Observable
final class AppModel {
    var harURL: URL?
    var pacURL: URL?
    var fetchedPACText: String?
    var pacSourceLabel: String?
    var report: AnalysisReport?
    var pacAnalysis: PACAnalysis?
    var errorMessage: String?
    var isLoading = false
    var selectedSection: DashboardSection = .overview
    var searchText = ""
    var selectedDomain: String?
    var selectedRequestURL: String?
    var savedPACURLs: [SavedPACURL] = []

    var hasPAC: Bool { pacURL != nil || fetchedPACText != nil }

    init() {
        if let data = UserDefaults.standard.data(forKey: "savedPACURLs"),
           let urls = try? JSONDecoder().decode([SavedPACURL].self, from: data) {
            savedPACURLs = urls
        }
    }

    func chooseHAR() {
        guard let url = pickFile(allowedContentTypes: ["har", "json"]) else { return }
        harURL = url
        reload()
    }

    func choosePAC() {
        guard let url = pickFile(allowedContentTypes: ["pac", "js", "txt"]) else { return }
        pacURL = url
        fetchedPACText = nil
        pacSourceLabel = url.lastPathComponent
        reload()
    }

    func clearPAC() {
        pacURL = nil
        fetchedPACText = nil
        pacSourceLabel = nil
        pacAnalysis = nil
        reload()
    }

    func loadPACFromURL(_ saved: SavedPACURL) {
        guard let url = URL(string: saved.urlString) else {
            errorMessage = "Invalid URL: \(saved.urlString)"
            return
        }
        pacURL = nil
        isLoading = true
        errorMessage = nil

        Task {
            do {
                let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData)
                let (data, response) = try await URLSession.shared.data(for: request)
                if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                    errorMessage = "Failed to load PAC: HTTP \(http.statusCode)"
                    isLoading = false
                    return
                }
                guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
                    errorMessage = "Could not decode PAC file content"
                    isLoading = false
                    return
                }
                fetchedPACText = text
                pacSourceLabel = saved.name
                reload()
            } catch {
                fetchedPACText = nil
                pacSourceLabel = nil
                errorMessage = "Failed to fetch PAC: \(error.localizedDescription)"
                isLoading = false
            }
        }
    }

    func addSavedPACURL(name: String, urlString: String) {
        savedPACURLs.append(SavedPACURL(id: UUID(), name: name, urlString: urlString))
        persistSavedURLs()
    }

    func deleteSavedPACURL(id: UUID) {
        savedPACURLs.removeAll { $0.id == id }
        persistSavedURLs()
    }

    func reload() {
        guard let harURL else {
            report = nil
            isLoading = false
            return
        }

        isLoading = true
        errorMessage = nil

        let capturedHARURL = harURL
        let capturedPACURL = pacURL
        let capturedFetchedPACText = fetchedPACText

        Task {
            do {
                let (newReport, firstDomain, newPAC) = try await Task.detached(priority: .userInitiated) {
                    let archive = try HARLoader.load(from: capturedHARURL)
                    let pac: PACAnalysis?
                    if let text = capturedFetchedPACText {
                        pac = PACParser.parse(text: text)
                    } else {
                        pac = try capturedPACURL.map { try PACParser.parse(fileURL: $0) }
                    }
                    let report = HARAnalyzer.analyze(archive: archive, pac: pac)
                    return (report, report.requiredBypassDomains.first, pac)
                }.value
                report = newReport
                pacAnalysis = newPAC
                selectedDomain = firstDomain
                selectedRequestURL = nil
            } catch {
                report = nil
                pacAnalysis = nil
                errorMessage = error.localizedDescription
                selectedDomain = nil
                selectedRequestURL = nil
            }
            isLoading = false
        }
    }

    func copyPACSnippet() {
        guard let report else { return }
        copy(text: report.pacReadyDomains.joined(separator: "\n"))
    }

    func copyRequiredDomains() {
        guard let report else { return }
        copy(text: report.requiredBypassDomains.joined(separator: "\n"))
    }

    func copyOptionalDomains() {
        guard let report else { return }
        copy(text: report.optionalDomains.joined(separator: "\n"))
    }

    func exportReport() {
        guard let report else { return }
        let panel = NSSavePanel()
        panel.title = "Export Analysis Report"
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = "\(harURL?.deletingPathExtension().lastPathComponent ?? "HAR") Analysis"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try buildMarkdownReport(report: report).write(to: url, atomically: true, encoding: .utf8)
        } catch {
            errorMessage = "Export failed: \(error.localizedDescription)"
        }
    }

    private func buildMarkdownReport(report: AnalysisReport) -> String {
        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .short
        var md = """
        # HAR & PAC Analyzer Report

        **Generated:** \(df.string(from: Date()))
        **HAR File:** \(harURL?.lastPathComponent ?? "Unknown")
        \(pacSourceLabel.map { "**PAC Source:** \($0)" } ?? "")

        ## Summary

        | Metric | Value |
        |--------|-------|
        | Total Requests | \(report.totalRequests) |
        | Unique Hosts | \(report.uniqueHosts.count) |
        | Required Bypass Domains | \(report.requiredBypassDomains.count) |
        | Optional Domains | \(report.optionalDomains.count) |
        | Findings | \(report.blockedCandidates.count) |
        """
        if hasPAC && !report.registrableDomains.isEmpty {
            let covered = report.registrableDomains.count - report.unmatchedDomains.count
            let pct = Int(Double(covered) / Double(report.registrableDomains.count) * 100)
            md += "\n| PAC Coverage | \(pct)% (\(covered)/\(report.registrableDomains.count) domains) |"
        }
        if !report.requiredBypassDomains.isEmpty {
            md += "\n\n## Required Bypass Domains\n\n"
            md += report.requiredBypassDomains.map { "- `\($0)`" }.joined(separator: "\n")
            md += "\n\n### PAC Snippet\n\n```javascript\n"
            md += report.requiredBypassDomains.map { "    dnsDomainIs(host, \".\($0)\") ||" }.joined(separator: "\n")
            md += "\n```"
        }
        if hasPAC && !report.unmatchedDomains.isEmpty {
            md += "\n\n## PAC Gaps (Unmatched Domains)\n\n"
            md += report.unmatchedDomains.map { "- `\($0)`" }.joined(separator: "\n")
        }
        if !report.blockedCandidates.isEmpty {
            md += "\n\n## Findings\n"
            for f in report.blockedCandidates {
                md += "\n### `\(f.url)`\n\n"
                md += "- **Status:** HTTP \(f.status)\n"
                if let cat = f.classification?.category.rawValue { md += "- **Category:** \(cat)\n" }
                md += f.pacMatch != nil ? "- **PAC Match:** `\(f.pacMatch!.pattern)`\n" : "- **PAC Match:** No match\n"
                for issue in f.suspectedIssues { md += "- \(issue)\n" }
            }
        }
        if !report.optionalDomains.isEmpty {
            md += "\n\n## Optional Domains\n\n"
            md += report.optionalDomains.map { "- `\($0)`" }.joined(separator: "\n")
        }
        md += "\n\n---\n*Generated by HAR & PAC Analyzer — Rutherford County Schools*\n"
        return md
    }

    func selectDomain(_ rawValue: String) {
        guard let report else { return }
        guard let normalized = normalizeSelection(rawValue) else { return }

        let allDomains = Set(
            report.registrableDomains
                + report.requiredBypassDomains
                + report.optionalDomains
                + report.requests.compactMap(\.registrableDomain)
        )

        if allDomains.contains(normalized) {
            selectedDomain = normalized
            selectedRequestURL = report.requests.first(where: { $0.registrableDomain == normalized })?.url
            selectedSection = .findings
        }
    }

    func selectRequest(_ url: String) {
        selectedRequestURL = url
    }

    private func copy(text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func persistSavedURLs() {
        if let data = try? JSONEncoder().encode(savedPACURLs) {
            UserDefaults.standard.set(data, forKey: "savedPACURLs")
        }
    }

    private func normalizeSelection(_ rawValue: String) -> String? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let extracted = trimmed.firstMatch(for: #""([^"]+)""#) {
            return extracted.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
        }

        if let host = URLComponents(string: trimmed)?.host?.lowercased() {
            return NormalizedURL(rawURL: "https://\(host)").registrableCandidate ?? host
        }

        let cleaned = trimmed
            .replacingOccurrences(of: "dnsDomainIs(host,", with: "")
            .replacingOccurrences(of: ")", with: "")
            .replacingOccurrences(of: "||", with: "")
            .replacingOccurrences(of: "\"", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: ". "))
            .lowercased()

        guard !cleaned.isEmpty else { return nil }
        return NormalizedURL(rawURL: "https://\(cleaned)").registrableCandidate ?? cleaned
    }

    func handleDrop(providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                guard let data = item as? Data,
                      let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                let ext = url.pathExtension.lowercased()
                Task { @MainActor in
                    if ["har", "json"].contains(ext) {
                        self.harURL = url
                        self.reload()
                    } else if ["pac", "js", "txt"].contains(ext) {
                        self.pacURL = url
                        self.fetchedPACText = nil
                        self.pacSourceLabel = url.lastPathComponent
                        self.reload()
                    }
                }
            }
        }
        return true
    }

    private func pickFile(allowedContentTypes: [String]) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = allowedContentTypes.compactMap { UTType(filenameExtension: $0) }
        return panel.runModal() == .OK ? panel.url : nil
    }
}

enum DashboardSection: String, CaseIterable, Identifiable {
    case overview = "Overview"
    case bypasses = "Bypasses"
    case categories = "Categories"
    case resources = "Resources"
    case findings = "Findings"
    case statistics = "Statistics"
    case pacExport = "PAC Export"
    case pacRules = "PAC Rules"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .overview: return "square.grid.2x2"
        case .bypasses: return "arrow.triangle.branch"
        case .categories: return "square.stack.3d.up"
        case .resources: return "shippingbox"
        case .findings: return "exclamationmark.magnifyingglass"
        case .statistics: return "chart.bar.xaxis"
        case .pacExport: return "doc.plaintext"
        case .pacRules: return "list.bullet.rectangle.portrait"
        }
    }
}

struct ContentView: View {
    let model: AppModel
    @State private var isDropTargeted = false
    @State private var showAddPACURL = false
    @State private var pacRulesSearch = ""

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            HSplitView {
                detail
                inspectorPanel
                    .frame(minWidth: 260, idealWidth: 320, maxWidth: 360)
            }
                .background(appBackground)
        }
        .toolbar(removing: .sidebarToggle)
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            model.handleDrop(providers: providers)
        }
        .sheet(isPresented: $showAddPACURL) {
            AddPACURLSheet { name, urlString in
                model.addSavedPACURL(name: name, urlString: urlString)
            }
        }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
                    .background(Color.accentColor.opacity(0.08).ignoresSafeArea())
                    .overlay {
                        VStack(spacing: 12) {
                            Image(systemName: "arrow.down.doc")
                                .font(.system(size: 44))
                                .foregroundStyle(Color.accentColor)
                            Text("Drop HAR or PAC file")
                                .font(.title2.weight(.semibold))
                        }
                    }
                    .allowsHitTesting(false)
            }
        }
    }

    private var sidebar: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    Text("HAR & PAC Analyzer")
                        .font(.title2.weight(.bold))
                    Text("Analyze HAR exports and PAC files for required bypasses, telemetry, CDN traffic, and breakage signals.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 6)
            }

            Section("Inputs") {
                fileButton(title: "HAR File", subtitle: model.harURL?.lastPathComponent ?? "Choose HAR export", symbol: "doc.badge.plus", action: model.chooseHAR)
            }

            Section("PAC File") {
                ForEach(model.savedPACURLs) { saved in
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(saved.name)
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(1)
                            Text(saved.urlString)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer(minLength: 4)
                        Button("Load") { model.loadPACFromURL(saved) }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                        Button(role: .destructive) {
                            model.deleteSavedPACURL(id: saved.id)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.vertical, 2)
                }

                Button {
                    showAddPACURL = true
                } label: {
                    Label("Add Hosted PAC URL", systemImage: "plus.circle")
                }

                fileButton(title: "Load from File", subtitle: "Open a .pac, .js, or .txt file", symbol: "folder.badge.plus", action: model.choosePAC)

                if let label = model.pacSourceLabel {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.shield.fill")
                            .foregroundStyle(.green)
                        Text(label)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Button("Clear", action: model.clearPAC)
                            .font(.caption)
                            .buttonStyle(.plain)
                            .foregroundStyle(.red)
                    }
                }
            }

            Section("Quick Actions") {
                Button("Reload Analysis", action: model.reload)
                    .disabled(model.harURL == nil)
                Button("Copy PAC Snippet", action: model.copyPACSnippet)
                    .disabled(model.report == nil)
                Button("Copy Required Domains", action: model.copyRequiredDomains)
                    .disabled(model.report?.requiredBypassDomains.isEmpty != false)
                Button("Copy Optional Domains", action: model.copyOptionalDomains)
                    .disabled(model.report?.optionalDomains.isEmpty != false)
                Button("Export Report…", action: model.exportReport)
                    .disabled(model.report == nil)
            }

            Section("Sections") {
                ForEach(DashboardSection.allCases) { section in
                    Button {
                        model.selectedSection = section
                    } label: {
                        Label(section.rawValue, systemImage: section.symbol)
                            .foregroundStyle(model.selectedSection == section ? .primary : .secondary)
                    }
                    .buttonStyle(.plain)
                }
            }

            Section("Status") {
                statusView
            }
        }
        .navigationTitle("Analyzer")
        .listStyle(.sidebar)
    }

    @ViewBuilder
    private var detail: some View {
        if model.isLoading && model.report == nil {
            VStack(spacing: 16) {
                ProgressView()
                    .scaleEffect(2)
                Text("Analyzing…")
                    .font(.title3.weight(.semibold))
                if let name = model.harURL?.lastPathComponent {
                    Text(name)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let report = model.report {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    hero(report: report)
                    sectionPicker
                    sectionContent(report: report)
                }
                .padding(28)
            }
            .scrollIndicators(.visible)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .navigationTitle(model.harURL?.lastPathComponent ?? "Analysis")
            .overlay {
                if model.isLoading {
                    Color.black.opacity(0.35)
                        .ignoresSafeArea()
                        .overlay {
                            VStack(spacing: 14) {
                                ProgressView()
                                    .scaleEffect(1.4)
                                Text("Reanalyzing…")
                                    .font(.subheadline.weight(.semibold))
                            }
                            .padding(24)
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        }
                }
            }
        } else {
            emptyState
        }
    }

    @ViewBuilder
    private var inspectorPanel: some View {
        if let report = model.report {
            ScrollView {
                InspectorPane(report: report, selectedDomain: model.selectedDomain, model: model)
                    .padding(.vertical, 18)
                    .padding(.trailing, 18)
                    .padding(.leading, 4)
            }
            .scrollIndicators(.visible)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            Color.clear.frame(minWidth: 260)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 22) {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color.blue.opacity(0.18), Color.teal.opacity(0.16), Color.orange.opacity(0.14)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay {
                    VStack(spacing: 16) {
                        Image(systemName: "network.badge.shield.half.filled")
                            .font(.system(size: 54))
                            .foregroundStyle(.blue)
                        Text("Load A HAR To Start")
                            .font(.system(size: 30, weight: .bold, design: .rounded))
                        Text("Open a HAR export and optionally a PAC file to see likely required domains, optional telemetry and ads, PAC gaps, and copy-ready bypass snippets.")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 720)

                        HStack(spacing: 12) {
                            Button("Choose HAR", action: model.chooseHAR)
                                .buttonStyle(.borderedProminent)
                            Button("Choose PAC", action: model.choosePAC)
                                .buttonStyle(.bordered)
                        }
                    }
                    .padding(40)
                }
                .frame(maxWidth: 980, minHeight: 420)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }

    private func hero(report: AnalysisReport) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Troubleshooting Snapshot")
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                    Text(heroSubtitle(report: report))
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if model.isLoading {
                    ProgressView()
                }
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 16)], spacing: 16) {
                metricCard(title: "Requests", value: "\(report.totalRequests)", tone: .blue)
                metricCard(title: "Hosts", value: "\(report.uniqueHosts.count)", tone: .indigo)
                metricCard(title: "Required", value: "\(report.requiredBypassDomains.count)", tone: .green)
                metricCard(title: "Optional", value: "\(report.optionalDomains.count)", tone: .orange)
                metricCard(title: "Findings", value: "\(report.blockedCandidates.count)", tone: .red)
                if model.hasPAC && !report.registrableDomains.isEmpty {
                    let total = report.registrableDomains.count
                    let pct = Int(Double(total - report.unmatchedDomains.count) / Double(total) * 100)
                    metricCard(title: "PAC Coverage", value: "\(pct)%",
                               tone: pct >= 80 ? .teal : pct >= 50 ? .yellow : .orange)
                }
            }
        }
        .padding(24)
        .background(
            LinearGradient(
                colors: [Color.blue.opacity(0.18), Color.teal.opacity(0.10), Color.white.opacity(0.02)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 28, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08))
        )
    }

    private var sectionPicker: some View {
        VStack(alignment: .leading, spacing: 12) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(DashboardSection.allCases) { section in
                        Button {
                            model.selectedSection = section
                        } label: {
                            Label(section.rawValue, systemImage: section.symbol)
                                .font(.subheadline.weight(.semibold))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 10)
                                .background(
                                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .fill(model.selectedSection == section ? Color.accentColor.opacity(0.18) : Color.white.opacity(0.04))
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Filter domains or findings", text: Bindable(model).searchText)
                    .textFieldStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color.white.opacity(0.05), in: Capsule())
        }
    }

    @ViewBuilder
    private func sectionContent(report: AnalysisReport) -> some View {
        switch model.selectedSection {
        case .overview:
            overviewSection(report: report)
        case .bypasses:
            bypassSection(report: report)
        case .categories:
            categoriesSection(report: report)
        case .resources:
            resourcesSection(report: report)
        case .findings:
            findingsSection(report: report)
        case .statistics:
            statisticsSection(report: report)
        case .pacExport:
            pacExportSection(report: report)
        case .pacRules:
            pacRulesSection(report: report)
        }
    }

    private func overviewSection(report: AnalysisReport) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            threeUpCards(
                appTrafficCard(report: report),
                pacCoverageCard(report: report),
                signalsCard(report: report)
            )
            categoriesSection(report: report, limit: 4)
        }
    }

    private func bypassSection(report: AnalysisReport) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            threeUpCards(
                domainCard(
                    title: "Likely Required",
                    subtitle: "Best candidates for PAC allow rules based on the capture.",
                    items: filter(report.requiredBypassDomains),
                    tone: .green,
                    action: model.selectDomain
                ),
                domainCard(
                    title: "Likely Optional",
                    subtitle: "Telemetry, ads, analytics, or support traffic to review carefully.",
                    items: filter(report.optionalDomains),
                    tone: .orange,
                    action: model.selectDomain
                ),
                domainCard(
                    title: "PAC Snippet",
                    subtitle: "Copy/paste-ready `dnsDomainIs` lines from the HAR.",
                    items: filter(report.pacReadyDomains),
                    tone: .blue,
                    action: model.selectDomain
                )
            )
        }
    }

    private func categoriesSection(report: AnalysisReport, limit: Int? = nil) -> some View {
        let summaries = filter(report.categorySummaries, limit: limit)

        return VStack(alignment: .leading, spacing: 16) {
            sectionHeader("Traffic Categories", subtitle: "How the analyzer currently interprets each host set.")

            ForEach(Array(summaries.enumerated()), id: \.offset) { _, summary in
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text(summary.category.rawValue)
                            .font(.headline)
                        Spacer()
                        Text(summary.criticality.rawValue)
                            .font(.caption.weight(.bold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(categoryTone(for: summary.criticality).opacity(0.16), in: Capsule())
                    }

                    Text(summary.hosts.joined(separator: "\n"))
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)

                    FlowHostButtons(hosts: summary.hosts, action: model.selectDomain)
                }
                .padding(18)
                .background(categoryTone(for: summary.criticality).opacity(0.10), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
        }
    }

    private func resourcesSection(report: AnalysisReport) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            sectionHeader("Resources", subtitle: "Useful assets to inspect when a page is partially broken.")

            twoUpCards(
                domainCard(
                    title: "JavaScript URLs",
                    subtitle: "Scripts from the capture. Helpful for spotting blocked app bundles.",
                    items: filter(report.javaScriptURLs),
                    tone: .purple,
                    action: model.selectDomain
                ),
                domainCard(
                    title: "Stylesheet URLs",
                    subtitle: "CSS assets from the capture. Useful when layout looks incomplete.",
                    items: filter(report.stylesheetURLs),
                    tone: .teal,
                    action: model.selectDomain
                )
            )
        }
    }

    private func findingsSection(report: AnalysisReport) -> some View {
        let findings = filter(report.blockedCandidates)

        return VStack(alignment: .leading, spacing: 16) {
            sectionHeader("Findings", subtitle: "Signals that may point to PAC gaps, proxy issues, or partial breakage.")

            if !report.zscalerSignals.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(filter(report.zscalerSignals), id: \.self) { signal in
                        Label(signal, systemImage: "exclamationmark.triangle.fill")
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.orange.opacity(0.14), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                }
            }

            let nonStandardPorts = report.portSummaries.filter { !$0.isStandard }
            if !nonStandardPorts.isEmpty {
                let portList = nonStandardPorts.map { "\($0.scheme.uppercased()):\($0.port) (\($0.requestCount) req)" }.joined(separator: ", ")
                Label("Alternate ports detected: \(portList). Traffic on non-standard ports may not be intercepted by proxy policies.", systemImage: "network.badge.shield.half.filled")
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.purple.opacity(0.14), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }

            if findings.isEmpty {
                cardShell(tone: .green) {
                    Text("No findings match the current filter.")
                        .foregroundStyle(.secondary)
                }
            } else {
                ForEach(Array(findings.enumerated()), id: \.offset) { _, item in
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .firstTextBaseline) {
                            Text("HTTP \(httpStatusLabel(item.status))")
                                .font(.headline)
                                .foregroundStyle(httpStatusColor(item.status))
                            Spacer()
                            if let category = item.classification?.category.rawValue {
                                Text(category)
                                    .font(.caption.weight(.bold))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(Color.white.opacity(0.08), in: Capsule())
                            }
                        }

                    Button {
                        model.selectDomain(item.url)
                    } label: {
                        Text(item.url)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .lineLimit(5)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .buttonStyle(.plain)

                        if let pacMatch = item.pacMatch?.pattern {
                            Text("PAC match: \(pacMatch)")
                                .foregroundStyle(.secondary)
                        } else {
                            Text("PAC match: no match")
                                .foregroundStyle(.secondary)
                        }

                        ForEach(item.suspectedIssues, id: \.self) { issue in
                            Text(issue)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(18)
                    .background(Color.red.opacity(0.10), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
            }
        }
    }

    private func appTrafficCard(report: AnalysisReport) -> some View {
        infoCard(
            title: "App Traffic",
            subtitle: "The domains most likely needed for the site to render and function.",
            items: filter(report.requiredBypassDomains).prefix(6).map { $0 },
            tone: .green
        )
    }

    private func pacCoverageCard(report: AnalysisReport) -> some View {
        infoCard(
            title: "PAC Coverage",
            subtitle: "Domains missing from the current PAC comparison.",
            items: filter(report.unmatchedDomains).prefix(6).map { $0 },
            tone: .orange
        )
    }

    private func signalsCard(report: AnalysisReport) -> some View {
        infoCard(
            title: "Signals",
            subtitle: "High-level warnings surfaced from the HAR.",
            items: filter(report.zscalerSignals).prefix(6).map { $0 },
            tone: .red
        )
    }

    private func infoCard(title: String, subtitle: String, items: [String], tone: Color) -> some View {
        cardShell(tone: tone) {
            VStack(alignment: .leading, spacing: 10) {
                Text(title)
                    .font(.headline)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if items.isEmpty {
                    Text("No items")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(items, id: \.self) { item in
                        Text(item)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                            .lineLimit(4)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private func domainCard(title: String, subtitle: String, items: [String], tone: Color, action: @escaping (String) -> Void) -> some View {
        cardShell(tone: tone) {
            VStack(alignment: .leading, spacing: 10) {
                Text(title)
                    .font(.headline)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        if items.isEmpty {
                            Text("No items")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(items, id: \.self) { item in
                                Button {
                                    action(item)
                                } label: {
                                    Text(item)
                                        .font(.system(.body, design: .monospaced))
                                        .textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .lineLimit(5)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .frame(minHeight: 220)
            }
        }
    }

    private func metricCard(title: String, value: String, tone: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            Text(value)
                .font(.system(size: 30, weight: .bold, design: .rounded))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(tone.opacity(0.14), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func cardShell<Content: View>(tone: Color, @ViewBuilder content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
            .background(tone.opacity(0.10), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private func sectionHeader(_ title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.title2.weight(.bold))
            Text(subtitle)
                .foregroundStyle(.secondary)
        }
    }

    private func twoUpCards<Left: View, Right: View>(_ left: Left, _ right: Right) -> some View {
        ViewThatFits {
            HStack(alignment: .top, spacing: 18) {
                left.frame(maxWidth: .infinity)
                right.frame(maxWidth: .infinity)
            }

            VStack(alignment: .leading, spacing: 18) {
                left
                right
            }
        }
    }

    private func threeUpCards<First: View, Second: View, Third: View>(_ first: First, _ second: Second, _ third: Third) -> some View {
        ViewThatFits {
            HStack(alignment: .top, spacing: 18) {
                first.frame(maxWidth: .infinity)
                second.frame(maxWidth: .infinity)
                third.frame(maxWidth: .infinity)
            }

            VStack(alignment: .leading, spacing: 18) {
                first
                second
                third
            }
        }
    }

    private var statusView: some View {
        Group {
            if model.isLoading {
                Label("Analyzing...", systemImage: "hourglass")
            } else if let errorMessage = model.errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
            } else if model.report != nil {
                Label("Report ready", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Label("Choose a HAR to begin", systemImage: "doc")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func fileButton(title: String, subtitle: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: symbol)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.headline)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
    }

    private func filter(_ items: [String]) -> [String] {
        guard !model.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return items }
        let query = model.searchText.lowercased()
        return items.filter { $0.lowercased().contains(query) }
    }

    private func filter(_ items: [CategorySummary], limit: Int? = nil) -> [CategorySummary] {
        let filtered = items.compactMap { summary -> CategorySummary? in
            let matchesQuery = model.searchText.isEmpty
                || summary.category.rawValue.lowercased().contains(model.searchText.lowercased())
                || summary.hosts.contains(where: { $0.lowercased().contains(model.searchText.lowercased()) })
            return matchesQuery ? summary : nil
        }

        if let limit {
            return Array(filtered.prefix(limit))
        }
        return filtered
    }

    private func filter(_ items: [RequestDiagnostic]) -> [RequestDiagnostic] {
        guard !model.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return items }
        let query = model.searchText.lowercased()
        return items.filter { item in
            item.url.lowercased().contains(query)
                || item.suspectedIssues.contains(where: { $0.lowercased().contains(query) })
                || item.classification?.category.rawValue.lowercased().contains(query) == true
        }
    }

    private func heroSubtitle(report: AnalysisReport) -> String {
        let required = report.requiredBypassDomains.count
        let optional = report.optionalDomains.count
        let findings = report.blockedCandidates.count
        return "\(required) likely required domains, \(optional) likely optional domains, \(findings) notable finding\(findings == 1 ? "" : "s")."
    }

    private func categoryTone(for criticality: AccessCriticality) -> Color {
        switch criticality {
        case .required:
            return .green
        case .optional:
            return .orange
        case .unknown:
            return .yellow
        }
    }

    private func statisticsSection(report: AnalysisReport) -> some View {
        let allTimings = report.requests.compactMap(\.elapsedMS).filter { $0 >= 0 }
        let sorted = allTimings.sorted()
        let count = allTimings.count

        let avgElapsed = avg(allTimings)
        let minElapsed = sorted.first ?? 0
        let maxElapsed = sorted.last ?? 0
        let medianElapsed: Double = {
            guard !sorted.isEmpty else { return 0 }
            let mid = sorted.count / 2
            return sorted.count.isMultiple(of: 2) ? (sorted[mid - 1] + sorted[mid]) / 2.0 : sorted[mid]
        }()
        let p95Elapsed = sorted.isEmpty ? 0.0 : sorted[Int(Double(sorted.count - 1) * 0.95)]

        let under100 = allTimings.filter { $0 < 100 }.count
        let band100_500 = allTimings.filter { $0 >= 100 && $0 < 500 }.count
        let band500_1000 = allTimings.filter { $0 >= 500 && $0 < 1_000 }.count
        let over1000 = allTimings.filter { $0 >= 1_000 }.count

        let dnsVals = report.requests.compactMap(\.timings.dns).filter { $0 >= 0 }
        let connectVals = report.requests.compactMap(\.timings.connect).filter { $0 >= 0 }
        let sslVals = report.requests.compactMap(\.timings.ssl).filter { $0 >= 0 }
        let waitVals = report.requests.compactMap(\.timings.wait).filter { $0 >= 0 }
        let receiveVals = report.requests.compactMap(\.timings.receive).filter { $0 >= 0 }

        let dnsAvg = avg(dnsVals)
        let connectAvg = avg(connectVals)
        let sslAvg = avg(sslVals)
        let waitAvg = avg(waitVals)
        let receiveAvg = avg(receiveVals)
        let maxPhase = [dnsAvg, connectAvg, sslAvg, waitAvg, receiveAvg].max() ?? 1

        var statusCounts: [Int: Int] = [:]
        for req in report.requests { statusCounts[req.status, default: 0] += 1 }
        let sortedCodes = statusCounts.keys.sorted()

        let slowestArray = Array(
            report.requests
                .compactMap { req -> (url: String, status: Int, elapsed: Double)? in
                    guard let e = req.elapsedMS else { return nil }
                    return (url: req.url, status: req.status, elapsed: e)
                }
                .sorted { $0.elapsed > $1.elapsed }
                .prefix(10)
        )

        return VStack(alignment: .leading, spacing: 20) {
            sectionHeader("Statistics", subtitle: "Aggregate timing, status, and performance breakdowns across all \(report.totalRequests) requests.")

            cardShell(tone: .blue) {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Response Time")
                        .font(.headline)
                    if count == 0 {
                        Text("No timing data available in this HAR.")
                            .foregroundStyle(.secondary)
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 10)], spacing: 10) {
                            timingStatCell("Average", value: avgElapsed, tone: .blue)
                            timingStatCell("Median", value: medianElapsed, tone: .teal)
                            timingStatCell("P95", value: p95Elapsed, tone: .orange)
                            timingStatCell("Min", value: minElapsed, tone: .green)
                            timingStatCell("Max", value: maxElapsed, tone: .red)
                        }
                        Divider().overlay(Color.white.opacity(0.08))
                        Text("Distribution")
                            .font(.subheadline.weight(.semibold))
                        VStack(spacing: 8) {
                            TimingBar(label: "< 100 ms", count: under100, total: count, tone: .green)
                            TimingBar(label: "100–500 ms", count: band100_500, total: count, tone: .blue)
                            TimingBar(label: "500 ms–1 s", count: band500_1000, total: count, tone: .orange)
                            TimingBar(label: "> 1 s", count: over1000, total: count, tone: .red)
                        }
                    }
                }
            }

            cardShell(tone: .indigo) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Timing Phases (Average)")
                        .font(.headline)
                    Text("Averages across requests that reported each phase. HAR fields reporting −1 are excluded.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    VStack(spacing: 8) {
                        TimingPhaseRow(label: "DNS", value: dnsAvg, maxValue: maxPhase, tone: .purple, count: dnsVals.count)
                        TimingPhaseRow(label: "TCP Connect", value: connectAvg, maxValue: maxPhase, tone: .blue, count: connectVals.count)
                        TimingPhaseRow(label: "SSL / TLS", value: sslAvg, maxValue: maxPhase, tone: .teal, count: sslVals.count)
                        TimingPhaseRow(label: "TTFB (Wait)", value: waitAvg, maxValue: maxPhase, tone: .orange, count: waitVals.count)
                        TimingPhaseRow(label: "Download", value: receiveAvg, maxValue: maxPhase, tone: .green, count: receiveVals.count)
                    }
                }
            }

            twoUpCards(
                statusGroupCard(statusCounts: statusCounts, total: report.totalRequests),
                statusDetailCard(sortedCodes: sortedCodes, statusCounts: statusCounts)
            )

            portBreakdownCard(summaries: report.portSummaries, total: report.totalRequests)

            if !slowestArray.isEmpty {
                cardShell(tone: .red) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Slowest Requests (Top \(slowestArray.count))")
                            .font(.headline)
                        Text("Sorted by total elapsed time, highest first.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        ForEach(Array(slowestArray.enumerated()), id: \.offset) { _, item in
                            HStack(alignment: .top, spacing: 12) {
                                Text(String(format: "%.0f ms", item.elapsed))
                                    .font(.system(.body, design: .monospaced).weight(.semibold))
                                    .foregroundStyle(item.elapsed >= 3_000 ? .red : .orange)
                                    .frame(width: 80, alignment: .trailing)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(httpStatusLabel(item.status))
                                        .font(.caption.weight(.bold))
                                        .foregroundStyle(httpStatusColor(item.status))
                                    Text(item.url)
                                        .font(.system(.caption, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(3)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            .padding(10)
                            .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                    }
                }
            }
        }
    }

    private func timingStatCell(_ label: String, value: Double, tone: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
            Text(String(format: "%.0f ms", value))
                .font(.system(.title3, design: .rounded, weight: .bold))
                .foregroundStyle(tone)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tone.opacity(0.10), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func statusGroupCard(statusCounts: [Int: Int], total: Int) -> some View {
        let twoXX = statusCounts.filter { $0.key >= 200 && $0.key < 300 }.values.reduce(0, +)
        let threeXX = statusCounts.filter { $0.key >= 300 && $0.key < 400 }.values.reduce(0, +)
        let fourXX = statusCounts.filter { $0.key >= 400 && $0.key < 500 }.values.reduce(0, +)
        let fiveXX = statusCounts.filter { $0.key >= 500 }.values.reduce(0, +)
        let zeroXX = statusCounts[0] ?? 0

        return cardShell(tone: .teal) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Status Groups")
                    .font(.headline)
                if twoXX > 0 { statusGroupRow(label: "2xx  Success", count: twoXX, total: total, tone: .green) }
                if threeXX > 0 { statusGroupRow(label: "3xx  Redirect", count: threeXX, total: total, tone: .blue) }
                if fourXX > 0 { statusGroupRow(label: "4xx  Client Error", count: fourXX, total: total, tone: .orange) }
                if fiveXX > 0 { statusGroupRow(label: "5xx  Server Error", count: fiveXX, total: total, tone: .red) }
                if zeroXX > 0 { statusGroupRow(label: "0  Blocked / Failed", count: zeroXX, total: total, tone: .red) }
            }
        }
    }

    private func statusGroupRow(label: String, count: Int, total: Int, tone: Color) -> some View {
        HStack(spacing: 8) {
            Circle().fill(tone).frame(width: 8, height: 8)
            Text(label).font(.subheadline)
            Spacer()
            Text("\(count)")
                .font(.subheadline.monospacedDigit().weight(.semibold))
            Text(total > 0 ? String(format: "(%.0f%%)", Double(count) / Double(total) * 100) : "")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 50, alignment: .leading)
        }
    }

    private func statusDetailCard(sortedCodes: [Int], statusCounts: [Int: Int]) -> some View {
        cardShell(tone: .orange) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Status Code Detail")
                    .font(.headline)
                ForEach(sortedCodes, id: \.self) { code in
                    let count = statusCounts[code] ?? 0
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(httpStatusLabel(code))
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(httpStatusColor(code))
                            Spacer()
                            Text("\(count) req")
                                .font(.caption.monospacedDigit().weight(.bold))
                                .foregroundStyle(.secondary)
                        }
                        Text(httpStatusExplanation(code))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(10)
                    .background(httpStatusColor(code).opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
            }
        }
    }

    private func avg(_ values: [Double]) -> Double {
        values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
    }

    @ViewBuilder
    private func portBreakdownCard(summaries: [PortSummary], total: Int) -> some View {
        let nonStandard = summaries.filter { !$0.isStandard }
        let standard = summaries.filter { $0.isStandard }
        if !nonStandard.isEmpty {
            cardShell(tone: .purple) {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Alternate Ports")
                            .font(.headline)
                        Text("Requests made on non-standard ports. Proxy policies that only intercept 80/443 may miss this traffic.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    VStack(spacing: 8) {
                        ForEach(nonStandard, id: \.port) { summary in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text(verbatim: "\(summary.scheme.uppercased()):\(summary.port)")
                                        .font(.system(.body, design: .monospaced).weight(.semibold))
                                        .foregroundStyle(.purple)
                                    Spacer()
                                    Text(verbatim: "\(summary.requestCount) req")
                                        .font(.caption.monospacedDigit().weight(.bold))
                                        .foregroundStyle(.secondary)
                                    Text(total > 0 ? String(format: "(%.0f%%)", Double(summary.requestCount) / Double(total) * 100) : "")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .frame(width: 44, alignment: .leading)
                                }
                                Text(summary.hosts.joined(separator: ", "))
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(3)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .padding(10)
                            .background(Color.purple.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                    }

                    if !standard.isEmpty {
                        let standardCount = standard.reduce(0) { $0 + $1.requestCount }
                        Text(verbatim: "\(standardCount) request\(standardCount == 1 ? "" : "s") on standard ports (80/443) not shown.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func pacExportSection(report: AnalysisReport) -> some View {
        let hasPAC = model.hasPAC
        let unmatchedDomains = hasPAC ? report.unmatchedDomains : report.registrableDomains

        let requiredSnippet = report.requiredBypassDomains
            .map { "    dnsDomainIs(host, \".\($0)\") ||" }
            .joined(separator: "\n")

        let allUnmatchedSnippet = unmatchedDomains
            .map { "    dnsDomainIs(host, \".\($0)\") ||" }
            .joined(separator: "\n")

        return VStack(alignment: .leading, spacing: 20) {
            sectionHeader(
                "PAC Export",
                subtitle: hasPAC
                    ? "Domains from this HAR not covered by the loaded PAC file, ready to paste into your PAC rule block."
                    : "All registrable domains from this HAR in PAC format. Load a PAC file to show only unmatched domains."
            )

            if report.requiredBypassDomains.isEmpty && unmatchedDomains.isEmpty {
                cardShell(tone: .green) {
                    Label("All domains in this HAR are already covered by the loaded PAC file.", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            }

            if !report.requiredBypassDomains.isEmpty {
                pacSnippetCard(
                    title: "Required Bypasses",
                    subtitle: "\(report.requiredBypassDomains.count) likely-required domain\(report.requiredBypassDomains.count == 1 ? "" : "s") not in the PAC file",
                    snippet: requiredSnippet,
                    tone: .green
                )
            }

            if !unmatchedDomains.isEmpty {
                pacSnippetCard(
                    title: hasPAC ? "All Unmatched Domains" : "All Domains",
                    subtitle: "\(unmatchedDomains.count) domain\(unmatchedDomains.count == 1 ? "" : "s")\(hasPAC ? " not found in the loaded PAC file" : " from this HAR capture")",
                    snippet: allUnmatchedSnippet,
                    tone: .blue
                )
            }
        }
    }

    private func pacSnippetCard(title: String, subtitle: String, snippet: String, tone: Color) -> some View {
        cardShell(tone: tone) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(title)
                            .font(.headline)
                        Text(subtitle)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(snippet, forType: .string)
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                            .font(.subheadline.weight(.semibold))
                    }
                    .buttonStyle(.borderedProminent)
                }

                ScrollView {
                    Text(snippet)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                }
                .frame(maxHeight: 340)
                .background(Color.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
    }

    private func pacRulesSection(report: AnalysisReport) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            if let pac = model.pacAnalysis {
                let q = pacRulesSearch.trimmingCharacters(in: .whitespaces).lowercased()

                let allDns  = pac.rules.filter { $0.kind == .dnsDomainIs }.sorted { $0.pattern < $1.pattern }
                let allShExp = pac.rules.filter { $0.kind == .shExpMatch }.sorted { $0.pattern < $1.pattern }
                let rawRules = pac.rules.filter { $0.kind == .raw }

                let dns  = q.isEmpty ? allDns  : allDns.filter  { $0.pattern.lowercased().contains(q) }
                let shExp = q.isEmpty ? allShExp : allShExp.filter { $0.pattern.lowercased().contains(q) }

                let totalMatching = dns.count + shExp.count
                let totalAll = allDns.count + allShExp.count

                sectionHeader(
                    "PAC Rules",
                    subtitle: q.isEmpty
                        ? "\(pac.rules.count) rule\(pac.rules.count == 1 ? "" : "s") — alphabetical"
                        : "\(totalMatching) of \(totalAll) matching \"\(pacRulesSearch)\""
                )

                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Filter rules", text: $pacRulesSearch)
                        .textFieldStyle(.plain)
                    if !pacRulesSearch.isEmpty {
                        Button { pacRulesSearch = "" } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Color.white.opacity(0.05), in: Capsule())

                if !allDns.isEmpty {
                    pacRuleCard(
                        title: "dnsDomainIs",
                        rules: dns,
                        totalCount: allDns.count,
                        isFiltered: !q.isEmpty,
                        tone: .blue
                    )
                }

                if !allShExp.isEmpty {
                    pacRuleCard(
                        title: "shExpMatch",
                        rules: shExp,
                        totalCount: allShExp.count,
                        isFiltered: !q.isEmpty,
                        tone: .purple
                    )
                }

                if !rawRules.isEmpty {
                    cardShell(tone: .gray) {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack(alignment: .top) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Other / Raw")
                                        .font(.headline)
                                    Text("\(rawRules.count) line\(rawRules.count == 1 ? "" : "s")")
                                        .font(.subheadline).foregroundStyle(.secondary)
                                }
                                Spacer()
                                copyButton(text: rawRules.map(\.sourceLine).joined(separator: "\n"))
                            }
                            ruleScrollList(rules: rawRules, idPath: \.sourceLine)
                        }
                    }
                }

                if !q.isEmpty && totalMatching == 0 {
                    cardShell(tone: .gray) {
                        Text("No rules match \"\(pacRulesSearch)\".")
                            .foregroundStyle(.secondary)
                    }
                }

            } else {
                sectionHeader("PAC Rules", subtitle: "No PAC file loaded.")
                cardShell(tone: .gray) {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("No PAC file loaded", systemImage: "doc.badge.ellipsis")
                            .font(.headline)
                        Text("Load a PAC file using the sidebar to see its parsed rules here.")
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private func pacRuleCard(title: String, rules: [PACRule], totalCount: Int, isFiltered: Bool, tone: Color) -> some View {
        cardShell(tone: tone) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(title).font(.headline)
                        Text(isFiltered ? "\(rules.count) of \(totalCount) match" : "\(totalCount) pattern\(totalCount == 1 ? "" : "s")")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    Spacer()
                    copyButton(text: rules.map(\.pattern).joined(separator: "\n"))
                }
                ruleScrollList(rules: rules, idPath: \.pattern)
            }
        }
    }

    private func copyButton(text: String) -> some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        } label: {
            Label("Copy All", systemImage: "doc.on.doc")
                .font(.subheadline.weight(.semibold))
        }
        .buttonStyle(.borderedProminent)
    }

    private func ruleScrollList(rules: [PACRule], idPath: KeyPath<PACRule, String>) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(rules, id: idPath) { rule in
                    Text(rule.pattern)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(12)
        }
        .frame(maxHeight: 360)
        .background(Color.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var appBackground: some View {
        LinearGradient(
            colors: [
                Color(red: 0.06, green: 0.08, blue: 0.12),
                Color(red: 0.08, green: 0.11, blue: 0.15),
                Color(red: 0.10, green: 0.10, blue: 0.12)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
    }
}

private struct FlowHostButtons: View {
    let hosts: [String]
    let action: (String) -> Void

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 8, alignment: .leading)], alignment: .leading, spacing: 8) {
            ForEach(hosts, id: \.self) { host in
                Button {
                    action(host)
                } label: {
                    Text(host)
                        .font(.caption.weight(.semibold))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(Color.white.opacity(0.08), in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

private struct InspectorPane: View {
    let report: AnalysisReport
    let selectedDomain: String?
    @Bindable var model: AppModel
    @State private var showAllRequestHeaders = false
    @State private var showAllResponseHeaders = false

    private var domain: String? {
        selectedDomain
    }

    private var matchingRequests: [AnalyzedRequest] {
        guard let domain else { return [] }
        return report.requests.filter { $0.registrableDomain == domain }
            .sorted {
                if $0.status == $1.status {
                    return ($0.elapsedMS ?? 0) > ($1.elapsedMS ?? 0)
                }
                return severityRank($0.status) > severityRank($1.status)
            }
    }

    private var matchingHosts: [String] {
        Array(Set(matchingRequests.compactMap(\.host))).sorted()
    }

    private var matchingFindings: [AnalyzedRequest] {
        matchingRequests.filter { !$0.issues.isEmpty }
    }

    private var selectedRequest: AnalyzedRequest? {
        if let selectedRequestURL,
           let matching = matchingRequests.first(where: { $0.url == selectedRequestURL }) {
            return matching
        }
        return matchingRequests.first
    }

    private var selectedRequestURL: String? {
        model.selectedRequestURL
    }

    private var categorySummary: String {
        let categories = Array(Set(matchingRequests.compactMap { $0.classification?.category.rawValue })).sorted()
        return categories.isEmpty ? "No category yet" : categories.joined(separator: ", ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let domain {
                header(domain: domain)

                inspectorMetricRow(
                    metric(title: "Hosts", value: "\(matchingHosts.count)", tone: .indigo),
                    metric(title: "Requests", value: "\(matchingRequests.count)", tone: .blue),
                    metric(title: "Findings", value: "\(matchingFindings.count)", tone: .red)
                )

                card(title: "Classification") {
                    Text(categorySummary)
                        .foregroundStyle(.secondary)
                }

                card(title: "Hosts") {
                    if matchingHosts.isEmpty {
                        Text("No hosts")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(matchingHosts, id: \.self) { host in
                            Text(host)
                                .font(.system(.body, design: .monospaced))
                                .textSelection(.enabled)
                        }
                    }
                }

                card(title: "Requests") {
                    if matchingRequests.isEmpty {
                        Text("No matching requests")
                            .foregroundStyle(.secondary)
                    } else {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(Array(matchingRequests.enumerated()), id: \.offset) { _, request in
                                Button {
                                    model.selectRequest(request.url)
                                } label: {
                                    VStack(alignment: .leading, spacing: 6) {
                                        HStack {
                                            Text("HTTP \(request.status)")
                                                .font(.caption.weight(.bold))
                                                .foregroundStyle(statusColor(request.status))
                                            Spacer()
                                            if let elapsed = request.elapsedMS {
                                                Text("\(Int(elapsed)) ms")
                                                    .font(.caption)
                                                    .foregroundStyle(.secondary)
                                            }
                                        }

                                        Text(request.url)
                                            .font(.system(.caption, design: .monospaced))
                                            .textSelection(.enabled)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .lineLimit(5)
                                            .fixedSize(horizontal: false, vertical: true)

                                        if let pac = request.pacMatch?.pattern {
                                            Text("PAC: \(pac)")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        } else {
                                            Text("PAC: no match")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }

                                        if !request.issues.isEmpty {
                                            ForEach(request.issues, id: \.self) { issue in
                                                Text(issue)
                                                    .font(.caption)
                                                    .foregroundStyle(.secondary)
                                                    .fixedSize(horizontal: false, vertical: true)
                                            }
                                        }
                                    }
                                    .padding(12)
                                    .background(
                                        (selectedRequest?.url == request.url ? Color.accentColor.opacity(0.18) : Color.white.opacity(0.05)),
                                        in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }

                card(title: "Request Detail") {
                    if let request = selectedRequest {
                        VStack(alignment: .leading, spacing: 10) {
                            detailRow(label: "URL", value: request.url, monospaced: true)
                            detailRow(label: "Method", value: request.method)
                            detailRow(label: "HTTP Status", value: httpStatusLabel(request.status))
                            detailRow(label: "Status Meaning", value: httpStatusExplanation(request.status))
                            detailRow(label: "Elapsed", value: request.elapsedMS.map { "\(Int($0)) ms" } ?? "Unknown")
                            if let port = request.port {
                                detailRow(
                                    label: "Port",
                                    value: request.isNonStandardPort
                                        ? "\(port) ⚠ non-standard"
                                        : "\(port)"
                                )
                            }
                            detailRow(label: "MIME Type", value: request.mimeType ?? "Unknown")
                            detailRow(label: "Host", value: request.host ?? "Unknown")
                            detailRow(label: "Domain", value: request.registrableDomain ?? "Unknown")
                            detailRow(label: "Category", value: request.classification?.category.rawValue ?? "Unclassified")
                            detailRow(label: "Criticality", value: request.classification?.criticality.rawValue ?? "Needs Review")
                            detailRow(label: "Reason", value: request.classification?.reason ?? "No classifier reason yet")
                            detailRow(label: "PAC Match", value: request.pacMatch?.pattern ?? "No match")

                            if !request.issues.isEmpty {
                                Divider().overlay(Color.white.opacity(0.08))
                                Text("Detected Issues")
                                    .font(.headline)
                                ForEach(request.issues, id: \.self) { issue in
                                    Text(issue)
                                        .foregroundStyle(.secondary)
                                }
                            }

                            if !request.headerSignals.isEmpty {
                                Divider().overlay(Color.white.opacity(0.08))
                                Text("Header / Content Signals")
                                    .font(.headline)
                                ForEach(request.headerSignals, id: \.self) { signal in
                                    Label(signal, systemImage: "sparkles.rectangle.stack")
                                        .padding(10)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                                }
                            }

                            Divider().overlay(Color.white.opacity(0.08))
                            Text("Timing Breakdown")
                                .font(.headline)
                            timingGrid(request.timings)

                            Divider().overlay(Color.white.opacity(0.08))
                            prioritizedHeaderSection(
                                title: "Request Headers",
                                headers: request.requestHeaders,
                                importantNames: [
                                    "host",
                                    "accept",
                                    "accept-language",
                                    "accept-encoding",
                                    "content-type",
                                    "origin",
                                    "referer",
                                    "user-agent",
                                    "cookie",
                                    "authorization"
                                ],
                                expanded: $showAllRequestHeaders
                            )

                            Divider().overlay(Color.white.opacity(0.08))
                            prioritizedHeaderSection(
                                title: "Response Headers",
                                headers: request.responseHeaders,
                                importantNames: [
                                    "content-type",
                                    "content-length",
                                    "content-encoding",
                                    "cache-control",
                                    "location",
                                    "server",
                                    "via",
                                    "proxy-authenticate",
                                    "x-cache",
                                    "cf-cache-status",
                                    "set-cookie",
                                    "access-control-allow-origin"
                                ],
                                expanded: $showAllResponseHeaders
                            )
                        }
                    } else {
                        Text("Select a request to inspect it in more detail.")
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Inspector")
                        .font(.title2.weight(.bold))
                    Text("Select a domain from the dashboard to inspect matching hosts, requests, findings, and PAC coverage.")
                        .foregroundStyle(.secondary)
                }
                .padding(22)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            }
        }
    }

    private func header(domain: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Inspector")
                .font(.title2.weight(.bold))
            Text(domain)
                .font(.system(.title3, design: .monospaced, weight: .semibold))
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            Text("Click domains from the dashboard to inspect exactly what traffic they carry.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private func metric(title: String, value: String, tone: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(.title3, design: .rounded, weight: .bold))
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tone.opacity(0.12), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func inspectorMetricRow(_ a: some View, _ b: some View, _ c: some View) -> some View {
        HStack(spacing: 10) {
            a
            b
            c
        }
    }

    private func card<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
            content()
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private func detailRow(label: String, value: String, monospaced: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
            if monospaced {
                Text(value)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(6)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(value)
                    .textSelection(.enabled)
                    .lineLimit(6)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func timingGrid(_ timings: RequestTimingBreakdown) -> some View {
        let rows: [(String, Double?)] = [
            ("Blocked", timings.blocked),
            ("DNS", timings.dns),
            ("Connect", timings.connect),
            ("SSL", timings.ssl),
            ("Send", timings.send),
            ("Wait", timings.wait),
            ("Receive", timings.receive)
        ]

        return LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 10) {
            ForEach(rows, id: \.0) { row in
                VStack(alignment: .leading, spacing: 4) {
                    Text(row.0)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                    Text(row.1.map { "\(Int($0)) ms" } ?? "n/a")
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
    }

    private func prioritizedHeaderSection(title: String, headers: [HeaderField], importantNames: [String], expanded: Binding<Bool>) -> some View {
        let important = prioritizedHeaders(headers, preferredNames: importantNames)
        let remaining = remainingHeaders(headers, excluding: Set(important.map { normalizedHeaderName($0.name) }))

        return VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)

            if headers.isEmpty {
                Text("No headers captured")
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    if !important.isEmpty {
                        Text("Important")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.secondary)

                        headerList(important)
                    }

                    if !remaining.isEmpty {
                        DisclosureGroup(isExpanded: expanded) {
                            VStack(alignment: .leading, spacing: 8) {
                                headerList(remaining)
                            }
                            .padding(.top, 8)
                        } label: {
                            Text("All Headers (\(headers.count))")
                                .font(.caption.weight(.bold))
                        }
                    }
                }
            }
        }
    }

    private func headerList(_ headers: [HeaderField]) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(headers.enumerated()), id: \.offset) { _, header in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(header.name)
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.secondary)
                        Text(header.value ?? "")
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            }
        }
        .frame(minHeight: 80, maxHeight: 220)
    }

    private func severityRank(_ status: Int) -> Int {
        switch status {
        case 0: return 4
        case 500...: return 3
        case 400...: return 2
        case 300...: return 1
        default: return 0
        }
    }

    private func statusColor(_ status: Int) -> Color {
        switch status {
        case 200..<300: return .green
        case 300..<400: return .orange
        default: return .red
        }
    }

    private func prioritizedHeaders(_ headers: [HeaderField], preferredNames: [String]) -> [HeaderField] {
        let preferred = Set(preferredNames.map { $0.lowercased() })
        let exactMatches = headers.filter { preferred.contains(normalizedHeaderName($0.name)) }
        let suspicious = headers.filter {
            let name = normalizedHeaderName($0.name)
            return !preferred.contains(name) && (name.contains("proxy") || name.contains("cache") || name.contains("cookie") || name.contains("cf-") || name.contains("x-"))
        }

        var seen = Set<String>()
        return (exactMatches + suspicious).filter { header in
            let key = normalizedHeaderName(header.name)
            if seen.contains(key) { return false }
            seen.insert(key)
            return true
        }
    }

    private func remainingHeaders(_ headers: [HeaderField], excluding names: Set<String>) -> [HeaderField] {
        headers.filter { !names.contains(normalizedHeaderName($0.name)) }
    }

    private func normalizedHeaderName(_ name: String) -> String {
        name.lowercased()
    }
}

private func httpStatusName(_ code: Int) -> String {
    switch code {
    case 0: return "Connection Failed"
    case 100: return "Continue"
    case 101: return "Switching Protocols"
    case 200: return "OK"
    case 201: return "Created"
    case 202: return "Accepted"
    case 204: return "No Content"
    case 206: return "Partial Content"
    case 301: return "Moved Permanently"
    case 302: return "Found"
    case 303: return "See Other"
    case 304: return "Not Modified"
    case 307: return "Temporary Redirect"
    case 308: return "Permanent Redirect"
    case 400: return "Bad Request"
    case 401: return "Unauthorized"
    case 403: return "Forbidden"
    case 404: return "Not Found"
    case 405: return "Method Not Allowed"
    case 407: return "Proxy Auth Required"
    case 408: return "Request Timeout"
    case 409: return "Conflict"
    case 410: return "Gone"
    case 412: return "Precondition Failed"
    case 413: return "Content Too Large"
    case 429: return "Too Many Requests"
    case 451: return "Unavailable For Legal Reasons"
    case 499: return "Client Closed Request"
    case 500: return "Internal Server Error"
    case 502: return "Bad Gateway"
    case 503: return "Service Unavailable"
    case 504: return "Gateway Timeout"
    default:
        if code >= 100 && code < 200 { return "Informational" }
        if code >= 200 && code < 300 { return "Success" }
        if code >= 300 && code < 400 { return "Redirect" }
        if code >= 400 && code < 500 { return "Client Error" }
        if code >= 500 { return "Server Error" }
        return "Unknown"
    }
}

private func httpStatusExplanation(_ code: Int) -> String {
    switch code {
    case 0: return "No response received. Likely blocked by a proxy, firewall, or network failure, or cancelled by the browser."
    case 100: return "The server received the request headers; the client should proceed to send the body."
    case 101: return "The server is switching protocols as requested (e.g., upgrading to WebSocket)."
    case 200: return "The request succeeded and the server returned the requested data."
    case 201: return "The request succeeded and a new resource was created as a result."
    case 202: return "The request has been accepted but processing is not yet complete."
    case 204: return "The request succeeded but there is no response body to return."
    case 206: return "The server is delivering only part of the resource in response to a range request."
    case 301: return "The resource has permanently moved to a new URL. Clients should update their links."
    case 302: return "The resource is temporarily at a different URL. Use the original URL for future requests."
    case 303: return "The response can be found at a different URL using a GET request."
    case 304: return "The resource has not changed; the client's cached copy is still valid."
    case 307: return "Temporary redirect — the client must use the same HTTP method as the original request."
    case 308: return "Permanent redirect — the client must use the same HTTP method as the original request."
    case 400: return "The server could not understand the request due to invalid syntax or missing parameters."
    case 401: return "Authentication is required. The client must authenticate to get the response."
    case 403: return "The server understood the request but refuses to authorize it. Common for proxy and firewall policy blocks."
    case 404: return "The server cannot find the requested resource. The URL may be wrong or the resource may be removed."
    case 405: return "The HTTP method is not allowed for this resource."
    case 407: return "Proxy authentication is required before the request can proceed. Common in Zscaler and enterprise proxy environments."
    case 408: return "The server timed out waiting for the client to complete the request."
    case 409: return "The request conflicts with the current state of the target resource."
    case 410: return "The resource is permanently gone and will not return."
    case 412: return "A precondition in the request headers evaluated to false. Seen in some proxy challenge-response flows."
    case 413: return "The request body is larger than the server is willing to process."
    case 429: return "The client has sent too many requests in a given time period. The server is rate limiting."
    case 451: return "Access denied for legal reasons, such as a government-mandated content block or geographic restriction."
    case 499: return "The client closed the connection before the server finished sending the response."
    case 500: return "The server encountered an unexpected error and could not complete the request."
    case 502: return "The gateway server received an invalid response from an upstream server."
    case 503: return "The server is not ready to handle requests — overloaded or under maintenance."
    case 504: return "The gateway server did not receive a timely response from an upstream server."
    default:
        if code >= 100 && code < 200 { return "Informational response." }
        if code >= 200 && code < 300 { return "The request was successfully received, understood, and accepted." }
        if code >= 300 && code < 400 { return "Further action is needed to complete the request." }
        if code >= 400 && code < 500 { return "The request cannot be fulfilled. The client should review its request." }
        if code >= 500 { return "The server failed to fulfill a valid request." }
        return "Unrecognized status code."
    }
}

private func httpStatusLabel(_ code: Int) -> String {
    "\(code) — \(httpStatusName(code))"
}

private func httpStatusColor(_ code: Int) -> Color {
    switch code {
    case 0: return .red
    case 100..<200: return .gray
    case 200..<300: return .green
    case 300..<400: return .blue
    case 400..<500: return .orange
    default: return .red
    }
}

private struct TimingBar: View {
    let label: String
    let count: Int
    let total: Int
    let tone: Color

    private var fraction: Double { total > 0 ? Double(count) / Double(total) : 0 }

    var body: some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.subheadline)
                .frame(width: 95, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(tone.opacity(0.15))
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(tone.opacity(0.55))
                        .frame(width: max(fraction > 0 ? 4 : 0, geo.size.width * fraction))
                }
            }
            .frame(height: 14)
            Text("\(count)")
                .font(.subheadline.monospacedDigit())
                .frame(width: 36, alignment: .trailing)
            Text(total > 0 ? String(format: "%.0f%%", fraction * 100) : "–")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 42, alignment: .leading)
        }
    }
}

private struct TimingPhaseRow: View {
    let label: String
    let value: Double
    let maxValue: Double
    let tone: Color
    let count: Int

    private var fraction: Double { maxValue > 0 ? min(value / maxValue, 1.0) : 0 }

    var body: some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.subheadline)
                .frame(width: 100, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(tone.opacity(0.15))
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(tone.opacity(0.55))
                        .frame(width: max(value > 0 ? 4.0 : 0.0, geo.size.width * fraction))
                }
            }
            .frame(height: 14)
            Group {
                if value > 0 {
                    Text(String(format: "%.0f ms", value))
                        .font(.subheadline.monospacedDigit().weight(.semibold))
                } else {
                    Text("n/a")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 70, alignment: .trailing)
            Text("(\(count))")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct AddPACURLSheet: View {
    @State private var name = ""
    @State private var urlString = ""
    let onAdd: (String, String) -> Void
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Field?

    private enum Field { case name, url }

    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty &&
        !urlString.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Add Hosted PAC URL")
                .font(.title2.weight(.bold))

            VStack(alignment: .leading, spacing: 6) {
                Text("Name")
                    .font(.headline)
                TextField("e.g., Zscaler Primary", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused, equals: .name)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("URL")
                    .font(.headline)
                TextField("https://...", text: $urlString)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused, equals: .url)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Add") {
                    onAdd(
                        name.trimmingCharacters(in: .whitespaces),
                        urlString.trimmingCharacters(in: .whitespaces)
                    )
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!isValid)
                .keyboardShortcut(.return, modifiers: [])
            }
        }
        .padding(28)
        .frame(minWidth: 420, idealWidth: 480, minHeight: 220)
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                focused = .name
            }
        }
    }
}

private extension String {
    func firstMatch(for pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(startIndex..., in: self)
        guard
            let match = regex.firstMatch(in: self, options: [], range: range),
            match.numberOfRanges > 1,
            let captureRange = Range(match.range(at: 1), in: self)
        else {
            return nil
        }
        return String(self[captureRange])
    }
}
