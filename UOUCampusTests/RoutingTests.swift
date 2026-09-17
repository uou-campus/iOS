import XCTest
@testable import UOUCampus

/// 웹(Client/src/routing)과 같은 길이 나오는지. 기대값은 웹 코드로 뽑았다 — campus.json 이 바뀌면 다시 뽑는다.
final class RoutingTests: XCTestCase {
  func testRoutesMatchWeb() {
    let graph = CampusGraph.bundled

    let library = findRoute(graph, "b15", "b3", RouteOptions())!
    XCTAssertEqual(library.meters, 176.192, accuracy: 0.001)
    XCTAssertEqual(library.seconds, 135.532, accuracy: 0.001)
    XCTAssertEqual(Directions.steps(graph, library).map(\.text), ["문수관에서 출발, 130m", "오른쪽으로 50m — 행정본관"])

    let stairs = findRoute(graph, "b20", "b28", RouteOptions())!
    XCTAssertEqual(stairs.legs.map(\.link.edge.id), ["s2", "e87", "e86", "e399"])
    XCTAssertEqual(Directions.steps(graph, stairs).map(\.text), [
      "기초과학실험동에서 출발, 40m", "음악대학 앞에서 직진 계단으로 30m", "오른쪽으로 살짝 꺾어 65m — 조형관",
    ])
  }

  func testRoomRepair() {
    XCTAssertEqual(Room.normalize("l9 − 5O9"), "19-509")
    /* 1-9509 는 95층이라 버리고 19-509 만 남는다. */
    XCTAssertEqual(Room.repair("19509", [1, 19]), "19-509")
    XCTAssertEqual(Room.floor("7-615"), 6)
  }

  /// 칸을 가로지르는 옅은 획 두 줄은 경계가 아니다. 틈 없이 맞붙은 다른 색 칸은 경계다.
  func testTextStrokeDoesNotSplitBlock() {
    let image = UIGraphicsImageRenderer(size: CGSize(width: 180, height: 300), format: {
      let format = UIGraphicsImageRendererFormat()
      format.scale = 1
      return format
    }()).image { ctx in
      UIColor.white.setFill()
      ctx.fill(CGRect(x: 0, y: 0, width: 180, height: 300))
      UIColor(red: 242 / 255, green: 160 / 255, blue: 158 / 255, alpha: 1).setFill()
      ctx.fill(CGRect(x: 0, y: 50, width: 180, height: 200))
      UIColor(red: 250 / 255, green: 215 / 255, blue: 214 / 255, alpha: 1).setFill()
      ctx.fill(CGRect(x: 8, y: 120, width: 164, height: 2))
      UIColor(red: 143 / 255, green: 201 / 255, blue: 168 / 255, alpha: 1).setFill()
      ctx.fill(CGRect(x: 0, y: 250, width: 180, height: 50))
    }
    let px = TimetableOCR.Pixels(image.cgImage!)!
    let runs = TimetableOCR.runsInColumn(px, left: 0, right: 180, minHeight: 37)
    XCTAssertEqual(runs.map { [$0.top, $0.bottom] }, [[50, 250], [250, 300]])
  }

  func testTwelveHourRuler() {
    let marks = [9, 10, 11, 12, 1, 2].enumerated().map { TimetableOCR.HourMark(hour: Double($1), y: Double(100 + $0 * 60)) }
    XCTAssertEqual(TimetableOCR.readHourMarks(marks).map(\.hour), [9, 10, 11, 12, 13, 14])
  }
}
