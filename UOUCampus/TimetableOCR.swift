import UIKit
import Vision

/// Client/src/timetable/parseImage.ts. 격자를 읽는 방법은 그대로고, 글자 인식만 tesseract 대신 Vision 이 한다.
///
/// 글자를 다 읽지 않는다. 요일은 칸의 가로 자리, 시각은 세로 자리에 적혀 있어서
/// 읽어야 하는 건 강의실 코드 하나다. 읽은 값은 확인 화면에서 사람이 고친 뒤에야 시간표가 된다.
enum TimetableOCR {
  struct Result {
    var slots: [ClassSlot]
    var warnings: [String]
  }

  static func parse(_ image: UIImage, known: Set<Int>, progress: @escaping (String) -> Void) async -> Result {
    await Task.detached(priority: .userInitiated) {
      run(image, known) { note in DispatchQueue.main.async { progress(note) } }
    }.value
  }

  // MARK: 격자 (웹과 같은 셈)

  static let hour = 60.0

  struct Run {
    let top: Int
    let bottom: Int
  }

  struct HourMark {
    let hour: Double
    let y: Double
  }

  struct TimeAxis {
    var originMinutes: Double
    var minutesPerPixel: Double
    var originY: Double

    func minutes(at y: Double) -> Double { originMinutes + (y - originY) * minutesPerPixel }
  }

  static func snap(_ minutes: Double) -> Int { Int(jsRound(minutes / hour) * hour) }

  private static func median(_ values: [Double]) -> Double { values.sorted()[values.count / 2] }
  private static func median(_ values: [Int]) -> Int { values.sorted()[values.count / 2] }

  private static func differs(_ a: [Int], _ b: [Int]) -> Bool {
    abs(a[0] - b[0]) + abs(a[1] - b[1]) + abs(a[2] - b[2]) > 24
  }

  /// 가장 멀리 떨어진 두 눈금으로 자를 세운다. 라벨은 칸 가운데 놓이므로 기준을 반 칸 올린다.
  static func fitTimeAxis(_ marks: [HourMark]) -> TimeAxis? {
    guard marks.count >= 2 else { return nil }
    let sorted = marks.sorted { $0.y < $1.y }
    let (first, last) = (sorted[0], sorted[sorted.count - 1])
    guard last.y != first.y, last.hour != first.hour else { return nil }
    let minutesPerPixel = (last.hour - first.hour) * 60 / (last.y - first.y)
    let pitch = 60 / minutesPerPixel
    guard pitch >= 20, pitch <= 200 else { return nil }
    return TimeAxis(originMinutes: first.hour * 60, minutesPerPixel: minutesPerPixel, originY: first.y - pitch / 2)
  }

  /// 가운뎃값 기울기로 자를 세우고, 거기서 30분 넘게 벗어난 눈금을 뺀다.
  private static func onTheRuler(_ marks: [HourMark]) -> [HourMark] {
    var slopes: [Double] = []
    for i in marks.indices {
      for j in marks.indices where j > i {
        let dy = marks[j].y - marks[i].y
        if dy != 0 { slopes.append((marks[j].hour - marks[i].hour) * hour / dy) }
      }
    }
    guard !slopes.isEmpty else { return [] }
    let minutesPerPixel = median(slopes)
    guard minutesPerPixel.isFinite, minutesPerPixel > 0 else { return [] }
    let base = median(marks.map { $0.hour * hour - $0.y * minutesPerPixel })
    return marks.filter { abs($0.hour * hour - (base + $0.y * minutesPerPixel)) <= 30 }
  }

  /// 12시간제로 적힌 눈금(`9 10 11 12 1 2`)을 편다. 정오가 넘어가는 자리를 하나씩 옮겨 보며 자에 가장 많이 얹히는 것을 고른다.
  static func readHourMarks(_ marks: [HourMark]) -> [HourMark] {
    let sorted = marks.sorted { $0.y < $1.y }
    var best: [HourMark] = []
    for noon in stride(from: sorted.count, through: 0, by: -1) {
      let guess = sorted.enumerated().map { i, m in i >= noon ? HourMark(hour: m.hour + 12, y: m.y) : m }
      if guess.contains(where: { $0.hour > 23 }) { continue }
      let kept = onTheRuler(guess)
      if kept.count > best.count { best = kept }
    }
    return best
  }

  /// 라벨을 칸 위에 붙이는 테마도 있다. 수업 칸 위쪽 경계가 죄다 30분에 떨어지면 자를 반 칸 옮긴다.
  static func alignToBlocks(_ axis: TimeAxis, _ tops: [Int]) -> TimeAxis {
    guard tops.count >= 3 else { return axis }
    let off = tops.map { y -> Double in
      let rest = axis.minutes(at: Double(y)).truncatingRemainder(dividingBy: hour)
      return rest < 0 ? rest + hour : rest
    }
    func agree(_ shift: Double) -> Int {
      off.filter { let gap = abs($0 - shift); return min(gap, hour - gap) <= 8 }.count
    }
    let (stay, move) = (agree(0), agree(hour / 2))
    if move <= stay || Double(move) < (Double(tops.count) * 0.6).rounded(.up) { return axis }
    var moved = axis
    moved.originMinutes -= hour / 2
    return moved
  }

  // MARK: 픽셀

  struct Pixels {
    let width: Int
    let height: Int
    let data: [UInt8]
    /// 흰 바탕에 다시 그린 그림. 투명한 자리는 바탕으로 읽힌다.
    let image: CGImage

    init?(_ source: CGImage) {
      let (w, h) = (source.width, source.height)
      var data = [UInt8](repeating: 255, count: w * h * 4)
      let image: CGImage? = data.withUnsafeMutableBytes { buffer in
        guard let ctx = CGContext(
          data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        ctx.setFillColor(UIColor.white.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.draw(source, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
      }
      guard let image else { return nil }
      width = w
      height = h
      self.data = data
      self.image = image
    }

    func rgb(_ x: Int, _ y: Int) -> [Int] {
      let i = (y * width + x) * 4
      return [Int(data[i]), Int(data[i + 1]), Int(data[i + 2])]
    }
  }

  /// 한 요일 칸을 위에서 아래로 훑어 색이 칠해진 구간을 찾는다.
  /// 흰색만 바탕으로 보고, 줄 전체를 훑어 다수결로 묻는다 — 글자가 검든 희든 속지 않는다.
  static func runsInColumn(_ px: Pixels, left: Double, right: Double, minHeight: Int) -> [Run] {
    let from = max(0, Int(jsRound(left)))
    let to = min(px.width, Int(jsRound(right)))
    let looked = Int((Double(to - from) / 2).rounded(.up))
    guard looked > 0 else { return [] }
    let enough = max(2, Int(jsRound(Double(looked) * 0.08)))

    var runs: [Run] = []
    var start = -1
    var colour: [Int]?
    /// 색이 바뀐 자리와 그 색, 그 색이 몇 줄째 이어지는지.
    var turn: (y: Int, colour: [Int], rows: Int)?
    func close(_ end: Int) {
      if start >= 0 && end - start >= minHeight { runs.append(Run(top: start, bottom: end)) }
      start = -1
      colour = nil
      turn = nil
    }
    /* 색이 바뀌어도 이만큼 이어져야 다른 수업으로 본다. 과목명이 칸 너비를 거의 채우면 흰 획이 지나는
       한두 줄의 가운뎃값이 확 밝아져, 그 줄을 경계로 읽고 9시 수업을 10시로 들였다. 글자 획은 몇 줄뿐이고
       맞붙은 수업은 적어도 반 교시라 그 사이에 문턱을 둔다. */
    let hold = max(3, minHeight / 4)

    var r: [Int] = [], g: [Int] = [], b: [Int] = []
    for y in 0..<px.height {
      r.removeAll(keepingCapacity: true)
      g.removeAll(keepingCapacity: true)
      b.removeAll(keepingCapacity: true)
      for x in stride(from: from, to: to, by: 2) {
        let i = (y * px.width + x) * 4
        let (cr, cg, cb) = (Int(px.data[i]), Int(px.data[i + 1]), Int(px.data[i + 2]))
        if cr > 249 && cg > 249 && cb > 249 { continue }
        r.append(cr)
        g.append(cg)
        b.append(cb)
      }
      if r.count < enough {
        /* 틈 바로 앞에서 색이 바뀌던 줄은 칸 가장자리다. 칸에 넣지 않는다. */
        close(turn?.y ?? y)
        continue
      }
      let here = [median(r), median(g), median(b)]
      if start < 0 {
        start = y
        colour = here
        continue
      }
      /* 색이 확 바뀌어 이어지면 다른 수업이 맞붙은 것이다. 사이에 흰 틈이 없을 수 있다. */
      guard let current = colour, differs(current, here) else {
        turn = nil
        continue
      }
      if let t = turn, !differs(t.colour, here) { turn?.rows += 1 } else { turn = (y, here, 1) }
      if let t = turn, t.rows >= hold {
        close(t.y)
        start = t.y
        colour = t.colour
      }
    }
    close(turn?.y ?? px.height)
    return runs
  }

  // MARK: 글자 읽기

  private struct Word {
    let text: String
    let confidence: Double
    let x, y, right, bottom: Double
  }

  private static let dayHeads: [Character] = ["월", "화", "수", "목", "금"]

  private static func read(_ image: CGImage) -> [Word] {
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.recognitionLanguages = ["ko-KR", "en-US"]
    request.usesLanguageCorrection = false
    try? VNImageRequestHandler(cgImage: image).perform([request])

    let (w, h) = (Double(image.width), Double(image.height))
    var words: [Word] = []
    for observation in request.results ?? [] {
      guard let candidate = observation.topCandidates(1).first else { continue }
      for token in candidate.string.split(whereSeparator: \.isWhitespace) {
        /* 머리글이 「월화수목금」 한 덩이로 올 수 있다. 요일 글자만으로 된 낱말은 한 자씩 가른다. */
        let pieces = token.count > 1 && token.allSatisfy({ dayHeads.contains($0) })
          ? token.indices.map { token[$0...$0] } : [token]
        for piece in pieces {
          guard let box = try? candidate.boundingBox(for: piece.startIndex..<piece.endIndex)?.boundingBox else { continue }
          words.append(Word(
            text: String(piece), confidence: Double(candidate.confidence) * 100,
            x: box.minX * w, y: (1 - box.maxY) * h, right: box.maxX * w, bottom: (1 - box.minY) * h
          ))
        }
      }
    }
    return words
  }

  private static let cropWidth = 360.0
  private static let cropMargin = 16.0
  private static let cropInset = 2

  /// 흰 여백을 두르고 키워서 그린다. 글자가 조각 가장자리에 닿으면 인식기가 통째로 흘린다.
  private static func draw(_ px: Pixels, _ rect: CGRect, scale: Double) -> CGImage? {
    guard let piece = px.image.cropping(to: rect) else { return nil }
    let w = Int(jsRound(rect.width * scale) + cropMargin * 2)
    let h = Int(jsRound(rect.height * scale) + cropMargin * 2)
    guard let ctx = CGContext(
      data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    ) else { return nil }
    ctx.setFillColor(UIColor.white.cgColor)
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    ctx.interpolationQuality = .high
    ctx.draw(piece, in: CGRect(x: cropMargin, y: cropMargin, width: Double(w) - cropMargin * 2, height: Double(h) - cropMargin * 2))
    return ctx.makeImage()
  }

  private static func cropBlock(_ px: Pixels, left: Double, top: Double, right: Double, bottom: Double) -> CGImage? {
    let x = max(0, Int(jsRound(left)) + cropInset)
    let y = max(0, Int(jsRound(top)))
    let width = min(px.width, Int(jsRound(right)) - cropInset) - x
    let height = min(px.height, Int(jsRound(bottom))) - y
    guard width >= 1, height >= 1 else { return nil }
    let scale = min(4, max(1, cropWidth / Double(width)))
    return draw(px, CGRect(x: x, y: y, width: width, height: height), scale: scale)
  }

  /// 칸 안에서 글자가 실제로 놓인 세로 구간. 빈 바닥까지 넘기면 인식기가 글자 섬을 못 본다.
  private static func contentRows(_ px: Pixels, left: Int, right: Int, top: Int, bottom: Int) -> (first: Int, last: Int)? {
    var sample: [[Int]] = []
    for y in stride(from: top, to: bottom, by: max(1, (bottom - top) / 12)) {
      for x in stride(from: left, to: right, by: max(1, (right - left) / 6)) { sample.append(px.rgb(x, y)) }
    }
    guard !sample.isEmpty else { return nil }
    let paper = (0..<3).map { c in median(sample.map { $0[c] }) }

    var first = -1, last = -1
    for y in top..<bottom {
      var seen = 0
      for x in stride(from: left, to: right, by: 2) where differs(paper, px.rgb(x, y)) {
        seen += 1
        if seen >= 2 { break }
      }
      if seen < 2 { continue }
      if first < 0 { first = y }
      last = y
    }
    return first < 0 ? nil : (first, last)
  }

  /// 캠퍼스에 실재하는 건물 번호로 풀리는 낱말을 고른다. 여럿이면 아래쪽 — 강의실은 칸의 마지막 줄에 적힌다.
  private static func roomInBlock(_ words: [Word], _ known: Set<Int>) -> String {
    let candidates = words.filter { Room.looksLikeCode($0.text) }
    let good = candidates.filter { word in
      Room.buildingNo(Room.repair(word.text, known)).map { known.contains($0) } ?? false
    }
    var pick: Word?
    for word in good.isEmpty ? candidates : good where pick == nil || word.bottom > pick!.bottom { pick = word }
    return pick.map { Room.repair($0.text, known) } ?? ""
  }

  private static func readColumns(_ height: Int, _ words: [Word]) -> (columns: [Double], pitch: Double)? {
    let heads = dayHeads.map { label in
      words.first { $0.text == String(label) && $0.y < Double(height) * 0.15 }.map { ($0.x + $0.right) / 2 }
    }
    guard heads.compactMap({ $0 }).count >= 2,
          let firstIndex = heads.firstIndex(where: { $0 != nil }),
          let lastIndex = heads.lastIndex(where: { $0 != nil }) else { return nil }
    let pitch = (heads[lastIndex]! - heads[firstIndex]!) / Double(lastIndex - firstIndex)
    let columns = heads.enumerated().map { i, x in x ?? heads[firstIndex]! + Double(i - firstIndex) * pitch }
    return (columns, pitch)
  }

  /// Vision 의 확신은 0.3·0.5·1.0 처럼 거칠게 온다. 잘못 읽은 눈금은 자가 걸러 내므로 문턱은 낮게 둔다.
  private static let sureEnough = 30.0

  private static func hourMarks(_ words: [Word], scale: Double, top: Double) -> [HourMark] {
    words.compactMap { w in
      guard let m = w.text.wholeMatch(of: /([0-9]{1,2})\s*시?/), let hour = Double(m.1), hour <= 23,
            w.confidence >= sureEnough else { return nil }
      return HourMark(hour: hour, y: top + (w.y + w.bottom) / 2 / scale)
    }
  }

  private static func upright(_ image: UIImage) -> CGImage? {
    if image.imageOrientation == .up { return image.cgImage }
    let format = UIGraphicsImageRendererFormat()
    format.scale = image.scale
    return UIGraphicsImageRenderer(size: image.size, format: format).image { _ in image.draw(at: .zero) }.cgImage
  }

  // MARK: 전체

  private static func run(_ image: UIImage, _ known: Set<Int>, _ progress: (String) -> Void) -> Result {
    guard let source = upright(image), let px = Pixels(source) else {
      return Result(slots: [], warnings: ["그림을 못 읽었습니다. PNG 나 JPG 인지 확인해 주세요."])
    }

    progress("글자 읽는 중 0%")
    /* 처음 한 번은 그림 전체를 읽는다. 여기서 얻는 건 격자뿐이다 — 요일 머리글과 왼쪽 시각 눈금. */
    let page = read(px.image)
    guard let grid = readColumns(px.height, page) else {
      return Result(slots: [], warnings: ["요일 줄을 못 찾았습니다. 시간표 전체가 나온 그림인지 확인해 주세요."])
    }
    let (columns, pitch) = grid

    /* 시각 눈금은 왼쪽 띠만 떼어 키워 읽는다. 통째로 읽으면 형편없이 읽힌다. */
    let leftEdge = columns[0] - pitch / 2
    var fromStrip: [HourMark] = []
    let gutterWidth = Int(jsRound(leftEdge))
    if gutterWidth >= 8 {
      let scale = min(3, max(1, 150 / Double(gutterWidth)))
      if let strip = draw(px, CGRect(x: 0, y: 0, width: gutterWidth, height: px.height), scale: scale) {
        fromStrip = hourMarks(read(strip), scale: scale, top: -cropMargin / scale)
      }
    }
    let marks = fromStrip.count >= 2 ? fromStrip : hourMarks(page.filter { $0.right <= leftEdge }, scale: 1, top: 0)

    guard let ruler = fitTimeAxis(readHourMarks(marks)) else {
      return Result(slots: [], warnings: ["왼쪽 시각 눈금을 못 읽었습니다. 시간이 함께 나온 그림이어야 합니다."])
    }

    /* 한 교시의 삼분의 일도 안 되는 높이는 수업 칸일 수 없다. */
    let minHeight = max(4, Int(jsRound(hour / ruler.minutesPerPixel / 3)))
    var found: [(day: Int, centre: Double, run: Run)] = []
    for day in 0..<5 {
      let centre = jsRound(columns[day])
      for run in runsInColumn(px, left: centre - pitch / 2, right: centre + pitch / 2, minHeight: minHeight)
      where ruler.minutes(at: Double(run.bottom)) - ruler.minutes(at: Double(run.top)) >= hour / 2 {
        found.append((day, centre, run))
      }
    }

    let axis = alignToBlocks(ruler, found.map { $0.run.top })

    /* 강의실은 칸을 하나씩 떼어 읽는다. 자리를 이미 아는데 인식기에게 다시 찾으라고 시킬 이유가 없다. */
    var slots: [ClassSlot] = []
    for (i, block) in found.enumerated() {
      progress("글자 읽는 중 \(Int(jsRound(Double(i + 1) / Double(found.count + 1) * 100)))%")
      let (top, bottom) = (block.run.top, block.run.bottom)
      let start = snap(axis.minutes(at: Double(top)))
      let left = max(0, Int(jsRound(block.centre - pitch / 2)))
      let right = min(px.width, Int(jsRound(block.centre + pitch / 2)))
      let ink = contentRows(px, left: left, right: right, top: top, bottom: bottom)
      let crop = cropBlock(
        px, left: block.centre - pitch / 2,
        top: Double(ink.map { max(top, $0.first - 6) } ?? top),
        right: block.centre + pitch / 2,
        bottom: Double(ink.map { min(bottom, $0.last + 6) } ?? bottom)
      )
      slots.append(ClassSlot(
        id: UUID().uuidString, day: block.day, startMinutes: start,
        /* 정각으로 맞추다 보면 한 교시짜리가 0분으로 눌린다. 최소 한 시간은 준다. */
        endMinutes: max(snap(axis.minutes(at: Double(bottom))), start + Int(hour)),
        // ponytail: 한 번만 읽는다. 웹은 한국어로 못 풀면 영어 모델로 다시 읽는데, Vision 은 두 언어를 한 번에 본다.
        room: crop.map { roomInBlock(read($0), known) } ?? ""
      ))
    }
    progress("글자 읽는 중 100%")

    return Result(
      slots: slots,
      warnings: slots.isEmpty ? ["수업 칸을 하나도 못 찾았습니다. 잘리지 않은 시간표 그림인지 확인해 주세요."] : []
    )
  }
}
