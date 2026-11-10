import Foundation
import VoyageCore

func printIssue(file: String, rule: String, message: String) {
    let data = try! JSONSerialization.data(withJSONObject: ["file": file, "rule": rule, "message": message], options: [.sortedKeys])
    FileHandle.standardOutput.write(data + Data([10]))
}

let arguments = Array(CommandLine.arguments.dropFirst())
var paths: [String: String] = [:]
var index = 1
var valid = arguments.first == "validate"
while valid && index < arguments.count {
    let flag = arguments[index]
    guard ["--pack", "--drafts"].contains(flag), paths[flag] == nil,
          index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--") else {
        valid = false
        break
    }
    paths[flag] = arguments[index + 1]
    index += 2
}
guard valid, let pack = paths["--pack"], let drafts = paths["--drafts"] else {
    printIssue(file: "arguments", rule: "arguments", message: "Usage: voyage-content validate --pack <Content dir> --drafts <dir>")
    exit(2)
}
let issues = ContentValidator.validate(directory: URL(fileURLWithPath: pack), drafts: URL(fileURLWithPath: drafts))
for issue in issues {
    printIssue(file: issue.file, rule: issue.rule, message: issue.message)
}
exit(issues.isEmpty ? 0 : 1)
