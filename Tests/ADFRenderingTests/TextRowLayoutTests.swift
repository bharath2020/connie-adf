import Foundation
import Testing
@testable import ADFRendering
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

@Suite("TextRowLayout") @MainActor
struct TextRowLayoutTests {
    private func layout(_ text: String, size: CGFloat = 17) -> TextRowLayout {
        let l = TextRowLayout()
        l.setAttributedString(NSAttributedString(
            string: text,
            attributes: [.font: ADFPlatformFont.systemFont(ofSize: size)]))
        return l
    }

    @Test func sameInputSameWidthMeasuresIdentically() {
        let text = String(repeating: "deterministic layout is the spacer-memo contract ", count: 40)
        let a = layout(text).measure(width: 320, displayScale: 3)
        let b = layout(text).measure(width: 320, displayScale: 3)
        #expect(a == b)
        // And re-measuring the SAME instance after another width round-trips exactly:
        let l = layout(text)
        let first = l.measure(width: 320, displayScale: 3)
        _ = l.measure(width: 640, displayScale: 3)
        #expect(l.measure(width: 320, displayScale: 3) == first)
    }

    @Test func narrowerWidthIsTaller() {
        let text = String(repeating: "reflowing text scales like h*w0/w1 ", count: 40)
        let wide = layout(text).measure(width: 600, displayScale: 3)
        let narrow = layout(text).measure(width: 300, displayScale: 3)
        #expect(narrow.height > wide.height)
    }

    @Test func heightIsPixelAlignedAtScale() {
        let size = layout("one line").measure(width: 320, displayScale: 3)
        let remainder = (size.height * 3).truncatingRemainder(dividingBy: 1)
        #expect(abs(remainder) < 0.0001 || abs(remainder - 1) < 0.0001)  // fp-tolerant pixel check
    }

    @Test func unboundedWidthYieldsNaturalWidth() {   // code-block h-scroll case
        let size = layout("short").measure(width: .greatestFiniteMagnitude, displayScale: 3)
        #expect(size.width < 200)
    }
}
