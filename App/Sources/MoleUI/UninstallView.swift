import SwiftUI
import AppKit

struct UninstallView: View {
    @EnvironmentObject var model: UninstallModel
    @State private var query = ""
    @State private var selection: InstalledApp.ID?

    private var filtered: [InstalledApp] {
        query.isEmpty ? model.apps : model.apps.filter { $0.name.localizedCaseInsensitiveContains(query) || $0.bundle_id.localizedCaseInsensitiveContains(query) }
    }
    private var selected: InstalledApp? { model.apps.first { $0.id == selection } }

    var body: some View {
        VStack(spacing: 12) {
        header
        HSplitView {
            VStack(spacing: 0) {
                if model.loading && model.apps.isEmpty {
                    ProgressView("앱 목록 불러오는 중…").frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(filtered, selection: $selection) { app in
                        HStack(spacing: 8) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: app.path)).resizable().frame(width: 24, height: 24)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(app.name).lineLimit(1)
                                Text(app.bundle_id).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        .tag(app.id)
                    }
                }
            }
            .frame(minWidth: 280, idealWidth: 320)
            detail.frame(minWidth: 380)
        }
        .scrollContentBackground(.hidden)
        }
        .onAppear { if model.apps.isEmpty { model.load() } }
        .onChange(of: selection) { _, _ in
            if let a = selected { model.size(of: a); model.previewLog = [] }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.white.opacity(0.5))
                TextField("앱 검색", text: $query).textFieldStyle(.plain)
            }
            .padding(.horizontal, 14).padding(.vertical, 9)
            .glassEffect(.regular, in: .capsule)
            .frame(maxWidth: 340)
            Button { model.load() } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.glass).help("목록 새로고침")
            Spacer()
            Text("\(filtered.count)개 앱").font(.callout).foregroundStyle(.white.opacity(0.55))
        }
        .padding(.horizontal, 24)
    }

    @ViewBuilder private var detail: some View {
        if let app = selected {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: app.path)).resizable().frame(width: 48, height: 48)
                    VStack(alignment: .leading) {
                        Text(app.name).font(.title3.weight(.semibold))
                        Text(app.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled).lineLimit(2)
                    }
                }
                if let b = model.sizes[app.path] {
                    Text("앱 크기 \(Fmt.bytes(b))").font(.callout)
                }
                HStack {
                    Button { model.preview(app) } label: { Label("제거 미리보기", systemImage: "eye") }
                        .buttonStyle(.glass)
                        .disabled(model.previewing)
                    Button { Terminal.runInteractive("uninstall \(Terminal.shellQuote(app.uninstall_name))") } label: {
                        Label("터미널에서 제거", systemImage: "terminal")
                    }
                    .buttonStyle(.glassProminent)
                    if model.previewing { ProgressView().controlSize(.small) }
                }
                Text("실제 제거는 확인 절차와 관리자 권한을 위해 터미널에서 진행됩니다.")
                    .font(.caption).foregroundStyle(.secondary)
                if let e = model.error { Text(e).foregroundStyle(.red).font(.caption) }
                if !model.plan.isEmpty { PlanView(plan: model.plan, running: model.previewing) } else { Spacer() }
            }
            .padding(16)
        } else {
            VStack(spacing: 14) {
                PlanetView(kind: .mars, size: 260, spin: model.loading || model.previewing ? 48 : 1)
                Text("앱을 선택하세요").font(.title3.weight(.semibold))
                Text("제거될 앱과 잔여 파일을 미리 확인할 수 있습니다.").font(.callout).foregroundStyle(.white.opacity(0.6))
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct PlanView: View {
    let plan: UninstallPlan
    let running: Bool
    var body: some View {
        ScrollView {
            GlassEffectContainer(spacing: 12) {
                VStack(spacing: 12) {
                    group("삭제될 항목", icon: "trash.fill", tint: .red, entries: plan.remove)
                    if !plan.kept.isEmpty { group("보존되는 개인 데이터", icon: "lock.shield.fill", tint: .blue, entries: plan.kept) }
                    if plan.done {
                        Label("미리보기 완료 — 아무것도 삭제되지 않았습니다.", systemImage: "checkmark.seal.fill")
                            .foregroundStyle(.green).font(.callout)
                            .symbolEffect(.bounce, value: plan.done)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
            }
        }
    }

    private func group(_ title: String, icon: String, tint: Color, entries: [PlanEntry]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: icon).font(.headline).foregroundStyle(tint)
            ForEach(entries) { e in
                HStack {
                    Text(e.path).font(.callout).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    if let s = e.size { Text(s).font(.caption).monospacedDigit().foregroundStyle(.secondary) }
                }
                .transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
        .animation(.smooth, value: entries.count)
    }
}
