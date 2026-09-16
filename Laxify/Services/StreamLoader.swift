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
    /// What the file actually is, as the server described it.
    ///
    /// It used to be declared an mp3 whatever arrived. That was true while
    /// everything behind this loader came from one source; a track found
    /// elsewhere arrives as AAC in an MP4, and telling the player it is an
    /// mp3 makes it refuse a perfectly good file as damaged.
    private var contentType = AVFileType.mp3.rawValue
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
        // Longer than it was. The server may have to find a track somewhere
        // else before its first byte exists — a few seconds normally, more
        // when that other source is slow — and giving up at eighteen turned
        // a track that was on its way into a skip.
        configuration.timeoutIntervalForRequest = 45
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

    /// Why the download failed, if it did.
    ///
    /// The player only ever sees its own wrapped version of this — "the media
    /// may be damaged" — which cannot tell "the server found this song
    /// nowhere" from "the connection dropped". The player asks here instead.
    /// Called from the main actor only, never from the loader's own queue.
    var failureReason: Error? {
        queue.sync { failure }
    }

    func cancel() {
        task?.cancel()
        queue.async { self.waiting.removeAll() }
        // The session holds a strong reference to its delegate — that is
        // this object — until it is invalidated. Without this a loader
        // dropped because the listener moved on stayed alive, and its
        // download stayed alive with it: a queue skipped through quickly
        // left half a dozen connections still pulling whole tracks nobody
        // was going to hear, on the very connection the next track needed.
        session.invalidateAndCancel()
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
        // The first answer is the true one. Refusing a response above cancels
        // the task, and the cancellation arrives here a moment later as an
        // error of its own — "cancelled" would then replace the status that
        // explains why, which is the only part worth keeping.
        guard failure == nil, !isComplete else { return }

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

            information.contentType = contentType
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
        // Whatever the server said before any of it is treated as audio.
        //
        // This used to be skipped entirely: the body was appended, the
        // download "finished" without an error, and a 401 from an expired
        // session or a 404 for a track the server cannot resolve was handed
        // to AVPlayer as if it were an mp3. The player took a moment to
        // decide that four hundred bytes of JSON were not music, failed, and
        // the track was written off as unplayable — for a reason that had
        // nothing to do with the track. Refuse it here instead, with the
        // status intact so the player can tell a dead track from a dead
        // session.
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 200
        let type = (http?.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()

        let looksLikeAnError = !(200..<300).contains(status)
            || type.contains("json")
            || type.hasPrefix("text/")

        guard !looksLikeAnError else {
            let error: Error = looksLikeATransientStatus(status)
                ? MusicServiceError.temporarilyUnavailable
                : MusicServiceError.underlying(
                    APIError.server(status: status, detail: "поток не отдан: \(type)")
                )
            queue.async { self.finished(with: error) }
            completionHandler(.cancel)
            return
        }

        let declared: String = if type.contains("mp4") || type.contains("m4a") || type.contains("aac") {
            AVFileType.m4a.rawValue
        } else {
            AVFileType.mp3.rawValue
        }

        queue.async {
            self.contentType = declared
            if response.expectedContentLength > 0 {
                self.expectedLength = Int(response.expectedContentLength)
            }
            // The player has been waiting on the length; it can now be told.
            self.serveWaiting()
        }
        completionHandler(.allow)
    }

    /// Whether a refusal says something about the moment rather than about
    /// the track. A throttled or briefly broken server must never cost a
    /// working song its place in the queue.
    private func looksLikeATransientStatus(_ status: Int) -> Bool {
        status == 408 || status == 425 || status == 429 || (500..<600).contains(status)
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
