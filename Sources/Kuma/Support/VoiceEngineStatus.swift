import SwiftUI

struct VoiceEngineStatus: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 8) {
                icon
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.caption.weight(.semibold))
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 4)
                if !model.voiceInstalling && !model.voiceReady {
                    Button(model.voiceError == nil ? "Install" : "Try again") { model.installVoice() }
                        .controlSize(.small)
                }
            }
            if model.voiceInstalling, let progress = model.voiceProgress {
                ProgressView(value: Double(progress), total: 100)
                    .progressViewStyle(.linear)
                    .controlSize(.small)
                    .padding(.leading, 24)
            }
        }
    }

    @ViewBuilder
    private var icon: some View {
        if model.voiceInstalling {
            ProgressView().controlSize(.mini)
        } else if model.voiceReady {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        } else {
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
        }
    }

    private var title: String {
        if model.voiceInstalling { return "Installing voice" }
        if model.voiceReady { return "Voice engine" }
        if model.voiceError != nil { return "Voice install failed" }
        return "Voice not installed"
    }

    private var subtitle: String {
        if model.voiceInstalling {
            let step = model.voiceStep ?? "Starting"
            guard let progress = model.voiceProgress else { return "\(step)..." }
            return "\(step), \(progress)%"
        }
        if model.voiceReady { return "Installed, runs on this Mac" }
        if let error = model.voiceError { return error }
        return "One time download, about 340 MB"
    }
}
