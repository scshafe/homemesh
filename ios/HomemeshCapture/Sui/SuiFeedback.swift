import SwiftUI

/// What a screen tells the user about the action they just took. Shared candidate (nothing app-specific).
/// Successes appear as a toast that goes by itself (with Undo when the action can be undone); everything else is a banner
/// at the top of the screen that stays until it is dismissed or replaced. Haptics follow the tone.
struct SuiMessage: Equatable, Identifiable {
    let id = UUID()
    var tone: SuiTone
    var text: String
    /// Shows a spinner instead of the symbol: the thing is still going on.
    var busy = false
    /// 0 to 1 when the progress is known: a bar under the text.
    var progress: Double?
    /// A label for the Undo button; the action itself is `SuiUndo`'s.
    var undoable = false

    static func info(_ text: String) -> SuiMessage { .init(tone: .info, text: text) }
    static func busy(_ text: String) -> SuiMessage { .init(tone: .info, text: text, busy: true) }
    static func success(_ text: String, undoable: Bool = false) -> SuiMessage { .init(tone: .success, text: text, undoable: undoable) }
    static func warning(_ text: String) -> SuiMessage { .init(tone: .warning, text: text) }
    static func danger(_ text: String) -> SuiMessage { .init(tone: .danger, text: text) }

    static func == (a: SuiMessage, b: SuiMessage) -> Bool { a.id == b.id }
}

/// The banner: symbol, text, a close button. Meant to sit in the layout (a safe-area inset), not float over content.
struct SuiBanner: View {
    let message: SuiMessage
    var onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if message.busy { ProgressView().controlSize(.small) }
            else { Image(systemName: message.tone.symbol).foregroundStyle(message.tone.color) }
            VStack(alignment: .leading, spacing: 6) {
                Text(message.text).font(.footnote)
                if let p = message.progress { ProgressView(value: min(1, max(0, p))) }
            }.frame(maxWidth: .infinity, alignment: .leading)
            Button { onDismiss() } label: { Image(systemName: "xmark").font(.footnote) }
                .accessibilityLabel("Dismiss")
                .buttonStyle(.borderless)
        }
        .padding(10)
        .background(message.tone.color.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(message.tone.color.opacity(0.4), lineWidth: 1))
        .padding(.horizontal).padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

/// The toast: a short confirmation at the bottom, with Undo when there is one.
struct SuiToastView: View {
    let message: SuiMessage
    var onUndo: (() -> Void)?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: message.tone.symbol).foregroundStyle(message.tone.color)
            Text(message.text).font(.footnote)
            if let onUndo, message.undoable {
                Button("Undo", action: onUndo).font(.footnote.bold()).buttonStyle(.borderless)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(.regularMaterial, in: Capsule())
        .shadow(radius: 4, y: 2)
        .padding(.bottom, 12)
        .accessibilityElement(children: .combine)
    }
}

private struct SuiMessageModifier: ViewModifier {
    @Binding var message: SuiMessage?
    var undo: (() -> Void)?
    var toastSeconds: Double

    func body(content: Content) -> some View {
        content
            .safeAreaInset(edge: .top, spacing: 0) {
                if let m = message, m.tone != .success {
                    SuiBanner(message: m) { message = nil }
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .overlay(alignment: .bottom) {
                if let m = message, m.tone == .success {
                    SuiToastView(message: m, onUndo: undo.map { u in { message = nil; u() } })
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .task(id: m.id) {
                            try? await Task.sleep(for: .seconds(toastSeconds))
                            if message?.id == m.id { message = nil }
                        }
                }
            }
            .animation(.default, value: message?.id)
            .suiHaptics(message)
    }
}

private struct SuiHapticsModifier: ViewModifier {
    let message: SuiMessage?

    func body(content: Content) -> some View {
        content.sensoryFeedback(trigger: message?.id) { _, new in
            guard new != nil, let m = message else { return nil }
            switch m.tone {
            case .success: return .success
            case .danger: return .error
            case .warning: return .warning
            default: return nil
            }
        }
    }
}

extension View {
    /// Only the haptic of a message (success, warning, error), for screens that draw the message themselves.
    func suiHaptics(_ message: SuiMessage?) -> some View { modifier(SuiHapticsModifier(message: message)) }

    /// Shows `message` as a toast (success) or a banner (anything else), with haptics. `undo` is offered on an undoable success.
    func suiMessage(_ message: Binding<SuiMessage?>, undo: (() -> Void)? = nil, toastSeconds: Double = 5) -> some View {
        modifier(SuiMessageModifier(message: message, undo: undo, toastSeconds: toastSeconds))
    }
}

/// The empty state: a symbol, a title, what to do about it. The system's view, so it looks and reads right everywhere.
struct SuiEmpty<Actions: View>: View {
    let title: String
    let symbol: String
    let detail: String
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: symbol)
        } description: {
            Text(detail)
        } actions: {
            actions()
        }
    }
}

extension SuiEmpty where Actions == EmptyView {
    init(title: String, symbol: String, detail: String) {
        self.init(title: title, symbol: symbol, detail: detail) { EmptyView() }
    }
}
