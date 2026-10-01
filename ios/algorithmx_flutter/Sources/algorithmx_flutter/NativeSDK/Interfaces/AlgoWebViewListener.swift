//
//  AlgoWebViewListener.swift
//  AlgorithmXSDK
//
//  Protocol for handling WebView campaign triggers
//

import Foundation

/// Protocol for handling WebView campaign triggers from the backend
/// Implement this in your AppDelegate to control when and how WebViews are displayed
@objc public protocol AlgoWebViewListener: AnyObject {

    /// Called when a WebView campaign should be triggered
    /// - Parameters:
    ///   - campaignId: Unique identifier for the campaign
    ///   - webviewUrl: URL of the HTML content to display
    ///   - dynamicContent: Dictionary of dynamic content to inject into the HTML (e.g., user name, promo codes)
    ///
    /// Example:
    /// ```swift
    /// func onWebViewTrigger(campaignId: String, webviewUrl: String, dynamicContent: [String: Any]?) {
    ///     // Only show if app is in foreground
    ///     guard UIApplication.shared.applicationState == .active else { return }
    ///
    ///     AlgorithmX.shared.showWebView(
    ///         campaignId: campaignId,
    ///         url: webviewUrl,
    ///         dynamicContent: dynamicContent
    ///     )
    /// }
    /// ```
    func onWebViewTrigger(
        campaignId: String,
        webviewUrl: String,
        dynamicContent: [String: Any]?
    )
}
