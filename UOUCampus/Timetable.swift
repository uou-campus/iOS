import Foundation

// Client/src/types/timetable.ts · data/timetable.ts · timetable/{room,schedule}.ts

struct ClassSlot: Codable, Identifiable, Equatable {
  var id: String
  /// 0=월 … 4=금.
  var day: Int
  /// 자정부터 몇 분. 09:00 이면 540.
  var startMinutes: Int
  var endMinutes: Int
  /// 적힌 그대로. 울산대는 `건물번호-호실` 이다 — 예: `7-615`.
  var room: String

  static func blank() -> ClassSlot {
    ClassSlot(id: UUID().uuidString, day: 0, startMinutes: 540, endMinutes: 600, room: "")
  }
}

let weekdayLabels = ["월", "화", "수", "목", "금"]

/// 시간표는 이 기기에만 남는다. 누가 몇 시에 어디 있는지는 남한테 줄 값이 아니다.
enum TimetableStore {
  private struct Saved: Codable {
    var slots: [ClassSlot]
    var savedAt: String
  }

  private static let key = "campus-route:timetable"

  static func load() -> [ClassSlot] {
    guard let data = UserDefaults.standard.data(forKey: key),
          let saved = try? JSONDecoder().decode(Saved.self, from: data) else { return [] }
    return saved.slots
  }

  static func save(_ slots: [ClassSlot]) {
    let saved = Saved(slots: slots, savedAt: ISO8601DateFormatter().string(from: Date()))
    UserDefaults.standard.set(try? JSONEncoder().encode(saved), forKey: key)
  }

  static func clear() { UserDefaults.standard.removeObject(forKey: key) }
}

// MARK: - 강의실

enum Room {
  /// 글자를 읽다 흔히 헷갈리는 것들을 숫자로 되돌린다.
  private static let unconfuse: [Character: Character] = [
    "O": "0", "o": "0", "D": "0", "Q": "0", "l": "1", "I": "1", "i": "1", "|": "1", "!": "1",
    "Z": "2", "z": "2", "S": "5", "s": "5", "b": "6", "G": "6", "T": "7", "B": "8", "g": "9", "q": "9",
  ]
  private static let dashes: Set<Character> = ["-", "–", "—", "−", "ー", "－"]

  static func normalize(_ raw: String) -> String {
    String(raw.compactMap { ch -> Character? in
      if ch.isWhitespace { return nil }
      if dashes.contains(ch) { return "-" }
      return unconfuse[ch] ?? ch
    }).uppercased()
  }

  static func looksLikeCode(_ raw: String) -> Bool {
    normalize(raw).wholeMatch(of: /[0-9]{1,2}-?[A-Z]?[0-9]{2,4}/) != nil
  }

  /// `7-615` → 7.
  static func buildingNo(_ room: String) -> Int? {
    guard let m = normalize(room).prefixMatch(of: /([0-9]{1,2})-/), let no = Int(m.1), no > 0 else { return nil }
    return no
  }

  /// `7-615` → 6층. 세 자리가 안 되거나 지하면 1층으로 본다.
  static func floor(_ room: String) -> Int {
    guard let m = normalize(room).prefixMatch(of: /[0-9]{1,2}-([A-Z]?)([0-9]+)/), m.1.isEmpty, m.2.count >= 3,
          let floor = Int(m.2.dropLast(2)), floor > 0 else { return 1 }
    return floor
  }

  private static func looksLikeRoom(_ digits: Substring) -> Bool {
    guard (3...4).contains(digits.count), !digits.hasPrefix("0"), let floor = Int(digits.dropLast(2)) else { return false }
    return (1...25).contains(floor)
  }

  /// 하이픈이 빠져 붙어 버린 코드를 되살린다. 후보가 하나로 좁혀질 때만 고친다.
  static func repair(_ raw: String, _ known: Set<Int>) -> String {
    let room = normalize(raw)
    guard !room.contains("-"), room.wholeMatch(of: /[0-9]{3,6}/) != nil else { return room }
    let candidates = [1, 2].compactMap { cut -> String? in
      guard let head = Int(room.prefix(cut)), known.contains(head), looksLikeRoom(room.dropFirst(cut)) else { return nil }
      return "\(head)-\(room.dropFirst(cut))"
    }
    return candidates.count == 1 ? candidates[0] : room
  }

  static func knownBuildings(_ graph: CampusGraph) -> Set<Int> { Set(graph.places.compactMap(\.no)) }

  static func place(_ graph: CampusGraph, _ room: String) -> CampusNode? {
    guard let no = buildingNo(room) else { return nil }
    return graph.places.first { $0.no == no }
  }
}

// MARK: - 다음 수업

struct Upcoming: Equatable {
  let slot: ClassSlot
  let startsAt: Date
}

enum Schedule {
  /// 월=0 … 금=4. 주말이면 nil.
  static func weekday(_ date: Date) -> Int? {
    let day = Calendar.current.component(.weekday, from: date) - 1
    return (1...5).contains(day) ? day - 1 : nil
  }

  /// 아직 시작하지 않은 수업 중 가장 이른 것. 이레까지 내다본다.
  static func next(_ slots: [ClassSlot], _ now: Date) -> Upcoming? {
    var best: Upcoming?
    for ahead in 0...7 {
      let date = now.addingTimeInterval(Double(ahead) * 86_400)
      guard let day = weekday(date) else { continue }
      let midnight = Calendar.current.startOfDay(for: date)
      for slot in slots where slot.day == day {
        let startsAt = midnight.addingTimeInterval(Double(slot.startMinutes) * 60)
        if startsAt <= now { continue }
        if best == nil || startsAt < best!.startsAt { best = Upcoming(slot: slot, startsAt: startsAt) }
      }
      if best != nil { break }
    }
    return best
  }

  /// 건물 문 앞에서 강의실까지(초). 문 찾아 들어가는 데 1분, 한 층에 25초.
  static func indoorSeconds(_ room: String) -> Double { 60 + Double(Room.floor(room) - 1) * 25 }

  static func leaveBy(_ startsAt: Date, _ travelSeconds: Double, _ room: String) -> Date {
    startsAt.addingTimeInterval(-(travelSeconds + indoorSeconds(room)))
  }

  static func clock(_ minutes: Int) -> String { String(format: "%02d:%02d", minutes / 60, minutes % 60) }

  static func clock(_ date: Date) -> String {
    let c = Calendar.current.dateComponents([.hour, .minute], from: date)
    return clock(c.hour! * 60 + c.minute!)
  }

  static func until(_ target: Date, _ now: Date) -> String {
    let minutes = Int(jsRound(target.timeIntervalSince(now) / 60))
    if minutes < 0 { return "\(-minutes)분 지남" }
    if minutes == 0 { return "지금" }
    if minutes < 60 { return "\(minutes)분 뒤" }
    let (h, m) = (minutes / 60, minutes % 60)
    return m == 0 ? "\(h)시간 뒤" : "\(h)시간 \(m)분 뒤"
  }

  /// 오늘이면 '몇 분 뒤', 내일이면 '내일 09:00', 그 뒤는 요일과 시각.
  static func when(_ target: Date, _ now: Date) -> String {
    let calendar = Calendar.current
    if calendar.isDate(target, inSameDayAs: now) { return until(target, now) }
    let tomorrow = calendar.date(byAdding: .day, value: 1, to: now)!
    if calendar.isDate(target, inSameDayAs: tomorrow) { return "내일 \(clock(target))" }
    return weekday(target).map { "\(weekdayLabels[$0]) \(clock(target))" } ?? clock(target)
  }
}
