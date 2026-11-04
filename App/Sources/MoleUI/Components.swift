import SwiftUI
import Charts

struct Card<Content: View>: View {
    let title: String
    var systemImage: String?
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: systemImage ?? "circle")
                .labelStyle(CardTitleStyle(hasIcon: systemImage != nil))
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
    }
}

private struct CardTitleStyle: LabelStyle {
    let hasIcon: Bool
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            if hasIcon { configuration.icon }
            configuration.title
        }
    }
}

struct Sparkline: View {
    let values: [Double]
    var color: Color = .accentColor
    var maxValue: Double?
    var body: some View {
        Chart {
            ForEach(Array(values.enumerated()), id: \.offset) { i, v in
                AreaMark(x: .value("t", i), y: .value("v", v))
                    .foregroundStyle(color.opacity(0.18))
                LineMark(x: .value("t", i), y: .value("v", v))
                    .foregroundStyle(color)
                    .interpolationMethod(.monotone)
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartYScale(domain: 0...(maxValue ?? max(values.max() ?? 1, 1)))
        .frame(height: 44)
    }
}

struct UsageBar: View {
    let fraction: Double
    var tint: Color = .accentColor
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(tint).frame(width: max(4, g.size.width * min(max(fraction, 0), 1)))
            }
        }
        .frame(height: 8)
    }
}

struct LogView: View {
    let lines: [String]
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { i, l in
                        Text(l.isEmpty ? " " : l)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(i)
                    }
                }
                .padding(10)
            }
            .onChange(of: lines.count) { _, n in
                if n > 0 { proxy.scrollTo(n - 1, anchor: .bottom) }
            }
        }
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
    }
}

struct EmptyHint: View {
    let systemImage: String
    let title: String
    let message: String
    var body: some View {
        ContentUnavailableView(title, systemImage: systemImage, description: Text(message))
    }
}

/// Soft color field behind content so the glass has something to refract.
struct GlassBackdrop: View {
    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            LinearGradient(colors: [.blue.opacity(0.22), .purple.opacity(0.14), .teal.opacity(0.18)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            Circle().fill(.pink.opacity(0.14)).frame(width: 380).blur(radius: 90).offset(x: 260, y: -160)
        }
        .ignoresSafeArea()
    }
}

/// Number that rolls smoothly when its value changes.
struct CountingBytes: View {
    let bytes: Int64
    var font: Font = .system(size: 44, weight: .bold, design: .rounded)
    var body: some View {
        Text(Fmt.bytes(bytes))
            .font(font)
            .monospacedDigit()
            .contentTransition(.numericText(value: Double(bytes)))
            .animation(.smooth(duration: 0.6), value: bytes)
    }
}

/// Live progress card: pulsing icon, running total, and sections that slide in as the CLI reports them.
struct LiveProgressView: View {
    let title: String
    let sections: [PreviewSection]
    let finished: Bool
    var success = true
    var freed: Int64?
    @State private var pulse = false

    private var total: Int64 { freed ?? sections.reduce(0) { $0 + $1.totalBytes } }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                GlassEffectContainer(spacing: 14) {
                    VStack(spacing: 14) {
                        hero
                        ForEach(Array(sections.enumerated()), id: \.element.id) { i, s in
                            SectionCard(section: s, active: !finished && i == sections.count - 1)
                                .id(s.id)
                                .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity).combined(with: .scale(scale: 0.96)), removal: .opacity))
                        }
                        Color.clear.frame(height: 1).id("end")
                    }
                    .padding(20)
                }
            }
            .onChange(of: sections.count) { _, _ in
                withAnimation(.smooth) { proxy.scrollTo("end", anchor: .bottom) }
            }
        }
    }

    private var hero: some View {
        VStack(spacing: 8) {
            ZStack {
                if finished {
                    Image(systemName: success ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .font(.system(size: 54))
                        .foregroundStyle(success ? .green : .orange)
                        .symbolEffect(.bounce, value: finished)
                        .transition(.scale.combined(with: .opacity))
                } else {
                    Image(systemName: "sparkles")
                        .font(.system(size: 50))
                        .foregroundStyle(.tint)
                        .symbolEffect(.variableColor.iterative.reversing, isActive: true)
                        .scaleEffect(pulse ? 1.08 : 0.94)
                        .animation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true), value: pulse)
                        .onAppear { pulse = true }
                }
            }
            .frame(height: 64)
            CountingBytes(bytes: total)
            Text(finished ? (success ? "\(title) 완료" : "\(title) 종료됨") : "\(title) 진행 중…")
                .font(.callout).foregroundStyle(.secondary)
                .contentTransition(.interpolate)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
        .glassEffect(.regular, in: .rect(cornerRadius: 26))
        .animation(.smooth, value: finished)
    }
}

struct SectionCard: View {
    let section: PreviewSection
    var active = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                if active { ProgressView().controlSize(.small).transition(.opacity) }
                else { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).transition(.scale) }
                Text(section.name).font(.headline)
                Spacer()
                if section.totalBytes > 0 {
                    Text(Fmt.bytes(section.totalBytes)).monospacedDigit()
                        .contentTransition(.numericText(value: Double(section.totalBytes)))
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(section.items) { item in
                HStack(spacing: 8) {
                    Image(systemName: item.kind == .skipped ? "forward.circle" : item.kind == .hint ? "lightbulb" : "checkmark")
                        .font(.caption).foregroundStyle(item.kind == .skipped ? .orange : .green).frame(width: 16)
                    Text(item.label).font(.callout).lineLimit(1)
                    Spacer()
                    if let b = item.bytes, item.kind == .clean || item.kind == .hint {
                        Text(Fmt.bytes(b)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
                .transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
        .animation(.smooth(duration: 0.35), value: section.items.count)
    }
}
