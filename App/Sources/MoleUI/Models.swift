import Foundation
import AppKit
import SwiftUI

/// Dry-run preview + real run for `mo clean` / `mo optimize`.
@MainActor
final class TaskModel: ObservableObject {
    enum Phase { case idle, previewing, previewed, running, finished }

    let command: String
    @Published var phase: Phase = .idle
    @Published var sections: [PreviewSection] = []
    @Published var summary = PreviewSummary()
    @Published var log: [String] = []
    @Published var live: [PreviewSection] = []
    @Published var error: String?
    @Published var exitCode: Int32?
    private var run: MoleRun?

    init(command: String) { self.command = command }

    var busy: Bool { phase == .previewing || phase == .running }

    func preview() {
        start(args: [command, "--dry-run"], phase: .previewing, done: .previewed)
    }

    func execute() {
        start(args: [command], phase: .running, done: .finished)
    }

    func cancel() {
        run?.cancel()
    }

    private func start(args: [String], phase: Phase, done: Phase) {
        guard !busy else { return }
        self.phase = phase
        error = nil
        exitCode = nil
        log = []
        live = []
        if phase == .previewing { sections = []; summary = PreviewSummary() }
        let r = MoleRun()
        run = r
        Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await r.run(args) { [weak self] line in
                    Task { @MainActor in
                        guard let self else { return }
                        self.log.append(line)
                        withAnimation(.smooth(duration: 0.35)) { self.live = Parsing.sections(from: self.log) }
                    }
                }
                exitCode = result.exitCode
                if phase == .previewing {
                    sections = Parsing.sections(from: result.lines)
                    summary = Parsing.summary(from: result.lines)
                }
                if result.exitCode != 0 && result.exitCode != 15 {
                    error = "mo \(args.joined(separator: " "))가 종료 코드 \(result.exitCode)로 끝났습니다."
                }
                self.phase = done
            } catch {
                self.error = error.localizedDescription
                self.phase = .idle
            }
            run = nil
        }
    }
}

@MainActor
final class UninstallModel: ObservableObject {
    @Published var apps: [InstalledApp] = []
    @Published var loading = false
    @Published var error: String?
    @Published var previewLog: [String] = []
    @Published var plan = UninstallPlan()
    @Published var previewing = false
    @Published var sizes: [String: Int64] = [:]

    func load() {
        guard !loading else { return }
        loading = true
        error = nil
        Task { [weak self] in
            guard let self else { return }
            do {
                let r = try await MoleRun().run(["uninstall", "--list"])
                let json = r.lines.joined(separator: "\n")
                if let start = json.firstIndex(of: "["),
                   let data = String(json[start...]).data(using: .utf8) {
                    apps = try JSONDecoder().decode([InstalledApp].self, from: data)
                        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                } else {
                    error = "앱 목록을 읽지 못했습니다."
                }
            } catch {
                self.error = error.localizedDescription
            }
            loading = false
        }
    }

    func size(of app: InstalledApp) {
        guard sizes[app.path] == nil else { return }
        Task.detached(priority: .utility) {
            let b = DiskScanner.size(of: URL(fileURLWithPath: app.path))
            await MainActor.run { self.sizes[app.path] = b }
        }
    }

    func preview(_ app: InstalledApp) {
        guard !previewing else { return }
        previewing = true
        previewLog = []
        plan = UninstallPlan()
        Task { [weak self] in
            guard let self else { return }
            do {
                let r = try await MoleRun().run(["uninstall", "--dry-run", app.uninstall_name]) { [weak self] l in
                    Task { @MainActor in
                        guard let self else { return }
                        self.previewLog.append(l)
                        withAnimation(.smooth(duration: 0.3)) { self.plan = UninstallPlan(lines: self.previewLog) }
                    }
                }
                if r.exitCode != 0 { error = "미리보기가 종료 코드 \(r.exitCode)로 끝났습니다." }
            } catch {
                self.error = error.localizedDescription
            }
            previewing = false
        }
    }
}

enum Terminal {
    /// Runs `mo <args>` in Terminal.app so interactive prompts and sudo work normally.
    static func runInteractive(_ args: String) {
        guard let exe = MoleLocator.find() else { return }
        let cmd = "\(shellQuote(exe.path)) \(args)"
        let script = "tell application \"Terminal\"\nactivate\ndo script \"\(cmd.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\"\nend tell"
        var err: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&err)
    }

    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
