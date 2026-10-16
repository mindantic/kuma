import KumaCore
import SwiftUI

struct ModeMenu: View {
    @ObservedObject var model: AppModel

    var body: some View {
        let mode = model.settings.mode
        HStack(spacing: 6) {
            Circle()
                .fill(mode.tint)
                .frame(width: 7, height: 7)
            Menu {
                ForEach(Mode.allCases, id: \.self) { option in
                    Button {
                        model.setMode(option)
                    } label: {
                        if option == mode {
                            Label(option.label, systemImage: "checkmark")
                        } else {
                            Text(option.label)
                        }
                    }
                }
            } label: {
                Text(mode.label)
                    .font(.system(size: 12, weight: .medium))
            }
            .menuIndicator(.visible)
            .tint(.primary)
            .fixedSize()
        }
        .fixedSize()
        .help("\(mode.label): \(mode.explanation)")
    }
}
