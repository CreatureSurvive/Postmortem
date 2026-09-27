#if !os(watchOS)
import SwiftUI

/// Browses stored diagnostics and metrics: crashes, hangs and exceptions
/// with symbolicated stacks, plus daily metrics.
///
/// Drop it into a debug menu or settings screen:
///
/// ```swift
/// NavigationLink("Diagnostics") { PostmortemView() }
/// ```
public struct PostmortemView: View {
    let store: ReportStore
    @State private var model: PostmortemModel

    public init(store: ReportStore = .shared) {
        self.store = store
        _model = State(initialValue: PostmortemModel(store: store))
    }

    public var body: some View {
        List {
            if model.diagnostics.isEmpty && model.metrics.isEmpty {
                ContentUnavailableView(
                    "No Reports Yet",
                    systemImage: "stethoscope",
                    description: Text("MetricKit delivers crash, hang and performance reports about once a day on real devices.")
                )
            }
            ForEach(Diagnostic.Kind.allCases, id: \.self) { kind in
                let items = model.diagnostics.filter { $0.kind == kind }
                if !items.isEmpty {
                    Section("\(kind.displayName)s") {
                        ForEach(items) { diagnostic in
                            NavigationLink(value: diagnostic) {
                                DiagnosticRow(diagnostic: diagnostic)
                            }
                            .accessibilityIdentifier("postmortem.diagnostic.\(kind.rawValue)")
                        }
                    }
                }
            }
            if !model.metrics.isEmpty {
                Section("Daily Metrics") {
                    ForEach(model.metrics) { metrics in
                        NavigationLink(value: metrics) {
                            MetricRow(metrics: metrics)
                        }
                        .accessibilityIdentifier("postmortem.metrics")
                    }
                }
            }
        }
        .navigationTitle("Diagnostics")
        .navigationDestination(for: Diagnostic.self) { DiagnosticDetailView(diagnostic: $0) }
        .navigationDestination(for: MetricPayload.self) { MetricDetailView(metrics: $0) }
        .toolbar {
            if !model.diagnostics.isEmpty || !model.metrics.isEmpty {
                Button("Delete All", systemImage: "trash", role: .destructive) {
                    Task { await model.deleteAll() }
                }
            }
        }
        .task { await model.observe() }
        .refreshable { await model.reload() }
    }
}

@MainActor
@Observable
final class PostmortemModel {
    let store: ReportStore
    var diagnostics: [Diagnostic] = []
    var metrics: [MetricPayload] = []

    init(store: ReportStore) {
        self.store = store
    }

    func observe() async {
        let changes = await store.changes()
        await reload()
        for await _ in changes { await reload() }
    }

    func reload() async {
        diagnostics = (try? await store.diagnostics()) ?? []
        metrics = (try? await store.metrics()) ?? []
    }

    func deleteAll() async {
        try? await store.removeAll()
        await reload()
    }
}

struct DiagnosticRow: View {
    let diagnostic: Diagnostic

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(diagnostic.title)
                .font(.headline)
                .lineLimit(1)
            Text(topFrame)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
            HStack {
                if let version = diagnostic.metadata.versionDescription { Text(version) }
                if let os = diagnostic.metadata.osVersion { Text(os) }
                Spacer()
                if let date = diagnostic.periodEnd { Text(date, style: .date) }
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
    }

    private var topFrame: String {
        let frames = diagnostic.primaryFrames
        let interesting = frames.first { !DiagnosticReport.isSystemBinary($0.binaryName) } ?? frames.first
        guard let interesting else { return "No stack" }
        let resolved = Self.symbolicator.symbolicate(interesting)
        let module = (interesting.binaryName ?? "?").components(separatedBy: ".").first ?? "?"
        if let symbol = resolved.symbol { return "\(Self.compact(symbol, module: module))  ·  \(module)" }
        return "\(interesting.binaryName ?? "?") +\(interesting.offsetIntoBinaryTextSegment ?? 0)"
    }

    /// `demoLoad()` for `@objc MyApp.demoLoad() -> Swift.Int32`.
    static func compact(_ symbol: String, module: String) -> String {
        var name = symbol
        for prefix in ["@objc ", "merged ", "\(module)."] where name.hasPrefix(prefix) {
            name.removeFirst(prefix.count)
        }
        if let arrow = name.range(of: " -> ") { name = String(name[..<arrow.lowerBound]) }
        return name
    }

    /// Created once: it reads the loaded images, and symbols are cached.
    private static let symbolicator = Symbolicator()
}

struct MetricRow: View {
    let metrics: MetricPayload

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let end = metrics.timeStampEnd {
                Text(end, style: .date).font(.headline)
            } else {
                Text("Metrics").font(.headline)
            }
            HStack(spacing: 12) {
                if let launch = metrics.launchTime?.percentile(0.5) {
                    Label(MetricValue("\(launch) sec").formatted, systemImage: "bolt")
                }
                if let peak = metrics.peakMemoryUsage {
                    Label(peak.formatted, systemImage: "memorychip")
                }
                if metrics.abnormalExitCount > 0 {
                    Label("\(metrics.abnormalExitCount)", systemImage: "exclamationmark.triangle")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}
#endif
