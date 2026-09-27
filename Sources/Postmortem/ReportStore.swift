import CryptoKit
import Foundation

/// A stored MetricKit payload.
public struct StoredPayload: Sendable, Hashable, Identifiable {
    public enum Kind: String, Sendable, Hashable {
        case diagnostic
        case metric
    }

    /// A content hash, so duplicate deliveries are stored once.
    public var id: String
    public var kind: Kind
    public var receivedAt: Date
    public var fileURL: URL
}

/// Persists MetricKit payloads as JSON files and parses them on demand.
///
/// MetricKit delivers each payload once, and `pastPayloads` only covers
/// recent history, so anything not stored is lost. The store keeps the raw
/// JSON (so nothing is lost if parsing improves later), deduplicates
/// identical payloads, and trims old ones.
public actor ReportStore {
    /// The directory holding `diagnostics/` and `metrics/`.
    public nonisolated let directory: URL
    /// Payloads older than this are removed by ``trim()``.
    public var maximumAge: TimeInterval
    /// At most this many payloads of each kind are kept.
    public var maximumCount: Int

    private var continuations: [UUID: AsyncStream<Void>.Continuation] = [:]

    /// A store in Application Support (or `directory`, if given).
    public init(directory: URL? = nil, maximumAge: TimeInterval = 90 * 86_400, maximumCount: Int = 200) {
        self.directory = directory ?? URL.applicationSupportDirectory.appending(path: "Postmortem", directoryHint: .isDirectory)
        self.maximumAge = maximumAge
        self.maximumCount = maximumCount
    }

    /// The shared store.
    public static let shared = ReportStore()

    // MARK: - Writing

    /// Stores a payload's JSON. Returns `false` if an identical payload was
    /// already stored.
    @discardableResult
    public func add(_ json: Data, kind: StoredPayload.Kind, receivedAt: Date = Date()) throws -> Bool {
        // Validate before storing.
        switch kind {
        case .diagnostic: _ = try DiagnosticPayload(json: json)
        case .metric: _ = try MetricPayload(json: json)
        }
        let id = SHA256.hash(data: json).prefix(16).map { String(format: "%02x", $0) }.joined()
        let folder = try folder(for: kind)
        if try FileManager.default.contentsOfDirectory(atPath: folder.path).contains(where: { $0.hasSuffix("-\(id).json") }) {
            return false
        }
        let name = "\(Int(receivedAt.timeIntervalSince1970))-\(id).json"
        try json.write(to: folder.appending(path: name), options: [.atomic])
        try trim()
        notify()
        return true
    }

    /// Removes a stored payload.
    public func remove(_ payload: StoredPayload) throws {
        try? FileManager.default.removeItem(at: payload.fileURL)
        notify()
    }

    /// Removes everything.
    public func removeAll() throws {
        for kind in [StoredPayload.Kind.diagnostic, .metric] {
            try? FileManager.default.removeItem(at: try folder(for: kind))
        }
        notify()
    }

    /// Applies ``maximumAge`` and ``maximumCount``.
    public func trim() throws {
        let cutoff = Date().addingTimeInterval(-maximumAge)
        for kind in [StoredPayload.Kind.diagnostic, .metric] {
            let payloads = try list(kind)
            for (index, payload) in payloads.enumerated() where index >= maximumCount || payload.receivedAt < cutoff {
                try? FileManager.default.removeItem(at: payload.fileURL)
            }
        }
    }

    // MARK: - Reading

    /// Stored payloads of `kind`, newest first.
    public func list(_ kind: StoredPayload.Kind) throws -> [StoredPayload] {
        let folder = try folder(for: kind)
        return try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .compactMap { url -> StoredPayload? in
                let parts = url.deletingPathExtension().lastPathComponent.split(separator: "-", maxSplits: 1)
                guard parts.count == 2, let seconds = TimeInterval(parts[0]) else { return nil }
                return StoredPayload(id: String(parts[1]), kind: kind, receivedAt: Date(timeIntervalSince1970: seconds), fileURL: url)
            }
            .sorted { $0.receivedAt == $1.receivedAt ? $0.id > $1.id : $0.receivedAt > $1.receivedAt }
    }

    /// Every stored diagnostic, newest reporting period first, deduplicated
    /// across payloads.
    public func diagnostics() throws -> [Diagnostic] {
        var seen = Set<String>()
        var result: [Diagnostic] = []
        for stored in try list(.diagnostic) {
            guard let data = try? Data(contentsOf: stored.fileURL), let payload = try? DiagnosticPayload(json: data) else { continue }
            for var diagnostic in payload.diagnostics where seen.insert(diagnostic.id).inserted {
                if diagnostic.periodEnd == nil { diagnostic.periodEnd = stored.receivedAt }
                result.append(diagnostic)
            }
        }
        // Newest reporting period first; payloads received later break ties.
        return result.enumerated()
            .sorted { a, b in
                let (dateA, dateB) = (a.element.periodEnd ?? .distantPast, b.element.periodEnd ?? .distantPast)
                return dateA == dateB ? a.offset < b.offset : dateA > dateB
            }
            .map(\.element)
    }

    /// Every stored metric payload, newest first.
    public func metrics() throws -> [MetricPayload] {
        try list(.metric).compactMap { stored in
            guard let data = try? Data(contentsOf: stored.fileURL) else { return nil }
            return try? MetricPayload(json: data)
        }
    }

    /// The raw JSON of a stored payload.
    public func data(for payload: StoredPayload) throws -> Data {
        try Data(contentsOf: payload.fileURL)
    }

    // MARK: - Observation

    /// Emits whenever payloads are added or removed.
    public func changes() -> AsyncStream<Void> {
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        continuations[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeContinuation(id) }
        }
        return stream
    }

    private func removeContinuation(_ id: UUID) {
        continuations[id] = nil
    }

    private func notify() {
        continuations.values.forEach { $0.yield() }
    }

    private func folder(for kind: StoredPayload.Kind) throws -> URL {
        let folder = directory.appending(path: kind == .diagnostic ? "diagnostics" : "metrics", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }
}
