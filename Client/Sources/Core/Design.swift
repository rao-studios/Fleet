import SwiftUI

// MARK: - Palette (ported from Totem/Client's Seer system)

extension Color {
    static let fleetBG = Color(red: 250 / 255, green: 249 / 255, blue: 246 / 255)
    static let fleetInk = Color(red: 45 / 255, green: 49 / 255, blue: 66 / 255)
    static let fleetGold = Color(red: 174 / 255, green: 144 / 255, blue: 96 / 255)
    static var fleetBorder: Color { Color.fleetGold.opacity(0.22) }
    static var fleetCard: Color { Color.white.opacity(0.62) }
    static var fleetFill: Color { Color.fleetInk.opacity(0.05) }
    static let fleetError = Color(red: 200 / 255, green: 60 / 255, blue: 60 / 255)
    static let fleetGreen = Color(red: 70 / 255, green: 150 / 255, blue: 90 / 255)
}

// MARK: - Typography

extension Font {
    static func fleetSerif(_ size: CGFloat, weight: Font.Weight = .regular, italic: Bool = false) -> Font {
        let f = Font.system(size: size, weight: weight, design: .serif)
        return italic ? f.italic() : f
    }

    static func fleetSans(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }

    static func fleetMono(_ size: CGFloat) -> Font {
        .system(size: size, design: .monospaced)
    }
}

// MARK: - Fleet mark

/// The Fleet brand glyph — a gold connected-nodes mark (a harness coordinating
/// Frigates/Totems), on the warm Seer-derived design system.
struct FleetMark: View {
    var size: CGFloat = 28
    var color: Color = .fleetGold

    var body: some View {
        Image(systemName: "point.3.connected.trianglepath.dotted")
            .font(.system(size: size, weight: .light))
            .foregroundStyle(color)
            .symbolRenderingMode(.hierarchical)
    }
}

// MARK: - Orbiting rings (ported)

struct FleetOrbitRings: View {
    let iconSize: CGFloat
    @State private var outerRotation = 0.0
    @State private var innerRotation = 0.0

    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(
                    Color.fleetGold.opacity(0.30),
                    style: StrokeStyle(lineWidth: 1, dash: [5, 3])
                )
                .frame(width: iconSize + 40, height: iconSize + 40)
                .rotationEffect(.degrees(outerRotation))
                .onAppear {
                    withAnimation(.linear(duration: 32).repeatForever(autoreverses: false)) {
                        outerRotation = -360
                    }
                }

            Circle()
                .strokeBorder(Color.fleetGold.opacity(0.30), lineWidth: 1)
                .frame(width: iconSize + 14, height: iconSize + 14)
                .rotationEffect(.degrees(innerRotation))
                .onAppear {
                    withAnimation(.linear(duration: 20).repeatForever(autoreverses: false)) {
                        innerRotation = 360
                    }
                }

            Circle()
                .fill(
                    RadialGradient(
                        colors: [Color.fleetGold.opacity(0.15), .clear],
                        center: .center, startRadius: 0, endRadius: iconSize * 0.6
                    )
                )
                .frame(width: iconSize + 8, height: iconSize + 8)
        }
        .frame(width: iconSize + 48, height: iconSize + 48)
    }
}

/// The mark inside the orbiting rings — used on landing/empty states.
struct FleetEmblem: View {
    var iconSize: CGFloat = 64

    var body: some View {
        ZStack {
            FleetOrbitRings(iconSize: iconSize)
            FleetMark(size: iconSize * 0.7)
        }
    }
}
