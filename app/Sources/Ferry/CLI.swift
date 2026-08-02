// Locating and running the ferry CLI. The app is a renderer; every action and
// every fact goes through `ferry` so the bash suite keeps covering the logic.

import Foundation

enum FerryCLI {
    /// FERRY_BIN wins (tests, development), then the usual install locations,
    /// then a login shell's PATH. Re-resolved per refresh so an install
    /// mid-session is picked up.
    static func find() -> String? {
        if let env = ProcessInfo.processInfo.environment["FERRY_BIN"],
           FileManager.default.isExecutableFile(atPath: env) {
            return env
        }
        let home = NSHomeDirectory()
        for c in ["/opt/homebrew/bin/ferry", "/usr/local/bin/ferry", "\(home)/.local/bin/ferry"] {
            if FileManager.default.isExecutableFile(atPath: c) { return c }
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["-lc", "command -v ferry"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
        let s = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return s.isEmpty ? nil : s
    }

    /// Run and capture stdout (porcelain reads). Never on the main thread.
    static func run(_ bin: String, _ args: [String]) -> (out: String, status: Int32) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return ("", -1) }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (String(data: data, encoding: .utf8) ?? "", p.terminationStatus)
    }

    /// Run with stdout+stderr merged and streamed line-by-line — this is what
    /// makes a long dry run watchable in the output window instead of a
    /// spinner followed by a wall of text.
    @discardableResult
    static func stream(_ bin: String, _ args: [String],
                       onLine: @escaping (String) -> Void,
                       onExit: @escaping (Int32) -> Void) -> Process? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = args
        // NO_COLOR: the output window renders text, not ANSI escapes
        var env = ProcessInfo.processInfo.environment
        env["NO_COLOR"] = "1"
        p.environment = env
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        var buffer = Data()
        pipe.fileHandleForReading.readabilityHandler = { h in
            let chunk = h.availableData
            if chunk.isEmpty { return }
            buffer.append(chunk)
            while let nl = buffer.firstIndex(of: 0x0A) {
                let line = String(data: buffer[..<nl], encoding: .utf8) ?? ""
                buffer = Data(buffer[buffer.index(after: nl)...])
                DispatchQueue.main.async { onLine(line) }
            }
        }
        p.terminationHandler = { proc in
            pipe.fileHandleForReading.readabilityHandler = nil
            if let tail = String(data: buffer, encoding: .utf8), !tail.isEmpty {
                DispatchQueue.main.async { onLine(tail) }
            }
            DispatchQueue.main.async { onExit(proc.terminationStatus) }
        }
        do { try p.run() } catch {
            DispatchQueue.main.async { onExit(-1) }
            return nil
        }
        return p
    }
}

/// One parsed key=value porcelain snapshot. Unknown keys are ignored so an
/// older app survives a newer CLI.
struct Porcelain {
    var fields: [String: String] = [:]
    subscript(_ k: String) -> String { fields[k] ?? "" }

    static func parse(_ s: String) -> Porcelain {
        var p = Porcelain()
        for line in s.split(separator: "\n") {
            guard let eq = line.firstIndex(of: "=") else { continue }
            p.fields[String(line[..<eq])] = String(line[line.index(after: eq)...])
        }
        return p
    }
}

enum Fmt {
    static func age(_ s: String) -> String {
        guard let v = Int(s), v >= 0 else { return "—" }
        if v < 60 { return "\(v)s" }
        if v < 3600 { return "\(v / 60)m" }
        if v < 86400 { return "\(v / 3600)h" }
        return "\(v / 86400)d"
    }

    static func bytes(_ s: String) -> String {
        guard var v = Double(s) else { return "—" }
        for unit in ["B", "KB", "MB", "GB"] {
            if v < 1024 { return String(format: "%.1f %@", v, unit) }
            v /= 1024
        }
        return String(format: "%.1f TB", v)
    }

    static func ago(_ epoch: Int) -> String {
        let d = Int(Date().timeIntervalSince1970) - epoch
        return age(String(max(d, 0)))
    }
}
