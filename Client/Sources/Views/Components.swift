import AppKit
import SwiftUI

/// A floating card surface in the warm design language.
struct FleetCard<Content: View>: View {
    var padding: CGFloat = 18
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: 18)
                    .fill(Color.fleetCard)
                    .overlay(
                        RoundedRectangle(cornerRadius: 18)
                            .strokeBorder(Color.fleetBorder, lineWidth: 1))
            )
            .shadow(color: Color.fleetInk.opacity(0.06), radius: 5, y: 2)
    }
}

/// Small uppercase section label.
struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased())
            .font(.fleetSans(10, weight: .semibold))
            .tracking(0.8)
            .foregroundStyle(Color.fleetInk.opacity(0.45))
    }
}

/// Gold primary-action button style.
struct FleetButtonStyle: ButtonStyle {
    var prominent: Bool = true
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.fleetSans(13, weight: .medium))
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .foregroundStyle(prominent ? Color.white : Color.fleetInk)
            .background(
                RoundedRectangle(cornerRadius: 9)
                    .fill(prominent ? Color.fleetGold : Color.fleetFill)
                    .opacity(configuration.isPressed ? 0.8 : 1)
            )
            .shadow(
                color: prominent ? Color.fleetGold.opacity(0.30) : .clear,
                radius: 4, y: 2)
    }
}

extension ButtonStyle where Self == FleetButtonStyle {
    static var fleet: FleetButtonStyle { FleetButtonStyle(prominent: true) }
    static var fleetQuiet: FleetButtonStyle { FleetButtonStyle(prominent: false) }
}

/// Colored status dot.
struct StatusDot: View {
    let color: Color
    var body: some View {
        Circle().fill(color).frame(width: 8, height: 8)
    }
}

/// Empty-state hero with the Fleet emblem.
struct EmptyHero: View {
    let title: String
    let subtitle: String
    var body: some View {
        VStack(spacing: 16) {
            FleetEmblem(iconSize: 56)
            Text(title)
                .font(.fleetSerif(20, weight: .light, italic: true))
                .foregroundStyle(Color.fleetInk)
            Text(subtitle)
                .font(.fleetSans(12))
                .foregroundStyle(Color.fleetInk.opacity(0.45))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Open a file picker and return the chosen files.
enum FilePicker {
    static func pickFiles() -> [URL] {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        return panel.runModal() == .OK ? panel.urls : []
    }

    /// Pick a single directory, with a prompt naming what it is for.
    static func pickDirectory(prompt: String) -> URL? {
        let panel = NSOpenPanel()
        panel.message = prompt
        panel.prompt = "Choose"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        return panel.runModal() == .OK ? panel.urls.first : nil
    }

    /// The JSON files in a directory, sorted by name so two folders pair up by index.
    static func jsonFiles(in directory: URL) throws -> [URL] {
        try FileManager.default
            .contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension.lowercased() == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}
