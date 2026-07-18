import Foundation
import SwiftUI
import Testing
import ADFPreparation
@testable import ADFRendering

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

#if canImport(UIKit)
func fontTraitsContainBold(_ font: ADFPlatformFont) -> Bool {
    font.fontDescriptor.symbolicTraits.contains(.traitBold)
}

func fontTraitsContainItalic(_ font: ADFPlatformFont) -> Bool {
    font.fontDescriptor.symbolicTraits.contains(.traitItalic)
}

func fontIsFixedPitch(_ font: ADFPlatformFont) -> Bool {
    font.fontDescriptor.symbolicTraits.contains(.traitMonoSpace)
}
#elseif canImport(AppKit)
func fontTraitsContainBold(_ font: ADFPlatformFont) -> Bool {
    font.fontDescriptor.symbolicTraits.contains(.bold)
}

func fontTraitsContainItalic(_ font: ADFPlatformFont) -> Bool {
    font.fontDescriptor.symbolicTraits.contains(.italic)
}

func fontIsFixedPitch(_ font: ADFPlatformFont) -> Bool {
    font.fontDescriptor.symbolicTraits.contains(.monoSpace)
}
#endif

@Suite("FontSpecResolver") @MainActor
struct FontSpecResolverTests {
    @Test func semanticStylesResolveDistinctly() {
        let r = FontSpecResolver.shared
        let body = r.font(for: .body, categoryRawValue: "UICTContentSizeCategoryL")
        let title = r.font(for: FontSpec(style: .title, bold: true), categoryRawValue: "UICTContentSizeCategoryL")
        #expect(title.pointSize > body.pointSize)
    }

    @Test func boldAndItalicApplyDescriptorTraits() {
        let r = FontSpecResolver.shared
        let bold = r.font(for: FontSpec(bold: true), categoryRawValue: "UICTContentSizeCategoryL")
        #expect(fontTraitsContainBold(bold))   // helper below per platform
    }

    @Test func italicAppliesDescriptorTrait() {
        let r = FontSpecResolver.shared
        let italic = r.font(for: FontSpec(italic: true), categoryRawValue: "UICTContentSizeCategoryL")
        #expect(fontTraitsContainItalic(italic))   // helper above per platform
    }

    @Test func monospacedUsesMonospacedSystemFont() {
        let r = FontSpecResolver.shared
        let mono = r.font(for: FontSpec(monospaced: true), categoryRawValue: "UICTContentSizeCategoryL")
        #expect(fontIsFixedPitch(mono))
    }

    @Test func resolutionIsMemoized() {
        let r = FontSpecResolver.shared
        let a = r.font(for: .body, categoryRawValue: "UICTContentSizeCategoryL")
        let countAfterFirst = r.resolutionCount
        let b = r.font(for: .body, categoryRawValue: "UICTContentSizeCategoryL")
        #expect(a === b)
        // The `===` check above can pass vacuously: UIFont/NSFont factory
        // methods use their own interning, so two independent resolutions
        // could coincidentally return the same instance. Assert the cache
        // actually short-circuits by checking the resolver's own call count
        // doesn't move on the second, identical lookup.
        #expect(r.resolutionCount == countAfterFirst)
    }
}
