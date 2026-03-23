import ArgumentParser
import Foundation
import Logging

enum PlaybackOrder: String, Codable {
    case random
    case az
    case za
}

struct StreamConfig: Codable {
    let radioStreamName: String
    let mediaDir: String
    let playbackOrder: PlaybackOrder
}

struct ConfigFile: Codable {
    let host: String?
    let port: Int?
    let username: String?
    let protocolScheme: String?
    let bitrateKbps: Int?
    let sampleRate: Int?
    let ffmpegPath: String?
    let streams: [StreamConfig]

    enum CodingKeys: String, CodingKey {
        case host
        case port
        case username
        case protocolScheme = "protocol"
        case bitrateKbps
        case sampleRate
        case ffmpegPath
        case streams
    }
}

struct AppOptions {
    let configPath: String
    let host: String
    let port: Int
    let username: String
    let protocolScheme: String
    let bitrateKbps: Int
    let sampleRateHz: Int
    let ffmpegPath: String
}

enum CliError: Error, CustomStringConvertible {
    case invalidValue(String)
    case message(String)

    var description: String {
        switch self {
        case .invalidValue(let message):
            return "Invalid value: \(message)"
        case .message(let text):
            return text
        }
    }
}

private let supportedLogLevels = [
    "trace", "debug", "info", "notice", "warning", "error", "critical",
]

@main
struct Radio: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract:
            "Run a standalone HTTP radio server and stream one or more channels from media directories."
    )

    @Option(name: .long, help: "Path to stream config JSON file.")
    var config: String

    @Option(name: .long, help: "Stream server host. Overrides config file value.")
    var host: String?

    @Option(name: .long, help: "Stream server port. Overrides config file value.")
    var port: Int?

    @Option(name: .long, help: "Source username. Overrides config file value.")
    var username: String?

    @Option(
        name: [.customLong("protocol")],
        help: "Server protocol. Only 'http' is supported in standalone mode.")
    var protocolScheme: String?

    @Option(name: .long, help: "AAC output bitrate for HLS (kbps). Overrides config file value.")
    var bitrateKbps: Int?

    @Option(name: .long, help: "Output sample rate (Hz). Overrides config file value.")
    var sampleRate: Int?

    @Option(name: .long, help: "Path to ffmpeg executable. Overrides config file value.")
    var ffmpegPath: String?

    @Option(name: .long, help: "Log level: trace|debug|info|notice|warning|error|critical")
    var logLevel: String = "info"

    func validate() throws {
        if let port, port <= 0 {
            throw ValidationError("--port must be a positive integer.")
        }
        if let bitrateKbps, bitrateKbps <= 0 {
            throw ValidationError("--bitrate-kbps must be a positive integer.")
        }
        if let sampleRate, sampleRate <= 0 {
            throw ValidationError("--sample-rate must be a positive integer.")
        }

        if let protocolScheme {
            let normalized = protocolScheme.lowercased()
            guard normalized == "http" else {
                throw ValidationError("--protocol must be 'http' in standalone mode.")
            }
        }

        let normalizedLogLevel = logLevel.lowercased()
        guard supportedLogLevels.contains(normalizedLogLevel) else {
            throw ValidationError(
                "--log-level must be one of: \(supportedLogLevels.joined(separator: ", "))"
            )
        }
    }

    func run() throws {
        LoggingSystem.bootstrap(StreamLogHandler.standardError)
        var logger = Logger(label: "Radio")
        logger.logLevel = try parseLoggerLevel(logLevel)

        let configFile = try loadConfig(path: config)

        if configFile.streams.isEmpty {
            throw CliError.message("Config is empty. Add at least one stream object in 'streams'.")
        }

        let options = AppOptions(
            configPath: config,
            host: host ?? configFile.host ?? "localhost",
            port: port ?? configFile.port ?? 8000,
            username: username ?? configFile.username ?? "source",
            protocolScheme: (protocolScheme ?? configFile.protocolScheme ?? "http").lowercased(),
            bitrateKbps: bitrateKbps ?? configFile.bitrateKbps ?? 128,
            sampleRateHz: sampleRate ?? configFile.sampleRate ?? 44_100,
            ffmpegPath: ffmpegPath ?? configFile.ffmpegPath ?? "ffmpeg"
        )

        try validateMergedOptions(options)

        try ensureFfmpegExists(path: options.ffmpegPath)

        let app = RadioPublisher(
            options: options, streamConfigs: configFile.streams, logger: logger)
        try app.startAll()
        app.runUntilInterrupted()
    }

    private func validateMergedOptions(_ options: AppOptions) throws {
        guard options.port > 0 else {
            throw CliError.invalidValue("port must be a positive integer")
        }
        guard !options.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CliError.invalidValue("host must not be empty")
        }
        guard options.bitrateKbps > 0 else {
            throw CliError.invalidValue("bitrateKbps must be a positive integer")
        }
        guard options.sampleRateHz > 0 else {
            throw CliError.invalidValue("sampleRate must be a positive integer")
        }
        guard options.protocolScheme == "http" else {
            throw CliError.invalidValue("protocol must be 'http' in standalone mode")
        }
    }

    private func ensureFfmpegExists(path: String) throws {
        if path.contains("/") {
            guard FileManager.default.isExecutableFile(atPath: path) else {
                throw CliError.message("ffmpeg not found or not executable at '\(path)'.")
            }
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["which", path]

        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw CliError.message("ffmpeg executable '\(path)' not found in PATH.")
        }
    }

    private func loadConfig(path: String) throws -> ConfigFile {
        let expanded = (path as NSString).expandingTildeInPath
        let data = try Data(contentsOf: URL(fileURLWithPath: expanded))
        let decoder = JSONDecoder()
        return try decoder.decode(ConfigFile.self, from: data)
    }

    private func parseLoggerLevel(_ value: String) throws -> Logger.Level {
        switch value.lowercased() {
        case "trace":
            return .trace
        case "debug":
            return .debug
        case "info":
            return .info
        case "notice":
            return .notice
        case "warning":
            return .warning
        case "error":
            return .error
        case "critical":
            return .critical
        default:
            throw CliError.invalidValue(
                "log level must be one of: \(supportedLogLevels.joined(separator: ", "))"
            )
        }
    }
}
