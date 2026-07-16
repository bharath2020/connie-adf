// Demo/ADFReader/TextSizeControl.swift
import SwiftUI
import ADFRendering

/// Popover content for the toolbar text-size item: step the document's type
/// size down/up along the Dynamic Type ladder, with a percentage readout
/// relative to the reader's own baseline (step 0 = 100%) and a reset.
///
/// A popover, not a `Menu`: menu buttons dismiss on every tap, which kills
/// repeated A+ tapping.
struct TextSizeControl: View {
    @Binding var step: Int
    let systemTypeSize: DynamicTypeSize
    let onChange: (Int) -> Void

    private var effective: DynamicTypeSize { systemTypeSize.shifted(by: step) }

    private var percent: Int {
        Int((effective.approximateBodyPointSize
            / systemTypeSize.approximateBodyPointSize * 100).rounded())
    }

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Button {
                    adjust(-1)
                } label: {
                    Image(systemName: "textformat.size.smaller")
                        .frame(minWidth: 44, minHeight: 36)
                }
                .disabled(effective == DynamicTypeSize.allCases.first)
                .accessibilityLabel("Decrease Text Size")

                Text("\(percent)%")
                    .font(.callout.monospacedDigit())
                    .frame(minWidth: 56)

                Button {
                    adjust(1)
                } label: {
                    Image(systemName: "textformat.size.larger")
                        .frame(minWidth: 44, minHeight: 36)
                }
                .disabled(effective == DynamicTypeSize.allCases.last)
                .accessibilityLabel("Increase Text Size")
            }

            Divider()

            Button("Reset to 100%") {
                set(0)
            }
            .font(.callout)
            .disabled(step == 0)
            .accessibilityLabel("Reset Text Size")
        }
        .padding(12)
    }

    private func adjust(_ delta: Int) {
        // Step from the EFFECTIVE size, not the raw step: a persisted step
        // that overshoots the ladder under the current system size (saved
        // when the system size was different) would otherwise need several
        // taps before anything visibly changes.
        let ladder = DynamicTypeSize.allCases
        guard let target = ladder.firstIndex(of: effective.shifted(by: delta)),
              let base = ladder.firstIndex(of: systemTypeSize) else { return }
        set(target - base)
    }

    private func set(_ newStep: Int) {
        step = newStep
        onChange(newStep)
    }
}
