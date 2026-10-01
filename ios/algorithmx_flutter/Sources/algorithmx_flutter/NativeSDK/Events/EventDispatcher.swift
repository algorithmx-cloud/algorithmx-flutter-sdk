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
            self?.isOnline = (path.status == .satisfied)
        }
        monitor.start(queue: monitorQueue)
    }

    deinit { monitor.cancel() }

    func send(endpoint: String, method: String = "POST", payload: [String: Any]?) {
        guard isOnline else {
            SdkLog.debug("Network unavailable; dropping request to \(endpoint)")
            return
        }

        switch method {
        case "POST":
            NetworkClient.shared.postJson(endpoint: endpoint, payload: payload ?? [:]) { _ in }
        case "PUT":
            NetworkClient.shared.putJson(endpoint: endpoint, payload: payload ?? [:]) { _ in }
        case "GET":
            NetworkClient.shared.getJson(endpoint: endpoint) { _ in }
        default:
            SdkLog.error("Unsupported method: \(method)")
        }
    }
}
