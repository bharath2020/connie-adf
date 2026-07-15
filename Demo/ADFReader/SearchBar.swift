import SwiftUI
import ADFRendering

/// Bottom find-in-page bar: query field, streamed "current / total" counter,
/// previous/next, and Done. All state lives in the library's
/// `ADFDocumentSearch`; this view is a thin shell over it.
struct SearchBar: View {
    let search: ADFDocumentSearch
    @Binding var isPresented: Bool

    @State private var text = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Find in page", text: $text)
                    .textFieldStyle(.plain)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .focused($isFocused)
                    .onSubmit { search.next() }
                    .onChange(of: text) { _, newValue in
                        search.run(newValue)
                    }
                if search.isSearching {
                    ProgressView()
                        .controlSize(.small)
                } else if !text.isEmpty {
                    Text(counterText)
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.5)))

            Button {
                search.previous()
            } label: {
                Image(systemName: "chevron.up")
            }
            .disabled(search.matchCount == 0)
            .accessibilityLabel("Previous match")

            Button {
                search.next()
            } label: {
                Image(systemName: "chevron.down")
            }
            .disabled(search.matchCount == 0)
            .accessibilityLabel("Next match")

            Button("Done") {
                search.clear()
                isPresented = false
            }
            .fontWeight(.semibold)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
        .onAppear { isFocused = true }
    }

    private var counterText: String {
        guard search.matchCount > 0 else { return "0" }
        return "\((search.currentIndex ?? 0) + 1) / \(search.matchCount)"
    }
}
