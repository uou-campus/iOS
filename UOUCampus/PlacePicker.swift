import SwiftUI

/// Client/src/components/PlacePicker. 손바닥만 한 지도에서 22px 짜리 점을 찍어 맞히라는 건 무리라 화면을 통째로 덮는다.
struct PlacePicker: View {
  let model: AppModel
  let field: Field
  /// 가로로 돌리면 폭이 남는다. 빠른 선택은 나란히, 목록은 두 칸씩.
  let landscape: Bool
  @State private var query = ""

  private struct Group: Identifiable {
    let title: String?
    let items: [CampusNode]
    var id: String { title ?? "hits" }
  }

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 8) {
        Text("\(field.label) 선택").font(.section).foregroundStyle(Theme.textPrimary)
          .frame(maxWidth: .infinity, alignment: .leading)
        Button { model.picker = nil } label: {
          Text("×").font(.system(size: 20)).foregroundStyle(Theme.textSecondary)
            .frame(width: 36, height: 36).contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("닫기")
      }
      .padding(.leading, 16)
      .padding(.trailing, 10)
      .padding(.vertical, landscape ? 4 : 10)
      .bottomRule()

      /* 열자마자 키보드가 올라오면 목록이 반으로 줄어든다. 눌러야 뜨게 둔다. */
      TextField("건물 이름이나 번호", text: $query)
        .font(.body14)
        .autocorrectionDisabled()
        .submitLabel(.search)
        .padding(.horizontal, 16)
        .frame(height: 44)
        .background(Theme.gray50, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.outline))
        .padding(.horizontal, 16)
        .padding(.vertical, landscape ? 8 : 12)

      quick

      ScrollView {
        list.padding(.horizontal, 16).padding(.bottom, 16)
      }
      .scrollDismissesKeyboard(.immediately)
    }
    .background(Theme.surface.ignoresSafeArea())
  }

  private var quick: some View {
    let layout = landscape ? AnyLayout(HStackLayout(spacing: 6)) : AnyLayout(VStackLayout(spacing: 6))
    return layout {
      if field == .from {
        /* 한 번 켜면 다시 누를 일이 없다. 그래도 왜 못 누르는지는 적어 둔다. */
        quickRow("location.fill", "현위치에서 출발", geoNote, enabled: [Locator.Status.idle, .failed].contains(model.locator.status)) {
          model.useHereAsOrigin()
        }
      }
      quickRow("map", "지도에서 고르기", "지도만 크게 보기", enabled: true) { model.startMapPick(field) }
    }
    .padding(.horizontal, 16)
    .padding(.bottom, landscape ? 8 : 12)
  }

  private func quickRow(_ symbol: String, _ title: String, _ note: String, enabled: Bool, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      HStack(spacing: 10) {
        Image(systemName: symbol).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.accent)
          .frame(width: 26, height: 26).background(Theme.accentTint, in: Circle())
        Text(title).font(.bodyStrong).foregroundStyle(Theme.textPrimary).lineLimit(1)
        Spacer(minLength: 0)
        Text(note).font(.caption12).foregroundStyle(Theme.textTertiary).lineLimit(1)
      }
      .padding(.horizontal, 12)
      .padding(.vertical, landscape ? 9 : 11)
      .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.outline))
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .disabled(!enabled)
    .opacity(enabled ? 1 : 0.45)
  }

  private var geoNote: String {
    switch model.locator.status {
    case .idle: "위치 권한 필요"
    case .locating: "찾는 중"
    case .coarse: "자리를 다듬는 중"
    case .ready: "켜져 있음"
    case .denied: "권한이 막혀 있습니다"
    case .unsupported: "이 기기는 못 씁니다"
    case .failed: "못 찾았습니다 — 다시"
    }
  }

  private var list: some View {
    let hits = model.graph.places.filter { matchesPlace($0, query) }
    /* 검색 중에는 묶지 않고 걸린 순서대로 쭉 보여 준다. 건물이 먼저, 문은 맨 뒤. */
    let groups = query.trimmingCharacters(in: .whitespaces).isEmpty
      ? [(NodeKind.building, "건물"), (.place, "시설"), (.gate, "출입문")]
        .map { kind, title in Group(title: title, items: hits.filter { $0.kind == kind }) }
        .filter { !$0.items.isEmpty }
      : [Group(title: nil, items: hits)]
    let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: landscape ? 2 : 1)

    return VStack(alignment: .leading, spacing: 0) {
      if hits.isEmpty {
        Text("찾는 이름이 없습니다.").font(.body14).foregroundStyle(Theme.textTertiary).padding(.vertical, 16)
      }
      ForEach(groups) { group in
        if let title = group.title {
          Text(title).font(.caption12).foregroundStyle(Theme.textTertiary).padding(.top, 12).padding(.bottom, 4)
        }
        LazyVGrid(columns: columns, spacing: 2) {
          ForEach(group.items) { row($0) }
        }
      }
    }
  }

  private func row(_ node: CampusNode) -> some View {
    let value = field == .from ? model.fromId : model.toId
    /* 반대편 칸에 이미 들어가 있는 곳. 같은 곳끼리는 경로가 없다. */
    let taken = (field == .from ? model.toId : model.fromId) == node.id
    /* 이름을 그대로 옮겨 둔 별칭이 있다. 같은 말을 두 줄로 적을 이유는 없다. */
    let aliases = (node.aliases ?? []).filter { $0 != node.name }

    return Button { model.pickFromList(node) } label: {
      HStack(spacing: 10) {
        Text(node.no.map { String($0) } ?? "·")
          .font(.system(size: 11, weight: .bold).monospacedDigit())
          .foregroundStyle(node.no == nil ? Theme.textTertiary : Theme.textSecondary)
          .frame(width: 26, height: 26)
          .background(Theme.gray100, in: Circle())
        VStack(alignment: .leading, spacing: 1) {
          Text(node.name).font(.bodyStrong).foregroundStyle(Theme.textPrimary).lineLimit(1)
          if !aliases.isEmpty {
            Text(aliases.joined(separator: " · ")).font(.caption12).foregroundStyle(Theme.textTertiary).lineLimit(1)
          }
        }
        Spacer(minLength: 0)
        if node.precision == "approx" {
          Text("근사").font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.warn)
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(Theme.warnSoft, in: Capsule())
        }
        if let here = model.locator.here {
          Text(formatMeters(Geo.distance(here, node.at))).font(.caption12).monospacedDigit().foregroundStyle(Theme.textTertiary)
        }
      }
      .padding(.horizontal, 10)
      .padding(.vertical, 9)
      .background(value == node.id ? Theme.accentSoft : .clear, in: RoundedRectangle(cornerRadius: 6))
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .disabled(taken)
    .opacity(taken ? 0.4 : 1)
  }
}
