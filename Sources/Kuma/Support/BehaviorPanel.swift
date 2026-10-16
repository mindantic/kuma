import KumaCore
import SwiftUI

private enum SpeakLevel: Hashable {
    case everything, important, muted
}

struct BehaviorPanel: View {
    @ObservedObject var model: AppModel
    @Binding var draft: SessionPrefs
    let inheritLabel: String

    var body: some View {
        VStack(spacing: 0) {
            row("Speak", symbol: "speaker.wave.2") {
                Picker("Speak", selection: level) {
                    Text("Everything").tag(SpeakLevel.everything)
                    Text("Important").tag(SpeakLevel.important)
                    Text("Muted").tag(SpeakLevel.muted)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 260)
            }
            Group {
                Divider().padding(.leading, 32)
                row("Detail", symbol: "text.alignleft") {
                    Picker("Detail", selection: $draft.verbosity) {
                        Text("One line").tag(Verbosity.line)
                        Text("Short summary").tag(Verbosity.summary)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 260)
                }
                Divider().padding(.leading, 32)
                row("Personality", symbol: "person.crop.circle") {
                    Picker("Personality", selection: $draft.personaId) {
                        Text(inheritLabel).tag(String?.none)
                        Divider()
                        ForEach(model.personas) { Text($0.name).tag(String?.some($0.id)) }
                    }
                    .labelsHidden()
                    .frame(width: 260)
                }
                Divider().padding(.leading, 32)
                row("Voice", symbol: "waveform") {
                    Picker("Voice", selection: $draft.voice) {
                        Text("Match personality").tag(String?.none)
                        Divider()
                        ForEach(model.voices) { Text($0.name).tag(String?.some($0.id)) }
                    }
                    .labelsHidden()
                    .frame(width: 260)
                }
                Divider().padding(.leading, 32)
                VStack(alignment: .leading, spacing: 8) {
                    label("Speak about", symbol: "bell")
                    HStack(spacing: 6) {
                        chip("Finished", isOn: $draft.speakFinished)
                        chip("Approvals", isOn: $draft.speakApprovals)
                        chip("Questions", isOn: $draft.speakQuestions)
                        chip("Errors", isOn: $draft.speakErrors)
                        chip("Subagents", isOn: $draft.speakSubagents)
                    }
                    .padding(.leading, 32)
                }
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .disabled(draft.muted)
            .opacity(draft.muted ? 0.45 : 1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.08)))
    }

    private func row<Control: View>(_ title: String, symbol: String, @ViewBuilder control: () -> Control) -> some View {
        HStack {
            label(title, symbol: symbol)
            Spacer(minLength: 12)
            control()
        }
        .padding(.vertical, 8)
    }

    private func label(_ title: String, symbol: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .regular))
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(KumaTheme.purple)
                .frame(width: 20, height: 18)
            Text(title)
        }
    }

    private func chip(_ title: String, isOn: Binding<Bool>) -> some View {
        Button {
            isOn.wrappedValue.toggle()
        } label: {
            HStack(spacing: 4) {
                if isOn.wrappedValue {
                    Image(systemName: "checkmark").font(.system(size: 9, weight: .bold))
                }
                Text(title)
            }
            .font(.callout)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .foregroundStyle(isOn.wrappedValue ? KumaTheme.purple : Color.secondary)
            .background(Capsule().fill(isOn.wrappedValue ? KumaTheme.purple.opacity(0.16) : Color.primary.opacity(0.05)))
            .overlay(Capsule().strokeBorder(isOn.wrappedValue ? KumaTheme.purple.opacity(0.4) : Color.primary.opacity(0.1)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private var level: Binding<SpeakLevel> {
        Binding(
            get: { draft.muted ? .muted : draft.highOnly ? .important : .everything },
            set: { value in
                draft.muted = value == .muted
                draft.highOnly = value == .important
            }
        )
    }
}
