import SwiftUI
import Testing
import ADFRendering

/// The per-document text-size control moves along the DynamicTypeSize ladder
/// relative to the system baseline; these helpers are the whole mechanism.
@Suite("Dynamic Type stepping")
struct DynamicTypeStepTests {
    @Test("A step moves one rung along the ladder")
    func shiftsUpAndDown() {
        #expect(DynamicTypeSize.large.shifted(by: 1) == .xLarge)
        #expect(DynamicTypeSize.large.shifted(by: -1) == .medium)
        #expect(DynamicTypeSize.xxxLarge.shifted(by: 1) == .accessibility1)
    }

    @Test("Shifting clamps at both ends of the ladder")
    func clampsAtEnds() {
        #expect(DynamicTypeSize.accessibility4.shifted(by: 5) == .accessibility5)
        #expect(DynamicTypeSize.small.shifted(by: -9) == .xSmall)
        #expect(DynamicTypeSize.accessibility5.shifted(by: 1) == .accessibility5)
        #expect(DynamicTypeSize.xSmall.shifted(by: -1) == .xSmall)
    }

    @Test("A zero shift is the identity for every size")
    func zeroIsIdentity() {
        for size in DynamicTypeSize.allCases {
            #expect(size.shifted(by: 0) == size)
        }
    }

    @Test("Body point sizes grow strictly along the ladder, 17pt at .large")
    func pointSizesAreMonotonic() {
        let sizes = DynamicTypeSize.allCases.map(\.approximateBodyPointSize)
        #expect(sizes == sizes.sorted())
        #expect(Set(sizes).count == sizes.count)
        #expect(DynamicTypeSize.large.approximateBodyPointSize == 17)
    }
}
