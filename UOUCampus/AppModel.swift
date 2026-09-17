import Foundation
import Observation

enum Field: String, Identifiable {
  case from, to
  var id: String { rawValue }
  var label: String { self == .from ? "출발지" : "도착지" }
}

/// 폰에서 시트가 어느 자리에 있는지. hidden 은 지도에서 곳을 고르는 중.
enum SheetState {
  case expanded, collapsed, hidden
}

/// Client/src/App.tsx 의 상태와 손짓을 한 곳에 모았다. 화면의 단계는 여기서만 정한다.
@Observable
final class AppModel {
  let graph = CampusGraph.bundled
  let locator = Locator()
  let indoorCount = CampusGraph.bundled.edges.filter { $0.surface == .indoor }.count
  let shortcutCount = CampusGraph.bundled.edges.filter(\.shortcut).count

  var fromId: String? { didSet { recompute() } }
  var toId: String? { didSet { recompute() } }
  var options = RouteOptions() { didSet { recompute() } }

  private(set) var route: Route?
  /// 다른 기준으로 잡으면 길이 달라질 때만 있다.
  private(set) var compare: Route?
  /// 큰길로만 돌았을 때의 기준선.
  private(set) var roadsOnly: Route?
  /// 상단 띠, 진행 줄, 안내 목록이 나눠 쓴다. 따로 셈하면 '지금 몇 번째 줄' 이 어긋난다.
  private(set) var steps: [DirectionStep] = []

  /// 전체 화면 장소 목록을 띄운 칸.
  var picker: Field?
  /// 지도에서 직접 고르는 중인 칸. 이때는 시트를 치우고 지도만 남긴다.
  var picking: Field?
  var guiding = false
  var timetableOpen = false
  private(set) var slots = TimetableStore.load()
  var now = Date()

  /// 사람이 손으로 잡아 둔 시트 자리. 어느 구간을 보다가 잡은 것인지까지 같이 들고 있는다.
  private var heldSheet: (pair: String, at: SheetState)?
  /// 다음에 잡히는 첫 좌표를 출발지로 삼을지. '현위치에서 출발' 을 눌렀을 때만 참이다.
  @ObservationIgnored private var claimFirstFix = true

  init() {
    locator.onFirstFix = { [weak self] at in
      guard let self, self.claimFirstFix else { return }
      self.claimFirstFix = false
      /* 건물만 골라 붙이면 열에 일곱은 시작하자마자 '경로에서 벗어남' 이다. 길목까지 포함한다. */
      if let near = self.graph.nearest(at), near.meters <= Self.campusReach { self.fromId = near.node.id }
    }
    locator.onFix = { [weak self] in self?.rerouteIfLost() }
  }

  /// 벗어난 채로 이만큼 지나면 선 자리에서 길을 다시 찾는다(초). GPS 가 한 번 튄 것으로는 안 바꾼다.
  static let rerouteAfter = 5.0
  @ObservationIgnored private var lostSince: Date?

  /// 안내 중 한참 벗어나 있으면 지금 선 자리에서 가장 가까운 곳을 출발지로 다시 세운다.
  private func rerouteIfLost() {
    guard guiding, lost, locator.status == .ready, let here = locator.here else {
      lostSince = nil
      return
    }
    let since = lostSince ?? Date()
    lostSince = since
    /* 도착지 코앞이면 출발지와 도착지가 같아져 안내가 사라진다. */
    guard Date().timeIntervalSince(since) >= Self.rerouteAfter,
          let near = graph.nearest(here), near.node.id != toId else { return }
    lostSince = nil
    fromId = near.node.id
  }

  /// 가장 가까운 곳이 이보다 멀면 캠퍼스 밖이다(m). 정문 건너 정류장쯤까지는 봐준다.
  static let campusReach = 300.0

  /// 집에서 켜면 캠퍼스 끝 길목이 '현위치 근처' 로 들어앉고 지도는 집으로 날아간다.
  var offCampus: Bool {
    guard let here = locator.here else { return false }
    return (graph.nearest(here)?.meters ?? .infinity) > Self.campusReach
  }

  private func recompute() {
    guard let fromId, let toId else {
      route = nil
      compare = nil
      roadsOnly = nil
      steps = []
      return
    }
    route = findRoute(graph, fromId, toId, options)
    let alt = findRoute(graph, fromId, toId, RouteOptions(profile: options.profile.other, allowIndoor: options.allowIndoor))
    compare = sameRoute(route, alt) ? nil : alt
    var roads = options
    roads.roadsOnly = true
    roadsOnly = findRoute(graph, fromId, toId, roads)
    steps = route.map { Directions.steps(graph, $0) } ?? []
  }

  // MARK: 파생 값

  var toNode: CampusNode? { toId.flatMap { graph.nodes[$0] } }

  /// 길목에는 이름이 없다. 현위치로 잡힌 자리는 가까운 건물 이름을 빌려 부른다.
  var fromNode: CampusNode? {
    guard var node = fromId.flatMap({ graph.nodes[$0] }) else { return nil }
    if node.name.isEmpty {
      let near = Directions.landmark(graph, node.at)
      node.name = "\(near.isEmpty ? "현위치" : near) 근처"
    }
    return node
  }

  var hasRoute: Bool { !(route?.legs.isEmpty ?? true) }
  var unreachable: Bool { fromId != nil && toId != nil && fromId != toId && route == nil }

  var progress: RouteProgress? {
    /* 캠퍼스 밖이면 '경로에서 수만 km' 가 뜬다. 따라갈 게 없다. */
    guard let route, let here = locator.here, !offCampus else { return nil }
    return Progress.track(route, here)
  }

  var lost: Bool { progress.map { $0.offRoute > Progress.offRouteLimit(locator.accuracy) } ?? false }
  var arrived: Bool { (progress?.remainingMeters ?? .infinity) <= Progress.arrivedMeters }
  var stepIndex: Int { progress.map { Progress.stepAt(steps.map(\.meters), $0.along) } ?? 0 }

  /// 고를 게 남았으면 펼쳐 두고, 두 곳이 다 정해지면 접어서 지도를 내준다.
  var sheet: SheetState {
    if picking != nil { return .hidden }
    if let heldSheet, heldSheet.pair == pair { return heldSheet.at }
    return fromId != nil && toId != nil ? .collapsed : .expanded
  }

  private var pair: String { "\(fromId ?? "")→\(toId ?? "")" }

  func holdSheet(_ at: SheetState) { heldSheet = (pair, at) }

  // MARK: 시간표

  var hasTimetable: Bool { !slots.isEmpty }
  var upcoming: Upcoming? { hasTimetable ? Schedule.next(slots, now) : nil }
  var upcomingPlace: CampusNode? { upcoming.flatMap { Room.place(graph, $0.slot.room) } }

  /// 다음 수업 건물을 도착지로 세운다. 출발지는 사람이 고른 것을 지킨다.
  func goToClass() {
    if let place = upcomingPlace { toId = place.id }
  }

  func saveTimetable(_ slots: [ClassSlot]) {
    self.slots = slots
    TimetableStore.save(slots)
  }

  func clearTimetable() {
    slots = []
    TimetableStore.clear()
  }

  // MARK: 곳 고르기

  private func assign(_ field: Field, _ node: CampusNode) {
    if field == .from { fromId = node.id } else { toId = node.id }
  }

  /// 목록에서 골랐다. 반대편이 비어 있으면 이어서 그 칸을 연다.
  func pickFromList(_ node: CampusNode) {
    guard let field = picker else { return }
    assign(field, node)
    let otherEmpty = field == .from ? toId == nil : fromId == nil
    picker = otherEmpty ? (field == .from ? .to : .from) : nil
  }

  func startMapPick(_ field: Field) {
    picker = nil
    picking = field
  }

  func useHereAsOrigin() {
    claimFirstFix = true
    locator.start()
    picker = nil
  }

  func pickNode(_ node: CampusNode) {
    if let field = picking {
      assign(field, node)
      picking = nil
      return
    }
    /* 안내 중에 지도를 누르다 출발지가 바뀌면 걷던 길이 사라진다. */
    if guiding { return }
    if fromId == nil {
      fromId = node.id
    } else if toId == nil && node.id != fromId {
      toId = node.id
    } else {
      fromId = node.id
      toId = nil
    }
  }

  /// 고르는 중이면 누른 자리에서 120m 안의 가장 가까운 곳을 잡는다. 빈 자리에 엉뚱한 건물이 들어오면 더 나쁘다.
  func tapMap(_ at: LatLng) {
    guard let field = picking, let near = graph.nearest(at, where: { $0.kind != .junction }),
          near.meters <= 120 else { return }
    assign(field, near.node)
    picking = nil
  }

  func swap() {
    (fromId, toId) = (toId, fromId)
  }

  // MARK: 안내

  func startGuide() {
    guard route != nil else { return }
    /* 위치가 없으면 따라갈 게 없다. 다만 출발지는 사람이 고른 것을 지킨다. */
    if !locator.active {
      claimFirstFix = false
      locator.start()
    }
    guiding = true
    holdSheet(.collapsed)
  }

  func stopGuide() { guiding = false }
}
