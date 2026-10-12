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
let destination = directory.appendingPathComponent("it's $(unsafe).bin")
let original = Data("original content".utf8)
let replacement = Data([0, 1, 255, 10, 128])

func upload(_ data: Data, expectedCount: Int, path: URL) throws -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", RemoteWorkspaceService.uploadCommand(path: path.path, byteCount: expectedCount)]
    let input = Pipe()
    process.standardInput = input
    try process.run()
    input.fileHandleForWriting.write(data)
    try input.fileHandleForWriting.close()
    process.waitUntilExit()
    return process.terminationStatus
}

func check(_ condition: Bool, _ message: String = "Upload check failed") {
    precondition(condition, message)
}

try original.write(to: destination)
check(try upload(replacement.prefix(2), expectedCount: replacement.count, path: destination) != 0)
check(try Data(contentsOf: destination) == original, "Interrupted upload replaced the original")
check(try upload(replacement, expectedCount: 2, path: destination) != 0)
check(try Data(contentsOf: destination) == original, "Oversized upload replaced the original")
check(try upload(replacement, expectedCount: replacement.count, path: destination) == 0)
check(try Data(contentsOf: destination) == replacement, "Binary upload changed the bytes")
check(try upload(Data(), expectedCount: 0, path: destination) == 0)
check(try Data(contentsOf: destination).isEmpty)
check(try upload(Data(), expectedCount: 0, path: directory) != 0)
check(try FileManager.default.contentsOfDirectory(atPath: directory.path) == [destination.lastPathComponent])
print("Upload checks passed: short/long transfers preserve originals; binary and empty uploads succeed; temporary files are removed.")
SWIFT
swiftc -module-cache-path "$scratch/modules" \
    "$root/ios/Steer/Models/RemoteWorkspace.swift" "$scratch/ShellQuote.swift" "$scratch/main.swift" \
    -o "$scratch/check-upload"
"$scratch/check-upload"
