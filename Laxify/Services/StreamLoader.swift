import AVFoundation
import Foundation

/// Feeds AVPlayer from a single download that is served as it arrives.
///
/// Left to itself the player fetches a track in pieces: a few kilobytes to
/// read the headers, then another range, then another — six to eight requests
/// before any sound. Each is a round trip, and on a slow link those round
/// trips were the whole wait.
///
/// So the app opens one connection and answers the player's ranges from what
/// has arrived so far. It does not wait for the file to finish: a track plays
/// at about sixteen kilobytes a second, so a connection managing even a
/// fraction of a megabit is delivering faster than playback consumes. Waiting
/// for the last byte before the first sound was six seconds of nothing.
///
/// AVPlayer only consults a resource loader for schemes it does not know, so
/// the url handed to it carries a scheme of ours, swapped back before
/// anything is fetched.
final class StreamLoader: NSObject, @unchecked Sendable {
    static let scheme = "laxify-stream"

    private let source: URL
    private let headers: [String: String]
    private let usesPinnedTrust: Bool

    private let queue = DispatchQueue(label: "laxify.stream.loader")

    /// What has arrived, and how much is expected in total.
    private var buffer = Data()
    private var expectedLength: Int?
    private var isComplete = false
    private var failure: Error?

    /// Requests waiting on bytes that have not arrived yet.
    private var waiting: [AVAssetResourceLoadingRequest] = []

    private var task: URLSessionDataTask?
    private var startedAt = Date()
    private var reportedFirstBytes = false

    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.default
        // Forty seconds of nothing before this gave up, on top of whatever
        // the resolve step already cost — long enough that a listener who
        // had given up and locked the phone was gone well before it did.
        configuration.timeoutIntervalForRequest = 18
        // One connection carrying the whole file is the entire point.
        configuration.httpMaximumConnectionsPerHost = 1
        configuration.waitsForConnectivity = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData

        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
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

    func makeAsset() -> AVURLAsset {
        let asset = AVURLAsset(url: playbackURL)
        asset.resourceLoader.setDelegate(self, queue: queue)
        start()
        return asset
    }

    func cancel() {
        task?.cancel()
        queue.async { self.waiting.removeAll() }
    }

    // MARK: - Downloading

    private func start() {
        guard task == nil else { return }

        var request = URLRequest(url: source)
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }

        startedAt = Date()
        task = session.dataTask(with: request)
        task?.resume()
    }

    private func finished(with error: Error?) {
        if let error {
            failure = error
            let pending = waiting
            waiting.removeAll()
            for request in pending where !request.isFinished {
                request.finishLoading(with: error)
            }

            RemoteLog.shared.error(
                "поток оборвался",
                category: "playback",
                context: ["error": "\(error)", "bytes": "\(buffer.count)"]
            )
            return
        }

        isComplete = true
        expectedLength = buffer.count

        RemoteLog.shared.timing(
            "поток загружен целиком",
            milliseconds: Int(Date().timeIntervalSince(startedAt) * 1000),
            category: "playback",
            context: ["bytes": "\(buffer.count)"]
        )

        serveWaiting()
    }

    // MARK: - Answering the player

    /// Answers one request with whatever of it is here.
    ///
    /// Returns false when nothing useful can be sent yet, in which case the
    /// request is held until more arrives.
    private func serve(_ request: AVAssetResourceLoadingRequest) -> Bool {
        if let information = request.contentInformationRequest {
            // The player will not start without knowing the length, so this
            // has to wait for the response headers — but only those, not the
            // body.
            guard let expectedLength else { return false }

            information.contentType = AVFileType.mp3.rawValue
            information.contentLength = Int64(expectedLength)
            // The whole file arrives in order, so a seek forward may have to
            // wait — but declaring ranges unsupported would stop the player
            // seeking at all.
            information.isByteRangeAccessSupported = true
        }

        guard let dataRequest = request.dataRequest else {
            request.finishLoading()
            return true
        }

        let start = Int(dataRequest.requestedOffset) + Int(dataRequest.currentOffset - dataRequest.requestedOffset)
        let available = buffer.count - start

        guard available > 0 else {
            // Nothing at this offset yet. If the download is done, this is
            // the end of the file rather than a wait.
            if isComplete {
                request.finishLoading()
                return true
            }
            return false
        }

        let wanted = dataRequest.requestsAllDataToEndOfResource
            ? available
            : min(Int(dataRequest.requestedLength) - Int(dataRequest.currentOffset - dataRequest.requestedOffset), available)

        guard wanted > 0 else { return false }

        dataRequest.respond(with: buffer.subdata(in: start..<(start + wanted)))

        let delivered = Int(dataRequest.currentOffset - dataRequest.requestedOffset)
        let complete = dataRequest.requestsAllDataToEndOfResource
            ? isComplete
            : delivered >= dataRequest.requestedLength

        if complete {
            request.finishLoading()
            return true
        }

        // Partly answered: keep it and top it up as more arrives.
        return false
    }

    private func serveWaiting() {
        let pending = waiting
        waiting.removeAll()

        for request in pending where !request.isFinished {
            if !serve(request) {
                waiting.append(request)
            }
        }
    }
}

// MARK: - Resource loading

extension StreamLoader: AVAssetResourceLoaderDelegate {
    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        if let failure {
            loadingRequest.finishLoading(with: failure)
            return true
        }

        if !serve(loadingRequest) {
            waiting.append(loadingRequest)
        }
        return true
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        didCancel loadingRequest: AVAssetResourceLoadingRequest
    ) {
        waiting.removeAll { $0 == loadingRequest }
    }
}

// MARK: - Receiving the download

extension StreamLoader: URLSessionDataDelegate {
    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        queue.async {
            if response.expectedContentLength > 0 {
                self.expectedLength = Int(response.expectedContentLength)
            }
            // The player has been waiting on the length; it can now be told.
            self.serveWaiting()
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        queue.async {
            self.buffer.append(data)

            if !self.reportedFirstBytes {
                self.reportedFirstBytes = true
                RemoteLog.shared.timing(
                    "первые байты потока",
                    milliseconds: Int(Date().timeIntervalSince(self.startedAt) * 1000),
                    category: "playback"
                )
            }

            self.serveWaiting()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        queue.async { self.finished(with: error) }
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        // Reaching the server by address needs the certificate checked
        // against the name it carries; every other route uses the default.
        guard usesPinnedTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        APITrust.shared.urlSession(
            session, didReceive: challenge, completionHandler: completionHandler
        )
    }
}
