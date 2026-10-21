import Foundation
import Network

final class BundleStaticFileServer: @unchecked Sendable {
    static let shared = BundleStaticFileServer()

    private let queue = DispatchQueue(label: "io.github.x0c.neatgit.bundle-static-server")
    private var listener: NWListener?
    private var rootDirectoryURL: URL?
    private var baseURL: URL?

    private init() {}

    func startIfNeeded(rootDirectoryURL: URL) throws -> URL {
        if let baseURL, self.rootDirectoryURL == rootDirectoryURL {
            return baseURL
        }

        stop()

        // 只绑 127.0.0.1。默认的 `.any` 会监听所有网卡（实测 lsof 显示 `*:port`），
        // 把 Monaco 静态资源和整个资源目录暂存暴露给同局域网；
        // 绑定回环地址后 lsof 变为 `127.0.0.1:port`，外部主机无法连入。
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)

        let listener = try NWListener(using: parameters)
        let startupState = StartupState()
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection: connection)
        }

        let readySemaphore = DispatchSemaphore(value: 0)

        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                guard let port = listener.port else {
                    startupState.error = GitCommandError(message: "本地静态资源服务启动后没有拿到端口。")
                    readySemaphore.signal()
                    return
                }

                self?.rootDirectoryURL = rootDirectoryURL
                self?.baseURL = URL(string: "http://127.0.0.1:\(port.rawValue)/")
                readySemaphore.signal()
            case let .failed(error):
                startupState.error = error
                readySemaphore.signal()
            default:
                break
            }
        }

        listener.start(queue: queue)
        readySemaphore.wait()

        if let listenerError = startupState.error {
            listener.cancel()
            throw listenerError
        }

        self.listener = listener

        guard let baseURL else {
            throw GitCommandError(message: "本地静态资源服务启动失败。")
        }

        return baseURL
    }

    private func stop() {
        listener?.cancel()
        listener = nil
        baseURL = nil
        rootDirectoryURL = nil
    }

    /// 把请求路径解成资源目录内的真实文件，越界或不存在返回 nil。
    ///
    /// 独立成静态方法是为了让安全校验可以被单独验证：
    /// 服务本身是进程内单例，测试若为了验证路径规则去改它的根目录，
    /// 会连带把同进程里的 Monaco 预览用例一起弄挂。
    static func resolveFileURL(for requestPath: String, rootDirectoryURL: URL) -> URL? {
        let rawPath = requestPath.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? requestPath
        let trimmedPath = rawPath == "/" ? "index.html" : String(rawPath.drop(while: { $0 == "/" }))
        let decodedPath = trimmedPath.removingPercentEncoding ?? trimmedPath

        let rootURL = rootDirectoryURL.standardizedFileURL
        let candidateURL = rootURL
            .appendingPathComponent(decodedPath)
            .standardizedFileURL

        // 按路径分量逐级比较，不用字符串前缀。
        // 字符串 hasPrefix 会把同级的「同名前缀」目录误当成子目录：
        // 实测请求 `/../<资源目录名>-secret/密钥.txt` 与 `%2e%2e` 编码形式
        // 都能穿越到资源目录之外读文件，改成分量比较后两者均被拒绝。
        let rootComponents = rootURL.pathComponents
        let candidateComponents = candidateURL.pathComponents

        guard
            candidateComponents.count > rootComponents.count,
            Array(candidateComponents.prefix(rootComponents.count)) == rootComponents
        else {
            return nil
        }

        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: candidateURL.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            return nil
        }

        return candidateURL
    }

    private func handle(connection: NWConnection) {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.receiveRequest(on: connection)
            case .failed, .cancelled:
                connection.cancel()
            default:
                break
            }
        }

        connection.start(queue: queue)
    }

    private func receiveRequest(on connection: NWConnection, accumulated: Data = Data()) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, isComplete, _ in
            guard let self else {
                connection.cancel()
                return
            }

            var request = accumulated
            if let data {
                request.append(data)
            }

            guard !request.isEmpty else {
                connection.cancel()
                return
            }

            // TCP 不保证请求头一次读全：未读到空行分隔符就继续收，
            // 否则请求被分片时会把半条报文当成非法请求返回 400。
            if !Self.containsCompleteHeader(request), !isComplete, request.count < 64_000 {
                self.receiveRequest(on: connection, accumulated: request)
                return
            }

            let response = self.makeResponse(for: request)
            connection.send(content: response, contentContext: .defaultMessage, isComplete: true, completion: .contentProcessed { _ in
                self.queue.asyncAfter(deadline: .now() + 0.5) {
                    connection.cancel()
                }
            })
        }
    }

    /// HTTP 头部以连续的 CRLF CRLF 结束。
    private static func containsCompleteHeader(_ data: Data) -> Bool {
        data.range(of: Data("\r\n\r\n".utf8)) != nil || data.range(of: Data("\n\n".utf8)) != nil
    }

    private func makeResponse(for requestData: Data) -> Data {
        guard
            let request = String(data: requestData, encoding: .utf8),
            let requestLine = request.components(separatedBy: "\r\n").first
        else {
            return buildResponse(status: "400 Bad Request", contentType: "text/plain", body: Data("Bad Request".utf8))
        }

        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else {
            return buildResponse(status: "400 Bad Request", contentType: "text/plain", body: Data("Bad Request".utf8))
        }

        let method = String(parts[0])
        guard method == "GET" || method == "HEAD" else {
            return buildResponse(status: "405 Method Not Allowed", contentType: "text/plain", body: Data("Method Not Allowed".utf8))
        }

        let requestPath = String(parts[1])
        guard let fileURL = resolveFileURL(for: requestPath) else {
            return buildResponse(status: "404 Not Found", contentType: "text/plain", body: Data("Not Found".utf8))
        }

        do {
            let body = try Data(contentsOf: fileURL)
            return buildResponse(
                status: "200 OK",
                contentType: mimeType(for: fileURL),
                cacheControl: cacheControl(for: fileURL),
                body: method == "HEAD" ? Data() : body,
                contentLength: body.count
            )
        } catch {
            return buildResponse(status: "500 Internal Server Error", contentType: "text/plain", body: Data("Failed to read resource".utf8))
        }
    }

    private func resolveFileURL(for requestPath: String) -> URL? {
        guard let rootDirectoryURL else { return nil }
        return Self.resolveFileURL(for: requestPath, rootDirectoryURL: rootDirectoryURL)
    }

    private func buildResponse(
        status: String,
        contentType: String,
        cacheControl: String = "no-store",
        body: Data,
        contentLength: Int? = nil
    ) -> Data {
        let header = [
            "HTTP/1.1 \(status)",
            "Content-Type: \(contentType)",
            "Content-Length: \(contentLength ?? body.count)",
            "Cache-Control: \(cacheControl)",
            "Connection: close",
            "Access-Control-Allow-Origin: *",
            "",
            ""
        ].joined(separator: "\r\n")

        var response = Data(header.utf8)
        response.append(body)
        return response
    }

    private func mimeType(for fileURL: URL) -> String {
        switch fileURL.pathExtension.lowercased() {
        case "css":
            return "text/css; charset=utf-8"
        case "html":
            return "text/html; charset=utf-8"
        case "js":
            return "text/javascript; charset=utf-8"
        case "json":
            return "application/json; charset=utf-8"
        case "ttf":
            return "font/ttf"
        default:
            return "application/octet-stream"
        }
    }

    private func cacheControl(for fileURL: URL) -> String {
        if fileURL.lastPathComponent == "index.html" {
            return "no-cache"
        }

        switch fileURL.pathExtension.lowercased() {
        case "js", "css", "ttf":
            return "public, max-age=31536000, immutable"
        default:
            return "public, max-age=3600"
        }
    }
}

private final class StartupState: @unchecked Sendable {
    var error: Error?
}
