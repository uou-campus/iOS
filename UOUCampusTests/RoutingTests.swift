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

  func testTwelveHourRuler() {
    let marks = [9, 10, 11, 12, 1, 2].enumerated().map { TimetableOCR.HourMark(hour: Double($1), y: Double(100 + $0 * 60)) }
    XCTAssertEqual(TimetableOCR.readHourMarks(marks).map(\.hour), [9, 10, 11, 12, 13, 14])
  }
}
