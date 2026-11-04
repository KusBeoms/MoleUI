import Foundation

/// Finds the `mo` entrypoint and runs it as a child process, streaming output.
enum MoleLocator {
    static let overrideKey = "moleExecutablePath"

    static func find() -> URL? {
        var candidates: [String] = []
        if let custom = UserDefaults.standard.string(forKey: overrideKey), !custom.isEmpty {
            candidates.append(custom)
        }
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("mole/mo").path {
            candidates.append(bundled)
        }
        let home = NSHomeDirectory()
        candidates += [
            "/opt/homebrew/bin/mo",
            "/usr/local/bin/mo",
            "\(home)/.local/bin/mo",
            "\(home)/Developer/MoleUI/Mole/mo",
        ]
        return candidates
            .first { FileManager.default.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }
}

enum ANSI {
    private static let pattern = try! NSRegularExpression(pattern: "\u{1B}\\[[0-9;?]*[A-Za-z]|\u{1B}\\][^\u{07}]*\u{07}|\r")

    static func strip(_ s: String) -> String {
        pattern.stringByReplacingMatches(
            in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "")
    }
}

struct MoleResult {
    var exitCode: Int32
    var lines: [String]
}

/// One running `mo` invocation. Cancel terminates the process group.
final class MoleRun: @unchecked Sendable {
    private let process = Process()
    private let lock = NSLock()
    private var buffer = Data()
    private(set) var lines: [String] = []

    func cancel() {
        if process.isRunning { process.terminate() }
    }

    func run(_ args: [String], onLine: @escaping @Sendable (String) -> Void = { _ in }) async throws -> MoleResult {
        guard let exe = MoleLocator.find() else { throw MoleError.notFound }
        process.executableURL = exe
        process.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:" + (env["PATH"] ?? "")
        env["TERM"] = "dumb"
        env["NO_COLOR"] = "1"
        process.environment = env
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        let emit: (Data) -> Void = { [weak self] chunk in
            guard let self else { return }
            self.lock.lock()
            self.buffer.append(chunk)
            var out: [String] = []
            while let nl = self.buffer.firstIndex(of: 0x0A) {
                let lineData = self.buffer.subdata(in: self.buffer.startIndex..<nl)
                self.buffer.removeSubrange(self.buffer.startIndex...nl)
                out.append(ANSI.strip(String(decoding: lineData, as: UTF8.self)))
            }
            self.lines.append(contentsOf: out)
            self.lock.unlock()
            out.forEach(onLine)
        }
        pipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if !d.isEmpty { emit(d) }
        }

        return try await withCheckedThrowingContinuation { cont in
            process.terminationHandler = { [weak self] p in
                guard let self else { return }
                pipe.fileHandleForReading.readabilityHandler = nil
                let rest = pipe.fileHandleForReading.readDataToEndOfFile()
                if !rest.isEmpty { emit(rest + Data([0x0A])) }
                self.lock.lock()
                let all = self.lines
                self.lock.unlock()
                cont.resume(returning: MoleResult(exitCode: p.terminationStatus, lines: all))
            }
            do { try process.run() } catch { cont.resume(throwing: error) }
        }
    }
}

enum MoleError: LocalizedError {
    case notFound
    var errorDescription: String? {
        "Mole CLI(mo)를 찾을 수 없습니다. `brew install mole`로 설치하거나 설정에서 경로를 지정하세요."
    }
}
