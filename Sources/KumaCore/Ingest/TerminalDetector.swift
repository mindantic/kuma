import Foundation

public enum TerminalDetector {
    static let cursorBundle = "com.todesktop.230313mzl4w4u92"

    static let byBundle: [String: String] = [
        "com.stablyai.orca": "Orca",
        "com.googlecode.iterm2": "iTerm2",
        "com.apple.Terminal": "Terminal",
        "com.mitchellh.ghostty": "Ghostty",
        "com.microsoft.VSCode": "VS Code",
        "com.microsoft.VSCodeInsiders": "VS Code",
        cursorBundle: "Cursor",
        "com.github.wez.wezterm": "WezTerm",
        "dev.warp.Warp-Stable": "Warp",
        "net.kovidgoyal.kitty": "kitty",
        "org.alacritty": "Alacritty",
        "dev.zed.Zed": "Zed",
    ]

    static let byTermProgram: [String: String] = [
        "orca": "Orca",
        "iterm.app": "iTerm2",
        "apple_terminal": "Terminal",
        "ghostty": "Ghostty",
        "wezterm": "WezTerm",
        "warpterminal": "Warp",
        "kitty": "kitty",
        "alacritty": "Alacritty",
        "zed": "Zed",
    ]

    public static func name(env: [String: String]) -> String? {
        let base = baseName(env: env)
        let inTmux = !(env["TMUX"] ?? "").isEmpty
        switch (base, inTmux) {
        case (let b?, true): return b + " (tmux)"
        case (nil, true): return "tmux"
        case (let b, false): return b
        }
    }

    static func baseName(env: [String: String]) -> String? {
        let bundle = env["__CFBundleIdentifier"] ?? ""
        let program = (env["TERM_PROGRAM"] ?? "").lowercased()
        if bundle == "com.stablyai.orca" || program == "orca" || !(env["ORCA_TERMINAL_ID"] ?? "").isEmpty {
            return "Orca"
        }
        if program == "vscode" {
            return bundle == cursorBundle ? "Cursor" : "VS Code"
        }
        if let n = byTermProgram[program] { return n }
        if let n = byBundle[bundle] { return n }
        if !(env["ITERM_SESSION_ID"] ?? "").isEmpty { return "iTerm2" }
        if !(env["GHOSTTY_RESOURCES_DIR"] ?? "").isEmpty { return "Ghostty" }
        if !(env["TERM_SESSION_ID"] ?? "").isEmpty { return "Terminal" }
        return nil
    }
}
