import MapKit
import SwiftUI

/// Client/src/components/Map + map/mapStyle.ts. 바탕은 웹과 같은 OpenStreetMap 타일이다 —
/// 캠퍼스 안 보행로와 계단이 그려진 지도는 그쪽뿐이다.
struct CampusMapView: UIViewRepresentable {
  let model: AppModel
  // 아래 값들은 SwiftUI 가 바뀔 때마다 지도를 다시 맞추게 하려고 따로 받는다.
  let route: Route?
  let fromId: String?
  let toId: String?
  let here: LatLng?
  let accuracy: Double?
  let sheet: SheetState
  let picking: Bool
  let guiding: Bool
  let landscape: Bool
  /// 패널이 지도를 가리는 만큼. 캠퍼스를 보이는 자리에 맞출 때 피한다.
  let insets: UIEdgeInsets

  func makeCoordinator() -> MapCoordinator { MapCoordinator() }

  func makeUIView(context: Context) -> LayoutMapView {
    let map = LayoutMapView()
    let coordinator = context.coordinator
    map.delegate = coordinator
    map.showsCompass = false
    map.isRotateEnabled = false
    map.isPitchEnabled = false
    map.pointOfInterestFilter = .excludingAll
    map.region = MKCoordinateRegion(
      center: CLLocationCoordinate2D(latitude: 35.5442, longitude: 129.2566),
      latitudinalMeters: 1200, longitudinalMeters: 1200
    )
    /* 타일은 19단계까지다. 더 당기면 바탕이 빈다. */
    map.cameraZoomRange = MKMapView.CameraZoomRange(minCenterCoordinateDistance: 250)

    let tiles = OverzoomTileOverlay(urlTemplate: "https://tile.openstreetmap.org/{z}/{x}/{y}.png")
    tiles.canReplaceMapContent = true
    tiles.maximumZ = 22
    map.addOverlay(tiles, level: .aboveLabels)
    map.addOverlays(MapCoordinator.baseOverlays(model.graph), level: .aboveLabels)

    /* 두 번 눌러 당기기는 지도에 맡기고, 한 번 누른 것만 받는다. */
    let double = UITapGestureRecognizer(target: nil, action: nil)
    double.numberOfTapsRequired = 2
    double.delegate = coordinator
    let single = UITapGestureRecognizer(target: coordinator, action: #selector(MapCoordinator.tapped(_:)))
    single.require(toFail: double)
    single.delegate = coordinator
    map.addGestureRecognizer(double)
    map.addGestureRecognizer(single)

    map.onLayout = { [weak coordinator, weak map] in
      if let coordinator, let map { coordinator.layoutChanged(map) }
    }
    return map
  }

  func updateUIView(_ map: LayoutMapView, context: Context) {
    context.coordinator.update(map, self)
  }
}

/// OSM 타일은 19단계까지다. 걷는 배율은 그보다 깊어서 MapKit 이 바탕을 비운다 — 19단계 타일을 잘라 채운다.
final class OverzoomTileOverlay: MKTileOverlay {
  private let nativeZ = 19

  override func loadTile(at path: MKTileOverlayPath, result: @escaping (Data?, Error?) -> Void) {
    let dz = path.z - nativeZ
    guard dz > 0 else { return super.loadTile(at: path, result: result) }
    var parent = path
    parent.x >>= dz
    parent.y >>= dz
    parent.z = nativeZ
    super.loadTile(at: parent) { data, error in
      guard let data, let image = UIImage(data: data)?.cgImage else { return result(nil, error) }
      let side = image.width >> dz
      let crop = CGRect(x: (path.x - (parent.x << dz)) * side, y: (path.y - (parent.y << dz)) * side, width: side, height: side)
      result(image.cropping(to: crop).flatMap { UIImage(cgImage: $0).pngData() }, nil)
    }
  }
}

final class LayoutMapView: MKMapView {
  var onLayout: (() -> Void)?

  override func layoutSubviews() {
    super.layoutSubviews()
    onLayout?()
  }
}

final class PlaceAnnotation: NSObject, MKAnnotation {
  enum Role { case place, gate, from, to }

  let node: CampusNode
  let role: Role
  let coordinate: CLLocationCoordinate2D

  init(node: CampusNode, role: Role) {
    self.node = node
    self.role = role
    coordinate = CLLocationCoordinate2D(latitude: node.lat, longitude: node.lng)
  }
}

final class HereAnnotation: NSObject, MKAnnotation {
  @objc dynamic var coordinate = CLLocationCoordinate2D()
}

private final class NameTag: UILabel {
  override var intrinsicContentSize: CGSize {
    let size = super.intrinsicContentSize
    return CGSize(width: size.width + 12, height: size.height + 2)
  }
}

private struct LineStyle {
  let color: UIColor
  let width: CGFloat
  let alpha: CGFloat
  var dash: [NSNumber]?
}

final class MapCoordinator: NSObject, MKMapViewDelegate, UIGestureRecognizerDelegate {
  private var view: CampusMapView!
  private var markerKey: String?
  private var routeKey: String?
  private var fitKey: String?
  private var legKey: String?
  private var routeOverlays: [MKOverlay] = []
  private var halo: MKCircle?
  private let hereDot = HereAnnotation()
  private var hereShown = false
  private var lastHere: LatLng?
  private var lastAccuracy: Double?
  private var following = false
  /// 안내를 켠 뒤 위치가 처음 잡히는 순간에 한 번만 당긴다. 그 뒤로 배율은 손대지 않는다.
  private var needsGuideZoom = false
  /// 마지막으로 맞춘 대상. 시트가 움직이면 같은 것을 다시 맞춘다.
  private var lastFit: [LatLng]?
  private var fitRequest: (points: [LatLng], remember: Bool)?
  private var lastSize = CGSize.zero
  /// 이름표는 17단계부터 보인다.
  private var labelsShown = false

  func update(_ map: MKMapView, _ view: CampusMapView) {
    self.view = view
    let model = view.model

    let markers = "\(view.fromId ?? "")|\(view.toId ?? "")"
    if markers != markerKey {
      markerKey = markers
      drawMarkers(map, model)
    }

    let progress = model.progress
    let ids = { (route: Route?) in route?.legs.map(\.link.edge.id).joined(separator: ",") ?? "-" }
    let routeNow = "\(ids(view.route))|\(ids(model.compare))|\(progress?.passed.count ?? 0)|\(progress?.snapped.lat ?? 0)|\(progress?.snapped.lng ?? 0)"
    if routeNow != routeKey {
      routeKey = routeNow
      drawRoute(map, view.route, model.compare, progress)
    }

    /* 시트가 움직이면 지도에 남는 자리가 달라진다. 따라가는 중에는 손대지 않는다. */
    let fitNow = "\(view.sheet)|\(view.picking)|\(view.guiding)|\(view.landscape)|\(Int(view.insets.left))|\(Int(view.insets.bottom))"
    if fitNow != fitKey {
      fitKey = fitNow
      if !view.guiding {
        let all = model.graph.nodeList.map(\.at)
        /* 고르는 중에는 어느 곳이든 누를 수 있게 캠퍼스 전체를. 그 맞춤은 기억하지 않는다. */
        if view.picking { fit(map, all, remember: false) } else { fit(map, lastFit ?? all) }
      }
    }

    /* 출발·도착이 바뀌면 경로가 다 보이게. 기준만 바꿀 때는 화면을 튀기지 않는다.
       안내 중 길을 다시 찾았을 때는 발밑을 따라가던 화면을 그대로 둔다. */
    let legNow = view.route.map { "\($0.from.id)→\($0.to.id)" } ?? ""
    if legNow != legKey {
      legKey = legNow
      if !view.guiding, let route = view.route, route.points.count >= 2 { fit(map, route.points) }
    }

    let followChanged = view.guiding != following
    if followChanged {
      following = view.guiding
      needsGuideZoom = following
    }
    if view.here != lastHere || view.accuracy != lastAccuracy || followChanged {
      lastHere = view.here
      lastAccuracy = view.accuracy
      drawHere(map, view.here, view.accuracy)
    }
  }

  func layoutChanged(_ map: MKMapView) {
    let size = map.bounds.size
    guard let view, size != lastSize, size.width > 0, size.height > 0 else { return }
    lastSize = size
    /* 폰을 돌렸다. 걷는 중이면 발밑으로, 아니면 보던 것을 다시 맞춘다. */
    if following, let here = view.here, !view.model.offCampus {
      map.setCenter(Self.coordinate(here), animated: false)
    } else if let request = fitRequest {
      fit(map, request.points, remember: request.remember)
    }
  }

  // MARK: 맞추기

  private static func coordinate(_ p: LatLng) -> CLLocationCoordinate2D {
    CLLocationCoordinate2D(latitude: p.lat, longitude: p.lng)
  }

  private func fit(_ map: MKMapView, _ points: [LatLng], remember: Bool = true) {
    if remember { lastFit = points }
    fitRequest = (points, remember)
    let size = map.bounds.size
    guard size.width > 0, size.height > 0, !points.isEmpty else { return }

    var rect = MKMapRect.null
    for p in points {
      let point = MKMapPoint(Self.coordinate(p))
      rect = rect.union(MKMapRect(x: point.x, y: point.y, width: 0, height: 0))
    }
    /* 화면 밖으로 내보낸 시트는 아무것도 가리지 않는다. 가려도 절반쯤은 남긴다. */
    let covered = view.sheet != .hidden
    let left = covered ? min(view.insets.left, size.width * 0.55) : 0
    let bottom = covered ? min(view.insets.bottom, size.height * 0.55) : 0
    map.setVisibleMapRect(
      rect, edgePadding: UIEdgeInsets(top: view.insets.top + 16, left: left + 16, bottom: bottom + 16, right: 16),
      animated: false
    )
  }

  private static func zoomLevel(_ map: MKMapView) -> Double {
    log2(MKMapSize.world.width / map.visibleMapRect.width * Double(map.bounds.width) / 256)
  }

  private func zoom(_ map: MKMapView, to center: CLLocationCoordinate2D, level: Double) {
    let size = map.bounds.size
    guard size.width > 0 else { return }
    let width = MKMapSize.world.width * Double(size.width) / (256 * pow(2, level))
    let height = width * Double(size.height / size.width)
    let p = MKMapPoint(center)
    map.setVisibleMapRect(MKMapRect(x: p.x - width / 2, y: p.y - height / 2, width: width, height: height), animated: false)
  }

  // MARK: 그리기

  static func baseOverlays(_ graph: CampusGraph) -> [MKOverlay] {
    var groups: [String: [MKPolyline]] = [:]
    for (id, links) in graph.links {
      /* 양방향이라 같은 간선이 두 번 나온다. 한쪽만 그린다. */
      for link in links where link.edge.from == id {
        let edge = link.edge
        let key = edge.connector ? "connector"
          : edge.shortcut ? "shortcut"
          : [Surface.stairs, .indoor, .road].contains(edge.surface) ? edge.surface.rawValue : "path"
        let coords = link.points.map(coordinate)
        groups[key, default: []].append(MKPolyline(coordinates: coords, count: coords.count))
      }
    }
    return ["road", "connector", "path", "indoor", "stairs", "shortcut"].compactMap { key in
      groups[key].map { lines -> MKOverlay in
        let multi = MKMultiPolyline(lines)
        multi.title = key
        return multi
      }
    }
  }

  private func drawRoute(_ map: MKMapView, _ route: Route?, _ compare: Route?, _ progress: RouteProgress?) {
    map.removeOverlays(routeOverlays)
    routeOverlays = []
    guard let route else { return }

    func line(_ points: [LatLng], _ title: String) -> MKPolyline {
      let coords = points.map(Self.coordinate)
      let polyline = MKPolyline(coordinates: coords, count: coords.count)
      polyline.title = title
      return polyline
    }

    if let compare { routeOverlays.append(line(compare.points, "compare")) }
    /* 흰 테를 한 겹 깔아 배경과 떼어 놓는다. 지도 위에서 초록은 이 선 하나뿐이다. */
    routeOverlays.append(line(route.points, "casing"))
    routeOverlays.append(line(route.points, "route"))
    if let progress, progress.passed.count > 1 { routeOverlays.append(line(progress.passed, "passed")) }
    for leg in route.legs where leg.link.edge.shortcut { routeOverlays.append(line(leg.link.points, "shortcutOverlay")) }
    map.addOverlays(routeOverlays, level: .aboveLabels)
  }

  private func drawMarkers(_ map: MKMapView, _ model: AppModel) {
    map.removeAnnotations(map.annotations.filter { $0 is PlaceAnnotation })
    map.addAnnotations(model.graph.nodeList.compactMap { node -> PlaceAnnotation? in
      guard node.kind != .junction else { return nil }
      let role: PlaceAnnotation.Role = node.id == view.fromId ? .from
        : node.id == view.toId ? .to
        : node.kind == .gate ? .gate : .place
      return PlaceAnnotation(node: node, role: role)
    })
  }

  private func drawHere(_ map: MKMapView, _ here: LatLng?, _ accuracy: Double?) {
    if let halo {
      map.removeOverlay(halo)
      self.halo = nil
    }
    guard let here else {
      if hereShown {
        map.removeAnnotation(hereDot)
        hereShown = false
      }
      return
    }

    let center = Self.coordinate(here)
    /* GPS 는 '여기' 가 아니라 '이 안쪽' 을 알려 준다. 점만큼 작은 반경은 그리지 않는다. */
    if let accuracy, accuracy > 10 {
      let circle = MKCircle(center: center, radius: accuracy)
      map.addOverlay(circle, level: .aboveLabels)
      halo = circle
    }
    hereDot.coordinate = center
    if !hereShown {
      map.addAnnotation(hereDot)
      hereShown = true
    }

    /* 캠퍼스 밖의 점을 쫓아가면 캠퍼스가 화면에서 사라진다. */
    if view.model.offCampus {
      return
    } else if following && needsGuideZoom {
      needsGuideZoom = false
      zoom(map, to: center, level: max(Self.zoomLevel(map), 18))
    } else if following {
      map.setCenter(center, animated: false)
    } else {
      /* 안내를 안 켰을 때는 정말로 화면을 벗어났을 때만 옮긴다. */
      let visible = map.visibleMapRect
      if !visible.insetBy(dx: visible.width * 0.15, dy: visible.height * 0.15).contains(MKMapPoint(center)) {
        map.setCenter(center, animated: false)
      }
    }
  }

  private static let styles: [String: LineStyle] = [
    "connector": LineStyle(color: Palette.gray300, width: 1, alpha: 0.5, dash: [1, 4]),
    "shortcut": LineStyle(color: Palette.gray700, width: 3.5, alpha: 0.62),
    "stairs": LineStyle(color: Palette.gray500, width: 3, alpha: 0.55, dash: [2, 4]),
    "indoor": LineStyle(color: Palette.gray500, width: 3, alpha: 0.5, dash: [1, 6]),
    "road": LineStyle(color: Palette.gray400, width: 1.5, alpha: 0.28),
    "path": LineStyle(color: Palette.gray500, width: 2.5, alpha: 0.4),
    "compare": LineStyle(color: Palette.warn, width: 4, alpha: 0.85, dash: [7, 6]),
    "casing": LineStyle(color: .white, width: 12, alpha: 0.95),
    "route": LineStyle(color: Palette.accent, width: 6, alpha: 1),
    "passed": LineStyle(color: Palette.gray400, width: 5, alpha: 0.65),
    "shortcutOverlay": LineStyle(color: .white, width: 2, alpha: 0.9, dash: [1, 7]),
  ]

  func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
    if let tiles = overlay as? MKTileOverlay { return MKTileOverlayRenderer(tileOverlay: tiles) }
    if let circle = overlay as? MKCircle {
      let renderer = MKCircleRenderer(circle: circle)
      renderer.strokeColor = Palette.here.withAlphaComponent(0.3)
      renderer.lineWidth = 1
      renderer.fillColor = Palette.here.withAlphaComponent(0.07)
      return renderer
    }
    let renderer: MKOverlayPathRenderer
    if let multi = overlay as? MKMultiPolyline {
      renderer = MKMultiPolylineRenderer(multiPolyline: multi)
    } else if let line = overlay as? MKPolyline {
      renderer = MKPolylineRenderer(polyline: line)
    } else {
      return MKOverlayRenderer(overlay: overlay)
    }
    let style = Self.styles[(overlay as? MKShape)?.title ?? ""] ?? Self.styles["path"]!
    renderer.strokeColor = style.color.withAlphaComponent(style.alpha)
    renderer.lineWidth = style.width
    renderer.lineDashPattern = style.dash
    renderer.lineCap = .round
    renderer.lineJoin = .round
    return renderer
  }

  func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
    let marker = MKAnnotationView(annotation: annotation, reuseIdentifier: nil)
    marker.isUserInteractionEnabled = false
    marker.displayPriority = .required
    marker.collisionMode = .none

    if annotation is HereAnnotation {
      marker.image = Self.hereImage
      marker.zPriority = MKAnnotationViewZPriority(rawValue: 900)
      return marker
    }
    guard let place = annotation as? PlaceAnnotation else { return nil }
    let endpoint = place.role == .from || place.role == .to
    marker.image = Self.markerImage(place)
    marker.zPriority = endpoint ? .max : .defaultUnselected

    let tag = NameTag()
    tag.text = place.node.name
    tag.font = .systemFont(ofSize: 12, weight: .medium)
    tag.textColor = Palette.gray900
    tag.textAlignment = .center
    tag.backgroundColor = UIColor.white.withAlphaComponent(0.92)
    tag.layer.cornerRadius = 4
    tag.clipsToBounds = true
    tag.frame.size = tag.intrinsicContentSize
    tag.frame.origin = CGPoint(x: marker.bounds.width + 2, y: (marker.bounds.height - tag.frame.height) / 2)
    tag.isHidden = !labelsShown
    tag.tag = 7
    marker.addSubview(tag)
    return marker
  }

  func mapViewDidChangeVisibleRegion(_ mapView: MKMapView) {
    let show = Self.zoomLevel(mapView) >= 17
    guard show != labelsShown else { return }
    labelsShown = show
    for annotation in mapView.annotations {
      mapView.view(for: annotation)?.viewWithTag(7)?.isHidden = !show
    }
  }

  private static func markerImage(_ place: PlaceAnnotation) -> UIImage {
    let endpoint = place.role == .from || place.role == .to
    let size: CGFloat = endpoint ? 28 : 22
    let (fill, stroke, ink): (UIColor, UIColor, UIColor) = switch place.role {
    case .from: (Palette.accent, .white, .white)
    case .to: (Palette.gray900, .white, .white)
    case .gate: (Palette.gray700, .white, .white)
    case .place: (.white, Palette.gray400, Palette.gray500)
    }
    let text = place.role == .from ? "출발" : place.role == .to ? "도착" : place.node.no.map { String($0) } ?? ""

    return UIGraphicsImageRenderer(size: CGSize(width: size, height: size)).image { _ in
      let circle = UIBezierPath(ovalIn: CGRect(x: 1, y: 1, width: size - 2, height: size - 2))
      fill.setFill()
      circle.fill()
      stroke.setStroke()
      circle.lineWidth = 2
      /* 좌표를 아직 못 믿는 곳은 테를 점선으로 둔다. */
      if place.node.precision == "approx" && !endpoint { circle.setLineDash([3, 2], count: 2, phase: 0) }
      circle.stroke()
      let attributes: [NSAttributedString.Key: Any] = [
        .font: UIFont.systemFont(ofSize: endpoint ? 10 : 10, weight: .bold), .foregroundColor: ink,
      ]
      let label = text as NSString
      let fits = label.size(withAttributes: attributes)
      label.draw(at: CGPoint(x: (size - fits.width) / 2, y: (size - fits.height) / 2), withAttributes: attributes)
    }
  }

  private static let hereImage = UIGraphicsImageRenderer(size: CGSize(width: 30, height: 30)).image { _ in
    Palette.here.withAlphaComponent(0.18).setFill()
    UIBezierPath(ovalIn: CGRect(x: 0, y: 0, width: 30, height: 30)).fill()
    UIColor.white.setFill()
    UIBezierPath(ovalIn: CGRect(x: 6, y: 6, width: 18, height: 18)).fill()
    Palette.here.setFill()
    UIBezierPath(ovalIn: CGRect(x: 9, y: 9, width: 12, height: 12)).fill()
  }

  // MARK: 손짓

  /// 점을 정확히 못 맞혀도 된다. 22pt 안의 가장 가까운 곳을 잡고, 없으면 빈 자리를 누른 것으로 친다.
  @objc func tapped(_ gesture: UITapGestureRecognizer) {
    guard let map = gesture.view as? MKMapView, let model = view?.model else { return }
    let point = gesture.location(in: map)
    var best: (node: CampusNode, distance: CGFloat)?
    for node in model.graph.places {
      let p = map.convert(Self.coordinate(node.at), toPointTo: map)
      let distance = hypot(p.x - point.x, p.y - point.y)
      if distance <= 22 && (best == nil || distance < best!.distance) { best = (node, distance) }
    }
    if let best {
      model.pickNode(best.node)
    } else {
      let c = map.convert(point, toCoordinateFrom: map)
      model.tapMap(LatLng(lat: c.latitude, lng: c.longitude))
    }
  }

  func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
    true
  }
}
