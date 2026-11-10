import Foundation

/// Supplies a GitHub token. `force` re-reads it (after a 401).
protocol TokenProvider: Sendable {
    func token(force: Bool) async throws -> String
}

/// Reads `gh auth token`. Looks in /opt/homebrew/bin, /usr/local/bin,
/// then falls back to `/bin/zsh -lc 'gh auth token'`. Throws GitHubError(kind: .noToken).
///
/// Apps launched from Finder get a minimal PATH, hence the explicit lookup.
/// `GitHubClient` caches the token; this always asks gh.
struct GhCLIToken: TokenProvider {
    static let candidates = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh"]

    func token(force: Bool) async throws -> String {
        let fm = FileManager.default
        let (executable, arguments): (String, [String]) =
            if let gh = Self.candidates.first(where: { fm.isExecutableFile(atPath: $0) }) {
                (gh, ["auth", "token"])
            } else {
                ("/bin/zsh", ["-lc", "gh auth token"])
            }

        let result: ProcessResult
        do {
            result = try await Self.run(executable, arguments)
        } catch {
            throw Self.failure("Could not run the GitHub CLI: \(error.localizedDescription).")
        }

        let token = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.status == 0, !token.isEmpty, !token.contains(where: \.isWhitespace) {
            return token
        }
        // zsh exits 127 when `gh` is not on the login PATH either.
        let reason = result.status == 127
            ? "GitHub CLI (gh) is not installed."
            : result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        throw Self.failure(reason)
    }

    private static func failure(_ reason: String) -> GitHubError {
        let message = "Could not get a token from the GitHub CLI. \(reason) Run `gh auth login`."
            .replacingOccurrences(of: "  ", with: " ")
        return GitHubError(message: message, status: 401, kind: .noToken)
    }

    struct ProcessResult: Sendable, Equatable {
        var status: Int32
        var stdout: String
        var stderr: String
    }

    /// Runs a process off the cooperative pool and collects its output.
    static func run(_ executable: String, _ arguments: [String]) async throws -> ProcessResult {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                let out = Pipe()
                let err = Pipe()
                process.standardOutput = out
                process.standardError = err
                process.standardInput = FileHandle.nullDevice
                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }
                // Drain stderr concurrently so a chatty login shell can't block on a full pipe.
                let stderrBox = DataBox()
                let group = DispatchGroup()
                group.enter()
                DispatchQueue.global().async {
                    stderrBox.data = err.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }
                let stdout = out.fileHandleForReading.readDataToEndOfFile()
                group.wait()
                process.waitUntilExit()
                continuation.resume(returning: ProcessResult(
                    status: process.terminationStatus,
                    stdout: String(decoding: stdout, as: UTF8.self),
                    stderr: String(decoding: stderrBox.data, as: UTF8.self)
                ))
            }
        }
    }

    private final class DataBox: @unchecked Sendable {
        var data = Data()
    }
}
