#if canImport(MetricKit) && !os(tvOS) && !os(watchOS)
import Foundation
import MetricKit
import os

/// Receives MetricKit payloads and saves them to a ``ReportStore``.
///
/// Start it once, early in launch (MetricKit delivers pending payloads
/// shortly after the app starts):
///
/// ```swift
/// @main
/// struct MyApp: App {
///     init() { PostmortemCollector.shared.start() }
///     ...
/// }
/// ```
///
/// On start it also imports `pastDiagnosticPayloads` and `pastPayloads`, so
/// reports delivered before the collector was added aren't lost. Duplicates
/// are ignored.
public final class PostmortemCollector: NSObject, MXMetricManagerSubscriber, @unchecked Sendable {
    public static let shared = PostmortemCollector()

    public let store: ReportStore
    /// Called after a new payload is stored, for example to upload it.
    public var onReceive: (@Sendable (StoredPayload.Kind, Data) -> Void)? {
        get { lock.withLock { receiveHandler } }
        set { lock.withLock { receiveHandler = newValue } }
    }

    private let lock = NSLock()
    private var isStarted = false
    private var receiveHandler: (@Sendable (StoredPayload.Kind, Data) -> Void)?
    private static let logger = Logger(subsystem: "Postmortem", category: "collector")

    public init(store: ReportStore = .shared) {
        self.store = store
    }

    /// Subscribes to MetricKit and imports past payloads. Safe to call more than once.
    public func start() {
        let shouldStart = lock.withLock {
            defer { isStarted = true }
            return !isStarted
        }
        guard shouldStart else { return }
        let manager = MXMetricManager.shared
        manager.add(self)
        ingest(manager.pastDiagnosticPayloads.map { $0.jsonRepresentation() }, kind: .diagnostic)
        ingest(manager.pastPayloads.map { $0.jsonRepresentation() }, kind: .metric)
    }

    /// Unsubscribes from MetricKit.
    public func stop() {
        lock.withLock { isStarted = false }
        MXMetricManager.shared.remove(self)
    }

    public func didReceive(_ payloads: [MXDiagnosticPayload]) {
        ingest(payloads.map { $0.jsonRepresentation() }, kind: .diagnostic)
    }

    public func didReceive(_ payloads: [MXMetricPayload]) {
        ingest(payloads.map { $0.jsonRepresentation() }, kind: .metric)
    }

    private func ingest(_ payloads: [Data], kind: StoredPayload.Kind) {
        guard !payloads.isEmpty else { return }
        let store = store
        let onReceive = onReceive
        Task {
            for json in payloads {
                do {
                    if try await store.add(json, kind: kind) {
                        onReceive?(kind, json)
                    }
                } catch {
                    Self.logger.error("Couldn't store a \(kind.rawValue, privacy: .public) payload: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }
}
#endif
