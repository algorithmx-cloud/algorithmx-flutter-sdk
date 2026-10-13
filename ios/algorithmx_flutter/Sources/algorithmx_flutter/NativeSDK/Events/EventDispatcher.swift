//
//  EventDispatcher.swift
//  AlgorithmXSDK
//
//  Fire-and-forget HTTP dispatcher. Events sent while offline are dropped —
//  there is no persistent queue. (The previous name "EventQueue" was historical
//  and misleading.) Network reachability is gated via NWPathMonitor.
//

import Foundation
import Network

final class EventDispatcher {

    static let shared = EventDispatcher()

    private let monitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "com.algorithmx.network.monitor")
    private var isOnline: Bool = true

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self = self else { return }
            self.requestQueue.async {
                let restored = !self.isOnline && path.status == .satisfied
                self.isOnline = (path.status == .satisfied)
                if restored {
                    DispatchQueue.main.async { NotificationCenter.default.post(name: Notification.Name("AlgorithmXConnectivityRestored"), object: nil) }
                }
            }
        }
        monitor.start(queue: monitorQueue)
    }

    deinit { monitor.cancel() }

    private struct PendingRequest {
        let endpoint: String
        let method: String
        let payload: Any
        let headers: [String: String]
        var arrayCompletion: ((Result<[[String: Any]], Error>) -> Void)? = nil
    }
    private let requestQueue = DispatchQueue(label: "com.algorithmx.requests")
    private var pending: [PendingRequest] = []
    private var sending = false

    func send(
        endpoint: String, method: String = "POST", payload: Any?,
        headers: [String: String] = [:]
    ) {
        var capturedHeaders = headers
        capturedHeaders["x-partner-id"] = NetworkClient.shared.partnerId
        let request = PendingRequest(endpoint: endpoint, method: method, payload: payload ?? [:], headers: capturedHeaders)
        requestQueue.async {
            self.pending.append(request)
            self.sendNext()
        }
    }

    func getJsonArray(request: URLRequest, completion: @escaping (Result<[[String: Any]], Error>) -> Void) {
        let pendingRequest = PendingRequest(endpoint: request.url!.absoluteString, method: "GET_ARRAY",
            payload: request, headers: [:], arrayCompletion: completion)
        requestQueue.async {
            self.pending.append(pendingRequest)
            self.sendNext()
        }
    }

    private func sendNext() {
        guard !sending, !pending.isEmpty else { return }
        let request = pending.removeFirst()
        guard isOnline else {
            SdkLog.error("Network unavailable; dropping request to \(request.endpoint)")
            request.arrayCompletion?(.failure(NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)))
            sendNext()
            return
        }
        sending = true
        let completed: (Result<[String: Any], Error>) -> Void = { _ in
            self.requestQueue.async {
                self.sending = false
                self.sendNext()
            }
        }
        switch request.method {
        case "GET_ARRAY":
            NetworkClient.shared.getJsonArray(request: request.payload as! URLRequest) { result in
                request.arrayCompletion?(result)
                completed(.success([:]))
            }
        case "POST":
            NetworkClient.shared.postJson(endpoint: request.endpoint, payload: request.payload, headers: request.headers, completion: completed)
        case "PUT":
            NetworkClient.shared.putJson(endpoint: request.endpoint, payload: request.payload as? [String: Any] ?? [:], headers: request.headers, completion: completed)
        case "GET":
            NetworkClient.shared.getJson(endpoint: request.endpoint, completion: completed)
        default:
            SdkLog.error("Unsupported method: \(request.method)")
            sending = false
            sendNext()
        }
    }

}
