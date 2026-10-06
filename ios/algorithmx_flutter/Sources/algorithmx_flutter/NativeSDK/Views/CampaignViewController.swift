//
//  CampaignViewController.swift
//  AlgorithmXSDK
//
//  WebView container for displaying campaign HTML content.
//  Mirrors Android `CampaignActivity`:
//   - Tracks "impression" once the HTML has loaded (WKNavigationDelegate didFinish),
//     not in viewDidLoad. Records the webview display at the same point.
//   - Reports "closeDismiss" if a shown campaign is dismissed without a JS bridge
//     close or submit (a campaign that never loaded reports nothing).
//   - Bridge interactions forward the template's own fields plus `timestamp` and
//     `source`, exactly like Android. The template owns the close button; the view
//     is transparent over the app, like Android's translucent activity.
//

import UIKit
import WebKit

public class CampaignViewController: UIViewController {

    private let campaignId: String
    private let variationId: String
    private let url: String
    private let dynamicContent: [String: Any]?
    private let expiresAt: Int64

    private var webView: WKWebView!
    private var activityIndicator: UIActivityIndicatorView!
    private var userContentController: WKUserContentController!
    private var trackedExplicitClose = false
    private var shown = false

    private static let interactionEndpoint = "/api/v1/tracks/algoViewInteract"

    public init(
        campaignId: String, variationId: String, url: String,
        dynamicContent: [String: Any]?, expiresAt: Int64 = 0
    ) {
        self.campaignId = campaignId
        self.variationId = variationId
        self.url = url
        self.dynamicContent = dynamicContent
        self.expiresAt = expiresAt
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - Lifecycle

    public override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        loadWebView()
    }

    public override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if shown && !trackedExplicitClose {
            AlgorithmX.shared.trackCampaignInteraction(
                campaignId: campaignId, variationId: variationId,
                interactionType: "closeDismiss",
                payload: ["reason": "viewDismissed", "timestamp": Int64(Date().timeIntervalSince1970 * 1000)],
                endpoint: Self.interactionEndpoint
            )
        }
        AlgorithmX.shared.setWebViewShowing(false)
    }

    deinit {
        userContentController?.removeScriptMessageHandler(forName: "EngageBridge")
    }

    // MARK: - UI setup

    private func setupUI() {
        view.backgroundColor = .clear

        let config = WKWebViewConfiguration()
        userContentController = WKUserContentController()
        userContentController.add(self, name: "EngageBridge")
        config.userContentController = userContentController

        webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.alpha = 0
        view.addSubview(webView)

        activityIndicator = UIActivityIndicatorView(style: .large)
        activityIndicator.color = .white
        activityIndicator.translatesAutoresizingMaskIntoConstraints = false
        activityIndicator.startAnimating()
        view.addSubview(activityIndicator)

        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: view.topAnchor),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            activityIndicator.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            activityIndicator.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])
    }

    // MARK: - WebView load

    private func loadWebView() {
        guard let url = URL(string: url) else { dismiss(animated: true); return }
        fetchAndLoadHTMLWithPlaceholders(url: url)
    }

    private func resolveDynamicPlaceholders(in html: String) -> String {
        let pattern = "\\$\\{\\{([^}]+)\\}\\}"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return html }

        let ns = html as NSString
        let matches = regex.matches(in: html, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return html }

        var out = html
        for match in matches.reversed() {
            guard match.numberOfRanges >= 2 else { continue }
            let raw = ns.substring(with: match.range(at: 1))
            let parts = raw.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
            let key = String(parts[0]).trimmingCharacters(in: .whitespacesAndNewlines)
            let fallback = parts.count > 1 ? String(parts[1]) : nil
            if let replacement = resolveDynamicValue(forKey: key, fallback: fallback) {
                out = (out as NSString).replacingCharacters(in: match.range(at: 0), with: replacement)
            }
        }
        return out
    }

    private func resolveDynamicValue(forKey key: String, fallback: String?) -> String? {
        guard let dynamicContent = dynamicContent else { return fallback }
        guard let raw = dynamicContent[key] else { return fallback }
        let str = AlgorithmX.dynamicValueText(raw)
        return str.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? fallback : str
    }

    private func fetchAndLoadHTMLWithPlaceholders(url: URL) {
        URLSession.shared.dataTask(with: url) { [weak self] data, _, error in
            guard let self = self else { return }
            if error != nil {
                DispatchQueue.main.async { self.dismiss(animated: true) }
                return
            }
            guard let data = data, var html = String(data: data, encoding: .utf8) else {
                DispatchQueue.main.async { self.dismiss(animated: true) }
                return
            }
            html = self.resolveDynamicPlaceholders(in: html)
            html = html.replacingOccurrences(of: "${variationId}", with: self.variationId)

            let baseURL = url.deletingLastPathComponent()
            DispatchQueue.main.async { self.webView.loadHTMLString(html, baseURL: baseURL) }
        }.resume()
    }

}

// MARK: - WKScriptMessageHandler

extension CampaignViewController: WKScriptMessageHandler {
    public func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard message.name == "EngageBridge",
              let body = message.body as? [String: Any],
              let event = body["event"] as? String else { return }

        // Same payload as Android: the template's fields, plus timestamp and source.
        var payload = body
        payload.removeValue(forKey: "event")
        payload["timestamp"] = Int64(Date().timeIntervalSince1970 * 1000)
        payload["source"] = "javascript"

        switch event {
        case "campaignClose", "campaign_close":
            trackedExplicitClose = true
            AlgorithmX.shared.trackCampaignInteraction(
                campaignId: campaignId, variationId: variationId,
                interactionType: "close",
                payload: payload, endpoint: Self.interactionEndpoint
            )
            dismiss(animated: true)

        case "campaignClick", "campaign_click":
            AlgorithmX.shared.trackCampaignInteraction(
                campaignId: campaignId, variationId: variationId,
                interactionType: "click",
                payload: payload, endpoint: Self.interactionEndpoint
            )

        case "campaignSubmit", "campaign_submit":
            trackedExplicitClose = true
            AlgorithmX.shared.trackCampaignInteraction(
                campaignId: campaignId, variationId: variationId,
                interactionType: "submit",
                payload: payload, endpoint: Self.interactionEndpoint
            )
            dismiss(animated: true)

        case "campaignCouponCopy", "copyCoupon", "campaign_coupon_copy", "copy_coupon":
            if let coupon = pickCouponCode(body)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !coupon.isEmpty {
                UIPasteboard.general.string = coupon
                payload["couponCode"] = coupon
            }
            AlgorithmX.shared.trackCampaignInteraction(
                campaignId: campaignId, variationId: variationId,
                interactionType: "copy",
                payload: payload, endpoint: Self.interactionEndpoint
            )

        default:
            AlgorithmX.shared.trackEvent(event, properties: body)
        }
    }

    private func pickCouponCode(_ body: [String: Any]) -> String? {
        let topKeys = ["couponCode", "coupon_code", "coupon", "code", "text"]
        if let direct = topKeys.lazy.compactMap({ body[$0] as? String }).first { return direct }
        guard let nested = body["payload"] as? [String: Any] else { return nil }
        return topKeys.lazy.compactMap({ nested[$0] as? String }).first
    }
}

// MARK: - WKNavigationDelegate

extension CampaignViewController: WKNavigationDelegate {
    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard !shown else { return }
        shown = true
        activityIndicator.stopAnimating()
        activityIndicator.isHidden = true
        DispatchQueue.main.async {
            UIView.animate(withDuration: 0.25) { self.webView.alpha = 1 }
        }

        // HTML loaded successfully — now (and only now) record impression and display.
        var impressionPayload: [String: Any] = [
            "url": url,
            "timestamp": Int64(Date().timeIntervalSince1970 * 1000)
        ]
        if let dynamicContent = dynamicContent, !dynamicContent.isEmpty {
            impressionPayload["dynamicContent"] = dynamicContent.mapValues { AlgorithmX.dynamicValueText($0) }
        }
        AlgorithmX.shared.trackCampaignInteraction(
            campaignId: campaignId, variationId: variationId,
            interactionType: "impression",
            payload: impressionPayload, endpoint: Self.interactionEndpoint
        )
        AlgorithmX.shared.recordWebViewDisplaySuccess(
            campaignId: campaignId, variationId: variationId, expiresAt: expiresAt
        )
    }

    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        dismiss(animated: true)
    }

    public func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        dismiss(animated: true)
    }
}
