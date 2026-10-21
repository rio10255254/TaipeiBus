import XCTest
import UIKit

extension JourneyUsabilityTestBase {
    /// Accessibility can retain a label during a failed render or a collapsing
    /// transition. Require visible light text on the actual black island as well.
    func assertIslandPixels(_ element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        let screenshot = XCUIScreen.main.screenshot()
        guard let full = UIImage(data: screenshot.pngRepresentation)?.cgImage else {
            XCTFail("System screenshot could not be decoded", file: file, line: line); return
        }
        let frame = element.frame, screen = UIScreen.main.bounds
        let scale = CGFloat(full.width) / screen.width
        let rect = CGRect(x: frame.minX * scale, y: frame.minY * scale,
            width: frame.width * scale, height: frame.height * scale).integral
        guard frame.minY < screen.height * 0.3, !frame.isEmpty,
              let crop = full.cropping(to: rect), crop.width > 0, crop.height > 0 else {
            XCTFail("The expected guidance is not positioned inside the system island", file: file, line: line); return
        }
        var pixels = [UInt8](repeating: 0, count: crop.width * crop.height * 4)
        let decoded = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: crop.width, height: crop.height,
                bitsPerComponent: 8, bytesPerRow: crop.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            context.draw(crop, in: CGRect(x: 0, y: 0, width: CGFloat(crop.width), height: CGFloat(crop.height)))
            return true
        }
        XCTAssertTrue(decoded, file: file, line: line)
        var dark = 0, light = 0
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let r = Int(pixels[i]), g = Int(pixels[i+1]), b = Int(pixels[i+2])
            if max(r, max(g, b)) < 55 { dark += 1 }
            if min(r, min(g, b)) > 135 { light += 1 }
        }
        let proof = XCTAttachment(screenshot: screenshot)
        proof.name = "island-pixel-proof"; proof.lifetime = .keepAlways; add(proof)
        XCTAssertGreaterThan(light, 8, "The island has labels but its text is visually blank", file: file, line: line)
        XCTAssertGreaterThan(Double(dark) / Double(crop.width * crop.height), 0.15,
            "The island collapsed before its guidance could be visually verified", file: file, line: line)
    }
}
