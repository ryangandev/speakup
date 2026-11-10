// Draws the app icon: a voice that starts timid and grows into a full,
// confident wave, ending on an upswing. Writes the light, dark and tinted
// 1024 px images into the AppIcon set.
//
// From ios/: swiftc -swift-version 5 -parse-as-library -o /tmp/make-app-icon scripts/make-app-icon.swift
//            /tmp/make-app-icon SpeakUp/Assets.xcassets/AppIcon.appiconset

import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum Mode { case light, dark, tinted }

func rgb(_ hex: UInt32) -> (Double, Double, Double) {
    (Double((hex >> 16) & 0xff) / 255, Double((hex >> 8) & 0xff) / 255, Double(hex & 0xff) / 255)
}
func color(_ hex: UInt32) -> Color { let c = rgb(hex); return Color(.sRGB, red: c.0, green: c.1, blue: c.2) }

struct Icon: View {
    let mode: Mode
    // Background, and the wave from its quiet start to its loud end.
    let bgTop: UInt32 = 0x1C1D22, bgBottom: UInt32 = 0x0B0B0E
    let darkTop: UInt32 = 0x26272C, darkBottom: UInt32 = 0x0E0E11
    let waveStart: UInt32 = 0xFFB347, waveEnd: UInt32 = 0xFF4F7B
    let minAlpha = 0.4

    var body: some View {
        ZStack {
            switch mode {
            case .light: LinearGradient(colors: [color(bgTop), color(bgBottom)], startPoint: .topLeading, endPoint: .bottomTrailing)
            case .dark: LinearGradient(colors: [color(darkTop), color(darkBottom)], startPoint: .top, endPoint: .bottom)
            case .tinted: Color.black
            }
            Canvas { ctx, _ in
                let n = 400
                let x0: CGFloat = 160, x1: CGFloat = 850
                func point(_ t: CGFloat) -> CGPoint {
                    let amplitude = 250 * (0.05 + 0.95 * pow(t, 1.5))
                    let phase = 2 * CGFloat.pi * (5.0 * t - 1.75 * t * t)  // ends on a crest
                    return CGPoint(x: x0 + (x1 - x0) * t, y: 560 - amplitude * sin(phase))
                }
                let a = rgb(waveStart), b = rgb(waveEnd)
                for i in 0..<n {
                    let t0 = CGFloat(i) / CGFloat(n), t1 = CGFloat(i + 1) / CGFloat(n)
                    var segment = Path()
                    segment.move(to: point(t0))
                    segment.addLine(to: point(t1))
                    let alpha = minAlpha + (1 - minAlpha) * Double(t0)
                    let shade: Color = mode == .tinted
                        ? Color(white: alpha)
                        : Color(.sRGB, red: a.0 + (b.0 - a.0) * t0, green: a.1 + (b.1 - a.1) * t0, blue: a.2 + (b.2 - a.2) * t0, opacity: alpha)
                    ctx.stroke(segment, with: .color(shade), style: StrokeStyle(lineWidth: 18 + 38 * t0, lineCap: .round))
                }
            }
        }
        .frame(width: 1024, height: 1024)
    }
}

// Renders opaque (no alpha channel), as App Store icons require.
@MainActor func writePNG(_ mode: Mode, to path: String) {
    let renderer = ImageRenderer(content: Icon(mode: mode))
    renderer.scale = 1
    guard let image = renderer.cgImage,
          let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
    else { fatalError("could not render the icon") }
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, ctx.makeImage()!, nil)
    CGImageDestinationFinalize(destination)
}

@main struct MakeAppIcon {
    @MainActor static func main() {
        guard CommandLine.arguments.count == 2 else { print("usage: make-app-icon <AppIcon.appiconset>"); exit(2) }
        let dir = CommandLine.arguments[1]
        writePNG(.light, to: "\(dir)/AppIcon.png")
        writePNG(.dark, to: "\(dir)/AppIcon-Dark.png")
        writePNG(.tinted, to: "\(dir)/AppIcon-Tinted.png")
    }
}
