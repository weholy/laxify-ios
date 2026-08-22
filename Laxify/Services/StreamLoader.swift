import AVFoundation
import Foundation

/// Feeds AVPlayer from a single download.
///
/// Left to itself the player fetches a track in pieces: a few kilobytes to
/// read the headers, then another range, then another — six to eight
/// requests before any sound comes out. Each is a round trip, and on a slow
/// link those round trips were the entire wait. Measured on a real device:
/// the app's own work took sixteen milliseconds and the first sound arrived
/// six seconds later.
///
/// So the app downloads the track once, into memory, and answers the
/// player's range requests itself. One round trip instead of eight, and
/// seeking within a track becomes instant because the bytes are already
/// here.
///
/// AVPlayer only consults a resource loader for schemes it does not know, so
/// the url handed to it carries a scheme of ours and is swapped back before
/// anything is fetched.
final class StreamLoader: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    static let scheme = "laxify-stream"

    private let source: URL
    private let headers: [String: String]
    private let usesPinnedTrust: Bool

    private let queue = DispatchQueue(label: "laxify.stream.loader")

    /// What has arrived so far, and how big the whole thing is.
    private var buffer = Data()
    private var totalLength: Int?
    private var contentType = "audio/mpeg"
    private var isComplete = false
    private var failure: Error?

    /// Requests waiting for bytes that have not arrived yet.
    private var waiting: [AVAssetResourceLoadingRequest] = []

    private var task: URLSessionDataTask?
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        // The whole point is one connection carrying the whole file.
        configuration.httpMaximumConnectionsPerHost = 1
        configuration.waitsForConnectivity = false

        return URLSession(
            configuration: configuration,
            delegate: usesPinnedTrust ? APITrust.shared : nil,
            delegateQueue: nil
        )
    }()

    init(source: URL, headers: [String: String], usesPinnedTrust: Bool) {
        self.source = source
        self.headers = headers
        self.usesPinnedTrust = usesPinnedTrust
        super.init()
    }

    /// The url to hand AVPlayer, which routes its requests here.
    var playbackURL: URL {
        var components = URLComponents(url: source, resolvingAgainstBaseURL: false)
        components?.scheme = Self.scheme
        return components?.url ?? source
    }

    /// Builds an asset that plays through this loader.
    func makeAsset() -> AVURLAsset {
        let asset = AVURLAsset(url: playbackURL)
        asset.resourceLoader.setDelegate(self, queue: queue)
        start()
        return asset
    }

    // MARK: - Downloading

    private func start() {
        guard task == nil else { return }

        var request = URLRequest(url: source)
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }

        let started = Date()

        task = session.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }

            self.queue.async {
                if let error {
                    self.failure = error
                    self.failAllWaiting(error)
                    RemoteLog.shared.error(
                        "поток не загрузился",
                        category: "playback",
                        context: ["error": "\(error)"]
                    )
                    return
                }

                if let http = response as? HTTPURLResponse,
                   let type = http.value(forHTTPHeaderField: "Content-Type") {
                    self.contentType = type
                }

                self.buffer = data ?? Data()
                self.totalLength = self.buffer.count
                self.isComplete = true

                RemoteLog.shared.timing(
                    "поток загружен целиком",
                    milliseconds: Int(Date().timeIntervalSince(started) * 1000),
                    category: "playback",
                    context: ["bytes": "\(self.buffer.count)"]
                )

                self.serveWaiting()
            }
        }

        task?.resume()
    }

    func cancel() {
        task?.cancel()
        queue.async { self.waiting.removeAll() }
    }

    // MARK: - Answering the player

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        if let failure {
            loadingRequest.finishLoading(with: failure)
            return true
        }

        if serve(loadingRequest) {
            return true
        }

        // Nothing to answer with yet; hold it until the download lands.
        waiting.append(loadingRequest)
        return true
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        didCancel loadingRequest: AVAssetResourceLoadingRequest
    ) {
        waiting.removeAll { $0 == loadingRequest }
    }

    /// Answers one request if the bytes it wants are here.
    private func serve(_ request: AVAssetResourceLoadingRequest) -> Bool {
        guard isComplete, let totalLength else { return false }

        if let information = request.contentInformationRequest {
            information.contentType = AVFileType.mp3.rawValue
            information.contentLength = Int64(totalLength)
            // Byte ranges are supported because the whole file is here; this
            // is what lets scrubbing land immediately.
            information.isByteRangeAccessSupported = true
        }

        guard let dataRequest = request.dataRequest else {
            request.finishLoading()
            return true
        }

        let start = Int(dataRequest.requestedOffset)
        guard start < totalLength else {
            request.finishLoading()
            return true
        }

        let wanted = dataRequest.requestsAllDataToEndOfResource
            ? totalLength - start
            : min(dataRequest.requestedLength, totalLength - start)

        dataRequest.respond(with: buffer.subdata(in: start..<(start + wanted)))
        request.finishLoading()
        return true
    }

    private func serveWaiting() {
        let pending = waiting
        waiting.removeAll()

        for request in pending where !request.isFinished {
            _ = serve(request)
        }
    }

    private func failAllWaiting(_ error: Error) {
        let pending = waiting
        waiting.removeAll()

        for request in pending where !request.isFinished {
            request.finishLoading(with: error)
        }
    }
}
