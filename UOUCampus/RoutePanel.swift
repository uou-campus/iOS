import SwiftUI

/// Client/src/components/RoutePanel. 시트와 기둥이 같은 내용을 쓴다.
struct PanelBody: View {
  let model: AppModel
  /// 가로로 돌린 폰의 기둥. 손잡이가 없으니 안내 시작 단추를 여기 둔다.
  let rail: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header
      fields
      NextClassRow(model: model)
      geoRow
      if rail && model.hasRoute {
        Button { model.guiding ? model.stopGuide() : model.startGuide() } label: {
          Text(model.guiding ? "안내 종료" : "안내 시작 — 현위치를 따라갑니다")
            .font(.bodyStrong).foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .background(model.guiding ? Theme.gray900 : Theme.accent, in: Capsule())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
      }
      controls
      result
    }
  }

  private var header: some View {
    HStack(spacing: 6) {
      Text("울산대 캠퍼스 길찾기").font(.appTitle).foregroundStyle(Theme.textPrimary).lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .leading)
      Button { model.timetableOpen = true } label: {
        Text("시간표 넣기").font(.caption12).pill(
          model.hasTimetable ? Theme.accent : Theme.textSecondary,
          fill: model.hasTimetable ? Theme.accentSoft : .clear,
          stroke: model.hasTimetable ? Theme.accent : Theme.outline
        )
      }
      .buttonStyle(.plain)
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 12)
    .bottomRule()
  }

  private var fields: some View {
    HStack(spacing: 8) {
      VStack(spacing: 6) {
        field(.from, "출발", model.fromNode?.name, "어디서 출발하나요")
        field(.to, "도착", model.toNode?.name, "어디로 가나요")
      }
      Button(action: model.swap) {
        Text("⇅").font(.system(size: 17)).foregroundStyle(Theme.textSecondary)
          .frame(width: 44)
          .frame(maxHeight: .infinity)
          .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.outline))
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel("출발지와 도착지 바꾸기")
    }
    .fixedSize(horizontal: false, vertical: true)
    .padding(.horizontal, 16)
    .padding(.top, 16)
    .padding(.bottom, 10)
  }

  private func field(_ which: Field, _ label: String, _ value: String?, _ placeholder: String) -> some View {
    Button { model.picker = which } label: {
      HStack(spacing: 10) {
        Text(label).font(.caption12).foregroundStyle(Theme.textTertiary).frame(width: 26, alignment: .leading)
        Text(value ?? placeholder)
          .font(value == nil ? .body14 : .bodyStrong)
          .foregroundStyle(value == nil ? Theme.textTertiary : Theme.textPrimary)
          .lineLimit(1)
        Spacer(minLength: 0)
      }
      .padding(.horizontal, 12)
      .frame(minHeight: 44)
      .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(value == nil ? Theme.outline : Theme.accent))
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }

  private var geoRow: some View {
    let locator = model.locator
    return HStack(spacing: 8) {
      Button { locator.active ? locator.stop() : model.useHereAsOrigin() } label: {
        Text(locator.active ? "현위치 끄기" : "현위치에서 출발").font(.caption12).pill(
          locator.active ? Theme.here : Theme.textSecondary,
          fill: locator.active ? Theme.hereSoft : .clear,
          stroke: locator.active ? Theme.here : Theme.outline, h: 11
        )
      }
      .buttonStyle(.plain)
      if let message = geoMessage {
        Text(message).font(.caption12).foregroundStyle(Theme.textTertiary)
      }
      /* GPS 는 '이 안쪽' 을 알려 준다. 얼마나 어림한지 적어 두지 않으면 점이 튀는 걸 고장으로 읽는다. */
      if locator.active, let accuracy = locator.accuracy {
        Text("±\(Int(jsRound(accuracy)))m").font(.caption12).foregroundStyle(Theme.textTertiary)
      }
    }
    .padding(.horizontal, 16)
    .padding(.bottom, 10)
  }

  private var geoMessage: String? {
    if model.offCampus { return "캠퍼스 밖이라 출발지로 못 씁니다" }
    return switch model.locator.status {
    case .locating: "현위치를 찾는 중입니다"
    case .coarse: "아직 어림한 자리입니다 — 다듬는 중"
    case .denied: "위치 권한이 막혀 있습니다"
    case .unsupported: "이 기기는 위치를 못 씁니다"
    case .failed: "현위치를 못 찾았습니다"
    default: nil
    }
  }

  private var controls: some View {
    VStack(alignment: .leading, spacing: 2) {
      HStack(spacing: 2) {
        /* 표시된 지름길이 하나도 없으면 그 기준은 아무 일도 안 한다. */
        ForEach(Profile.allCases.filter { $0 != .shortcut || model.shortcutCount > 0 }) { profile in
          let on = model.options.profile == profile
          Button { model.options.profile = profile } label: {
            Text(profile.label)
              .font(.system(size: 13, weight: on ? .bold : .medium))
              .foregroundStyle(on ? Theme.textPrimary : Theme.textSecondary)
              .padding(.horizontal, 12)
              .padding(.vertical, 6)
              .background(on ? Theme.surface : .clear, in: Capsule())
              .shadow(color: .black.opacity(on ? 0.08 : 0), radius: 2, y: 1)
              .contentShape(Capsule())
          }
          .buttonStyle(.plain)
        }
      }
      .padding(3)
      .background(Theme.gray100, in: Capsule())
      .padding(.bottom, 8)

      let indoor = model.options.allowIndoor
      Button { model.options.allowIndoor.toggle() } label: {
        HStack(alignment: .top, spacing: 10) {
          RoundedRectangle(cornerRadius: 4)
            .fill(indoor ? Theme.accent : Theme.surface)
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(indoor ? Theme.accent : Theme.gray300, lineWidth: 1.5))
            .overlay {
              if indoor {
                Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
              }
            }
            .frame(width: 18, height: 18)
            .padding(.top, 1)
          VStack(alignment: .leading, spacing: 2) {
            Text("건물 안으로 질러가기").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.textPrimary)
            Text(model.indoorCount == 0
              ? "아직 등록된 실내 구간이 없습니다"
              : "등록된 실내 구간 \(model.indoorCount)개. 문 닫히는 시간엔 꺼 두세요")
              .font(.caption12).foregroundStyle(Theme.textTertiary)
          }
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .disabled(model.indoorCount == 0)
      .opacity(model.indoorCount == 0 ? 0.45 : 1)
    }
    .padding(.horizontal, 16)
    .padding(.bottom, 12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .bottomRule()
  }

  @ViewBuilder private var result: some View {
    if let route = model.route, !route.legs.isEmpty {
      if model.locator.active { ProgressBox(model: model) }
      SummaryView(route: route, compare: model.compare, roadsOnly: model.roadsOnly)
      DirectionsList(route: route, steps: model.steps)
    }
    if model.route?.legs.isEmpty == true {
      Text("출발지와 도착지가 같습니다.").font(.body14).foregroundStyle(Theme.textTertiary).padding(16)
    }
    if model.unreachable {
      Text("이어진 길이 없습니다. 두 곳 사이를 잇는 길이 아직 지도에 없습니다.")
        .font(.body14).foregroundStyle(Theme.warn)
        .note(Theme.warnSoft)
        .padding(16)
    }
  }
}

/// 걷는 동안 보이는 줄. 남은 거리·시간과 지금 할 일만 크게 띄운다.
private struct ProgressBox: View {
  let model: AppModel

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      if let progress = model.progress {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          Text(formatDuration(progress.remainingSeconds)).font(.metric).foregroundStyle(Theme.textPrimary)
          Text("\(formatMeters(progress.remainingMeters)) 남음").font(.metricSmall).foregroundStyle(Theme.textSecondary)
          Spacer(minLength: 0)
          Text("경로에서 \(formatMeters(progress.offRoute))").font(.caption12).foregroundStyle(Theme.textTertiary)
        }
        if model.lost {
          Text("경로에서 많이 벗어났습니다. 지도를 보고 되돌아가거나 출발지를 다시 잡으세요.")
            .font(.caption12).foregroundStyle(Theme.warn)
        } else if model.steps.indices.contains(model.stepIndex) {
          Text(model.steps[model.stepIndex].text).font(.bodyStrong).foregroundStyle(Theme.textPrimary)
        }
      } else {
        Text(model.offCampus ? "캠퍼스 밖에 있습니다. 들어서면 경로 위 어디쯤인지 표시합니다." : "위치를 기다리는 중입니다. 잡히면 경로 위 어디쯤인지 표시합니다.")
          .font(.caption12).foregroundStyle(Theme.warn)
      }
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(model.lost ? Theme.warnSoft : Theme.accentSoft)
    .bottomRule()
  }
}

private struct SummaryView: View {
  let route: Route
  /// 다른 기준으로 잡았을 때의 경로. 같은 길이면 nil.
  let compare: Route?
  /// 차도만 따라 돌았을 때의 기준선.
  let roadsOnly: Route?

  private var stats: [(label: String, value: String)] {
    [("보행로·계단", route.footMeters), ("계단", route.stairsMeters), ("표시한 지름길", route.shortcutMeters), ("건물 안", route.indoorMeters)]
      .filter { $0.1 > 0 }
      .map { ($0.0, formatMeters($0.1)) }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Text(formatDuration(route.seconds)).font(.metric).foregroundStyle(Theme.textPrimary)
        Text(formatMeters(route.meters)).font(.metricSmall).foregroundStyle(Theme.textSecondary)
      }

      if !stats.isEmpty {
        FlowLayout(spacing: 6) {
          ForEach(stats, id: \.label) { stat in
            HStack(spacing: 5) {
              Text(stat.label).foregroundStyle(Theme.textSecondary)
              Text(stat.value).fontWeight(.bold).monospacedDigit().foregroundStyle(Theme.textPrimary)
            }
            .font(.caption12)
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            .background(Theme.gray100, in: Capsule())
          }
        }
      }

      /* 큰길만 따라 돌면 얼마나 손해인지. 이게 이 경로의 '지름길 이득'이다. 이 정도는 벌어져야 말할 값어치가 있다. */
      if let roads = roadsOnly, route.footMeters > 0,
         roads.seconds - route.seconds > 20 || roads.meters - route.meters > 30 {
        Text("큰길로만 돌아가면 \(Text(formatDuration(roads.seconds)).bold()) 걸립니다. 보행로와 계단을 타서 \(Text(formatDuration(roads.seconds - route.seconds)).bold()) · \(Text(formatMeters(roads.meters - route.meters)).bold()) 를 벌었습니다.")
          .font(.caption12).foregroundStyle(Theme.ok).lineSpacing(3)
          .note(Theme.accentSoft)
      }

      if roadsOnly == nil && route.footMeters > 0 {
        Text("견줄 만한 차도 경로를 못 찾았습니다 — 출발지나 도착지 언저리가 보행로로만 이어져 있습니다.")
          .font(.caption12).foregroundStyle(Theme.textSecondary)
          .note(Theme.gray100)
      }

      if let compare {
        let label = compare.options.profile.label
        VStack(alignment: .leading, spacing: 5) {
          HStack(spacing: 5) {
            Path { path in
              path.move(to: CGPoint(x: 0, y: 1))
              path.addLine(to: CGPoint(x: 14, y: 1))
            }
            .stroke(Theme.warn, style: StrokeStyle(lineWidth: 2, dash: [3, 2]))
            .frame(width: 14, height: 2)
            Text("\(Text(label).bold())\(josaRo(label)) 가면 \(formatDelta(compare.meters, route.meters, formatMeters)) · \(formatDelta(compare.seconds, route.seconds, formatDuration))")
          }
          Text("지도에 주황 점선으로 겹쳐 뒀습니다").opacity(0.75)
        }
        .font(.caption12).foregroundStyle(Theme.warn)
        .note(Theme.warnSoft)
      }
    }
    .padding(.horizontal, 16)
    .padding(.top, 16)
    .padding(.bottom, 12)
  }
}

private struct DirectionsList: View {
  let route: Route
  let steps: [DirectionStep]

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      ForEach(steps.indices, id: \.self) { i in
        let step = steps[i]
        VStack(alignment: .leading, spacing: 4) {
          Text(step.text).font(.body14).foregroundStyle(Theme.textPrimary)
          FlowLayout(spacing: 5) {
            if step.shortcut { tag("지름길", ink: Theme.accent, fill: Theme.accentSoft, bold: true) }
            if step.surface != .path && step.surface != .road { tag(step.surface.label) }
            if step.covered { tag("비 안 맞음") }
            Text("약 \(formatDuration(step.seconds))").font(.caption12).monospacedDigit().foregroundStyle(Theme.textTertiary)
          }
        }
        .padding(.leading, 26)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        /* 왼쪽에 이어지는 세로선. 마지막 칸만 고리로 끊는다. */
        .background(alignment: .topLeading) {
          Theme.gray200.frame(width: 2).padding(.top, 13).offset(x: 8)
        }
        .overlay(alignment: .topLeading) {
          Circle().fill(Theme.accent).frame(width: 6, height: 6).offset(x: 6, y: 5)
        }
      }
      HStack(spacing: 8) {
        Circle().strokeBorder(Theme.gray900, lineWidth: 3).frame(width: 12, height: 12).frame(width: 18)
        Text(Directions.arrival(route.to)).font(.body14).foregroundStyle(Theme.textPrimary)
      }
    }
    .padding(.horizontal, 16)
    .padding(.bottom, 16)
  }

  private func tag(_ text: String, ink: Color = Theme.textSecondary, fill: Color = Theme.gray100, bold: Bool = false) -> some View {
    Text(text)
      .font(.system(size: 11, weight: bold ? .bold : .medium))
      .foregroundStyle(ink)
      .padding(.horizontal, 6)
      .padding(.vertical, 1)
      .background(fill, in: Capsule())
  }
}

/// 다음 수업 한 줄 — 다음에 어디로 가야 하고, 언제 나서야 하는가.
private struct NextClassRow: View {
  let model: AppModel

  var body: some View {
    if model.hasTimetable {
      if let upcoming = model.upcoming {
        row(upcoming)
      } else {
        Text("남은 수업이 없습니다").font(.caption12).foregroundStyle(Theme.textTertiary)
          .padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 12)
      }
    }
  }

  private func row(_ upcoming: Upcoming) -> some View {
    let place = model.upcomingPlace
    let route = model.route
    /* 도착지가 그 건물로 잡혀 있을 때만 '언제 나가나' 를 말할 수 있다. */
    let aimed = place != nil && route?.to.id == place?.id
    let leave = aimed ? route.map { Schedule.leaveBy(upcoming.startsAt, $0.seconds, upcoming.slot.room) } : nil
    let late = leave.map { $0 < model.now } ?? false

    return HStack(spacing: 8) {
      VStack(alignment: .leading, spacing: 3) {
        HStack(spacing: 7) {
          Text(Schedule.when(upcoming.startsAt, model.now))
            .font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
            .padding(.horizontal, 8).padding(.vertical, 2)
            .background(Theme.accent, in: Capsule())
          /* 과목 이름은 안 가져온다. 걸어가는 사람에게 필요한 것은 어느 건물이냐다. */
          Text(place?.name ?? upcoming.slot.room).font(.bodyStrong).foregroundStyle(Theme.textPrimary).lineLimit(1)
        }
        Text("\(Schedule.clock(upcoming.startsAt)) · \(upcoming.slot.room)\(place == nil ? " · 건물을 못 찾음" : "")")
          .font(.caption12).foregroundStyle(Theme.textSecondary)
        if let leave, let route {
          let head = late
            ? "\(Schedule.clock(leave)) 에 나섰어야 합니다"
            : "\(Schedule.clock(leave)) 출발 — \(Schedule.until(leave, model.now))"
          Text("\(Text(head).bold()) 걷기 \(formatDuration(route.seconds)) · 건물 안 \(formatDuration(Schedule.indoorSeconds(upcoming.slot.room)))")
            .font(.caption12).foregroundStyle(late ? Theme.warn : Theme.ok)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      if place != nil && !aimed {
        Button(action: model.goToClass) {
          Text("길찾기").font(.system(size: 12, weight: .bold)).pill(.white, fill: Theme.accent, stroke: nil, h: 13, v: 7)
        }
        .buttonStyle(.plain)
      }
    }
    .padding(.horizontal, 16)
    .padding(.top, 10)
    .padding(.bottom, 12)
    .background(late ? Theme.warnSoft : .clear)
  }
}
