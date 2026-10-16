import Darwin
import Foundation
import KumaCore

signal(SIGPIPE, SIG_IGN)

let arguments = CommandLine.arguments
let toolArg = arguments.count > 1 ? arguments[1].lowercased() : ""
let eventArg = arguments.count > 2 ? arguments[2] : ""
let tool = Tool(rawValue: toolArg) ?? .other

if toolArg == "admin" {
    exit(Admin.run(Array(arguments.dropFirst(2))))
}

if tool == .codex, eventArg == "Stop" {
    FileHandle.standardOutput.write(Data("{}\n".utf8))
}

let environment = ProcessInfo.processInfo.environment
if environment[KumaEnv.summaryGuard] != nil {
    exit(0)
}

let input: Data = isatty(STDIN_FILENO) == 1 ? Data() : FileHandle.standardInput.readDataToEndOfFile()

let envelope = HookClient.makeEnvelope(tool: tool, event: eventArg, stdin: input, env: environment, parentPID: getppid())
HookClient().send(envelope)
exit(0)
