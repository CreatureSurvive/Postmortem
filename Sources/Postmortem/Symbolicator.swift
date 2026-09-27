import Foundation
import MachO

/// A frame with its symbol, when it could be resolved.
public struct SymbolicatedFrame: Sendable, Hashable {
    public var frame: StackTrace.Frame
    /// The demangled symbol name, such as `ContentView.load() async`.
    public var symbol: String?
    /// Bytes from the start of the symbol.
    public var symbolOffset: UInt64?
    /// Whether the frame's binary is loaded in this process (same build or
    /// same OS version), which is required to resolve it on device.
    public var imageIsLoaded: Bool

    /// `"MyApp  ContentView.load() + 52"`, or the binary and offset.
    public var description: String {
        let binary = frame.binaryName ?? "???"
        if let symbol {
            return "\(binary)  \(symbol) + \(symbolOffset ?? 0)"
        }
        return "\(binary)  +\(frame.offsetIntoBinaryTextSegment.map { String(format: "0x%llx", $0) } ?? "?")"
    }
}

/// Resolves frames to symbols on device, using the binaries loaded in the
/// current process.
///
/// MetricKit reports frames as a binary UUID plus an offset. When the same
/// build of the app is running, and for system libraries when the OS
/// version matches, the binary is loaded and the offset can be turned back
/// into a symbol:
///
/// - System libraries resolve through `dladdr`.
/// - The app's own binaries resolve through their full symbol table, which
///   is present in Debug builds. Stripped Release builds keep only exported
///   symbols; symbolicate those offline with the dSYM (see
///   ``DiagnosticReport/atosScript(for:)``).
///
/// Swift symbols are demangled.
public final class Symbolicator: Sendable {
    struct Image: Sendable {
        let header: UInt
        let slide: Int
        let path: String
        let inSharedCache: Bool
    }

    private let images: [UUID: Image]
    private let cache = SymbolCache()

    /// A symbolicator for the images loaded right now.
    public init() {
        images = Self.loadedImages()
    }

    /// Whether frames from `uuid` can be resolved in this process.
    public func hasImage(_ uuid: UUID) -> Bool {
        images[uuid] != nil
    }

    /// The runtime address of a frame in this process, if its binary is loaded.
    public func runtimeAddress(of frame: StackTrace.Frame) -> UInt? {
        guard let uuid = frame.binaryUUID, let image = images[uuid], let offset = frame.offsetIntoBinaryTextSegment else { return nil }
        let (address, overflow) = image.header.addingReportingOverflow(UInt(truncatingIfNeeded: offset))
        return overflow ? nil : address
    }

    public func symbolicate(_ frame: StackTrace.Frame) -> SymbolicatedFrame {
        guard let uuid = frame.binaryUUID, let image = images[uuid], let address = runtimeAddress(of: frame) else {
            return SymbolicatedFrame(frame: frame, symbol: nil, symbolOffset: nil, imageIsLoaded: false)
        }
        // Return addresses point after the call; look up the call itself.
        let lookup = address > image.header ? address - 1 : address
        if let cached = cache.value(for: lookup) {
            return SymbolicatedFrame(frame: frame, symbol: cached.name, symbolOffset: cached.name == nil ? nil : UInt64(address - cached.start), imageIsLoaded: true)
        }
        var best = Self.dladdrSymbol(lookup)
        if !image.inSharedCache, let local = SymbolTable.nearestSymbol(to: lookup, header: image.header, slide: image.slide) {
            if best == nil || local.start > best!.start { best = local }
        }
        // A symbol far below the address is a stripped binary's nearest
        // export, not the real function.
        if let found = best, address - found.start > 0x10_0000 || found.name.contains("mh_execute_header") {
            best = nil
        }
        let name = best.map { Demangler.demangle($0.name) }
        cache.store(lookup, name: name, start: best?.start ?? 0)
        return SymbolicatedFrame(frame: frame, symbol: name, symbolOffset: best.map { UInt64(address - $0.start) }, imageIsLoaded: true)
    }

    public func symbolicate(_ frames: [StackTrace.Frame]) -> [SymbolicatedFrame] {
        frames.map(symbolicate)
    }

    // MARK: - dyld

    static func loadedImages() -> [UUID: Image] {
        var result: [UUID: Image] = [:]
        for index in 0..<_dyld_image_count() {
            guard let header = _dyld_get_image_header(index), let uuid = uuid(of: header) else { continue }
            let path = String(cString: _dyld_get_image_name(index))
            let inCache = header.pointee.flags & 0x8000_0000 != 0 // MH_DYLIB_IN_CACHE
            result[uuid] = Image(header: UInt(bitPattern: header), slide: _dyld_get_image_vmaddr_slide(index), path: path, inSharedCache: inCache)
        }
        return result
    }

    static func uuid(of header: UnsafePointer<mach_header>) -> UUID? {
        var result: UUID?
        LoadCommands.forEach(header) { command, pointer in
            if command.cmd == UInt32(LC_UUID) {
                let uuidCommand = pointer.assumingMemoryBound(to: uuid_command.self).pointee
                result = UUID(uuid: uuidCommand.uuid)
                return false
            }
            return true
        }
        return result
    }

    static func dladdrSymbol(_ address: UInt) -> (name: String, start: UInt)? {
        var info = Dl_info()
        guard dladdr(UnsafeRawPointer(bitPattern: address), &info) != 0, let name = info.dli_sname, let start = info.dli_saddr else { return nil }
        return (String(cString: name), UInt(bitPattern: start))
    }
}

/// Iterates a Mach-O image's load commands in memory.
enum LoadCommands {
    static func forEach(_ header: UnsafePointer<mach_header>, _ body: (load_command, UnsafeRawPointer) -> Bool) {
        let is64 = header.pointee.magic == MH_MAGIC_64
        var pointer = UnsafeRawPointer(header).advanced(by: is64 ? MemoryLayout<mach_header_64>.size : MemoryLayout<mach_header>.size)
        for _ in 0..<header.pointee.ncmds {
            let command = pointer.assumingMemoryBound(to: load_command.self).pointee
            guard command.cmdsize > 0, body(command, pointer) else { return }
            pointer = pointer.advanced(by: Int(command.cmdsize))
        }
    }
}

/// Reads an image's `LC_SYMTAB` from its mapped `__LINKEDIT` segment, which
/// includes local (non-exported) symbols that `dladdr` can't see.
enum SymbolTable {
    static func nearestSymbol(to address: UInt, header: UInt, slide: Int) -> (name: String, start: UInt)? {
        guard let headerPointer = UnsafePointer<mach_header>(bitPattern: header), headerPointer.pointee.magic == MH_MAGIC_64 else { return nil }
        var symtab: symtab_command?
        var linkedit: segment_command_64?
        LoadCommands.forEach(headerPointer) { command, pointer in
            if command.cmd == UInt32(LC_SYMTAB) {
                symtab = pointer.assumingMemoryBound(to: symtab_command.self).pointee
            } else if command.cmd == UInt32(LC_SEGMENT_64) {
                let segment = pointer.assumingMemoryBound(to: segment_command_64.self).pointee
                if segmentName(segment) == "__LINKEDIT" { linkedit = segment }
            }
            return true
        }
        guard let symtab, let linkedit, symtab.nsyms > 0 else { return nil }
        let linkeditBase = Int(linkedit.vmaddr) + slide - Int(linkedit.fileoff)
        guard let symbols = UnsafePointer<nlist_64>(bitPattern: linkeditBase + Int(symtab.symoff)),
              let strings = UnsafePointer<CChar>(bitPattern: linkeditBase + Int(symtab.stroff))
        else { return nil }
        let target = UInt64(Int(address) - slide)
        var bestValue: UInt64 = 0
        var bestIndex: Int?
        for index in 0..<Int(symtab.nsyms) {
            let symbol = symbols[index]
            // Defined in a section, and not a debugging (stab) entry.
            guard symbol.n_type & UInt8(N_STAB) == 0, symbol.n_type & UInt8(N_TYPE) == UInt8(N_SECT) else { continue }
            let value = symbol.n_value
            if value <= target, value >= bestValue, symbol.n_un.n_strx > 0 {
                bestValue = value
                bestIndex = index
            }
        }
        guard let bestIndex, UInt32(symbols[bestIndex].n_un.n_strx) < symtab.strsize else { return nil }
        let name = String(cString: strings.advanced(by: Int(symbols[bestIndex].n_un.n_strx)))
        guard !name.isEmpty else { return nil }
        return (name, UInt(Int(bestValue) + slide))
    }

    static func segmentName(_ segment: segment_command_64) -> String {
        withUnsafeBytes(of: segment.segname) { buffer in
            String(decoding: buffer.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
    }
}

/// Demangles Swift symbols with the runtime's `swift_demangle`.
public enum Demangler {
    private typealias DemangleFunction = @convention(c) (UnsafePointer<CChar>?, Int, UnsafeMutablePointer<CChar>?, UnsafeMutablePointer<Int>?, UInt32) -> UnsafeMutablePointer<CChar>?

    private static let function: DemangleFunction? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "swift_demangle") else { return nil } // RTLD_DEFAULT
        return unsafeBitCast(symbol, to: DemangleFunction.self)
    }()

    /// Demangles `symbol` if it's a Swift symbol, stripping the leading
    /// underscore C symbols carry. Other names are returned as-is.
    public static func demangle(_ symbol: String) -> String {
        var name = symbol
        if name.hasPrefix("_$s") || name.hasPrefix("_$S") || name.hasPrefix("__T") { name.removeFirst() }
        guard name.hasPrefix("$s") || name.hasPrefix("$S") || name.hasPrefix("_T"), let function else {
            return symbol.hasPrefix("_") && !symbol.hasPrefix("__") ? String(symbol.dropFirst()) : symbol
        }
        return name.withCString { pointer in
            guard let result = function(pointer, strlen(pointer), nil, nil, 0) else { return name }
            defer { free(result) }
            return String(cString: result)
        }
    }
}

/// A small thread-safe address cache.
final class SymbolCache: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [UInt: (name: String?, start: UInt)] = [:]

    func value(for address: UInt) -> (name: String?, start: UInt)? {
        lock.withLock { entries[address] }
    }

    func store(_ address: UInt, name: String?, start: UInt) {
        lock.withLock {
            if entries.count > 10_000 { entries.removeAll() }
            entries[address] = (name, start)
        }
    }
}
