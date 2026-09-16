import SwiftUI

/// 세로로 들면 아래에서 올라오는 시트, 가로로 돌리면 왼쪽 기둥. 남는 자리의 모양이 정반대라서다.
struct ContentView: View {
  @State private var model = AppModel()
  @State private var sheetHeight: CGFloat = 0
  @State private var bodyHeight: CGFloat = 0
  @Environment(\.scenePhase) private var scenePhase

  var body: some View {
    GeometryReader { geo in
      let safe = geo.safeAreaInsets
      let landscape = geo.size.width > geo.size.height
      let railWidth = min((geo.size.width + safe.leading + safe.trailing) * 0.44, 330)
      let screenHeight = geo.size.height + safe.top + safe.bottom

      ZStack(alignment: .top) {
        CampusMapView(
          model: model, route: model.route, fromId: model.fromId, toId: model.toId,
          here: model.locator.here, accuracy: model.locator.accuracy, sheet: model.sheet,
          picking: model.picking != nil, guiding: model.guiding, landscape: landscape,
          insets: UIEdgeInsets(
            top: landscape ? 0 : safe.top,
            left: landscape ? safe.leading + railWidth + 32 : 0,
            bottom: landscape ? 0 : sheetHeight,
            right: 0
          )
        )
        .ignoresSafeArea()

        attribution(bottom: landscape ? safe.bottom : sheetHeight)

        if landscape {
          rail(width: railWidth, safe: safe)
        } else {
          sheet(maxBody: screenHeight * 0.76 - 72 - safe.bottom, safe: safe)
        }

        TopBar(model: model, landscape: landscape, safeTop: safe.top)
          .padding(.leading, landscape ? safe.leading + 8 + (model.picking == nil ? railWidth : 0) : 0)
          .padding(.trailing, landscape ? safe.trailing + 8 : 0)

        if let field = model.picker {
          PlacePicker(model: model, field: field, landscape: landscape)
            .transition(.move(edge: .bottom))
            .zIndex(2)
        }
        if model.timetableOpen {
          TimetableSheet(model: model)
            .transition(.move(edge: .bottom))
            .zIndex(3)
        }
      }
    }
    .animation(.snappy(duration: 0.25), value: model.sheet)
    .animation(.snappy(duration: 0.25), value: model.picker)
    .animation(.snappy(duration: 0.25), value: model.timetableOpen)
    /* '다음 수업까지 30분' 은 가만 두면 거짓말이 된다. 시간표가 있을 때만 자주 돌린다. */
    .task(id: model.hasTimetable) {
      while !Task.isCancelled {
        model.now = Date()
        try? await Task.sleep(for: .seconds(model.hasTimetable ? 30 : 600))
      }
    }
    .onChange(of: scenePhase) { _, phase in
      if phase == .active { model.now = Date() }
    }
  }

  private func sheet(maxBody: CGFloat, safe: EdgeInsets) -> some View {
    VStack(spacing: 0) {
      Spacer(minLength: 0)
      VStack(spacing: 0) {
        SheetHandle(model: model)
        if model.sheet == .expanded {
          ScrollView {
            PanelBody(model: model, rail: false)
              .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { bodyHeight = $0 }
          }
          .frame(height: min(bodyHeight, max(0, maxBody)))
          .scrollBounceBehavior(.basedOnSize)
        }
      }
      .padding(.bottom, safe.bottom)
      .background(Theme.surface, in: UnevenRoundedRectangle(topLeadingRadius: 10, topTrailingRadius: 10))
      .shadow(color: .black.opacity(0.12), radius: 12, y: -2)
      .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { sheetHeight = $0 }
      .offset(y: model.sheet == .hidden ? sheetHeight + 20 : 0)
    }
    .ignoresSafeArea(edges: .bottom)
  }

  private func rail(width: CGFloat, safe: EdgeInsets) -> some View {
    HStack(spacing: 0) {
      ScrollView {
        PanelBody(model: model, rail: true)
          .padding(.top, safe.top)
          .padding(.bottom, safe.bottom)
      }
      .padding(.leading, safe.leading)
      .frame(width: width + safe.leading)
      .background(Theme.surface, in: UnevenRoundedRectangle(bottomTrailingRadius: 10, topTrailingRadius: 10))
      .shadow(color: .black.opacity(0.12), radius: 12, x: 2)
      .offset(x: model.sheet == .hidden ? -(width + safe.leading + 20) : 0)
      Spacer(minLength: 0)
    }
    .ignoresSafeArea()
  }

  /// ODbL 과 타일 사용 정책이 요구하는 최소 표기.
  private func attribution(bottom: CGFloat) -> some View {
    VStack {
      Spacer()
      HStack {
        Spacer()
        SwiftUI.Link("© OpenStreetMap", destination: URL(string: "https://www.openstreetmap.org/copyright")!)
          .font(.system(size: 10))
          .foregroundStyle(Theme.textSecondary)
          .padding(.horizontal, 4)
          .padding(.vertical, 1)
          .background(.white.opacity(0.8))
      }
    }
    .padding(.bottom, bottom + 2)
    .ignoresSafeArea(edges: .bottom)
  }
}

/// 접힌 시트에서 유일하게 보이는 부분. 끌어서 접고 펴고, 그냥 눌러도 뒤집힌다.
struct SheetHandle: View {
  let model: AppModel

  var body: some View {
    VStack(spacing: 0) {
      Capsule().fill(Theme.gray300).frame(width: 38, height: 4).padding(.top, 7)
      HStack(spacing: 10) {
        VStack(alignment: .leading, spacing: 1) {
          if let metric {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
              Text(metric.value).font(.system(size: 19, weight: .bold).monospacedDigit())
              Text(metric.sub).font(.metricSmall).foregroundStyle(Theme.textSecondary)
            }
            .foregroundStyle(Theme.textPrimary)
          }
          if let note {
            Text(note).font(.body14).lineLimit(1)
              .foregroundStyle(model.unreachable ? Theme.warn : Theme.textSecondary)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)

        if model.hasRoute {
          Button { model.guiding ? model.stopGuide() : model.startGuide() } label: {
            Text(model.guiding ? "안내 종료" : "안내 시작").font(.bodyStrong)
              .pill(.white, fill: model.guiding ? Theme.gray900 : Theme.accent, stroke: nil, h: 16, v: 9)
          }
          .buttonStyle(.plain)
        }

        Button(action: toggle) {
          Text(model.sheet == .expanded ? "▼" : "▲").font(.system(size: 11))
            .foregroundStyle(Theme.textTertiary)
            .frame(width: 32, height: 32)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(model.sheet == .expanded ? "시트 접기" : "시트 펼치기")
      }
      .frame(minHeight: 46)
      .padding(.horizontal, 16)
      .padding(.top, 4)
    }
    .padding(.bottom, 10)
    .contentShape(Rectangle())
    .onTapGesture(perform: toggle)
    .gesture(DragGesture(minimumDistance: 8).onEnded { drag in
      if drag.translation.height > 24 { model.holdSheet(.collapsed) }
      else if drag.translation.height < -24 { model.holdSheet(.expanded) }
    })
  }

  private func toggle() {
    model.holdSheet(model.sheet == .expanded ? .collapsed : .expanded)
  }

  /// 걷는 중에는 전체 길이보다 남은 만큼을 본다.
  private var metric: (value: String, sub: String)? {
    if model.guiding, let progress = model.progress {
      return (formatDuration(progress.remainingSeconds), "\(formatMeters(progress.remainingMeters)) 남음")
    }
    if model.hasRoute, let route = model.route {
      return (formatDuration(route.seconds), formatMeters(route.meters))
    }
    return nil
  }

  private var note: String? {
    if model.guiding { return "위로 끌면 안내 목록이 나옵니다" }
    if model.unreachable { return "이어진 길이 없습니다" }
    if model.route?.legs.isEmpty == true { return "출발지와 도착지가 같습니다" }
    if model.hasRoute { return nil }
    if model.fromId != nil || model.toId != nil { return "한 곳만 더 고르면 됩니다" }
    return "출발지와 도착지를 고르세요"
  }
}

/// 지도 위 상단 띠. 걷는 중에는 다음 동작 하나만 크게 — 걸으면서 읽는 글은 한 줄이 넘어가면 안 읽힌다.
struct TopBar: View {
  let model: AppModel
  let landscape: Bool
  let safeTop: CGFloat

  var body: some View {
    if let field = model.picking {
      bar(fill: Theme.accentSoft, stroke: Theme.accent) {
        HStack(spacing: 10) {
          Text("지도에서 \(field.label)를 고르세요").font(.bodyStrong).foregroundStyle(Theme.accent)
            .frame(maxWidth: .infinity, alignment: .leading)
          stop("취소") { model.picking = nil }
        }
        Text("건물을 누르거나, 그 근처를 대충 눌러도 가장 가까운 곳이 잡힙니다.")
          .font(.caption12).foregroundStyle(Theme.textSecondary)
      }
    } else if model.guiding, let route = model.route {
      let warn = model.lost && !model.arrived
      bar(fill: warn ? Theme.warnSoft : Theme.surface, stroke: warn ? Theme.warn : Theme.outline) {
        guide(route)
      }
    }
  }

  @ViewBuilder private func guide(_ route: Route) -> some View {
    let progress = model.progress
    let arrived = progress != nil && model.arrived
    let index = model.stepIndex
    let next = model.steps.indices.contains(index + 1) ? model.steps[index + 1] : nil
    let current = model.steps.indices.contains(index) ? model.steps[index] : nil
    let headline = headline(route, progress, arrived, index, next)

    HStack(spacing: 10) {
      Text(headline.until).font(.metricSmall).foregroundStyle(.white)
        .padding(.horizontal, 10)
        .frame(minWidth: 58, minHeight: 30)
        .background(Theme.accent, in: Capsule())
      Text(headline.brief).font(.system(size: 17, weight: .bold)).foregroundStyle(Theme.textPrimary)
        .frame(maxWidth: .infinity, alignment: .leading)
      stop(arrived ? "끝내기" : "안내 종료") { model.stopGuide() }
    }

    if model.lost && !arrived, let progress {
      Text("경로에서 \(formatMeters(progress.offRoute)) 벗어났습니다.").font(.bodyStrong).foregroundStyle(Theme.warn)
    } else if progress != nil && !arrived, let detail = (next ?? current)?.text {
      Text(detail).font(.caption12).foregroundStyle(Theme.textSecondary).lineLimit(1)
    }

    if let progress, !arrived {
      HStack(spacing: 6) {
        Text(formatDuration(progress.remainingSeconds))
        Text(formatMeters(progress.remainingMeters))
        Text("남음").font(.caption12).foregroundStyle(Theme.textTertiary)
      }
      .font(.metricSmall)
      .foregroundStyle(Theme.textPrimary)
    }
    if progress == nil {
      Text(noFix.detail).font(.caption12).foregroundStyle(Theme.textSecondary)
    }
  }

  private func headline(_ route: Route, _ progress: RouteProgress?, _ arrived: Bool, _ index: Int, _ next: DirectionStep?) -> (until: String, brief: String) {
    guard let progress else { return ("···", noFix.brief) }
    if arrived { return ("도착", Directions.arrival(route.to)) }
    if let next {
      /* 이번 줄이 끝나는 자리까지 남은 거리 — 그게 다음에 꺾는 자리다. */
      let untilTurn = max(0, model.steps.prefix(index + 1).reduce(0) { $0 + $1.meters } - progress.along)
      return ("\(formatMeters(untilTurn)) 뒤", next.brief)
    }
    return (formatMeters(progress.remainingMeters), "곧 \(route.to.name)")
  }

  /// 권한이 막혔는데 '기다리는 중' 이라고 해 두면 사람은 계속 기다린다.
  private var noFix: (brief: String, detail: String) {
    switch model.locator.status {
    case .denied: ("위치 권한이 막혀 있습니다", "설정 → 개인정보 보호 → 위치 서비스에서 이 앱을 허용하면 따라갑니다.")
    case .unsupported: ("이 기기는 위치를 못 씁니다", "경로와 안내 목록은 그대로 볼 수 있습니다.")
    case .failed: ("현위치를 못 찾았습니다", "건물 안이면 창가나 밖으로 나가면 잡힙니다.")
    default: ("위치를 기다리는 중", "위치가 잡히면 여기서부터 안내합니다. 실내에서는 조금 걸립니다.")
    }
  }

  private func stop(_ title: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Text(title).font(.caption12).pill(Theme.textSecondary, fill: Theme.surface, h: 12, v: 6)
    }
    .buttonStyle(.plain)
  }

  private func bar<Content: View>(fill: Color, stroke: Color, @ViewBuilder content: () -> Content) -> some View {
    let shape = landscape
      ? AnyShape(RoundedRectangle(cornerRadius: 10))
      : AnyShape(UnevenRoundedRectangle(bottomLeadingRadius: 10, bottomTrailingRadius: 10))
    return VStack(alignment: .leading, spacing: 6, content: content)
      .padding(.horizontal, 16)
      .padding(.vertical, 12)
      .padding(.top, landscape ? 0 : safeTop)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(fill, in: shape)
      .overlay(shape.stroke(stroke))
      .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
      .padding(.top, landscape ? 8 : 0)
      .ignoresSafeArea(edges: landscape ? [] : .top)
  }
}
