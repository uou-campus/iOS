import Foundation

// Client/src/types/campus.ts · routing/{geo,graph,cost,dijkstra,route}.ts 를 그대로 옮겼다.
// 숫자 하나라도 바꾸면 웹과 길이 달라진다 — 고칠 때는 양쪽을 같이 고친다.

// MARK: - 자료형

struct LatLng: Codable, Hashable {
  var lat: Double
  var lng: Double
}

enum NodeKind: String, Codable {
  case building, place, gate, junction
}

enum Surface: String, Codable {
  case road, path, stairs, slope, indoor, crosswalk

  var label: String {
    switch self {
    case .road: "차도 옆"
    case .path: "보행로"
    case .crosswalk: "횡단"
    case .slope: "비탈"
    case .stairs: "계단"
    case .indoor: "건물 안"
    }
  }
}

struct CampusNode: Codable, Identifiable, Hashable {
  let id: String
  let kind: NodeKind
  var name: String
  var no: Int?
  var aliases: [String]?
  let lat: Double
  let lng: Double
  /// `approx` 면 아직 걸어 보고 확인하지 않은 좌표.
  let precision: String

  var at: LatLng { LatLng(lat: lat, lng: lng) }
}

struct CampusEdge: Codable {
  let id: String
  let from: String
  let to: String
  let surface: Surface
  let shortcut: Bool
  let covered: Bool
  let connector: Bool
  let via: [LatLng]?
}

struct CampusDoc: Codable {
  let nodes: [CampusNode]
  let edges: [CampusEdge]
}

// MARK: - 기하

enum Geo {
  private static let earthRadius = 6_371_008.8
  private static let metersPerDegLat = 111_320.0
  private static func rad(_ deg: Double) -> Double { deg * .pi / 180 }

  /// 두 점 사이 대권 거리(m).
  static func distance(_ a: LatLng, _ b: LatLng) -> Double {
    let dLat = rad(b.lat - a.lat)
    let dLng = rad(b.lng - a.lng)
    let h = pow(sin(dLat / 2), 2) + cos(rad(a.lat)) * cos(rad(b.lat)) * pow(sin(dLng / 2), 2)
    return 2 * earthRadius * asin(min(1, sqrt(h)))
  }

  static func length(_ points: [LatLng]) -> Double {
    guard points.count > 1 else { return 0 }
    return (1..<points.count).reduce(0) { $0 + distance(points[$1 - 1], points[$1]) }
  }

  /// a 에서 b 를 볼 때의 방위각(0~360, 북쪽이 0).
  static func bearing(_ a: LatLng, _ b: LatLng) -> Double {
    let lat1 = rad(a.lat), lat2 = rad(b.lat), dLng = rad(b.lng - a.lng)
    let y = sin(dLng) * cos(lat2)
    let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLng)
    return (atan2(y, x) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
  }

  /// -180~180. 양수면 오른쪽으로 꺾인 것.
  static func turnAngle(_ from: Double, _ to: Double) -> Double {
    (to - from + 540).truncatingRemainder(dividingBy: 360) - 180
  }

  static func toPlane(_ p: LatLng, _ origin: LatLng) -> (x: Double, y: Double) {
    ((p.lng - origin.lng) * metersPerDegLat * cos(rad(origin.lat)), (p.lat - origin.lat) * metersPerDegLat)
  }

  static func fromPlane(_ x: Double, _ y: Double, _ origin: LatLng) -> LatLng {
    LatLng(lat: origin.lat + y / metersPerDegLat, lng: origin.lng + x / (metersPerDegLat * cos(rad(origin.lat))))
  }
}

// MARK: - 그래프

struct Link {
  let edge: CampusEdge
  let to: String
  let meters: Double
  /// from → to 방향으로 늘어놓은 좌표.
  let points: [LatLng]
}

final class CampusGraph {
  let nodes: [String: CampusNode]
  /// 문서 순서 그대로. 가까운 노드를 찾을 때 웹과 같은 순서로 훑는다.
  let nodeList: [CampusNode]
  let edges: [CampusEdge]
  let links: [String: [Link]]
  /// 이름으로 찾을 수 있는 곳들 — 길목은 뺀다.
  let places: [CampusNode]

  init(doc: CampusDoc) {
    let nodes = Dictionary(doc.nodes.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
    var links: [String: [Link]] = [:]
    var edges: [CampusEdge] = []
    for edge in doc.edges {
      guard let a = nodes[edge.from], let b = nodes[edge.to] else { continue }
      let forward = [a.at] + (edge.via ?? []) + [b.at]
      let meters = Geo.length(forward)
      edges.append(edge)
      links[edge.from, default: []].append(Link(edge: edge, to: edge.to, meters: meters, points: forward))
      links[edge.to, default: []].append(Link(edge: edge, to: edge.from, meters: meters, points: forward.reversed()))
    }
    let korean = Locale(identifier: "ko")
    self.nodes = nodes
    self.nodeList = doc.nodes
    self.edges = edges
    self.links = links
    self.places = doc.nodes.filter { $0.kind != .junction }.sorted {
      let (a, b) = ($0.no ?? 999, $1.no ?? 999)
      return a != b ? a < b : $0.name.compare($1.name, locale: korean) == .orderedAscending
    }
  }

  /// 앱에 실린 캠퍼스 그래프. Client/src/data/campus.json 을 빌드할 때 그대로 싣는다.
  static let bundled: CampusGraph = {
    let url = Bundle.main.url(forResource: "campus", withExtension: "json")!
    return CampusGraph(doc: try! JSONDecoder().decode(CampusDoc.self, from: Data(contentsOf: url)))
  }()

  func nearest(_ point: LatLng, where filter: (CampusNode) -> Bool = { _ in true }) -> (node: CampusNode, meters: Double)? {
    var best: (node: CampusNode, meters: Double)?
    for node in nodeList where filter(node) {
      let meters = Geo.distance(point, node.at)
      if best == nil || meters < best!.meters { best = (node, meters) }
    }
    return best
  }
}

// MARK: - 비용

enum Profile: String, CaseIterable, Identifiable {
  case distance, time, shortcut
  var id: String { rawValue }

  var label: String {
    switch self {
    case .distance: "최단거리"
    case .time: "최소시간"
    case .shortcut: "지름길 우선"
    }
  }

  /// 결과를 나란히 견줄 상대.
  var other: Profile { self == .time ? .distance : .time }
}

struct RouteOptions: Equatable {
  var profile: Profile = .time
  var allowIndoor = true
  /// 차도만 따라 도는 기준선. 화면에 내놓지 않는다.
  var roadsOnly = false
}

enum Cost {
  static let walkSpeed = 1.3
  private static let meterDislike = 0.12
  private static let shortcutDiscount = 0.45

  private static func slowdown(_ s: Surface) -> Double {
    switch s {
    case .road, .path, .crosswalk: 1
    case .slope: 1.35
    case .stairs: 2.2
    case .indoor: 1.15
    }
  }

  private static func entryPenalty(_ s: Surface) -> Double {
    switch s {
    case .crosswalk: 10
    case .stairs: 4
    case .indoor: 12
    default: 0
    }
  }

  static func seconds(_ edge: CampusEdge, _ meters: Double) -> Double {
    meters * slowdown(edge.surface) / walkSpeed + entryPenalty(edge.surface)
  }

  static func cost(_ edge: CampusEdge, _ meters: Double, _ options: RouteOptions) -> Double {
    if !options.allowIndoor && edge.surface == .indoor { return .infinity }
    if options.roadsOnly && !edge.connector && edge.surface != .road { return .infinity }
    let base = options.profile == .distance ? meters : seconds(edge, meters) + meterDislike * meters
    return options.profile == .shortcut && edge.shortcut ? base * shortcutDiscount : base
  }
}

// MARK: - 다익스트라

private struct MinHeap {
  private var items: [(id: String, cost: Double)] = []
  var isEmpty: Bool { items.isEmpty }

  mutating func push(_ id: String, _ cost: Double) {
    items.append((id, cost))
    var i = items.count - 1
    while i > 0 {
      let parent = (i - 1) >> 1
      if items[parent].cost <= items[i].cost { break }
      items.swapAt(parent, i)
      i = parent
    }
  }

  mutating func pop() -> (id: String, cost: Double) {
    let top = items[0]
    let last = items.removeLast()
    if !items.isEmpty {
      items[0] = last
      var i = 0
      while true {
        let l = i * 2 + 1, r = l + 1
        var smallest = i
        if l < items.count && items[l].cost < items[smallest].cost { smallest = l }
        if r < items.count && items[r].cost < items[smallest].cost { smallest = r }
        if smallest == i { break }
        items.swapAt(smallest, i)
        i = smallest
      }
    }
    return top
  }
}

private struct Step {
  let link: Link
  let from: String
}

/// 건물은 목적지지 통로가 아니다. 접속선 두 가닥을 이어 붙이면 건물을 뚫고 가는 길이 된다.
private func canPassThrough(_ kind: NodeKind) -> Bool { kind != .building && kind != .place }

private func shortestPath(_ graph: CampusGraph, _ from: String, _ to: String, _ options: RouteOptions) -> [Step]? {
  if from == to { return [] }
  guard graph.nodes[from] != nil, graph.nodes[to] != nil else { return nil }

  var best: [String: Double] = [from: 0]
  var came: [String: Step] = [:]
  var settled = Set<String>()
  var queue = MinHeap()
  queue.push(from, 0)

  while !queue.isEmpty {
    let (id, cost) = queue.pop()
    if settled.contains(id) { continue }
    settled.insert(id)
    if id == to { break }
    if id != from, let kind = graph.nodes[id]?.kind, !canPassThrough(kind) { continue }

    for link in graph.links[id] ?? [] {
      if settled.contains(link.to) { continue }
      let weight = Cost.cost(link.edge, link.meters, options)
      if !weight.isFinite { continue }
      let next = cost + weight
      if next < best[link.to, default: .infinity] {
        best[link.to] = next
        came[link.to] = Step(link: link, from: id)
        queue.push(link.to, next)
      }
    }
  }

  guard came[to] != nil else { return nil }
  var steps: [Step] = []
  var at = to
  while at != from {
    let step = came[at]!
    steps.append(step)
    at = step.from
  }
  return steps.reversed()
}

// MARK: - 경로

struct RouteLeg {
  let link: Link
  let from: String
  let meters: Double
  let seconds: Double
}

struct Route {
  let from: CampusNode
  let to: CampusNode
  let options: RouteOptions
  let legs: [RouteLeg]
  let points: [LatLng]
  let meters: Double
  let seconds: Double
  let shortcutMeters: Double
  let stairsMeters: Double
  let indoorMeters: Double
  /// 차도를 벗어나 보행로·계단으로 지나는 구간의 길이.
  let footMeters: Double
}

func findRoute(_ graph: CampusGraph, _ fromId: String, _ toId: String, _ options: RouteOptions) -> Route? {
  guard let from = graph.nodes[fromId], let to = graph.nodes[toId],
        let steps = shortestPath(graph, fromId, toId, options) else { return nil }

  let legs = steps.map {
    RouteLeg(link: $0.link, from: $0.from, meters: $0.link.meters, seconds: Cost.seconds($0.link.edge, $0.link.meters))
  }
  var points: [LatLng] = []
  for leg in legs { points += points.isEmpty ? leg.link.points : Array(leg.link.points.dropFirst()) }
  func sum(_ pick: (RouteLeg) -> Double) -> Double { legs.reduce(0) { $0 + pick($1) } }

  return Route(
    from: from, to: to, options: options, legs: legs,
    points: legs.isEmpty ? [from.at] : points,
    meters: sum { $0.meters },
    seconds: sum { $0.seconds },
    shortcutMeters: sum { $0.link.edge.shortcut ? $0.meters : 0 },
    stairsMeters: sum { $0.link.edge.surface == .stairs ? $0.meters : 0 },
    indoorMeters: sum { $0.link.edge.surface == .indoor ? $0.meters : 0 },
    footMeters: sum { !$0.link.edge.connector && $0.link.edge.surface != .road ? $0.meters : 0 }
  )
}

func sameRoute(_ a: Route?, _ b: Route?) -> Bool {
  guard let a, let b else { return a == nil && b == nil }
  return a.legs.count == b.legs.count && zip(a.legs, b.legs).allSatisfy { $0.link.edge.id == $1.link.edge.id }
}
