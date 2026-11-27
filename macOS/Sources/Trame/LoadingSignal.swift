import SwiftUI

struct LoadingSignal: View {
  let label: String
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    HStack(spacing: 9) {
      TimelineView(.animation(minimumInterval: 1.0 / 24, paused: reduceMotion)) { timeline in
        let phase =
          reduceMotion
          ? 0
          : timeline.date.timeIntervalSinceReferenceDate
            .truncatingRemainder(dividingBy: 2) * .pi
        Canvas { context, size in
          for index in 0..<9 {
            let wave = (1 + cos(Double(index) * 0.64 - phase)) / 2
            let height = 4 + wave * (size.height - 4)
            let bar = CGRect(
              x: Double(index) * 4, y: (size.height - height) / 2,
              width: 2, height: height)
            context.fill(Path(roundedRect: bar, cornerRadius: 1), with: .color(coral))
          }
        }
      }
      .frame(width: 34, height: 18)
      .accessibilityHidden(true)
      Text(label).font(.callout).monospacedDigit()
    }
  }
}
