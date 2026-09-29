import SwiftUI
import UIKit

// Client/src/styles/{theme,font}.ts

extension UIColor {
  convenience init(hex: UInt32) {
    self.init(
      red: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
      blue: CGFloat(hex & 0xFF) / 255, alpha: 1
    )
  }
}

extension Color {
  init(hex: UInt32) { self.init(uiColor: UIColor(hex: hex)) }
}

/// 지도 위에 그리는 색. UIKit 쪽이 쓴다.
enum Palette {
  static let gray900 = UIColor(hex: 0x111111)
  static let gray700 = UIColor(hex: 0x374151)
  static let gray500 = UIColor(hex: 0x6B7280)
  static let gray400 = UIColor(hex: 0x9CA3AF)
  static let gray300 = UIColor(hex: 0xD1D5DB)
  /// 울산대 CI 그린.
  static let accent = UIColor(hex: 0x16A152)
  static let warn = UIColor(hex: 0xB45309)
  static let error = UIColor(hex: 0xB91C1C)
  static let here = UIColor(hex: 0x2563EB)
}

enum Theme {
  static let gray900 = Color(hex: 0x111111)
  static let gray700 = Color(hex: 0x374151)
  static let gray500 = Color(hex: 0x6B7280)
  static let gray400 = Color(hex: 0x9CA3AF)
  static let gray300 = Color(hex: 0xD1D5DB)
  static let gray200 = Color(hex: 0xE5E7EB)
  static let gray100 = Color(hex: 0xF3F4F6)
  static let gray50 = Color(hex: 0xF8F9FB)
  static let surface = Color.white

  static let accent = Color(hex: 0x16A152)
  static let accentSoft = Color(hex: 0xE8F6EE)
  static let accentTint = Color(hex: 0xD0ECDC)
  static let warn = Color(hex: 0xB45309)
  static let warnSoft = Color(hex: 0xFFFBEB)
  static let ok = Color(hex: 0x15803D)
  static let error = Color(hex: 0xB91C1C)
  static let here = Color(hex: 0x2563EB)
  static let hereSoft = Color(hex: 0xEFF6FF)

  static let outline = gray200
  static let textPrimary = gray900
  static let textSecondary = gray500
  static let textTertiary = gray400
}

extension Font {
  static let appTitle = Font.system(size: 17, weight: .bold)
  static let section = Font.system(size: 15, weight: .bold)
  static let body14 = Font.system(size: 14)
  static let bodyStrong = Font.system(size: 14, weight: .semibold)
  static let action = Font.system(size: 16, weight: .semibold)
  static let caption12 = Font.system(size: 12, weight: .medium)
  static let metric = Font.system(size: 22, weight: .bold).monospacedDigit()
  static let metricSmall = Font.system(size: 13, weight: .semibold).monospacedDigit()
}

extension View {
  /// 둥근 알약 꼴.
  func pill(_ ink: Color, fill: Color = .clear, stroke: Color? = Theme.outline, h: CGFloat = 10, v: CGFloat = 5) -> some View {
    foregroundStyle(ink)
      .padding(.horizontal, h)
      .padding(.vertical, v)
      .background(fill, in: Capsule())
      .overlay { if let stroke { Capsule().strokeBorder(stroke) } }
      .contentShape(Capsule())
  }

  /// 옅은 바탕을 깐 알림 칸.
  func note(_ fill: Color) -> some View {
    padding(.horizontal, 10)
      .padding(.vertical, 8)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(fill, in: RoundedRectangle(cornerRadius: 6))
  }

  func bottomRule() -> some View {
    overlay(alignment: .bottom) { Theme.outline.frame(height: 1) }
  }
}

/// 넘치면 다음 줄로 흘리는 줄. 태그·통계 알약에 쓴다.
struct FlowLayout: Layout {
  var spacing: CGFloat = 6

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let width = proposal.width ?? .infinity
    var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0, widest: CGFloat = 0
    for view in subviews {
      let size = view.sizeThatFits(.unspecified)
      if x > 0 && x + size.width > width {
        y += row + spacing
        x = 0
        row = 0
      }
      x += size.width + spacing
      row = max(row, size.height)
      widest = max(widest, x - spacing)
    }
    return CGSize(width: min(widest, width), height: y + row)
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    var x = bounds.minX, y = bounds.minY, row: CGFloat = 0
    for view in subviews {
      let size = view.sizeThatFits(.unspecified)
      if x > bounds.minX && x + size.width > bounds.maxX {
        y += row + spacing
        x = bounds.minX
        row = 0
      }
      view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
      x += size.width + spacing
      row = max(row, size.height)
    }
  }
}
