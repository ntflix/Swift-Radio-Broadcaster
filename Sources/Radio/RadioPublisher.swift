import Foundation
import Logging
import Network

final class RadioPublisher: @unchecked Sendable {
    private enum PublisherError: Error {
        case cleanupFailed(String)
    }

    private enum AssetLookupResult {
        case available(status: String, contentType: String, data: Data)
        case playlistNotReady
        case staleSegment
        case notFound
    }

    private final class StreamWorker: @unchecked Sendable {
        let config: StreamConfig
        let slug: String
        let playlistURL: URL

        private let options: AppOptions
        private let fileManager = FileManager.default
        private var logger: Logger

        private var process: Process?
        private var stderrPipe: Pipe?
        private var sourcePlaylistPath: String?
        private var outputDirURL: URL?

        init(config: StreamConfig, slug: String, options: AppOptions, logger: Logger) {
            self.config = config
            self.slug = slug
            self.options = options
            self.logger = logger

            let outputDir = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("radio-hls-\(slug)", isDirectory: true)
            self.playlistURL = outputDir.appendingPathComponent("index.m3u8")
            logger.trace(
                "Initialized StreamWorker for '\(config.radioStreamName)' with slug '\(slug)' - temp dir '\(outputDir.path)'"
            )
        }

        func start() throws {
            let mediaFiles = try orderedMediaFiles()
            guard !mediaFiles.isEmpty else {
                throw CliError.message(
                    "No playable files found in mediaDir '\(config.mediaDir)' for '\(config.radioStreamName)'."
                )
            }

            let sourcePlaylistPath = try writeConcatPlaylist(files: mediaFiles)
            self.sourcePlaylistPath = sourcePlaylistPath

            let outputDir = playlistURL.deletingLastPathComponent()
            self.outputDirURL = outputDir

            try purgeHLSArtifacts(context: "startup", strict: false)
            try fileManager.createDirectory(at: outputDir, withIntermediateDirectories: true)

            if fileManager.fileExists(atPath: playlistURL.path) {
                throw CliError.message(
                    "HLS playlist file still exists after startup cleanup: '\(playlistURL.path)'"
                )
            }

            let process = Process()
            process.executableURL = URL(fileURLWithPath: options.ffmpegPath)
            process.arguments = [
                "-hide_banner",
                "-nostats",
                "-stream_loop", "-1",
                "-re",
                "-f", "concat",
                "-safe", "0",
                "-i", sourcePlaylistPath,
                "-vn",
                "-c:a", "aac",
                "-b:a", "\(options.bitrateKbps)k",
                "-ar", "\(options.sampleRateHz)",
                "-ac", "2",
                "-f", "hls",
                // Live-radio mode: sliding window only, no rewind/event history.
                "-hls_time", "10",
                "-hls_list_size", "2",
                "-hls_delete_threshold", "1",
                "-hls_allow_cache", "0",
                "-hls_flags",
                "delete_segments+independent_segments+program_date_time+temp_file+omit_endlist",
                "-start_number", "0",
                "-hls_segment_filename", outputDir.appendingPathComponent("segment_%06d.ts").path,
                playlistURL.path,
            ]

            let stderrPipe = Pipe()
            process.standardOutput = Pipe()
            process.standardError = stderrPipe

            try process.run()

            self.process = process
            self.stderrPipe = stderrPipe

            logger.info("HLS worker started for '\(config.radioStreamName)' at /\(slug)/index.m3u8")
        }

        func stop() throws {
            if let process, process.isRunning {
                process.terminate()
                process.waitUntilExit()
            }

            if let stderrPipe {
                logFfmpegStderr(stderrPipe: stderrPipe)
            }

            if let sourcePlaylistPath {
                do {
                    try fileManager.removeItem(atPath: sourcePlaylistPath)
                } catch {
                    throw PublisherError.cleanupFailed(
                        "Failed to delete source concat playlist '\(sourcePlaylistPath)': \(error.localizedDescription)"
                    )
                }

                if fileManager.fileExists(atPath: sourcePlaylistPath) {
                    throw PublisherError.cleanupFailed(
                        "Source concat playlist still exists after shutdown cleanup: '\(sourcePlaylistPath)'"
                    )
                }
            }

            try purgeHLSArtifacts(context: "shutdown", strict: true)
        }

        private func purgeHLSArtifacts(context: String, strict: Bool) throws {
            let outputDir = outputDirURL ?? playlistURL.deletingLastPathComponent()
            guard fileManager.fileExists(atPath: outputDir.path) else {
                return
            }

            if let items = try? fileManager.contentsOfDirectory(
                at: outputDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            {
                for item in items {
                    let name = item.lastPathComponent
                    let isPlaylist = (name == "index.m3u8")
                    let isSegment = name.hasPrefix("segment_") && name.hasSuffix(".ts")
                    if isPlaylist || isSegment {
                        do {
                            try fileManager.removeItem(at: item)
                        } catch {
                            if strict {
                                throw PublisherError.cleanupFailed(
                                    "Failed to delete HLS asset during \(context): '\(item.path)': \(error.localizedDescription)"
                                )
                            }
                            logger.warning(
                                "Failed to delete HLS asset during \(context): '\(item.path)'"
                            )
                        }

                        if fileManager.fileExists(atPath: item.path) {
                            if strict {
                                throw PublisherError.cleanupFailed(
                                    "Failed to delete HLS asset during \(context): '\(item.path)'"
                                )
                            }
                            logger.warning(
                                "Failed to delete HLS asset during \(context): '\(item.path)'"
                            )
                        }
                    }
                }
            }

            let playlistStillExists = fileManager.fileExists(atPath: playlistURL.path)
            if playlistStillExists {
                if strict {
                    throw PublisherError.cleanupFailed(
                        "Playlist still exists after \(context) cleanup: '\(playlistURL.path)'"
                    )
                }
                logger.warning(
                    "Playlist still exists after \(context) cleanup: '\(playlistURL.path)'"
                )
            }

            var remainingSegments = 0
            if let items = try? fileManager.contentsOfDirectory(
                at: outputDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            {
                remainingSegments =
                    items.filter {
                        let name = $0.lastPathComponent
                        return name.hasPrefix("segment_") && name.hasSuffix(".ts")
                    }.count
            }

            if remainingSegments > 0 {
                if strict {
                    throw PublisherError.cleanupFailed(
                        "\(remainingSegments) segment files remain after \(context) cleanup in '\(outputDir.path)'"
                    )
                }
                logger.warning(
                    "\(remainingSegments) segment files remain after \(context) cleanup in '\(outputDir.path)'"
                )
            }

            do {
                try fileManager.removeItem(at: outputDir)
            } catch {
                if strict {
                    throw PublisherError.cleanupFailed(
                        "Failed to remove output directory after \(context): '\(outputDir.path)': \(error.localizedDescription)"
                    )
                }
            }

            if fileManager.fileExists(atPath: outputDir.path) {
                if strict {
                    throw PublisherError.cleanupFailed(
                        "Output directory still exists after \(context) cleanup: '\(outputDir.path)'"
                    )
                }
                logger.warning(
                    "Output directory still exists after \(context) cleanup: '\(outputDir.path)'")
            }
        }

        func waitForInitialSegments(timeoutSeconds: TimeInterval = 14.0) throws {
            let deadline = Date().addingTimeInterval(timeoutSeconds)
            while Date() < deadline {
                if fileManager.fileExists(atPath: playlistURL.path),
                    let text = try? String(contentsOf: playlistURL, encoding: .utf8),
                    text.contains("#EXTINF")
                {
                    // Let filesystem and readers settle briefly to reduce startup request races.
                    Thread.sleep(forTimeInterval: 0.35)
                    return
                }

                if let process, !process.isRunning {
                    let status = process.terminationStatus
                    let stderrSummary = ffmpegStderrSummary()
                    throw CliError.message(
                        "HLS worker for '\(config.radioStreamName)' exited before readiness (status \(status)). \(stderrSummary)"
                    )
                }

                Thread.sleep(forTimeInterval: 0.1)
            }

            if let process, process.isRunning {
                logger.warning(
                    "HLS worker for '\(config.radioStreamName)' is still warming up after \(Int(timeoutSeconds))s; continuing startup."
                )
                return
            }

            let status = process?.terminationStatus ?? -1
            let stderrSummary = ffmpegStderrSummary()
            throw CliError.message(
                "HLS worker for '\(config.radioStreamName)' did not produce initial playlist/segments in time and is not running (status \(status)). \(stderrSummary)"
            )
        }

        private func ffmpegStderrSummary(maxLines: Int = 8) -> String {
            guard let stderrPipe else {
                return "No ffmpeg stderr available."
            }

            let data = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            guard let text = String(data: data, encoding: .utf8) else {
                return "ffmpeg stderr could not be decoded as UTF-8."
            }

            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                return "No ffmpeg stderr output."
            }

            let lines =
                trimmed
                .components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .suffix(maxLines)

            return "Recent ffmpeg stderr: \(lines.joined(separator: " | "))"
        }

        func servePathComponent(_ name: String) -> AssetLookupResult {
            let safeName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if safeName.isEmpty || safeName.contains("..") || safeName.contains("/") {
                return .notFound
            }

            let fileURL = playlistURL.deletingLastPathComponent().appendingPathComponent(safeName)

            if safeName.hasSuffix(".m3u8") {
                guard fileManager.fileExists(atPath: fileURL.path),
                    let data = try? Data(contentsOf: fileURL)
                else {
                    return .playlistNotReady
                }
                return .available(
                    status: "200 OK", contentType: "application/vnd.apple.mpegurl", data: data)
            }

            if safeName.hasSuffix(".ts") {
                // Only serve segments that are currently referenced in the active playlist window.
                // This prevents old cached playlist requests from pulling out-of-window segments.
                guard currentPlaylistSegmentNames().contains(safeName) else {
                    return .staleSegment
                }

                guard fileManager.fileExists(atPath: fileURL.path),
                    let data = try? Data(contentsOf: fileURL)
                else {
                    return .staleSegment
                }

                return .available(status: "200 OK", contentType: "video/mp2t", data: data)
            }

            guard fileManager.fileExists(atPath: fileURL.path),
                let data = try? Data(contentsOf: fileURL)
            else {
                return .notFound
            }

            return .available(status: "200 OK", contentType: "application/octet-stream", data: data)
        }

        private func currentPlaylistSegmentNames() -> Set<String> {
            guard let text = try? String(contentsOf: playlistURL, encoding: .utf8) else {
                return []
            }

            var names = Set<String>()
            for rawLine in text.components(separatedBy: "\n") {
                let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
                if line.isEmpty || line.hasPrefix("#") {
                    continue
                }
                if line.hasSuffix(".ts") {
                    names.insert((line as NSString).lastPathComponent)
                }
            }
            return names
        }

        private func logFfmpegStderr(stderrPipe: Pipe) {
            let data = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            guard let text = String(data: data, encoding: .utf8), !text.isEmpty else {
                return
            }

            for rawLine in text.components(separatedBy: "\n") {
                let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
                if line.isEmpty { continue }
                logger.error("[ffmpeg][\(config.radioStreamName)][err] \(line)")
            }
        }

        private func orderedMediaFiles() throws -> [String] {
            let resolvedDir = (config.mediaDir as NSString).expandingTildeInPath
            var isDir = ObjCBool(false)

            guard fileManager.fileExists(atPath: resolvedDir, isDirectory: &isDir), isDir.boolValue
            else {
                throw CliError.message("mediaDir '\(config.mediaDir)' is not a directory.")
            }

            let supportedExtensions: Set<String> = [
                "mp3", "aac", "m4a", "wav", "flac", "ogg", "opus",
            ]

            let enumerator = fileManager.enumerator(
                at: URL(fileURLWithPath: resolvedDir),
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles],
                errorHandler: nil
            )

            var files: [String] = []
            while let next = enumerator?.nextObject() as? URL {
                let ext = next.pathExtension.lowercased()
                if supportedExtensions.contains(ext) {
                    files.append(next.path)
                }
            }

            switch config.playbackOrder {
            case .az:
                files.sort { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            case .za:
                files.sort { $0.localizedCaseInsensitiveCompare($1) == .orderedDescending }
            case .random:
                files.shuffle()
            }

            return files
        }

        private func writeConcatPlaylist(files: [String]) throws -> String {
            let path = (NSTemporaryDirectory() as NSString).appendingPathComponent(
                "radio-src-\(slug).ffconcat"
            )

            let lines = files.map { "file '\($0.replacingOccurrences(of: "'", with: "'\\''"))'" }
            let content = (["ffconcat version 1.0"] + lines).joined(separator: "\n") + "\n"
            try content.write(toFile: path, atomically: true, encoding: .utf8)
            return path
        }
    }

    private struct RouteTable {
        var workersBySlug: [String: StreamWorker]
    }

    private let options: AppOptions
    private let streamConfigs: [StreamConfig]
    private var logger: Logger
    private var keepRunning = true
    private var listener: NWListener?
    private let listenerQueue = DispatchQueue(label: "radio.server.listener")
    private var workers: [StreamWorker] = []
    private var signalSources: [DispatchSourceSignal] = []

    init(options: AppOptions, streamConfigs: [StreamConfig], logger: Logger) {
        self.options = options
        self.streamConfigs = streamConfigs
        self.logger = logger
    }

    func startAll() throws {
        cleanupStaleTempArtifacts()

        let port = try validatedPort(options.port)
        let listener = try NWListener(using: .tcp, on: port)
        self.listener = listener

        var workersBySlug: [String: StreamWorker] = [:]
        for config in streamConfigs {
            let slug = slugify(config.radioStreamName)
            let worker = StreamWorker(config: config, slug: slug, options: options, logger: logger)
            try worker.start()
            try worker.waitForInitialSegments()
            workers.append(worker)
            workersBySlug[slug] = worker
        }
        let routes = RouteTable(workersBySlug: workersBySlug)

        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            self.handleConnection(connection, routes: routes)
        }

        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.logger.info(
                    "Standalone HLS server listening on \(self.options.host):\(self.options.port)"
                )
                for worker in self.workers.sorted(by: { $0.slug < $1.slug }) {
                    self.logger.info(
                        "HLS '\(worker.config.radioStreamName)' available at http://\(self.options.host):\(self.options.port)/\(worker.slug)/index.m3u8"
                    )
                }
            case .failed(let error):
                self.logger.error("Server listener failed: \(error.localizedDescription)")
            default:
                break
            }
        }

        listener.start(queue: listenerQueue)
        logger.info("Started \(workers.count) HLS endpoint(s). Press Ctrl+C to stop.")
    }

    func runUntilInterrupted() {
        let handledSignals = [SIGINT, SIGTERM, SIGQUIT]

        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)
        signal(SIGQUIT, SIG_IGN)

        signalSources = handledSignals.map { sig in
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { [weak self] in
                self?.handleShutdownSignal(sig)
            }
            source.resume()
            return source
        }

        while keepRunning {
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.25))
        }
    }

    private func handleShutdownSignal(_ signalNumber: Int32) {
        guard keepRunning else { return }
        keepRunning = false
        logger.info("Received signal \(signalNumber). Stopping publishers...")
        do {
            try stopAll()
            exit(0)
        } catch {
            logger.error("Shutdown cleanup failed: \(error.localizedDescription)")
            exit(1)
        }
    }

    private func handleConnection(_ connection: NWConnection, routes: RouteTable) {
        logger.debug("Incoming connection from \(endpointString(connection.endpoint)).")
        connection.start(queue: listenerQueue)
        receiveHTTPRequest(connection, routes: routes, accumulated: Data())
    }

    private func receiveHTTPRequest(
        _ connection: NWConnection, routes: RouteTable, accumulated: Data
    ) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) {
            [weak self] data, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }

            if let error {
                self.logger.error("Connection receive error: \(error.localizedDescription)")
                connection.cancel()
                return
            }

            var buffer = accumulated
            if let data, !data.isEmpty {
                buffer.append(data)
            }

            if buffer.count > 65_536 {
                self.logger.debug(
                    "Request headers too large from \(self.endpointString(connection.endpoint)).")
                self.sendSimpleResponse(
                    connection,
                    status: "413 Payload Too Large",
                    contentType: "text/plain; charset=utf-8",
                    body: Data("Request Too Large\n".utf8)
                )
                return
            }

            if self.hasCompleteHTTPHeaders(buffer) || isComplete {
                self.processHTTPRequest(connection, routes: routes, raw: buffer)
                return
            }

            self.receiveHTTPRequest(connection, routes: routes, accumulated: buffer)
        }
    }

    private func processHTTPRequest(_ connection: NWConnection, routes: RouteTable, raw: Data) {
        guard let request = String(data: raw, encoding: .utf8) else {
            logger.debug(
                "Failed UTF-8 decode for request from \(endpointString(connection.endpoint)).")
            sendSimpleResponse(
                connection,
                status: "400 Bad Request",
                contentType: "text/plain; charset=utf-8",
                body: Data("Bad Request\n".utf8)
            )
            return
        }

        guard let path = parseRequestPath(from: request) else {
            logger.debug(
                "Could not parse HTTP request line from \(endpointString(connection.endpoint)).")
            sendSimpleResponse(
                connection,
                status: "400 Bad Request",
                contentType: "text/plain; charset=utf-8",
                body: Data("Bad Request\n".utf8)
            )
            return
        }

        logger.debug("HTTP path from \(endpointString(connection.endpoint)): \(path)")

        if path == "/" {
            let lines =
                workers
                .sorted(by: { $0.slug < $1.slug })
                .map {
                    "\($0.config.radioStreamName): http://\(options.host):\(options.port)/\($0.slug)/index.m3u8"
                }
            let body = Data((lines + [""]).joined(separator: "\n").utf8)
            sendSimpleResponse(
                connection,
                status: "200 OK",
                contentType: "text/plain; charset=utf-8",
                body: body
            )
            return
        }

        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        guard components.count == 2 else {
            logger.debug(
                "Route mismatch for path '\(path)' from \(endpointString(connection.endpoint)).")
            sendSimpleResponse(
                connection,
                status: "404 Not Found",
                contentType: "text/plain; charset=utf-8",
                body: Data("Not Found\n".utf8)
            )
            return
        }

        let streamSlug = String(components[0])
        let fileName = String(components[1])

        guard let worker = routes.workersBySlug[streamSlug] else {
            logger.debug(
                "Unknown stream slug '\(streamSlug)' from \(endpointString(connection.endpoint)).")
            sendSimpleResponse(
                connection,
                status: "404 Not Found",
                contentType: "text/plain; charset=utf-8",
                body: Data("Not Found\n".utf8)
            )
            return
        }

        switch worker.servePathComponent(fileName) {
        case .available(let status, let contentType, let data):
            sendSimpleResponse(
                connection,
                status: status,
                contentType: contentType,
                body: data
            )
        case .playlistNotReady:
            logger.debug("HLS playlist not ready yet for stream '\(streamSlug)'.")
            sendSimpleResponse(
                connection,
                status: "503 Service Unavailable",
                contentType: "text/plain; charset=utf-8",
                body: Data("HLS stream warming up, retry shortly\n".utf8)
            )
        case .staleSegment:
            logger.debug(
                "Stale/expired HLS segment '\(fileName)' requested for stream '\(streamSlug)'.")
            sendSimpleResponse(
                connection,
                status: "410 Gone",
                contentType: "text/plain; charset=utf-8",
                body: Data("Segment expired; refresh playlist\n".utf8)
            )
        case .notFound:
            logger.debug("Missing HLS asset '\(fileName)' for stream '\(streamSlug)'.")
            sendSimpleResponse(
                connection,
                status: "404 Not Found",
                contentType: "text/plain; charset=utf-8",
                body: Data("Not Found\n".utf8)
            )
        }
    }

    private func hasCompleteHTTPHeaders(_ data: Data) -> Bool {
        if let text = String(data: data, encoding: .utf8) {
            return text.contains("\r\n\r\n") || text.contains("\n\n")
        }
        return false
    }

    private func sendSimpleResponse(
        _ connection: NWConnection, status: String, contentType: String, body: Data
    ) {
        let responseTime = httpDateString(Date())
        var header = "HTTP/1.1 \(status)\r\n"
        header += "Content-Type: \(contentType)\r\n"
        header += "Content-Length: \(body.count)\r\n"
        // Explicitly disable validator-based caching to avoid stale playlist reuse.
        header +=
            "Cache-Control: no-store, no-cache, must-revalidate, max-age=0, s-maxage=0, proxy-revalidate\r\n"
        header += "Pragma: no-cache\r\n"
        header += "Expires: 0\r\n"
        header += "ETag: \"disabled-\(UInt64(Date().timeIntervalSince1970 * 1000))\"\r\n"
        header += "Last-Modified: \(responseTime)\r\n"
        header += "Date: \(responseTime)\r\n"
        header += "Connection: close\r\n"
        header += "\r\n"

        logger.debug(
            "Sending HTTP \(status) to \(endpointString(connection.endpoint)) with body bytes: \(body.count)."
        )
        connection.send(
            content: Data(header.utf8),
            completion: .contentProcessed { [weak self] headerError in
                guard let self else {
                    connection.cancel()
                    return
                }

                if let headerError {
                    self.logger.debug(
                        "Header send failed to \(self.endpointString(connection.endpoint)): \(headerError)."
                    )
                    connection.cancel()
                    return
                }

                connection.send(
                    content: body,
                    completion: .contentProcessed { bodyError in
                        if let bodyError {
                            self.logger.debug(
                                "Body send failed to \(self.endpointString(connection.endpoint)): \(bodyError)."
                            )
                        }

                        self.listenerQueue.asyncAfter(deadline: .now() + .milliseconds(200)) {
                            connection.cancel()
                        }
                    })
            })
    }

    private func parseRequestPath(from request: String) -> String? {
        guard let firstLine = request.components(separatedBy: "\r\n").first else {
            return nil
        }

        let parts = firstLine.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 2, parts[0] == "GET" else {
            return nil
        }

        let path = String(parts[1])
        if let queryIdx = path.firstIndex(of: "?") {
            return String(path[..<queryIdx])
        }
        return path
    }

    private func validatedPort(_ value: Int) throws -> NWEndpoint.Port {
        guard let port = NWEndpoint.Port(rawValue: UInt16(value)) else {
            throw CliError.invalidValue("Invalid port '\(value)'.")
        }
        return port
    }

    private func stopAll() throws {
        var failures: [String] = []

        for worker in workers {
            do {
                try worker.stop()
            } catch {
                let message = "\(worker.config.radioStreamName): \(error.localizedDescription)"
                failures.append(message)
                logger.error(
                    "Cleanup failed for stream '\(worker.config.radioStreamName)': \(error.localizedDescription)"
                )
            }
        }
        workers.removeAll()

        cleanupStaleTempArtifacts()

        listener?.cancel()
        listener = nil

        if !failures.isEmpty {
            throw PublisherError.cleanupFailed(failures.joined(separator: " | "))
        }
    }

    private func cleanupStaleTempArtifacts() {
        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        guard
            let items = try? FileManager.default.contentsOfDirectory(
                at: tempURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        else {
            return
        }

        for item in items {
            let name = item.lastPathComponent
            if name.hasPrefix("radio-hls-") {
                // Remove stale segment files first, then remove the stream temp directory.
                if let childItems = try? FileManager.default.contentsOfDirectory(
                    at: item, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
                {
                    for child in childItems {
                        let childName = child.lastPathComponent
                        if childName.hasPrefix("segment_") && childName.hasSuffix(".ts") {
                            try? FileManager.default.removeItem(at: child)
                        }
                    }
                }
                try? FileManager.default.removeItem(at: item)
                continue
            }

            if (name.hasPrefix("radio-src-") && name.hasSuffix(".ffconcat"))
                || (name.hasPrefix("segment_") && name.hasSuffix(".ts"))
            {
                try? FileManager.default.removeItem(at: item)
            }
        }
    }

    private func slugify(_ text: String) -> String {
        let lower = text.lowercased()
        let mapped = lower.map { ch -> Character in
            if ch.isLetter || ch.isNumber { return ch }
            return "-"
        }
        let collapsed = String(mapped).replacingOccurrences(
            of: "-{2,}", with: "-", options: .regularExpression
        )
        let trimmed = collapsed.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return trimmed.isEmpty ? "stream" : trimmed
    }

    private func endpointString(_ endpoint: NWEndpoint) -> String {
        switch endpoint {
        case .hostPort(let host, let port):
            return "\(host):\(port)"
        default:
            return String(describing: endpoint)
        }
    }

    private func httpDateString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return formatter.string(from: date)
    }
}
