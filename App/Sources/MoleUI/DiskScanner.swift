import Foundation

struct DiskEntry: Identifiable, Hashable {
    var id: String { url.path }
    let url: URL
    var name: String { url.lastPathComponent }
    let isDirectory: Bool
    var bytes: Int64
    var isScanning: Bool
}

enum DiskScanner {
    /// Allocated size of a file or directory tree. Does not follow symlinks.
    static func size(of url: URL) -> Int64 {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .isRegularFileKey, .isSymbolicLinkKey]
        guard let v = try? url.resourceValues(forKeys: Set(keys)) else { return 0 }
        if v.isSymbolicLink == true { return 0 }
        if v.isRegularFile == true { return Int64(v.totalFileAllocatedSize ?? 0) }
        guard let e = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in true })
        else { return 0 }
        var total: Int64 = 0
        for case let f as URL in e {
            if Task.isCancelled { return total }
            guard let r = try? f.resourceValues(forKeys: Set(keys)), r.isSymbolicLink != true, r.isRegularFile == true
            else { continue }
            total += Int64(r.totalFileAllocatedSize ?? 0)
        }
        return total
    }

    static func children(of dir: URL) -> [DiskEntry] {
        let items = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [])) ?? []
        return items.map { u in
            let r = try? u.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            let isDir = (r?.isDirectory ?? false) && r?.isSymbolicLink != true
            return DiskEntry(url: u, isDirectory: isDir, bytes: 0, isScanning: true)
        }
    }
}

@MainActor
final class AnalyzeModel: ObservableObject {
    @Published var current: URL
    @Published var entries: [DiskEntry] = []
    @Published var scanning = false
    @Published var hasScanned = false
    @Published var error: String?
    private var task: Task<Void, Never>?
    private var generation = 0

    init() { current = FileManager.default.homeDirectoryForCurrentUser }

    var total: Int64 { entries.reduce(0) { $0 + $1.bytes } }

    func open(_ url: URL) {
        current = url
        scan()
    }

    func up() {
        let parent = current.deletingLastPathComponent()
        if parent.path != current.path { open(parent) }
    }

    func scan() {
        task?.cancel()
        generation += 1
        hasScanned = true
        let gen = generation
        let dir = current
        let kids = DiskScanner.children(of: dir)
        entries = kids
        scanning = !kids.isEmpty
        error = nil
        if kids.isEmpty {
            error = FileManager.default.isReadableFile(atPath: dir.path)
                ? "비어 있는 폴더입니다." : "읽을 수 없는 폴더입니다. 시스템 설정에서 전체 디스크 접근 권한을 확인하세요."
        }
        task = Task { [weak self] in
            await withTaskGroup(of: (URL, Int64).self) { group in
                var iterator = kids.makeIterator()
                var running = 0
                func addNext() {
                    guard let e = iterator.next() else { return }
                    group.addTask { (e.url, DiskScanner.size(of: e.url)) }
                    running += 1
                }
                for _ in 0..<6 { addNext() }
                while running > 0, let (url, bytes) = await group.next() {
                    running -= 1
                    addNext()
                    await MainActor.run {
                        guard let self, self.generation == gen,
                              let i = self.entries.firstIndex(where: { $0.url == url }) else { return }
                        self.entries[i].bytes = bytes
                        self.entries[i].isScanning = false
                        self.entries.sort { $0.bytes > $1.bytes }
                    }
                }
            }
            await MainActor.run {
                if let self, self.generation == gen { self.scanning = false }
            }
        }
    }

    /// Moves to the Trash (recoverable). Refuses anything outside the user's home.
    func trash(_ entry: DiskEntry) {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        let path = entry.url.standardizedFileURL.path
        guard path.hasPrefix(home + "/"), path != home else {
            error = "홈 폴더 밖의 항목은 앱에서 삭제하지 않습니다."
            return
        }
        do {
            try FileManager.default.trashItem(at: entry.url, resultingItemURL: nil)
            entries.removeAll { $0.url == entry.url }
        } catch {
            self.error = "휴지통으로 이동하지 못했습니다: \(error.localizedDescription)"
        }
    }
}
