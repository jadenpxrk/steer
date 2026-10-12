#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
sed -n '/^enum ShellQuote {/,$p' "$root/ios/Steer/Models/MuxTarget.swift" > "$scratch/ShellQuote.swift"
cat > "$scratch/main.swift" <<'SWIFT'
import Foundation

let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: directory) }

func run(_ command: String, expected: Int32 = 0) throws -> Data {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", command]
    process.currentDirectoryURL = directory
    let output = Pipe()
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    precondition(process.terminationStatus == expected, "Command failed: \(command)")
    return data
}
func git(_ args: String) throws -> Data { try run(RemoteGit.command(args, directory: directory.path)) }
func write(_ name: String, _ content: String) throws {
    try Data(content.utf8).write(to: directory.appendingPathComponent(name))
}
func check(_ condition: Bool) { precondition(condition) }

_ = try git("init -q")
let unusual = "a b\n'$(unsafe).txt"
try write(unusual, "original\n")
_ = try git("add -- " + ShellQuote.posixSingle(unusual))
let initial = RemoteGit.changes(try git("status --porcelain=v1 -z --untracked-files=all"))
check(initial.count == 1 && initial[0].area == .staged)
check(String(decoding: try run(RemoteGit.diffCommand(initial[0], directory: directory.path)), as: UTF8.self).contains("+original"))
_ = try git("-c user.name=Test -c user.email=test@example.invalid commit -qm initial")
let commits = RemoteGit.commits(try git("log --format='%H%x00%s%x00'"))
check(commits.count == 1)
try write(unusual, "staged\n")
_ = try git("add -- " + ShellQuote.posixSingle(unusual))
try write(unusual, "unstaged\n")
try write(":(glob)*.txt", "untracked\n")
let changes = RemoteGit.changes(try git("status --porcelain=v1 -z --untracked-files=all"))
check(changes.count == 3)
for change in changes {
    let diff = String(decoding: try run(RemoteGit.diffCommand(change, directory: directory.path)), as: UTF8.self)
    switch change.area {
    case .staged: check(diff.contains("+staged") && !diff.contains("+unstaged"))
    case .unstaged: check(diff.contains("+unstaged") && diff.contains("-staged"))
    case .untracked: check(diff.contains("+untracked") && !diff.contains("unstaged"))
    }
}
check(String(decoding: try run(RemoteGit.sourceCommand(path: unusual, revision: commits[0].id, directory: directory.path)), as: UTF8.self) == "original\n")
check(String(decoding: try run(RemoteGit.sourceCommand(path: unusual, revision: nil, directory: directory.path)), as: UTF8.self) == "unstaged\n")
check(String(decoding: try run(RemoteGit.sourceCommand(path: unusual, revision: nil, directory: directory.path, staged: true)), as: UTF8.self) == "staged\n")
let paths = RemoteGit.paths(try git("ls-tree -rz --name-only " + commits[0].id))
check(paths == [unusual])
try write("large.txt", String(repeating: "a", count: 524289))
_ = try run(RemoteGit.sourceCommand(path: "large.txt", revision: nil, directory: directory.path), expected: 1)
_ = try git("add -- " + ShellQuote.posixSingle(unusual))
_ = try git("-c user.name=Test -c user.email=test@example.invalid commit -qm update")
_ = try git("mv -- " + ShellQuote.posixSingle(unusual) + " renamed.txt")
let rename = RemoteGit.changes(try git("status --porcelain=v1 -z --untracked-files=all")).first { $0.status == "R" }!
check(rename.originalPath == unusual)
check(!String(decoding: try run(RemoteGit.diffCommand(rename, directory: directory.path)), as: UTF8.self).isEmpty)
print("Git checks passed: unborn/staged/unstaged/untracked changes, literal filenames, renames, commit browsing, and preview size limit.")
SWIFT
swiftc -module-cache-path "$scratch/modules" \
    "$root/ios/Steer/Models/RemoteGit.swift" "$scratch/ShellQuote.swift" "$scratch/main.swift" \
    -o "$scratch/check-git"
"$scratch/check-git"
