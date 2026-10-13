import AppKit
import QuaydeckCore
import QuaydeckUI
import SwiftUI

// Renders the real menu, fed by DemoMachine, into the brand kit. Never ordered on
// screen: every view is drawn into an offscreen bitmap.

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1
               ? CommandLine.arguments[1]
               : FileManager.default.currentDirectoryPath + "/../..")
    .standardizedFileURL
let brand = root.appendingPathComponent("brand")

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)

let navy = Color(red: 0.043, green: 0.114, blue: 0.196)
let brass = Color(red: 0.945, green: 0.769, blue: 0.482)

@MainActor
func render<V: View>(_ view: V, size: CGSize, dark: Bool, to path: String) {
    let host = NSHostingView(rootView: view.environment(\.colorScheme, dark ? .dark : .light))
    host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    host.frame = NSRect(origin: .zero, size: size)
    host.layoutSubtreeIfNeeded()
    let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
    host.cacheDisplay(in: host.bounds, to: rep)
    let url = brand.appendingPathComponent(path)
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    // Photographic shots go out as JPEG; anything with transparency stays PNG.
    let data = path.hasSuffix(".jpg")
        ? rep.representation(using: .jpeg, properties: [.compressionFactor: 0.9])!
        : rep.representation(using: .png, properties: [:])!
    try! data.write(to: url)
    print("wrote brand/\(path)")
}

/// The menu as the popover draws it: its own material colour, rounded, lifted.
struct Popover: View {
    let model: AppModel
    let dark: Bool

    var body: some View {
        MenuView(model: model)
            .background(dark ? Color(white: 0.155) : Color(white: 0.955))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.white.opacity(dark ? 0.12 : 0.6), lineWidth: 0.5))
            .shadow(color: .black.opacity(dark ? 0.55 : 0.22), radius: 26, y: 14)
    }
}

/// A desktop at night with the menu open under its status item.
struct Desktop: View {
    let model: AppModel
    let backdrop: NSImage

    var body: some View {
        ZStack(alignment: .top) {
            Image(nsImage: backdrop).resizable().aspectRatio(contentMode: .fill)
                .frame(width: 1440, height: 900).clipped()
            VStack(spacing: 0) {
                menuBar
                HStack {
                    Spacer()
                    // Centred under the status item, as macOS places it: the item's
                    // centre sits 255 pt from the right edge (see menuBar).
                    Popover(model: model, dark: true).padding(.trailing, 255 - 180).padding(.top, 7)
                }
                Spacer()
            }
        }
        .frame(width: 1440, height: 900)
    }

    private var menuBar: some View {
        HStack(spacing: 18) {
            Spacer()
            // Fixed widths, so the status item's centre is known: 18 + 124 + 18 + 24 + 18
            // + 20 + 18 + 15 = 255 pt from the right edge.
            ZStack {
                RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.22)).frame(width: 30, height: 20)
                Image(systemName: "\(model.snapshot.devServers.count).circle.fill").font(.system(size: 14))
            }
            .frame(width: 30)
            Image(systemName: "wifi").font(.system(size: 14)).frame(width: 20)
            Image(systemName: "battery.75percent").font(.system(size: 16)).frame(width: 24)
            Text(verbatim: "Tue 14 Oct  09:41").font(.system(size: 13, weight: .medium))
                .frame(width: 124, alignment: .trailing)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 18)
        .frame(height: 28)
        .background(Color.black.opacity(0.28))
    }
}

/// The link-preview card. The words are set here, never painted by an image model.
struct SocialCard: View {
    let background: NSImage
    let icon: NSImage

    var body: some View {
        ZStack(alignment: .leading) {
            Image(nsImage: background).resizable().aspectRatio(contentMode: .fill)
                .frame(width: 1200, height: 630).clipped()
            VStack(alignment: .leading, spacing: 0) {
                Image(nsImage: icon).resizable().frame(width: 132, height: 132)
                    .padding(.leading, -14).padding(.bottom, 26)
                Text(verbatim: "Quaydeck")
                    .font(.system(size: 76, weight: .bold))
                    .tracking(-1.5)
                    .foregroundStyle(.white)
                Text(verbatim: "Every dev server on your Mac,\nin your menu bar.")
                    .font(.system(size: 34, weight: .medium))
                    .foregroundStyle(.white.opacity(0.86))
                    .lineSpacing(2)
                    .padding(.top, 10)
                Text(verbatim: "Free and open source  ·  Claude, Codex and Docker aware")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(brass)
                    .padding(.top, 26)
            }
            .padding(.leading, 84)
        }
        .frame(width: 1200, height: 630)
    }
}

Task { @MainActor in
    @MainActor func freshModel() -> AppModel {
        let suite = "quaydeck-screenshots"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let model = AppModel(preferences: Preferences(defaults: defaults),
                             probe: DemoMachine.Probe(),
                             inventory: DemoMachine.inventory())
        model.setMenuOpen(true)
        return model
    }

    let model = freshModel()
    try? await Task.sleep(nanoseconds: 1_500_000_000)

    for dark in [false, true] {
        render(Popover(model: model, dark: dark).padding(44),
               size: CGSize(width: 448, height: 660), dark: dark,
               to: "screenshots/menu-\(dark ? "dark" : "light").png")
    }

    let backdrop = NSImage(contentsOf: brand.appendingPathComponent("art/harbour-backdrop.jpg"))!
    render(Desktop(model: model, backdrop: backdrop), size: CGSize(width: 1440, height: 900), dark: true,
           to: "screenshots/desktop.jpg")

    let quay = NSImage(contentsOf: brand.appendingPathComponent("art/harbour-quay.jpg"))!
    let icon = NSImage(contentsOf: brand.appendingPathComponent("icon/AppIcon-1024.png"))!
    render(SocialCard(background: quay, icon: icon), size: CGSize(width: 1200, height: 630), dark: true,
           to: "social/og-image@2x.jpg")
    exit(0)
}
app.run()
