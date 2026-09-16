import PhotosUI
import SwiftUI

/// Client/src/components/TimetableSheet. 읽은 값을 그대로 쓰지 않는다 — 여기서 보고 고친 뒤에야 시간표가 된다.
struct TimetableSheet: View {
  let model: AppModel
  @State private var draft: [ClassSlot]
  /// 읽는 중이면 진행 문구.
  @State private var reading: String?
  @State private var failed: String?
  @State private var warnings: [String] = []
  @State private var choosing = false
  @State private var photo: PhotosPickerItem?

  init(model: AppModel) {
    self.model = model
    _draft = State(initialValue: Self.inOrder(model.slots))
  }

  /// 요일이 먼저, 같은 요일이면 이른 시각이 먼저.
  private static func inOrder(_ list: [ClassSlot]) -> [ClassSlot] {
    list.sorted { $0.day != $1.day ? $0.day < $1.day : $0.startMinutes < $1.startMinutes }
  }

  /// 울산대 마스코트 울리니. 지도를 펴 들고 갈 길을 보고 있다. 크기만 비례 그대로 줄여 쓴다.
  private static let mascot = Bundle.main.url(forResource: "ulrinee-campus-tour", withExtension: "webp")
    .flatMap { UIImage(contentsOfFile: $0.path) }

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Text("시간표").font(.section).foregroundStyle(Theme.textPrimary)
        Spacer()
        Button { model.timetableOpen = false } label: {
          Text("×").font(.system(size: 20)).foregroundStyle(Theme.textSecondary)
            .frame(width: 36, height: 36).contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("닫기")
      }
      .padding(.leading, 16)
      .padding(.trailing, 10)
      .padding(.vertical, 10)
      .bottomRule()

      ScrollView {
        VStack(alignment: .leading, spacing: 10) {
          /* 표가 없을 때는 이 창에서 할 일이 첨부 하나뿐이라, 화면도 그 하나만 말한다. */
          if draft.isEmpty { blank } else { listHead }

          ForEach(notes, id: \.self) { text in
            Text(text).font(.body14).foregroundStyle(Theme.warn).note(Theme.warnSoft)
          }

          ForEach(draft) { slot in
            SlotRow(slot: binding(slot.id), place: Room.place(model.graph, slot.room)) {
              draft.removeAll { $0.id == slot.id }
            }
          }

          Button { draft.append(.blank()) } label: {
            Text("칸 추가").font(.bodyStrong).foregroundStyle(Theme.textSecondary)
              .frame(maxWidth: .infinity)
              .padding(.vertical, 10)
              .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.outline, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
              .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
        }
        .padding(16)
      }

      HStack(spacing: 8) {
        Button { model.timetableOpen = false } label: {
          Text("취소").font(.bodyStrong).foregroundStyle(Theme.textSecondary)
            .frame(maxWidth: .infinity).padding(.vertical, 11)
            .overlay(Capsule().strokeBorder(Theme.outline))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)

        /* 저장할 것이 없으면 물러선다 — 표가 비었을 때의 다음 걸음은 첨부지 저장이 아니다. */
        let cannotSave = reading != nil || draft.isEmpty
        Button {
          model.saveTimetable(Self.inOrder(draft.filter { !$0.room.trimmingCharacters(in: .whitespaces).isEmpty }))
          model.timetableOpen = false
        } label: {
          Text(draft.isEmpty ? "저장" : "\(draft.count)칸 저장").font(.bodyStrong).foregroundStyle(.white)
            .frame(maxWidth: .infinity).padding(.vertical, 11)
            .background(Theme.accent, in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(cannotSave)
        .opacity(cannotSave ? 0.4 : 1)
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 12)
      .overlay(alignment: .top) { Theme.outline.frame(height: 1) }
    }
    .background(Theme.surface.ignoresSafeArea())
    .photosPicker(isPresented: $choosing, selection: $photo, matching: .images)
    .onChange(of: photo) { _, item in
      if let item { read(item) }
    }
  }

  private var notes: [String] {
    let unresolved = draft.filter { Room.place(model.graph, $0.room) == nil }.count
    return [failed].compactMap { $0 } + warnings
      + (unresolved > 0 ? ["\(unresolved)칸은 강의실을 캠퍼스 건물과 못 맞췄습니다 — 표시된 칸을 「건물번호-호실」 로 고쳐 주세요."] : [])
  }

  private var blank: some View {
    VStack(spacing: 12) {
      if let mascot = Self.mascot {
        Image(uiImage: mascot).resizable().scaledToFit().frame(height: 150).accessibilityHidden(true)
      }
      Text(reading ?? "시간표 이미지 첨부").font(.action).foregroundStyle(Theme.textPrimary)
      Text("에브리타임에서 \(Text("시간표 → 설정 아이콘 → 이미지 저장").bold())으로 받은 이미지를 첨부해주세요.")
        .font(.body14).foregroundStyle(Theme.textSecondary).multilineTextAlignment(.center)
      Button { choosing = true } label: {
        Text("이미지 고르기").font(.bodyStrong).pill(.white, fill: Theme.accent, stroke: nil, h: 20, v: 10)
      }
      .buttonStyle(.plain)
      .disabled(reading != nil)
      .opacity(reading != nil ? 0.5 : 1)
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 24)
  }

  private var listHead: some View {
    HStack(spacing: 8) {
      Text("\(draft.count)칸").font(.bodyStrong).foregroundStyle(Theme.textPrimary)
      Spacer()
      Button { choosing = true } label: {
        Text(reading ?? "다시 읽기").font(.caption12).pill(Theme.textSecondary)
      }
      .buttonStyle(.plain)
      .disabled(reading != nil)
      Button {
        model.clearTimetable()
        draft = []
        warnings = []
      } label: {
        Text("모두 지우기").font(.caption12).pill(Theme.error, stroke: Theme.error)
      }
      .buttonStyle(.plain)
    }
  }

  /// 칸을 지우는 사이에 낡은 자리를 붙들지 않도록 id 로 찾아 묶는다.
  private func binding(_ id: String) -> Binding<ClassSlot> {
    Binding(
      get: { draft.first { $0.id == id } ?? .blank() },
      set: { new in
        if let i = draft.firstIndex(where: { $0.id == id }) { draft[i] = new }
      }
    )
  }

  private func read(_ item: PhotosPickerItem) {
    /* 같은 그림을 다시 골라도 다시 읽히게 비워 둔다. */
    photo = nil
    failed = nil
    warnings = []
    reading = "글자 읽을 준비를 하는 중"
    Task {
      guard let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) else {
        reading = nil
        failed = "못 읽었습니다. 다른 그림으로 해 보세요."
        return
      }
      let result = await TimetableOCR.parse(image, known: Room.knownBuildings(model.graph)) { reading = $0 }
      warnings = result.warnings
      draft = Self.inOrder(result.slots)
      reading = nil
    }
  }
}

private struct SlotRow: View {
  @Binding var slot: ClassSlot
  let place: CampusNode?
  let onRemove: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 2) {
        Picker("요일", selection: $slot.day) {
          ForEach(0..<5, id: \.self) { Text(weekdayLabels[$0]).tag($0) }
        }
        Picker("시작 시각", selection: Binding(
          get: { slot.startMinutes },
          set: {
            slot.startMinutes = $0
            slot.endMinutes = max(slot.endMinutes, $0 + 60)
          }
        )) {
          hours(8...22, keep: slot.startMinutes)
        }
        Text("–").foregroundStyle(Theme.textTertiary)
        Picker("끝 시각", selection: $slot.endMinutes) {
          hours(9...23, keep: slot.endMinutes, after: slot.startMinutes)
        }
        Spacer(minLength: 0)
        Button(action: onRemove) {
          Text("×").font(.system(size: 20)).foregroundStyle(Theme.textTertiary)
            .frame(width: 32, height: 32).contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("이 칸 지우기")
      }
      .pickerStyle(.menu)
      .tint(Theme.textPrimary)

      HStack(spacing: 10) {
        TextField("7-615", text: Binding(get: { slot.room }, set: { slot.room = Room.normalize($0) }))
          .font(.body14.monospacedDigit())
          .keyboardType(.numbersAndPunctuation)
          .autocorrectionDisabled()
          .textInputAutocapitalization(.characters)
          .padding(.horizontal, 10)
          .frame(width: 110, height: 36)
          .background(Theme.surface, in: RoundedRectangle(cornerRadius: 6))
          .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.outline))
        /* 빈 칸과 못 찾은 칸은 할 일이 다르다. 채우라는 말과 고치라는 말을 뭉뚱그리지 않는다. */
        Text(place?.name ?? (slot.room.trimmingCharacters(in: .whitespaces).isEmpty ? "강의실을 넣어 주세요" : "건물을 못 찾음"))
          .font(.caption12)
          .foregroundStyle(place == nil ? Theme.warn : Theme.textSecondary)
      }
    }
    .padding(12)
    .background(place == nil ? Theme.warnSoft : Theme.gray50, in: RoundedRectangle(cornerRadius: 10))
  }

  /// 읽어 온 시각이 목록 밖이어도 사라지지 않게 지금 값은 늘 넣어 둔다.
  @ViewBuilder private func hours(_ range: ClosedRange<Int>, keep: Int, after: Int = -1) -> some View {
    let options = Set(range.map { $0 * 60 }.filter { $0 > after } + [keep]).sorted()
    ForEach(options, id: \.self) { Text(Schedule.clock($0)).tag($0) }
  }
}
