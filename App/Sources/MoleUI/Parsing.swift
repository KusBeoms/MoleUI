import Foundation

enum ItemKind { case clean, skipped, hint, empty, info }

struct PreviewItem: Identifiable {
    let id = UUID()
    var label: String
    var detail: String
    var bytes: Int64?
    var kind: ItemKind
}

struct PreviewSection: Identifiable {
    let id = UUID()
    var name: String
    var items: [PreviewItem] = []
    /// Matches the CLI headline total, which leaves out Homebrew-style "would free" estimates.
    var totalBytes: Int64 {
        items.filter { $0.kind == .clean && !$0.detail.contains("would free") }.compactMap(\.bytes).reduce(0, +)
    }
    var isEmpty: Bool { items.allSatisfy { $0.kind == .empty } }
}

struct PreviewSummary {
    var potential: String?
    var items: Int?
    var categories: Int?
}

enum Parsing {
    private static let sizeRegex = try! NSRegularExpression(pattern: "(\\d+(?:\\.\\d+)?)\\s?(B|KB|MB|GB|TB)\\b")

    static func bytes(in text: String) -> Int64? {
        let ns = text as NSString
        guard let m = sizeRegex.matches(in: text, range: NSRange(location: 0, length: ns.length)).last,
              let value = Double(ns.substring(with: m.range(at: 1)))
        else { return nil }
        let mult: Double
        switch ns.substring(with: m.range(at: 2)) {
        case "KB": mult = 1024
        case "MB": mult = 1024 * 1024
        case "GB": mult = 1024 * 1024 * 1024
        case "TB": mult = 1024 * 1024 * 1024 * 1024
        default: mult = 1
        }
        return Int64(value * mult)
    }

    /// Parses the `➤ Section` / `  → item · detail` layout shared by `mo clean` and `mo optimize`.
    static func sections(from lines: [String]) -> [PreviewSection] {
        var result: [PreviewSection] = []
        for raw in lines {
            let line = raw.trimmingCharacters(in: .newlines)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("➤") {
                let name = trimmed.dropFirst().trimmingCharacters(in: .whitespaces)
                result.append(PreviewSection(name: name))
                continue
            }
            guard !result.isEmpty else { continue }
            // Deeper-indented rows are sub-details of the previous item.
            let indent = line.prefix { $0 == " " }.count
            guard indent <= 3, let first = trimmed.first else { continue }
            let body = trimmed.dropFirst().trimmingCharacters(in: .whitespaces)
            let kind: ItemKind
            switch first {
            case "→": kind = .clean
            case "◎": kind = .skipped
            case "⊙": kind = .hint
            case "✓": kind = body.lowercased().contains("nothing to clean") ? .empty : .info
            case "-": kind = .info
            default: continue
            }
            let parts = body.components(separatedBy: " · ")
            let label = parts.first ?? body
            let detail = parts.dropFirst().joined(separator: " · ")
            let b = bytes(in: detail.isEmpty ? body : detail)
            result[result.count - 1].items.append(
                PreviewItem(label: label, detail: detail, bytes: kind == .clean || kind == .hint ? b : nil, kind: kind))
        }
        return result
    }

    static func summary(from lines: [String]) -> PreviewSummary {
        var s = PreviewSummary()
        for line in lines where line.contains("Potential space:") {
            for part in line.components(separatedBy: "|") {
                let p = part.trimmingCharacters(in: .whitespaces)
                if p.hasPrefix("Potential space:") { s.potential = String(p.dropFirst(16)).trimmingCharacters(in: .whitespaces) }
                if p.hasPrefix("Items:") { s.items = Int(p.dropFirst(6).trimmingCharacters(in: .whitespaces)) }
                if p.hasPrefix("Categories:") { s.categories = Int(p.dropFirst(11).trimmingCharacters(in: .whitespaces)) }
            }
        }
        return s
    }
}

struct InstalledApp: Identifiable, Decodable, Hashable {
    var id: String { path }
    let name: String
    let bundle_id: String
    let source: String
    let uninstall_name: String
    let path: String
}

enum Fmt {
    static func bytes(_ b: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: b, countStyle: .binary)
    }
}

struct PlanEntry: Identifiable {
    let id = UUID()
    let path: String
    let size: String?
}

/// Structured view of `mo uninstall --dry-run <app>` output.
struct UninstallPlan {
    var remove: [PlanEntry] = []
    var kept: [PlanEntry] = []
    var done = false
    var isEmpty: Bool { remove.isEmpty && kept.isEmpty }

    init() {}
    init(lines: [String]) {
        enum Block { case none, remove, kept }
        var block = Block.none
        for raw in lines {
            let t = raw.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("Files to be removed") { block = .remove; continue }
            if t.hasPrefix("Personal data kept") { block = .kept; continue }
            if t.hasPrefix("Dry run complete") { done = true; block = .none; continue }
            guard let first = t.first, "✓⊙".contains(first) else { continue }
            let body = t.dropFirst().trimmingCharacters(in: .whitespaces)
            let parts = body.components(separatedBy: " , ")
            let entry = PlanEntry(path: parts[0], size: parts.count > 1 ? parts[1] : nil)
            switch block {
            case .remove: if first == "✓" { remove.append(entry) }
            case .kept: kept.append(entry)
            case .none: break
            }
        }
    }
}

extension Parsing {
    /// Space freed reported by a real run, e.g. "Space freed: 1.2GB".
    static func freed(from lines: [String]) -> Int64? {
        lines.last { $0.localizedCaseInsensitiveContains("freed") && bytes(in: $0) != nil }.flatMap { bytes(in: $0) }
    }
}
