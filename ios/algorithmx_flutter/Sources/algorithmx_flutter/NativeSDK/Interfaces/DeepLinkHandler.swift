//
//  DeepLinkHandler.swift
//  AlgorithmXSDK
//
//  Protocol for handling deep link actions
//

import Foundation

/// Protocol for intercepting and handling deep links before SDK processes them
/// This is OPTIONAL - use only if you need custom deep link handling or analytics
@objc public protocol DeepLinkHandler: AnyObject {
    
    /// Called when a deep link is about to be processed
    /// - Parameter url: The deep link URL to be processed
    /// - Returns: `true` if you handled the deep link (SDK won't process it), `false` to let SDK handle it
    ///
    /// Example:
    /// ```swift
    /// func onDeepLinkReceived(url: URL) -> Bool {
    ///     // Track analytics
    ///     AlgorithmX.shared.trackEvent("deepLinkIntercepted", properties: [
    ///         "url": url.absoluteString,
    ///         "scheme": url.scheme ?? ""
    ///     ])
    ///     
    ///     // Block admin deep links
    ///     if url.path.contains("admin") {
    ///         print("Admin deep links are blocked")
    ///         return true
    ///     }
    ///     
    ///     // Let SDK handle normal deep links
    ///     return false
    /// }
    /// ```
    func onDeepLinkReceived(url: URL) -> Bool
}
