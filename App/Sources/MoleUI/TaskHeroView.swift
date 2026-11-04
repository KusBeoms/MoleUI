import SwiftUI

struct PillButtonStyle: ButtonStyle {
    var prominent = true
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(prominent ? Color.black : Color.white)
            .padding(.horizontal, 52).padding(.vertical, 17)
            .background(Capsule().fill(prominent ? Color.white : Color.white.opacity(0.14)))
            .shadow(color: .white.opacity(prominent ? 0.22 : 0), radius: 22)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(duration: 0.2), value: configuration.isPressed)
    }
}

/// Planet-first flow shared by Clean and Optimize: scan → found → review → run → done.
struct TaskHeroView: View {
    @ObservedObject var model: TaskModel
    let kind: PlanetKind
    let moon: Bool
    let verb: String
    let startLabel: String
    let tagline: String
    let terminalArgs: String?

    @State private var reviewing = false
    @State private var confirm = false
    @State private var showDetail = false

    private var liveTotal: Int64 { model.live.reduce(0) { $0 + $1.totalBytes } }
    private var previewTotal: Int64 { model.sections.reduce(0) { $0 + $1.totalBytes } }

    var body: some View {
        ZStack {
            if reviewing {
                review.transition(.move(edge: .trailing).combined(with: .opacity))
            } else {
                hero.transition(.opacity)
            }
        }
        .animation(.smooth(duration: 0.4), value: reviewing)
        .onChange(of: model.phase) { _, p in if p == .running { reviewing = false } }
        .confirmationDialog("정말 실행할까요?", isPresented: $confirm, titleVisibility: .visible) {
            Button("\(verb) 실행", role: .destructive) { model.execute() }
            Button("취소", role: .cancel) {}
        } message: {
            Text("미리보기에 표시된 항목이 삭제됩니다. 관리자 권한이 필요한 항목은 건너뜁니다.")
        }
        .sheet(isPresented: $showDetail) {
            VStack(spacing: 0) {
                HStack {
                    Text("\(verb) 상세").font(.headline)
                    Spacer()
                    Button("닫기") { showDetail = false }.buttonStyle(.glass)
                }.padding(16)
                LiveProgressView(title: verb, sections: model.live, finished: true,
                                 success: model.exitCode == 0, freed: Parsing.freed(from: model.log))
            }
            .frame(width: 560, height: 640)
        }
    }

    // MARK: Hero

    private var busy: Bool { model.busy }

    private var hero: some View {
        VStack(spacing: 18) {
            Spacer(minLength: 0)
            GeometryReader { geo in
                PlanetView(kind: kind, size: min(340, max(220, geo.size.height * 0.95 / (moon ? 1.3 : 1))), spin: busy ? 48 : 1, moon: moon)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(minHeight: 260, maxHeight: 460)
            VStack(spacing: 10) { texts }
                .frame(minHeight: 120)
            controls
            if let e = model.error {
                Text(e).font(.caption).foregroundStyle(.red.opacity(0.9))
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 24)
    }

    @ViewBuilder private var texts: some View {
        switch model.phase {
        case .idle:
            Text(tagline).font(.system(size: 20, design: .serif)).multilineTextAlignment(.center)
                .foregroundStyle(.white.opacity(0.85)).lineSpacing(6)
        case .previewing, .running:
            Text(model.phase == .previewing ? "스캔 중…" : "\(verb) 중…").font(.system(size: 38, weight: .bold, design: .rounded))
            if kind == .earth { CountingBytes(bytes: liveTotal, font: .system(size: 22, weight: .semibold, design: .rounded)).foregroundStyle(.white.opacity(0.9)) }
            Text(model.live.last?.name ?? "준비 중")
                .font(.callout).foregroundStyle(.white.opacity(0.6))
                
        case .previewed:
            if let p = model.summary.potential {
                Text("\(p) 발견").font(.system(size: 42, weight: .bold, design: .rounded))
                HStack(spacing: 6) {
                    Text("\(model.summary.items ?? 0)개 항목 · \(model.summary.categories ?? 0)개 카테고리 ·")
                        .foregroundStyle(.white.opacity(0.6))
                    Button("다시 스캔") { model.preview() }.buttonStyle(.plain).foregroundStyle(.cyan)
                }.font(.callout)
            } else {
                let n = model.sections.filter { !$0.isEmpty }.count
                Text("\(n)개 작업 확인").font(.system(size: 38, weight: .bold, design: .rounded))
                Button("다시 확인") { model.preview() }.buttonStyle(.plain).foregroundStyle(.cyan).font(.callout)
            }
        case .finished:
            Text(model.exitCode == 0 ? "\(verb) 완료" : "\(verb) 종료됨").font(.system(size: 40, weight: .bold, design: .rounded))
            if let f = Parsing.freed(from: model.log) {
                Text("\(Fmt.bytes(f)) 확보").font(.title3).foregroundStyle(.white.opacity(0.7))
            }
            HStack(spacing: 14) {
                Button("상세 보기") { showDetail = true }.buttonStyle(.plain).foregroundStyle(.cyan)
                Button("다시 스캔") { model.preview() }.buttonStyle(.plain).foregroundStyle(.cyan)
            }.font(.callout)
        }
    }

    @ViewBuilder private var controls: some View {
        switch model.phase {
        case .idle:
            Button(startLabel) { model.preview() }.buttonStyle(PillButtonStyle())
        case .previewing, .running:
            Button("중지") { model.cancel() }.buttonStyle(PillButtonStyle(prominent: false))
        case .previewed:
            Button("결과 검토") { reviewing = true }.buttonStyle(PillButtonStyle())
        case .finished:
            EmptyView()
        }
    }

    // MARK: Review

    private var review: some View {
        VStack(spacing: 0) {
            HStack {
                Button { reviewing = false } label: { Label("돌아가기", systemImage: "chevron.left") }
                    .buttonStyle(.glass)
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(verb) 검토").font(.title2.weight(.bold))
                    if let p = model.summary.potential { Text("정리 가능 \(p)").font(.callout).foregroundStyle(.white.opacity(0.6)) }
                }
            }
            .padding(.horizontal, 28).padding(.vertical, 14)

            ScrollView {
                GlassEffectContainer(spacing: 14) {
                    LazyVStack(spacing: 14) {
                        ForEach(model.sections) { s in ReviewCard(section: s) }
                    }
                    .padding(.horizontal, 28).padding(.bottom, 20)
                }
            }
            .scrollIndicators(.hidden)

            HStack {
                Text(previewTotal > 0 ? Fmt.bytes(previewTotal) : "").font(.headline).monospacedDigit()
                Spacer()
                if terminalArgs == nil {
                    Button("\(verb) 실행 · \(Fmt.bytes(previewTotal))") { confirm = true }.buttonStyle(PillButtonStyle())
                } else if let args = terminalArgs {
                    Button("터미널에서 실행") { Terminal.runInteractive(args) }.buttonStyle(PillButtonStyle())
                }
            }
            .padding(.horizontal, 28).padding(.vertical, 16)
            .background(.black.opacity(0.25))
        }
    }
}

private struct ReviewCard: View {
    let section: PreviewSection
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(section.name).font(.headline)
                Spacer()
                if section.totalBytes > 0 {
                    Text(Fmt.bytes(section.totalBytes)).font(.system(.body, design: .monospaced)).foregroundStyle(.white.opacity(0.7))
                }
            }
            if section.isEmpty {
                Label("정리할 항목 없음", systemImage: "checkmark.circle").font(.callout).foregroundStyle(.white.opacity(0.5))
            } else {
                ForEach(section.items.filter { $0.kind != .empty }) { item in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Image(systemName: icon(item.kind)).foregroundStyle(color(item.kind)).frame(width: 16)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.label)
                            if !item.detail.isEmpty && item.bytes == nil {
                                Text(item.detail).font(.caption).foregroundStyle(.white.opacity(0.5))
                            }
                        }
                        Spacer()
                        if let b = item.bytes, item.kind == .clean || item.kind == .hint {
                            Text(Fmt.bytes(b)).font(.system(.callout, design: .monospaced)).foregroundStyle(.white.opacity(0.6))
                        }
                    }
                    .opacity(item.kind == .skipped ? 0.55 : 1)
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
    }
    private func icon(_ k: ItemKind) -> String {
        switch k { case .clean: "checkmark.circle.fill"; case .skipped: "forward.circle"; case .hint: "lightbulb"; default: "info.circle" }
    }
    private func color(_ k: ItemKind) -> Color {
        switch k { case .clean: .green; case .skipped: .orange; case .hint: .yellow; default: .secondary }
    }
}
