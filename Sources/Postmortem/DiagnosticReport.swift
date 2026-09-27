import Foundation

/// Human-readable reports for sharing, filing bugs or offline symbolication.
public enum DiagnosticReport {
    /// A plain-text report resembling an Apple crash log: header, exception
    /// details and every thread's frames, symbolicated where possible.
    public static func text(for diagnostic: Diagnostic, symbolicator: Symbolicator? = Symbolicator()) -> String {
        var lines: [String] = []
        let meta = diagnostic.metadata
        lines.append("\(diagnostic.kind.displayName): \(diagnostic.title)")
        lines.append(String(repeating: "=", count: min(72, lines[0].count)))
        func add(_ label: String, _ value: String?) {
            if let value, !value.isEmpty { lines.append("\(label.padding(toLength: 18, withPad: " ", startingAt: 0))\(value)") }
        }
        add("App:", meta.bundleIdentifier)
        add("Version:", meta.versionDescription)
        add("OS:", meta.osVersion)
        add("Device:", [meta.deviceType, meta.platformArchitecture].compactMap { $0 }.joined(separator: " "))
        add("TestFlight:", meta.isTestFlightApp.map { $0 ? "yes" : "no" })
        add("Low Power Mode:", meta.lowPowerModeEnabled.map { $0 ? "on" : "off" })
        add("Reported by:", diagnostic.periodEnd.map { ISO8601DateFormatter.string(from: $0, timeZone: .current, formatOptions: [.withInternetDateTime]) })
        lines.append("")
        switch diagnostic.kind {
        case .crash:
            add("Exception:", [meta.exceptionType.map(CrashExplanation.exceptionName), meta.exceptionCode.map { "code \($0)" }].compactMap { $0 }.joined(separator: ", "))
            add("Signal:", meta.signal.map(CrashExplanation.signalName))
            add("Termination:", meta.terminationReason)
            add("VM Region:", meta.virtualMemoryRegionInfo)
            if let objc = meta.objectiveCException {
                add("ObjC Exception:", objc.exceptionName)
                add("Message:", objc.composedMessage)
            }
        case .hang:
            add("Duration:", meta.hangDuration?.formatted)
            add("Type:", diagnostic.hangType)
        case .cpuException:
            add("CPU Time:", meta.totalCPUTime?.formatted)
            add("Sampled Time:", meta.totalSampledTime?.formatted)
        case .diskWriteException:
            add("Writes:", meta.writesCaused?.formatted)
        case .appLaunch:
            add("Launch:", meta.launchDuration?.formatted)
        }
        lines.append("")
        lines.append(diagnostic.summary)
        lines.append("")

        if let trace = diagnostic.stackTrace {
            for (index, thread) in trace.threads.enumerated() {
                let label = trace.callStackPerThread ? "Thread \(index)" : "Samples \(index)"
                lines.append("\(label)\(thread.threadAttributed ? " (attributed)" : ""):")
                let frames = trace.callStackPerThread ? thread.frames : thread.heaviestPath
                for (number, frame) in frames.enumerated() {
                    lines.append(frameLine(number, frame, symbolicator: symbolicator, showSamples: !trace.callStackPerThread))
                }
                lines.append("")
            }
            let binaries = trace.binaries
            if !binaries.isEmpty {
                lines.append("Binary Images:")
                for binary in binaries {
                    let loaded = symbolicator?.hasImage(binary.uuid) == true ? "" : " (not loaded)"
                    lines.append("  \(binary.uuid.uuidString)  \(binary.name)\(loaded)")
                }
            }
        }
        return lines.joined(separator: "\n")
    }

    static func frameLine(_ number: Int, _ frame: StackTrace.Frame, symbolicator: Symbolicator?, showSamples: Bool) -> String {
        let index = String(number).padding(toLength: 4, withPad: " ", startingAt: 0)
        let binary = (frame.binaryName ?? "???").padding(toLength: 30, withPad: " ", startingAt: 0)
        let address = frame.address.map { String(format: "0x%016llx", $0) } ?? String(repeating: " ", count: 18)
        var location: String
        if let symbolicated = symbolicator?.symbolicate(frame), let symbol = symbolicated.symbol {
            location = "\(symbol) + \(symbolicated.symbolOffset ?? 0)"
        } else {
            location = "\(frame.binaryName ?? "???") + \(frame.offsetIntoBinaryTextSegment ?? 0)"
        }
        if showSamples, let samples = frame.sampleCount {
            location += "  [\(samples) samples]"
        }
        return "\(index)\(binary) \(address) \(location)"
    }

    /// A shell script that symbolicates every frame from `binaryNames` with
    /// `atos`, given the matching dSYMs. Use it for Release builds, whose
    /// app symbols are stripped on device.
    ///
    /// Run it as `sh symbolicate.sh /path/to/MyApp.app.dSYM ...`. Each dSYM's
    /// UUID is checked against the report before use.
    public static func atosScript(for diagnostic: Diagnostic, binaryNames: Set<String>? = nil) -> String {
        let trace = diagnostic.stackTrace
        let arch = diagnostic.metadata.platformArchitecture ?? "arm64"
        var frames: [StackTrace.Frame] = []
        for thread in trace?.threads ?? [] {
            frames.append(contentsOf: trace?.callStackPerThread == false ? thread.heaviestPath : thread.frames)
        }
        let wanted = frames.filter { frame in
            guard frame.binaryUUID != nil, frame.offsetIntoBinaryTextSegment != nil else { return false }
            guard let binaryNames else { return !isSystemBinary(frame.binaryName) }
            return frame.binaryName.map(binaryNames.contains) ?? false
        }
        var byBinary: [UUID: (name: String, offsets: [UInt64])] = [:]
        for frame in wanted {
            let uuid = frame.binaryUUID!
            byBinary[uuid, default: (frame.binaryName ?? "?", [])].offsets.append(frame.offsetIntoBinaryTextSegment!)
        }
        var script = """
        #!/bin/sh
        # Symbolicates \(diagnostic.kind.displayName.lowercased()) \(diagnostic.id) with atos.
        # Usage: sh symbolicate.sh MyApp.app.dSYM [more.dSYM ...]
        # Apple arm64 executables load __TEXT at 0x100000000; adjust LOAD if yours differs.
        LOAD=0x100000000

        find_binary() { # uuid -> DWARF file whose UUID matches
          for dsym in "$@"; do
            for dwarf in "$dsym"/Contents/Resources/DWARF/*; do
              if dwarfdump --uuid "$dwarf" 2>/dev/null | grep -qi "$UUID"; then echo "$dwarf"; return; fi
            done
          done
        }

        """
        for (uuid, entry) in byBinary.sorted(by: { $0.value.name < $1.value.name }) {
            let addresses = entry.offsets.map { String(format: "0x%llx", 0x1_0000_0000 + $0) }.joined(separator: " ")
            script += """

            UUID=\(uuid.uuidString)
            BIN=$(find_binary "$@")
            if [ -n "$BIN" ]; then
              echo "== \(entry.name) ($UUID)"
              atos -arch \(arch) -o "$BIN" -l $LOAD \(addresses)
            else
              echo "== \(entry.name): no dSYM with UUID $UUID" >&2
            fi

            """
        }
        return script
    }

    /// Binaries that ship with the OS, which symbolicate on device when the
    /// OS version matches and never need the app's dSYMs.
    static func isSystemBinary(_ name: String?) -> Bool {
        guard let name else { return false }
        return name.hasPrefix("lib") && name.hasSuffix(".dylib")
            || ["UIKitCore", "CoreFoundation", "Foundation", "SwiftUI", "SwiftUICore", "AppKit", "GraphicsServices",
                "FrontBoardServices", "dyld", "QuartzCore", "CoreData", "Combine", "AttributeGraph", "CFNetwork",
                "UIKit", "CoreGraphics", "AVFoundation", "WebKit", "JavaScriptCore", "Network", "RunningBoardServices"].contains(name)
    }
}
