import Foundation

/// Turns a crash's exception type, signal and termination reason into a
/// title and a plain-language explanation.
public struct CrashExplanation: Sendable, Hashable {
    public var title: String
    public var summary: String

    public init(_ metadata: DiagnosticMetadata) {
        let exception = metadata.exceptionType.map(Self.exceptionName)
        let signal = metadata.signal.map(Self.signalName)
        let termination = metadata.terminationReason.flatMap(TerminationReason.init)

        if let objc = metadata.objectiveCException, let name = objc.exceptionName {
            title = name
            summary = "Uncaught Objective-C exception \(name)" + (objc.composedMessage.map { ": \($0)" } ?? ".")
            return
        }
        if let known = termination?.knownCode {
            title = known.title
            summary = known.summary
            return
        }

        switch (exception, signal) {
        case let (exception?, signal?): title = "\(exception) (\(signal))"
        case let (exception?, nil): title = exception
        case let (nil, signal?): title = signal
        default: title = "Crash"
        }

        switch (metadata.exceptionType, metadata.signal) {
        case (6, _), (_, 5):
            summary = "The app hit a trap. In Swift this is usually a runtime check: force-unwrapping nil, an array index out of range, integer overflow, a failed `as!` cast, or `fatalError`/`precondition`."
        case (1, _):
            var text = "The app accessed memory it doesn't own, such as a dangling pointer, a deallocated object, or a data race."
            if let region = metadata.virtualMemoryRegionInfo, !region.isEmpty {
                text += " Address: \(region)"
            }
            summary = text
        case (2, _), (_, 4):
            summary = "The CPU tried to run an illegal instruction, often a Swift runtime trap or a corrupted function pointer."
        case (3, _), (_, 8):
            summary = "An arithmetic error, such as integer division by zero."
        case (10, _), (_, 6):
            summary = "The process aborted, usually because of an uncaught exception, a failed assertion in a framework, or a call to abort()."
        case (11, _):
            summary = "The app exceeded a system resource limit (CPU, memory, or wakeups) and was terminated."
        case (12, _):
            summary = "The app violated a guarded resource, for example by closing a file descriptor the system owns."
        case (_, 9):
            summary = "The system killed the app. Check the termination reason for why."
        default:
            summary = "The app crashed."
        }
        if let termination, termination.knownCode == nil {
            summary += " Termination reason: \(termination.raw)."
        }
    }

    static func exceptionName(_ code: Int) -> String {
        switch code {
        case 1: "EXC_BAD_ACCESS"
        case 2: "EXC_BAD_INSTRUCTION"
        case 3: "EXC_ARITHMETIC"
        case 4: "EXC_EMULATION"
        case 5: "EXC_SOFTWARE"
        case 6: "EXC_BREAKPOINT"
        case 7: "EXC_SYSCALL"
        case 8: "EXC_MACH_SYSCALL"
        case 9: "EXC_RPC_ALERT"
        case 10: "EXC_CRASH"
        case 11: "EXC_RESOURCE"
        case 12: "EXC_GUARD"
        case 13: "EXC_CORPSE_NOTIFY"
        default: "EXC_\(code)"
        }
    }

    static func signalName(_ signal: Int) -> String {
        switch signal {
        case 1: "SIGHUP"
        case 2: "SIGINT"
        case 3: "SIGQUIT"
        case 4: "SIGILL"
        case 5: "SIGTRAP"
        case 6: "SIGABRT"
        case 7: "SIGEMT"
        case 8: "SIGFPE"
        case 9: "SIGKILL"
        case 10: "SIGBUS"
        case 11: "SIGSEGV"
        case 12: "SIGSYS"
        case 13: "SIGPIPE"
        case 14: "SIGALRM"
        case 15: "SIGTERM"
        default: "signal \(signal)"
        }
    }
}

/// A parsed termination reason, such as
/// `"Namespace FRONTBOARD, Code 0x8badf00d"`.
public struct TerminationReason: Sendable, Hashable {
    public var raw: String
    public var namespace: String?
    public var code: UInt64?

    public init?(_ raw: String) {
        guard !raw.isEmpty else { return nil }
        self.raw = raw
        let scanner = Scanner(string: raw)
        if scanner.scanString("Namespace") != nil {
            namespace = scanner.scanUpToString(",")?.trimmingCharacters(in: .whitespaces)
            _ = scanner.scanString(",")
            if scanner.scanString("Code") != nil {
                let token = scanner.scanUpToCharacters(from: .whitespaces)?.trimmingCharacters(in: CharacterSet(charactersIn: ","))
                if let token {
                    code = token.lowercased().hasPrefix("0x") ? UInt64(token.dropFirst(2), radix: 16) : UInt64(token)
                }
            }
        }
    }

    /// Well-known termination codes.
    public var knownCode: (title: String, summary: String)? {
        switch code {
        case 0x8badf00d:
            ("Watchdog Timeout", "The system watchdog killed the app because it took too long to launch, resume, or respond (0x8badf00d). Look for blocking work on the main thread.")
        case 0xdead10cc:
            ("Held Lock in Background", "The app was killed for holding a file lock or SQLite database lock while suspended (0xdead10cc).")
        case 0xc00010ff:
            ("Thermal Kill", "The system killed the app because the device was too hot (0xc00010ff).")
        case 0xbaaaaaad:
            ("Stackshot", "Not a crash: the system recorded a stackshot of all processes (0xbaaaaaad).")
        case 0xbad22222:
            ("VoIP Resume Loop", "A VoIP app was killed for resuming too often (0xbad22222).")
        case 0xdeadfa11:
            ("Force Quit", "The user force-quit the app (0xdeadfa11).")
        case 0xc51bad01, 0xc51bad02, 0xc51bad03:
            ("Background Time Limit", "The system killed the app for using too much CPU time or taking too long in the background (\(String(format: "0x%llx", code ?? 0))).")
        default:
            nil
        }
    }

    public static func == (lhs: TerminationReason, rhs: TerminationReason) -> Bool { lhs.raw == rhs.raw }
    public func hash(into hasher: inout Hasher) { hasher.combine(raw) }
}
