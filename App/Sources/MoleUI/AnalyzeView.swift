import SwiftUI
import AppKit

enum Treemap {
    /// Squarified treemap. `values` must be sorted descending and positive.
    static func layout(_ values: [Double], in rect: CGRect) -> [CGRect] {
        var rects = [CGRect](repeating: .zero, count: values.count)
        let total = values.reduce(0, +)
        guard total > 0, rect.width > 0, rect.height > 0 else { return rects }
        let scale = Double(rect.width * rect.height) / total
        let areas = values.map { $0 * scale }
        var rem = rect
        var i = 0
        func worst(_ r: [Double], _ s: Double) -> Double {
            let sum = r.reduce(0, +)
            return max(s * s * r.max()! / (sum * sum), sum * sum / (s * s * r.min()!))
        }
        while i < areas.count {
            let side = Double(min(rem.width, rem.height))
            var row = [areas[i]]
            var j = i + 1
            while j < areas.count, worst(row + [areas[j]], side) <= worst(row, side) { row.append(areas[j]); j += 1 }
            let sum = row.reduce(0, +)
            if rem.width >= rem.height {
                let w = CGFloat(sum / Double(rem.height))
                var y = rem.minY
                for (k, a) in row.enumerated() {
                    let h = CGFloat(a) / w
                    rects[i + k] = CGRect(x: rem.minX, y: y, width: w, height: h)
                    y += h
                }
                rem = CGRect(x: rem.minX + w, y: rem.minY, width: max(rem.width - w, 0), height: rem.height)
            } else {
                let h = CGFloat(sum / Double(rem.width))
                var x = rem.minX
                for (k, a) in row.enumerated() {
                    let w = CGFloat(a) / h
                    rects[i + k] = CGRect(x: x, y: rem.minY, width: w, height: h)
                    x += w
                }
                rem = CGRect(x: rem.minX, y: rem.minY + h, width: rem.width, height: max(rem.height - h, 0))
            }
            i = j
        }
        return rects
    }
}

private struct Tile: Identifiable {
    let id: String
    let entry: DiskEntry?
    let label: String
    let bytes: Int64
    let rect: CGRect
}

struct AnalyzeView: View {
    @EnvironmentObject var model: AnalyzeModel
    @State private var pendingTrash: DiskEntry?

    var body: some View {
        Group {
            if !model.hasScanned { intro } else { browser }
        }
        .confirmationDialog("휴지통으로 이동할까요?", isPresented: .init(get: { pendingTrash != nil }, set: { if !$0 { pendingTrash = nil } }), titleVisibility: .visible, presenting: pendingTrash) { e in
            Button("“\(e.name)” 휴지통으로 이동", role: .destructive) { model.trash(e) }
            Button("취소", role: .cancel) {}
        } message: { e in
            Text("\(Fmt.bytes(e.bytes)) · 휴지통에서 되돌릴 수 있습니다.")
        }
    }

    private var intro: some View {
        VStack(spacing: 20) {
            Spacer(minLength: 0)
            PlanetView(kind: .jupiter, size: 340)
            Text("어디에 얼마나 쓰였는지\n한눈에 펼쳐 보세요")
                .font(.system(size: 20, design: .serif)).multilineTextAlignment(.center)
                .foregroundStyle(.white.opacity(0.85)).lineSpacing(6)
            Button("디스크 살펴보기") { model.scan() }.buttonStyle(PillButtonStyle())
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity).padding(.bottom, 24)
    }

    private var browser: some View {
        HStack(alignment: .top, spacing: 16) {
            sidebar.frame(width: 250)
            VStack(spacing: 12) {
                topBar
                if let e = model.error {
                    Text(e).font(.callout).foregroundStyle(.orange).frame(maxWidth: .infinity, alignment: .leading)
                }
                treemap
            }
        }
        .padding(.horizontal, 24).padding(.bottom, 24)
    }

    private var sidebar: some View {
        VStack(spacing: 10) {
            PlanetView(kind: .jupiter, size: 170, spin: model.scanning ? 48 : 1)
            Text("\(model.entries.count)개 항목, \(Fmt.bytes(model.total))")
                .font(.system(.callout, design: .monospaced)).foregroundStyle(.white.opacity(0.7))
            Text("현재 폴더").font(.caption.weight(.semibold)).foregroundStyle(.white.opacity(0.5)).frame(maxWidth: .infinity, alignment: .leading)
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(model.entries) { e in
                        Button { if e.isDirectory { model.open(e.url) } } label: {
                            HStack {
                                Image(systemName: e.isDirectory ? "folder" : "doc").frame(width: 18).foregroundStyle(.white.opacity(0.6))
                                VStack(alignment: .leading, spacing: 0) {
                                    Text(e.name).lineLimit(1)
                                    Group { if e.isScanning { Text("계산 중…") } else { Text(Fmt.bytes(e.bytes)) } }
                                        .font(.caption).foregroundStyle(.white.opacity(0.55))
                                }
                                Spacer()
                                if e.isDirectory { Image(systemName: "chevron.right").font(.caption).foregroundStyle(.white.opacity(0.35)) }
                            }
                            .padding(.horizontal, 8).padding(.vertical, 6).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .contextMenu { menu(e) }
                    }
                }
            }
            .scrollIndicators(.hidden)
            Text("우클릭: 열기 / 휴지통").font(.caption2).foregroundStyle(.white.opacity(0.4))
        }
    }

    private var topBar: some View {
        HStack(spacing: 8) {
            Button { model.up() } label: { Image(systemName: "chevron.up") }.buttonStyle(.glass).help("상위 폴더")
            breadcrumb
            Spacer()
            if model.scanning { ProgressView().controlSize(.small) }
            Text(Fmt.bytes(model.total)).font(.headline).monospacedDigit()
            Button("폴더 선택…") { choose() }.buttonStyle(.glass)
            Button { model.scan() } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.glass).help("다시 스캔")
        }
    }

    private var breadcrumb: some View {
        let comps = Array(model.current.pathComponents.dropFirst())
        let shown = Array(comps.suffix(3))
        return HStack(spacing: 4) {
            ForEach(Array(shown.enumerated()), id: \.offset) { i, name in
                if i > 0 { Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.white.opacity(0.4)) }
                Button(name) {
                    let upTo = comps.count - shown.count + i + 1
                    model.open(URL(fileURLWithPath: "/" + comps.prefix(upTo).joined(separator: "/")))
                }
                .buttonStyle(.plain)
                .fontWeight(i == shown.count - 1 ? .bold : .regular)
                .foregroundStyle(i == shown.count - 1 ? .white : .white.opacity(0.6))
            }
        }
    }

    private var treemap: some View {
        GeometryReader { geo in
            let tiles = makeTiles(in: CGRect(origin: .zero, size: geo.size))
            ZStack(alignment: .topLeading) {
                ForEach(tiles) { t in
                    tile(t)
                        .frame(width: max(t.rect.width - 4, 0), height: max(t.rect.height - 4, 0))
                        .position(x: t.rect.midX, y: t.rect.midY)
                        .transition(.opacity.combined(with: .scale(scale: 0.96)))
                }
                if tiles.isEmpty && model.scanning {
                    ProgressView("크기 계산 중…").frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            
        }
    }

    private func makeTiles(in rect: CGRect) -> [Tile] {
        let sized = model.entries.filter { $0.bytes > 0 }
        let total = Double(sized.reduce(0) { $0 + $1.bytes })
        guard total > 0 else { return [] }
        let big = sized.filter { Double($0.bytes) / total >= 0.015 }
        let small = sized.filter { Double($0.bytes) / total < 0.015 }
        var items: [(String, DiskEntry?, String, Int64)] = big.map { ($0.id, $0, $0.name, $0.bytes) }
        if !small.isEmpty {
            items.append(("__rest", nil, "\(small.count)개 항목", small.reduce(0) { $0 + $1.bytes }))
            items.sort { $0.3 > $1.3 }
        }
        let rects = Treemap.layout(items.map { Double($0.3) }, in: rect)
        return zip(items, rects).map { Tile(id: $0.0.0, entry: $0.0.1, label: $0.0.2, bytes: $0.0.3, rect: $0.1) }
    }

    private static let palette: [Color] = [
        Color(red: 0.55, green: 0.42, blue: 0.35), Color(red: 0.62, green: 0.36, blue: 0.24),
        Color(red: 0.50, green: 0.43, blue: 0.47), Color(red: 0.57, green: 0.43, blue: 0.24),
        Color(red: 0.40, green: 0.36, blue: 0.30), Color(red: 0.48, green: 0.36, blue: 0.38),
    ]

    private func color(for t: Tile) -> Color {
        guard t.entry != nil else { return Color(red: 0.40, green: 0.36, blue: 0.31) }
        let h = t.label.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        return Self.palette[h % Self.palette.count]
    }

    @ViewBuilder private func tile(_ t: Tile) -> some View {
        let roomy = t.rect.width > 96 && t.rect.height > 54
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous).fill(color(for: t).opacity(0.9))
            if roomy {
                VStack(spacing: 3) {
                    Label(t.label, systemImage: t.entry == nil ? "square.grid.2x2" : (t.entry!.isDirectory ? "folder" : "doc"))
                        .font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Text(Fmt.bytes(t.bytes)).font(.system(size: 11, design: .monospaced)).foregroundStyle(.white.opacity(0.75))
                }
                .padding(6)
            }
        }
        .contentShape(Rectangle())
        .help("\(t.label) · \(Fmt.bytes(t.bytes))")
        .onTapGesture(count: 2) { if let e = t.entry, e.isDirectory { model.open(e.url) } }
        .contextMenu { if let e = t.entry { menu(e) } }
    }

    @ViewBuilder private func menu(_ e: DiskEntry) -> some View {
        if e.isDirectory { Button("열기") { model.open(e.url) } }
        Button("Finder에서 보기") { NSWorkspace.shared.activateFileViewerSelecting([e.url]) }
        Divider()
        Button("휴지통으로 이동…", role: .destructive) { pendingTrash = e }
    }

    private func choose() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.directoryURL = model.current
        if p.runModal() == .OK, let u = p.url { model.open(u) }
    }
}
