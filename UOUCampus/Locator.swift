import CoreLocation
import Observation

/// Client/src/hooks/useGeolocation.ts. 버튼을 눌러야 켜진다 — 화면 열자마자 권한을 묻지 않는다.
@Observable
final class Locator: NSObject, CLLocationManagerDelegate {
  enum Status {
    case idle, locating
    /// 좌표는 왔지만 아직 어림하다. 점은 찍되 출발지로 쓰진 않는다.
    case coarse
    case ready, denied, unsupported, failed
  }

  private(set) var here: LatLng?
  /// 오차 반경(m). 이탈 판정을 여기에 맞춘다.
  private(set) var accuracy: Double?
  private(set) var status = Status.idle
  var active: Bool { status != .idle }

  /// 쓸 만한 첫 좌표가 잡혔을 때 한 번.
  @ObservationIgnored var onFirstFix: ((LatLng) -> Void)?
  /// 좌표가 올 때마다. 안내 중 경로를 벗어났는지 여기서 본다.
  @ObservationIgnored var onFix: (() -> Void)?
  @ObservationIgnored private let manager = CLLocationManager()
  @ObservationIgnored private var pending = false
  @ObservationIgnored private var gotFix = false
  @ObservationIgnored private var timeout: Task<Void, Never>?

  /// 이보다 어림한 좌표로는 출발지를 잡지 않는다(m). 캠퍼스 반대편 건물이 조용히 들어앉는다.
  private let usableAccuracy = 50.0

  override init() {
    super.init()
    manager.delegate = self
    manager.desiredAccuracy = kCLLocationAccuracyBest
    manager.activityType = .fitness
    /* 신호 기다리며 서 있으면 iOS 가 갱신을 멈추고, 다시 걸어도 점이 그 자리에 박혀 있다. */
    manager.pausesLocationUpdatesAutomatically = false
  }

  func start() {
    status = .locating
    pending = true
    gotFix = false
    switch manager.authorizationStatus {
    case .denied, .restricted:
      pending = false
      status = .denied
      return
    case .notDetermined:
      manager.requestWhenInUseAuthorization()
    default:
      break
    }
    manager.startUpdatingLocation()
    /* 건물 안에서는 첫 좌표가 10초를 넘긴다. 30초 넘게 못 받으면 알리되, 기다림은 계속한다. */
    timeout?.cancel()
    timeout = Task { @MainActor [weak self] in
      try? await Task.sleep(for: .seconds(30))
      guard let self, !Task.isCancelled, !self.gotFix, self.status == .locating else { return }
      self.status = .failed
    }
  }

  func stop() {
    manager.stopUpdatingLocation()
    timeout?.cancel()
    pending = false
    gotFix = false
    status = .idle
    here = nil
    accuracy = nil
  }

  func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
    guard status != .idle else { return }
    if manager.authorizationStatus == .denied || manager.authorizationStatus == .restricted {
      pending = false
      status = .denied
    }
  }

  func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
    guard status != .idle, let location = locations.last, location.horizontalAccuracy >= 0 else { return }
    /* 켜자마자 오는 첫 좌표는 몇 분 전 딴 데서 잡아 둔 것일 수 있다. 웹의 maximumAge 처럼 5초 넘은 건 버린다. */
    if location.timestamp.timeIntervalSinceNow < -5 { return }
    let at = LatLng(lat: location.coordinate.latitude, lng: location.coordinate.longitude)
    let usable = location.horizontalAccuracy <= usableAccuracy
    gotFix = true
    here = at
    accuracy = location.horizontalAccuracy
    status = usable ? .ready : .coarse
    if pending && usable {
      pending = false
      onFirstFix?(at)
    }
    onFix?()
  }

  func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
    let code = (error as? CLError)?.code
    /* 권한 창이 떠 있는 동안에도 거부 오류가 먼저 온다. 사람이 고르기 전에는 막혔다고 하지 않는다. */
    if code == .denied && manager.authorizationStatus == .notDetermined { return }
    if code == .denied {
      pending = false
      status = .denied
      return
    }
    /* 권한이 막힌 것만 되돌릴 수 없다. 나머지는 계속 기다린다. */
    if code != .locationUnknown && !gotFix { status = .failed }
  }
}
