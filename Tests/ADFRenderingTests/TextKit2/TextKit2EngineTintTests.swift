#if canImport(UIKit)
import SwiftUI
import UIKit
import Testing
import ADFPreparation
@_spi(ADFDiagnostics) @testable import ADFRendering

/// `View.adfEngineTint` on the TextKit 2 arm: a row fills its bounds with
/// its engine's colour while the tint is on (TextKit 2, or TextKit 1-backed
/// while its text holds a link, following the text), and keeps the clear
/// background it is created with while the tint is off.
@Suite("Engine tint on TextKit 2 rows", .serialized)
@MainActor
struct TextKit2EngineTintTests {
    @Test("a row is clear while the tint is off and follows its engine while it is on")
    func rowFill() async throws {
        let plain = try await TK2Parity.plain("tint-plain", "Plain text drawn by TextKit 2")
        let linked = try await TK2Parity.fixture("tint-link", content:
            TK2Parity.adfText("See ") + "," + TextKit2LinkTests.link("the notes", "https://example.com/notes"))
        let view = TextKit2RowView()
        view.apply(try TK2Parity.inputs(plain, env: .init()))
        #expect(view.backgroundColor == .clear)

        view.engineTint = true
        #expect(view.backgroundColor == ADFEngineTint.textKit2.fillUIColor)
        view.apply(try TK2Parity.inputs(linked, env: .init()))
        #expect(view.isTextKit1Backed)
        #expect(view.backgroundColor == ADFEngineTint.textKit1Backed.fillUIColor)
        view.apply(try TK2Parity.inputs(plain, env: .init()))
        #expect(!view.isTextKit1Backed)
        #expect(view.backgroundColor == ADFEngineTint.textKit2.fillUIColor)

        view.engineTint = false
        #expect(view.backgroundColor == .clear)
        // Off, a TextKit 1-backed row stays clear too.
        view.apply(try TK2Parity.inputs(linked, env: .init()))
        #expect(view.backgroundColor == .clear)
    }

    @Test("the three engines have distinct colours")
    func distinctColours() {
        let fills = ADFEngineTint.allCases.map(\.fillUIColor)
        #expect(Set(fills).count == ADFEngineTint.allCases.count)
    }
}
#endif
