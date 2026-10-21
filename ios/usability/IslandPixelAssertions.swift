import XCTest
import UIKit

extension JourneyUsabilityTestBase {
    private func islandPixelSample(_ element: XCUIElement) -> (shot: XCUIScreenshot, light: Int, dark: Double)? {
        guard element.exists else { return nil }
        let screenshot = XCUIScreen.main.screenshot()
        guard let full = UIImage(data: screenshot.pngRepresentation)?.cgImage else { return nil }
        let frame = element.frame, screen = UIScreen.main.bounds
        let scale = CGFloat(full.width) / screen.width
        let rect = CGRect(x: frame.minX * scale, y: frame.minY * scale,
            width: frame.width * scale, height: frame.height * scale).integral
        guard frame.minY < screen.height * 0.3, !frame.isEmpty,
              let crop = full.cropping(to: rect), crop.width > 0, crop.height > 0 else { return nil }
        var pixels = [UInt8](repeating: 0, count: crop.width * crop.height * 4)
        let decoded = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: crop.width, height: crop.height,
                bitsPerComponent: 8, bytesPerRow: crop.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            context.draw(crop, in: CGRect(x: 0, y: 0, width: CGFloat(crop.width), height: CGFloat(crop.height)))
            return true
        }
        guard decoded else { return nil }
        var dark = 0, light = 0
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let r = Int(pixels[i]), g = Int(pixels[i+1]), b = Int(pixels[i+2])
            if max(r, max(g, b)) < 55 { dark += 1 }
            if min(r, min(g, b)) > 135 { light += 1 }
        }
        return (screenshot, light, Double(dark) / Double(crop.width * crop.height))
    }
    /// A label is exposed before the expansion animation paints its first frame.
    /// Allow a bounded transition, while still rejecting persistent empty content.
    func assertIslandPixels(_ element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(3)
        var sample = islandPixelSample(element)
        while (sample?.light ?? 0) <= 8 || (sample?.dark ?? 0) <= 0.15 {
            if Date() >= deadline { break }
            Thread.sleep(forTimeInterval: 0.15)
            if let next = islandPixelSample(element) { sample = next }
        }
        let proof = XCTAttachment(screenshot: sample?.shot ?? XCUIScreen.main.screenshot())
        proof.name = "island-pixel-proof"; proof.lifetime = .keepAlways; add(proof)
        guard let sample else {
            XCTFail("The expected guidance is not positioned inside the system island", file: file, line: line); return
        }
        XCTAssertGreaterThan(sample.light, 8, "The island has labels but its text is visually blank", file: file, line: line)
        XCTAssertGreaterThan(sample.dark, 0.15,
            "The island collapsed before its guidance could be visually verified", file: file, line: line)
    }
}
