import CoreGraphics
import Foundation
import UIKit

enum LocalMixCoverArtwork {
    static let stickers = ["MIXED EDITION", "DJ SET", "BEAT MATCHED", "NIGHT MIX", "DANCE FLOOR", "NONE"]

    // Custom local artwork, not a Spotify cloud cover or artist image.
    static func render(title: String, sticker: String) -> UIImage {
        let side: CGFloat = 1024
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: side, height: side))
        return renderer.image { rendererContext in
            let context = rendererContext.cgContext
            let colors = [
                UIColor(red: 0.02, green: 0.04, blue: 0.08, alpha: 1).cgColor,
                UIColor(red: 0.05, green: 0.24, blue: 0.28, alpha: 1).cgColor,
                UIColor(red: 0.20, green: 0.75, blue: 0.53, alpha: 1).cgColor
            ]
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                         colors: colors as CFArray, locations: [0, 0.62, 1]) {
                context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: 0),
                                            end: CGPoint(x: side, y: side), options: [])
            }

            context.setStrokeColor(UIColor.white.withAlphaComponent(0.12).cgColor)
            for line in 0..<15 {
                let x = CGFloat(line) * 87
                let waveHeight: CGFloat = 120 + CGFloat((line * 73) % 360)
                context.setLineWidth(18)
                context.setLineCap(.round)
                context.move(to: CGPoint(x: x, y: side * 0.44 - waveHeight / 2))
                context.addLine(to: CGPoint(x: x, y: side * 0.44 + waveHeight / 2))
                context.strokePath()
            }

            let clean = title.isEmpty ? "MY MIX" : title
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byWordWrapping
            let textAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 90, weight: .black),
                .foregroundColor: UIColor.white,
                .paragraphStyle: paragraph
            ]
            (clean as NSString).draw(in: CGRect(x: 70, y: 625, width: 900, height: 245),
                                     withAttributes: textAttrs)
            if sticker != "NONE" {
                let rect = CGRect(x: 70, y: 72, width: 360, height: 70)
                context.setFillColor(UIColor.white.cgColor)
                UIBezierPath(roundedRect: rect, cornerRadius: 14).fill()
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: UIFont.systemFont(ofSize: 32, weight: .heavy),
                    .foregroundColor: UIColor.black
                ]
                (sticker as NSString).draw(in: CGRect(x: 92, y: 89, width: 335, height: 50),
                                           withAttributes: attrs)
            }
        }
    }

    static func export(title: String, sticker: String) -> URL? {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalMix-\(UUID().uuidString).png")
        let artwork = render(title: title, sticker: sticker)
        guard let data = artwork.pngData(),
              (try? data.write(to: url, options: .atomic)) != nil else { return nil }
        return url
    }
}
