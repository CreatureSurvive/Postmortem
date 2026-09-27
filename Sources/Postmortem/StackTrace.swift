import Foundation

/// The call stacks captured with a diagnostic (MetricKit's call stack tree).
public struct StackTrace: Sendable, Hashable, Codable {
    /// Whether stacks are per thread (crashes) rather than aggregated samples
    /// across the process (hangs, CPU and disk exceptions).
    public var callStackPerThread: Bool
    public var threads: [Thread]

    public init(callStackPerThread: Bool, threads: [Thread]) {
        self.callStackPerThread = callStackPerThread
        self.threads = threads
    }

    enum CodingKeys: String, CodingKey {
        case callStackPerThread
        case threads = "callStacks"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        callStackPerThread = (try? container.decode(Bool.self, forKey: .callStackPerThread)) ?? true
        threads = (try? container.decode([Thread].self, forKey: .threads)) ?? []
    }

    /// One thread's stack, or one aggregated sample tree.
    public struct Thread: Sendable, Hashable, Codable {
        /// Whether this is the thread the diagnostic is attributed to (for
        /// a crash, the crashing thread).
        public var threadAttributed: Bool
        /// The root frames. For crashes, the first root is the innermost
        /// frame and each frame's single sub-frame is its caller.
        public var rootFrames: [Frame]

        public init(threadAttributed: Bool, rootFrames: [Frame]) {
            self.threadAttributed = threadAttributed
            self.rootFrames = rootFrames
        }

        enum CodingKeys: String, CodingKey {
            case threadAttributed
            case rootFrames = "callStackRootFrames"
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            threadAttributed = (try? container.decode(Bool.self, forKey: .threadAttributed)) ?? false
            rootFrames = (try? container.decode([Frame].self, forKey: .rootFrames)) ?? []
        }

        /// The frames along the first path through the tree, innermost first.
        /// This is the backtrace for per-thread (crash) stacks.
        public var frames: [Frame] {
            var result: [Frame] = []
            var next = rootFrames.first
            while let frame = next, result.count < 2048 {
                result.append(frame)
                next = frame.subFrames.first
            }
            return result
        }

        /// The path with the most samples at each level: the hottest stack in
        /// an aggregated tree (hangs, CPU exceptions).
        public var heaviestPath: [Frame] {
            var result: [Frame] = []
            var level = rootFrames
            while let frame = level.max(by: { ($0.sampleCount ?? 0) < ($1.sampleCount ?? 0) }), result.count < 2048 {
                result.append(frame)
                level = frame.subFrames
            }
            return result
        }
    }

    /// One frame: a return address in a binary.
    ///
    /// Frames of a runaway recursion can nest thousands deep, so copying,
    /// comparing, hashing and freeing them never recurses.
    public struct Frame: Sendable, Hashable, Codable {
        public var binaryUUID: UUID?
        public var binaryName: String?
        /// The address's offset from the start of the binary's `__TEXT`
        /// segment, which is stable across launches (unlike `address`).
        public var offsetIntoBinaryTextSegment: UInt64?
        /// The runtime address in the reporting process.
        public var address: UInt64?
        /// How many samples included this frame.
        public var sampleCount: Int?
        /// The frames below this one: for crashes, its caller.
        public var subFrames: [Frame] {
            get { children.frames }
            set {
                if isKnownUniquelyReferenced(&children) {
                    children.frames = newValue
                } else {
                    children = Children(newValue)
                }
            }
        }
        private var children: Children

        public init(
            binaryUUID: UUID? = nil,
            binaryName: String? = nil,
            offsetIntoBinaryTextSegment: UInt64? = nil,
            address: UInt64? = nil,
            sampleCount: Int? = nil,
            subFrames: [Frame] = []
        ) {
            self.binaryUUID = binaryUUID
            self.binaryName = binaryName
            self.offsetIntoBinaryTextSegment = offsetIntoBinaryTextSegment
            self.address = address
            self.sampleCount = sampleCount
            self.children = Children(subFrames)
        }

        public static func == (lhs: Frame, rhs: Frame) -> Bool {
            var pairs = [(lhs, rhs)]
            while let (a, b) = pairs.popLast() {
                if a.children === b.children, a.hasSameFields(as: b) { continue }
                guard a.hasSameFields(as: b), a.subFrames.count == b.subFrames.count else { return false }
                pairs.append(contentsOf: zip(a.subFrames, b.subFrames))
            }
            return true
        }

        public func hash(into hasher: inout Hasher) {
            var stack = [self]
            while let frame = stack.popLast() {
                hasher.combine(frame.binaryUUID)
                hasher.combine(frame.binaryName)
                hasher.combine(frame.offsetIntoBinaryTextSegment)
                hasher.combine(frame.address)
                hasher.combine(frame.sampleCount)
                hasher.combine(frame.subFrames.count)
                stack.append(contentsOf: frame.subFrames)
            }
        }

        private func hasSameFields(as other: Frame) -> Bool {
            binaryUUID == other.binaryUUID && binaryName == other.binaryName
                && offsetIntoBinaryTextSegment == other.offsetIntoBinaryTextSegment
                && address == other.address && sampleCount == other.sampleCount
        }

        /// Holds sub-frames so a deep tree can be freed with a loop instead of
        /// recursive deallocation, which can overflow a thread's stack.
        private final class Children: @unchecked Sendable {
            var frames: [Frame]

            init(_ frames: [Frame]) {
                self.frames = frames
            }

            deinit {
                guard !frames.isEmpty else { return }
                var pending = frames
                frames = []
                while var frame = pending.popLast() {
                    // Take the children of any frame this is the last owner
                    // of, so freeing it frees at most one level.
                    if isKnownUniquelyReferenced(&frame.children) {
                        pending.append(contentsOf: frame.children.frames)
                        frame.children.frames = []
                    }
                }
            }
        }

        enum CodingKeys: String, CodingKey {
            case binaryUUID, binaryName, offsetIntoBinaryTextSegment, address, sampleCount, subFrames
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            binaryUUID = (try? container.decode(String.self, forKey: .binaryUUID)).flatMap(UUID.init(uuidString:))
            binaryName = try? container.decode(String.self, forKey: .binaryName)
            offsetIntoBinaryTextSegment = Self.decodeUInt64(container, .offsetIntoBinaryTextSegment)
            address = Self.decodeUInt64(container, .address)
            sampleCount = try? container.decode(Int.self, forKey: .sampleCount)
            children = Children((try? container.decode([Frame].self, forKey: .subFrames)) ?? [])
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encodeIfPresent(binaryUUID?.uuidString, forKey: .binaryUUID)
            try container.encodeIfPresent(binaryName, forKey: .binaryName)
            try container.encodeIfPresent(offsetIntoBinaryTextSegment, forKey: .offsetIntoBinaryTextSegment)
            try container.encodeIfPresent(address, forKey: .address)
            try container.encodeIfPresent(sampleCount, forKey: .sampleCount)
            if !subFrames.isEmpty { try container.encode(subFrames, forKey: .subFrames) }
        }

        /// Addresses can exceed `Int64` and may be encoded as floating point.
        private static func decodeUInt64(_ container: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> UInt64? {
            if let value = try? container.decode(UInt64.self, forKey: key) { return value }
            if let value = try? container.decode(Double.self, forKey: key), value >= 0, value < 1.8e19 { return UInt64(value) }
            if let string = try? container.decode(String.self, forKey: key) {
                return string.hasPrefix("0x") ? UInt64(string.dropFirst(2), radix: 16) : UInt64(string)
            }
            return nil
        }
    }

    /// Frames deeper than this are dropped; real stacks are far shallower.
    public static let maximumDepth = 4096

    /// Builds a tree from MetricKit's JSON without recursion, so arbitrarily
    /// deep stacks (stack overflows) are handled.
    public init(json: JSONValue) {
        callStackPerThread = json["callStackPerThread"]?.boolValue ?? true
        threads = (json["callStacks"]?.arrayValue ?? []).map { thread in
            Thread(
                threadAttributed: thread["threadAttributed"]?.boolValue ?? false,
                rootFrames: (thread["callStackRootFrames"]?.arrayValue ?? []).map(Self.frame(from:))
            )
        }
    }

    static func frame(from root: JSONValue) -> Frame {
        struct Pending {
            let json: JSONValue
            let children: [JSONValue]
            var built: [Frame] = []
        }
        func pending(_ json: JSONValue, depth: Int) -> Pending {
            Pending(json: json, children: depth < maximumDepth ? (json["subFrames"]?.arrayValue ?? []) : [])
        }
        var stack = [pending(root, depth: 0)]
        while let top = stack.popLast() {
            if top.built.count < top.children.count {
                let child = top.children[top.built.count]
                stack.append(top)
                stack.append(pending(child, depth: stack.count))
                continue
            }
            let frame = Frame(
                binaryUUID: top.json["binaryUUID"]?.stringValue.flatMap(UUID.init(uuidString:)),
                binaryName: top.json["binaryName"]?.stringValue,
                offsetIntoBinaryTextSegment: top.json["offsetIntoBinaryTextSegment"].flatMap(uint64),
                address: top.json["address"].flatMap(uint64),
                sampleCount: top.json["sampleCount"]?.intValue,
                subFrames: top.built
            )
            guard var parent = stack.popLast() else { return frame }
            parent.built.append(frame)
            stack.append(parent)
        }
        return Frame()
    }

    static func uint64(_ value: JSONValue) -> UInt64? {
        switch value {
        case .number(let number):
            return number >= 0 && number < 18_446_744_073_709_549_568 ? UInt64(number) : nil
        case .string(let string):
            return string.hasPrefix("0x") ? UInt64(string.dropFirst(2), radix: 16) : UInt64(string)
        default:
            return nil
        }
    }

    /// The attributed thread, or the first thread.
    public var attributedThread: Thread? {
        threads.first(where: \.threadAttributed) ?? threads.first
    }

    /// Every distinct binary referenced by the tree.
    public var binaries: [BinaryReference] {
        var seen: [UUID: BinaryReference] = [:]
        var stack = threads.flatMap(\.rootFrames)
        while let frame = stack.popLast() {
            if let uuid = frame.binaryUUID, seen[uuid] == nil {
                seen[uuid] = BinaryReference(uuid: uuid, name: frame.binaryName ?? "?")
            }
            stack.append(contentsOf: frame.subFrames)
        }
        return seen.values.sorted { $0.name < $1.name }
    }
}

/// A binary referenced by a stack trace.
public struct BinaryReference: Sendable, Hashable {
    public var uuid: UUID
    public var name: String
}
