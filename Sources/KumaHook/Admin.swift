import Foundation
import KumaCore

enum Admin {
    static func run(_ args: [String]) -> Int32 {
        let command = args.first ?? "help"
        let self_ = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().path
        let installer = HookInstaller()
        let heard = HeardRemover()
        do {
            switch command {
            case "status":
                for tool in [Tool.claude, .opencode, .codex, .cursor] {
                    print("\(tool.rawValue): hooks \(installer.isInstalled(tool) ? "installed" : "not installed"), binary \(ToolLocator.shared.isInstalled(tool) ? "found" : "missing")")
                }
                print("heard: \(heard.isHeardPresent ? "present" : "absent")")
            case "heard-plan":
                heard.plan().forEach { print($0) }
            case "remove-heard":
                try heard.apply().forEach { print($0) }
            case "install":
                let tools = args.dropFirst().compactMap(Tool.init(rawValue:))
                for tool in tools.isEmpty ? ToolLocator.shared.installedTools.filter({ $0 != .other }) : tools {
                    try installer.install(tool, hookBinary: self_)
                    print("installed \(tool.rawValue)")
                }
            case "uninstall":
                let tools = args.dropFirst().compactMap(Tool.init(rawValue:))
                for tool in tools.isEmpty ? [Tool.claude, .opencode, .codex, .cursor] : tools {
                    try installer.uninstall(tool)
                    print("uninstalled \(tool.rawValue)")
                }
            default:
                print("usage: kuma-hook admin status | heard-plan | remove-heard | install [tools] | uninstall [tools]")
            }
            return 0
        } catch {
            FileHandle.standardError.write(Data("error: \(error)\n".utf8))
            return 1
        }
    }
}
