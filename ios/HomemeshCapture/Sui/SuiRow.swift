import SwiftUI

/// A list row with a symbol, a title, an optional line of detail and an optional status chip. Shared candidate.
struct SuiRow: View {
    let symbol: String
    let title: String
    var detail: String?
    var chip: (SuiTone, String)?
    /// The row that is the point of the screen: bolder, on a tint.
    var prominent = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(prominent ? .title2 : .body)
                .foregroundStyle(SuiColor.accent)
                .frame(width: 30)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(prominent ? .headline : .body)
                if let detail { Text(detail).font(.footnote).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 8)
            if let chip { SuiChip(chip.0, chip.1) }
        }
        .padding(.vertical, prominent ? 6 : 0)
    }
}

/// A small sheet that asks for one name and says what is wrong with it while it is typed.
/// `isTaken` says whether the name clashes; `save` returns an error to show in the sheet, or nil when it worked (the sheet closes).
struct SuiNameSheet: View {
    let title: String
    let prompt: String
    let confirm: String
    let noun: String
    var isTaken: (String) -> Bool = { _ in false }
    let save: (String) async -> String?

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var touched = false
    @State private var saving = false
    @State private var failure: String?
    @FocusState private var focused: Bool

    /// What is wrong with the name now, or nil.
    var problem: String? { Self.problem(name, noun: noun, isTaken: isTaken) }

    static func problem(_ name: String, noun: String, isTaken: (String) -> Bool) -> String? {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if n.isEmpty { return "Give the \(noun) a name." }
        if isTaken(n) { return "There is already a \(noun) called \"\(n)\"." }
        return nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(prompt, text: $name)
                        .focused($focused)
                        .submitLabel(.done)
                        .onSubmit { submit() }
                        .onChange(of: name) { touched = true; failure = nil }
                } footer: {
                    if let text = failure ?? (touched ? problem : nil) { SuiNote(.danger, text) }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(confirm) { submit() }.disabled(problem != nil || saving)
                }
            }
            .onAppear { focused = true }
        }
        .presentationDetents([.height(220), .medium])
        .interactiveDismissDisabled(saving)
    }

    private func submit() {
        guard problem == nil, !saving else { touched = true; return }
        saving = true
        Task {
            let error = await save(name.trimmingCharacters(in: .whitespacesAndNewlines))
            saving = false
            if let error { failure = error } else { dismiss() }
        }
    }
}
