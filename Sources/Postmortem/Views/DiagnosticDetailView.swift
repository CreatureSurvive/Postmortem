#if !os(watchOS)
import SwiftUI

/// Shows one diagnostic: what happened, where, and the full stacks,
/// symbolicated on device when the binaries match.
public struct DiagnosticDetailView: View {
    let diagnostic: Diagnostic
    @State private var threads: [SymbolicatedThread] = []
    @State private var report = ""
    @State private var showsAllThreads = false

    public init(diagnostic: Diagnostic) {
        self.diagnostic = diagnostic
    }

    public var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Label(diagnostic.kind.displayName, systemImage: symbol)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(diagnostic.title)
                        .font(.title3.bold())
                    Text(diagnostic.summary)
                        .font(.callout)
                }
                .padding(.vertical, 4)
            }
            Section("Details") {
                ForEach(details, id: \.0) { label, value in
                    LabeledContent(label, value: value)
                }
            }
            ForEach(visibleThreads) { thread in
                Section(thread.title) {
                    ForEach(thread.frames) { frame in
                        FrameRow(frame: frame)
                    }
                }
            }
            if threads.count > 1 {
                Section {
                    Toggle("Show All Threads", isOn: $showsAllThreads)
                }
            }
        }
        .navigationTitle(diagnostic.kind.displayName)
        #if !os(tvOS)
        .toolbar {
            if !report.isEmpty {
                ShareLink(item: report, subject: Text(diagnostic.title)) {
                    Label("Share Report", systemImage: "square.and.arrow.up")
                }
            }
        }
        #endif
        .task(id: diagnostic.id) {
            let diagnostic = diagnostic
            let result = await Task.detached(priority: .userInitiated) {
                let symbolicator = Symbolicator()
                return (SymbolicatedThread.make(for: diagnostic, symbolicator: symbolicator), DiagnosticReport.text(for: diagnostic, symbolicator: symbolicator))
            }.value
            threads = result.0
            report = result.1
        }
    }

    private var visibleThreads: [SymbolicatedThread] {
        showsAllThreads ? threads : Array(threads.filter(\.attributed).prefix(1).ifEmpty(threads.prefix(1)))
    }

    private var symbol: String {
        switch diagnostic.kind {
        case .crash: "xmark.octagon"
        case .hang: "hourglass"
        case .cpuException: "cpu"
        case .diskWriteException: "internaldrive"
        case .appLaunch: "timer"
        }
    }

    private var details: [(String, String)] {
        let meta = diagnostic.metadata
        var rows: [(String, String)] = []
        func add(_ label: String, _ value: String?) {
            if let value, !value.isEmpty { rows.append((label, value)) }
        }
        add("Version", meta.versionDescription)
        add("OS", meta.osVersion)
        add("Device", meta.deviceType)
        add("Termination", meta.terminationReason)
        add("Hang Type", diagnostic.hangType)
        if let date = diagnostic.periodEnd { add("Reported", date.formatted(date: .abbreviated, time: .shortened)) }
        if meta.isTestFlightApp == true { add("Build", "TestFlight") }
        if meta.lowPowerModeEnabled == true { add("Low Power Mode", "On") }
        return rows
    }
}

struct SymbolicatedThread: Identifiable, Sendable {
    let id: Int
    let title: String
    let attributed: Bool
    let frames: [NumberedFrame]

    struct NumberedFrame: Identifiable, Sendable {
        let id: Int
        let symbolicated: SymbolicatedFrame
        let isSystem: Bool
    }

    static func make(for diagnostic: Diagnostic, symbolicator: Symbolicator) -> [SymbolicatedThread] {
        guard let trace = diagnostic.stackTrace else { return [] }
        return trace.threads.enumerated().map { index, thread in
            let frames = trace.callStackPerThread ? thread.frames : thread.heaviestPath
            let title = (trace.callStackPerThread ? "Thread \(index)" : "Heaviest Stack \(index + 1)") + (thread.threadAttributed ? " (attributed)" : "")
            return SymbolicatedThread(
                id: index,
                title: title,
                attributed: thread.threadAttributed,
                frames: frames.enumerated().map { number, frame in
                    NumberedFrame(id: number, symbolicated: symbolicator.symbolicate(frame), isSystem: DiagnosticReport.isSystemBinary(frame.binaryName))
                }
            )
        }
    }
}

struct FrameRow: View {
    let frame: SymbolicatedThread.NumberedFrame

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(frame.id)")
                .foregroundStyle(.tertiary)
                .frame(minWidth: 24, alignment: .trailing)
            VStack(alignment: .leading, spacing: 2) {
                Text(frame.symbolicated.symbol ?? "+\(frame.symbolicated.frame.offsetIntoBinaryTextSegment ?? 0)")
                    .foregroundStyle(frame.isSystem ? .secondary : .primary)
                    .fontWeight(frame.isSystem ? .regular : .semibold)
                Text(frame.symbolicated.frame.binaryName ?? "???")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if let samples = frame.symbolicated.frame.sampleCount, samples > 1 {
                Text("\(samples)×").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .font(.caption.monospaced())
        #if !os(tvOS)
        .textSelection(.enabled)
        #endif
    }
}

extension Collection {
    func ifEmpty(_ fallback: @autoclosure () -> Self) -> Self {
        isEmpty ? fallback() : self
    }
}
#endif
