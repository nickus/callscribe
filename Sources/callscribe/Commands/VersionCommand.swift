import ArgumentParser

struct VersionCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "version",
        abstract: "Print the CallScribe version."
    )

    func run() async throws {
        print("callscribe \(AppInfo.version)")
    }
}

enum AppInfo {
    static let version = "0.5.0"
}
