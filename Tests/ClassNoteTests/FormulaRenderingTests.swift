import SwiftUI
import XCTest
@testable import ClassNote

/// Formulas are typeset once into images (see Packages/MarkdownView/PATCHES.md).
/// These render one through the app's Markdown view and look at the pixels:
/// the formula has to be drawn, typeset rather than left as source, and the
/// right way up. The live AppKit label it replaced drew nothing off screen.
final class FormulaRenderingTests: XCTestCase {
    private struct Ink {
        var points: [(x: Int, y: Int)] = []
        var minX: Int { points.map { $0.x }.min() ?? 0 }
        var maxX: Int { points.map { $0.x }.max() ?? 0 }
        var minY: Int { points.map { $0.y }.min() ?? 0 }
        var maxY: Int { points.map { $0.y }.max() ?? 0 }

        /// Mean row of the ink between two fractions of the ink's width.
        /// Rows count down from the top.
        func meanY(fromFraction lower: Double, to upper: Double) -> Double? {
            let left = minX
            let width = Double(maxX - left)
            let picked = points.filter {
                let f = Double($0.x - left) / width
                return f >= lower && f <= upper
            }
            guard !picked.isEmpty else { return nil }
            return Double(picked.map { $0.y }.reduce(0, +)) / Double(picked.count)
        }
    }

    @MainActor
    private func ink(_ markdown: String) throws -> Ink {
        let view = RichMarkdownView(markdown: markdown)
            .frame(width: 320, alignment: .leading)
            .padding(8)
            .background(Color.white)
            .environment(\.colorScheme, .light)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.cgImage, "the view did not render")

        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress,
                                          width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        XCTAssertTrue(drawn)

        // The first row in memory is the top of the image.
        var result = Ink()
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                if pixels[i + 3] > 128, pixels[i] < 100, pixels[i + 1] < 100, pixels[i + 2] < 100 {
                    result.points.append((x, y))
                }
            }
        }
        return result
    }

    /// x², set as a formula: the small 2 sits up and to the right of the x.
    /// Left as source (`$$x^{2}$$`) the right end is braces and dollar signs
    /// down on the line, and drawn upside down the 2 hangs below the x.
    @MainActor
    func testAFormulaIsTypesetTheRightWayUp() throws {
        let ink = try ink("$$x^{2}$$")
        XCTAssertGreaterThan(ink.points.count, 50, "no formula was drawn")

        let x = try XCTUnwrap(ink.meanY(fromFraction: 0, to: 0.5))
        let two = try XCTUnwrap(ink.meanY(fromFraction: 0.75, to: 1))
        let height = Double(ink.maxY - ink.minY)
        XCTAssertGreaterThan(x - two, height * 0.25,
                             "the exponent is not raised above the x (x at \(x), 2 at \(two), ink \(height) high)")
    }
}
