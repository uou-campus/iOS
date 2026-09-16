import Foundation

// Client/src/routing/{progress,directions}.ts · utils/{format,korean,place}.ts

// MARK: - 진행

struct RouteProgress {
  let snapped: LatLng
  let offRoute: Double
  let along: Double
  let remainingMeters: Double
  let remainingSeconds: Double
  let passed: [LatLng]
  let ahead: [LatLng]
}

enum Progress {
  /// 도착으로 보는 거리. 건물 좌표는 출입구가 아니라 한가운데다.
  static let arrivedMeters = 15.0

  /// 35m 와 GPS 오차 반경의 1.5배 중 큰 쪽.
  static func offRouteLimit(_ accuracy: Double?) -> Double { max(35, (accuracy ?? 0) * 1.5) }

  static func track(_ route: Route, _ at: LatLng) -> RouteProgress? {
    let points = route.points
    guard points.count > 1 else { return nil }

    var best: (index: Int, t: Double, meters: Double)?
    for i in 1..<points.count {
      let p = Geo.toPlane(at, points[i - 1])
      let q = Geo.toPlane(points[i], points[i - 1])
      let lengthSquared = q.x * q.x + q.y * q.y
      let t = lengthSquared == 0 ? 0 : max(0, min(1, (p.x * q.x + p.y * q.y) / lengthSquared))
      let meters = hypot(p.x - q.x * t, p.y - q.y * t)
      if best == nil || meters < best!.meters { best = (i, t, meters) }
    }
    guard let best else { return nil }

    let a = points[best.index - 1]
    let plane = Geo.toPlane(points[best.index], a)
    let snapped = Geo.fromPlane(plane.x * best.t, plane.y * best.t, a)

    var along = 0.0
    for i in stride(from: 1, to: best.index, by: 1) { along += Geo.distance(points[i - 1], points[i]) }
    along += Geo.distance(a, snapped)

    /* 남은 시간은 구간마다 속도가 달라서, 지나온 만큼만 덜어 낸다. */
    var walked = 0.0
    var remainingSeconds = 0.0
    for leg in route.legs {
      let legStart = walked
      walked += leg.meters
      if walked <= along { continue }
      let left = min(leg.meters, walked - max(along, legStart))
      remainingSeconds += leg.meters > 0 ? left / leg.meters * leg.seconds : 0
    }

    return RouteProgress(
      snapped: snapped,
      offRoute: best.meters,
      along: along,
      remainingMeters: max(0, route.meters - along),
      remainingSeconds: remainingSeconds,
      passed: Array(points[..<best.index]) + [snapped],
      ahead: [snapped] + Array(points[best.index...])
    )
  }

  /// 따라온 거리로 몇 번째 안내 줄인지.
  static func stepAt(_ stepMeters: [Double], _ along: Double) -> Int {
    var walked = 0.0
    for (i, m) in stepMeters.enumerated() {
      walked += m
      if along < walked { return i }
    }
    return max(0, stepMeters.count - 1)
  }
}

// MARK: - 안내문

enum Turn {
  case straight, slightLeft, slightRight, left, right, back

  init(angle: Double) {
    let abs = Swift.abs(angle)
    if abs < 20 { self = .straight }
    else if abs > 135 { self = .back }
    else if abs < 55 { self = angle > 0 ? .slightRight : .slightLeft }
    else { self = angle > 0 ? .right : .left }
  }

  var text: String {
    switch self {
    case .straight: "직진"
    case .slightLeft: "왼쪽으로 살짝 꺾어"
    case .slightRight: "오른쪽으로 살짝 꺾어"
    case .left: "왼쪽으로"
    case .right: "오른쪽으로"
    case .back: "왔던 쪽으로"
    }
  }

  /// 걸으면서 흘깃 보는 배너에는 문장이 아니라 낱말이 맞다.
  var brief: String {
    switch self {
    case .straight: "직진"
    case .slightLeft: "왼쪽으로 살짝"
    case .slightRight: "오른쪽으로 살짝"
    case .left: "왼쪽으로 꺾기"
    case .right: "오른쪽으로 꺾기"
    case .back: "왔던 쪽으로"
    }
  }
}

struct DirectionStep {
  let turn: Turn?
  let text: String
  let meters: Double
  let seconds: Double
  let surface: Surface
  let shortcut: Bool
  let covered: Bool

  var brief: String { (turn ?? .straight).brief }
}

enum Directions {
  private static let mergeAngle = 40.0
  private static let mergeMeters = 30.0
  private static let landmarkMeters = 45.0

  private static func phrase(_ s: Surface) -> String? {
    switch s {
    case .stairs: "계단으로"
    case .slope: "비탈을 따라"
    case .indoor: "건물 안을 지나"
    case .crosswalk: "길을 건너"
    default: nil
    }
  }

  /// 길목에는 이름이 없다. 근처 건물을 표지로 삼는다.
  static func landmark(_ graph: CampusGraph, _ at: LatLng) -> String {
    var best: (name: String, meters: Double)?
    for place in graph.places {
      let meters = Geo.distance(at, place.at)
      if meters > landmarkMeters { continue }
      if best == nil || meters < best!.meters { best = (place.name, meters) }
    }
    return best?.name ?? ""
  }

  private static func roundMeters(_ m: Double) -> Int {
    m < 100 ? Int(jsRound(m / 5)) * 5 : Int(jsRound(m / 10)) * 10
  }

  /// 크게 꺾는 자리만 남기고, 짧은 토막은 앞 줄에 흡수시킨 뒤, 남은 자리마다 근처 건물 이름을 붙인다.
  static func steps(_ graph: CampusGraph, _ route: Route) -> [DirectionStep] {
    guard let first = route.legs.first else { return [] }
    let entry = { (leg: RouteLeg) in Geo.bearing(leg.link.points[0], leg.link.points[1]) }
    let exit = { (leg: RouteLeg) -> Double in
      let p = leg.link.points
      return Geo.bearing(p[p.count - 2], p[p.count - 1])
    }
    let sameKind = { (a: RouteLeg, b: RouteLeg) in
      a.link.edge.surface == b.link.edge.surface && a.link.edge.shortcut == b.link.edge.shortcut
        && a.link.edge.covered == b.link.edge.covered
    }
    let nameOf = { (id: String) in graph.nodes[id]?.name ?? "" }

    /* 1. 크게 꺾지 않고 성격도 같은 구간끼리 묶는다. */
    var groups: [(legs: [RouteLeg], turn: Turn?)] = [([first], nil)]
    for leg in route.legs.dropFirst() {
      let prev = groups[groups.count - 1].legs.last!
      let angle = Geo.turnAngle(exit(prev), entry(leg))
      if abs(angle) < mergeAngle && sameKind(prev, leg) { groups[groups.count - 1].legs.append(leg) }
      else { groups.append(([leg], Turn(angle: angle))) }
    }

    /* 2. 너무 짧은 토막은 앞 줄에 붙인다. */
    var merged: [(legs: [RouteLeg], turn: Turn?)] = []
    for group in groups {
      let meters = group.legs.reduce(0) { $0 + $1.meters }
      if !merged.isEmpty && meters < mergeMeters { merged[merged.count - 1].legs += group.legs }
      else { merged.append(group) }
    }

    /* 3. 줄마다 표지를 붙여 문장으로 만든다. */
    var lastLandmark = nameOf(first.from)
    return merged.enumerated().map { index, group in
      let head = group.legs[0], tail = group.legs[group.legs.count - 1]
      let meters = group.legs.reduce(0) { $0 + $1.meters }
      let seconds = group.legs.reduce(0) { $0 + $1.seconds }
      let edge = head.link.edge

      let at = index == 0 ? "" : landmark(graph, head.link.points[0])
      let showLandmark = !at.isEmpty && at != lastLandmark
      if !at.isEmpty { lastLandmark = at }

      let target = nameOf(tail.link.to)
      var parts: [String] = []
      if index == 0 {
        let origin = nameOf(head.from)
        parts.append("\(origin.isEmpty ? "출발지" : origin)에서 출발,")
      } else {
        if showLandmark { parts.append("\(at) 앞에서") }
        parts.append((group.turn ?? .straight).text)
      }
      if let p = phrase(edge.surface) { parts.append(p) }
      parts.append("\(roundMeters(meters))m")
      if !target.isEmpty && target != at { parts.append("— \(target)") }

      return DirectionStep(
        turn: group.turn, text: parts.joined(separator: " "), meters: meters, seconds: seconds,
        surface: edge.surface, shortcut: edge.shortcut, covered: edge.covered
      )
    }
  }

  static func arrival(_ to: CampusNode) -> String {
    "\(to.name)\(to.no.map { " (\($0)번)" } ?? "") 도착"
  }
}

// MARK: - 글자 모양

/// 자바스크립트 Math.round 와 같은 반올림(.5 는 늘 위로).
func jsRound(_ x: Double) -> Double { (x + 0.5).rounded(.down) }

func formatMeters(_ meters: Double) -> String {
  meters >= 1000 ? String(format: "%.2fkm", meters / 1000) : "\(Int(jsRound(meters)))m"
}

func formatDuration(_ seconds: Double) -> String {
  if seconds < 60 { return "\(Int(jsRound(seconds)))초" }
  let minutes = Int(jsRound(seconds / 60))
  if minutes < 60 { return "\(minutes)분" }
  return "\(minutes / 60)시간 \(minutes % 60)분"
}

func formatDelta(_ value: Double, _ base: Double, _ unit: (Double) -> String) -> String {
  let diff = value - base
  if abs(diff) < 1 { return "같음" }
  return "\(diff > 0 ? "+" : "−")\(unit(abs(diff)))"
}

/// '로 / 으로'. 받침이 없거나 ㄹ 받침이면 '로'.
func josaRo(_ word: String) -> String {
  guard let code = word.unicodeScalars.last?.value, (0xAC00...0xD7A3).contains(code) else { return "로" }
  let final = (code - 0xAC00) % 28
  return final == 0 || final == 8 ? "로" : "으로"
}

/// 이름·별칭·건물번호 아무거나 걸리면 후보로 올린다.
func matchesPlace(_ node: CampusNode, _ query: String) -> Bool {
  let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
  if q.isEmpty { return true }
  if node.no.map({ String($0) }) == q { return true }
  if node.name.lowercased().contains(q) { return true }
  return (node.aliases ?? []).contains { $0.lowercased().contains(q) }
}
