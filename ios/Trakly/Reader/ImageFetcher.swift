import Foundation
import ImageIO
import TraklyCore
import UIKit
import UniformTypeIdentifiers

/// Native product image fetches (docs/specs/phase10-apps-and-stores.md D11, §E5, §I3): an ephemeral session without
/// cookies, cache or stored credentials, `Accept: image/*`, a redirect only to the same host and only when the policy
/// allows it, at most 8 MiB, every resolved address public before the request and the connected remote address
/// (`URLSessionTaskTransactionMetrics.remoteAddress`) public before the body is accepted, the image type checked by its
/// bytes and the picture re-encoded as JPEG of at most 2048 px (quality 0.85). A Debug build's local fixture shops
/// are loopback by design and skip only the address checks.
final class ImageFetcher: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private final class Job {
        var data = Data()
        var refused = false
        var addressChecked = false
        let dev: Bool
        let host: String?
        var continuation: CheckedContinuation<Data?, Never>?

        init(dev: Bool, host: String?, continuation: CheckedContinuation<Data?, Never>) {
            self.dev = dev
            self.host = host
            self.continuation = continuation
        }
    }

    private let lock = NSLock()
    /// The running fetches by task (an object key: task identifiers are only unique within one session).
    private var jobs: [ObjectIdentifier: Job] = [:]
    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.name = "info.trakly.app.images"
        return queue
    }()

    /// Made once in `init`: fetches run concurrently, and a lazy property would race (two sessions, lost jobs).
    private var session: URLSession!

    override init() {
        super.init()
        session = URLSession(configuration: ImageFetcher.configuration(), delegate: self, delegateQueue: queue)
    }

    private static func configuration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = TimeInterval(Limits.imageTimeoutMs) / 1000
        configuration.timeoutIntervalForResource = TimeInterval(Limits.imageTimeoutMs) / 1000
        configuration.httpAdditionalHeaders = ["Accept": "image/*"]
        return configuration
    }

    private static let imageTypes: Set<String> = [UTType.jpeg.identifier, UTType.png.identifier, UTType.gif.identifier, UTType.webP.identifier, UTType.heic.identifier, UTType.heif.identifier]

    /// The image at `url` as JPEG (≤ 2048 px), or nil when any rule refuses it. `maxPixels` makes a thumbnail.
    func fetch(_ url: String, dev: Bool, maxPixels: Int = Limits.imageEdgePx) async -> Data? {
        let fixture = ImageAddress.isDevFixture(url, dev: dev)
        guard fixture || Policy.check(url, dev: dev).ok, let target = URL(string: url) else { return nil }
        let host = Url.parse(url)?.hostName
        if !fixture {
            guard let name = host, ImageAddress.allPublic(await ImageFetcher.resolve(name)) else { return nil }
        }
        let raw: Data? = await withCheckedContinuation { continuation in
            var request = URLRequest(url: target)
            request.httpShouldHandleCookies = false
            let task = session.dataTask(with: request)
            lock.lock()
            jobs[ObjectIdentifier(task)] = Job(dev: fixture, host: host, continuation: continuation)
            lock.unlock()
            task.resume()
        }
        guard let raw else { return nil }
        return ImageFetcher.reencode(raw, maxPixels: maxPixels)
    }

    /// Every address of `host` (getaddrinfo) as bytes.
    static func resolve(_ host: String) async -> [[UInt8]] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var hints = addrinfo()
                hints.ai_socktype = SOCK_STREAM
                var result: UnsafeMutablePointer<addrinfo>?
                var out: [[UInt8]] = []
                if getaddrinfo(host, "443", &hints, &result) == 0 {
                    var pointer = result
                    while let info = pointer {
                        if let address = info.pointee.ai_addr {
                            if info.pointee.ai_family == AF_INET {
                                address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { value in
                                    var raw = value.pointee.sin_addr
                                    out.append(withUnsafeBytes(of: &raw) { Array($0) })
                                }
                            } else if info.pointee.ai_family == AF_INET6 {
                                address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { value in
                                    var raw = value.pointee.sin6_addr
                                    out.append(withUnsafeBytes(of: &raw) { Array($0) })
                                }
                            }
                        }
                        pointer = info.pointee.ai_next
                    }
                    freeaddrinfo(result)
                }
                continuation.resume(returning: out)
            }
        }
    }

    /// The picture checked by its bytes and written again as JPEG within `maxPixels`.
    static func reencode(_ data: Data, maxPixels: Int) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), let type = CGImageSourceGetType(source) as String?, imageTypes.contains(type) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: Limits.imageQuality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    private func jobFor(_ task: URLSessionTask) -> Job? {
        lock.lock()
        defer { lock.unlock() }
        return jobs[ObjectIdentifier(task)]
    }

    // MARK: - URLSessionDataDelegate

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        guard jobFor(dataTask) != nil, let http = response as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode), response.expectedContentLength <= Int64(Limits.imageBytes) else {
            jobFor(dataTask)?.refused = true
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let job = jobFor(dataTask) else { return }
        job.data.append(data)
        if job.data.count > Limits.imageBytes {
            job.refused = true
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        guard let job = jobFor(task), let next = request.url?.absoluteString else {
            completionHandler(nil)
            return
        }
        let sameHost = Url.parse(next)?.hostName == job.host
        let allowed = sameHost && (ImageAddress.isDevFixture(next, dev: job.dev) || Policy.check(next, dev: false).ok)
        if !allowed {
            job.refused = true
        }
        completionHandler(allowed ? request : nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        guard let job = jobFor(task) else { return }
        if job.dev {
            job.addressChecked = true
            return
        }
        let remote = metrics.transactionMetrics.last { $0.remoteAddress != nil }?.remoteAddress
        if let remote, let bytes = ImageAddress.bytes(ofNumericAddress: remote), ImageAddress.isPublic(bytes) {
            job.addressChecked = true
        } else {
            job.refused = true
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let job = jobs.removeValue(forKey: ObjectIdentifier(task))
        lock.unlock()
        guard let job else { return }
        let accepted = error == nil && !job.refused && job.addressChecked && !job.data.isEmpty
        job.continuation?.resume(returning: accepted ? job.data : nil)
        job.continuation = nil
    }
}
