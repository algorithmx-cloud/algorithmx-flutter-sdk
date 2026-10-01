//
//  ActionButtonHandler.swift
//  AlgorithmXSDK
//
//  Protocol for handling notification action button clicks
//

import Foundation

/// Protocol for handling notification action button clicks
/// Implement this to define custom behavior for interactive notification buttons
@objc public protocol ActionButtonHandler: AnyObject {

    /// Called when an action button on a notification is clicked
    /// - Parameters:
    ///   - buttonId: Unique ID of the button that was clicked
    ///   - actionText: Action identifier (e.g., "view_offer", "dismiss")
    ///   - title: Button title/label shown to the user
    ///   - notificationData: Complete notification data including campaign info
    /// - Returns: `true` if you handled the action, `false` to let SDK handle it
    ///
    /// Example:
    /// ```swift
    /// func onActionButtonClicked(
    ///     buttonId: String,
    ///     actionText: String,
    ///     title: String,
    ///     notificationData: [String: Any]
    /// ) -> Bool {
    ///     switch actionText {
    ///     case "view_offer":
    ///         navigateToOfferScreen()
    ///         return true
    ///     case "dismiss":
    ///         // Just dismiss, nothing to do
    ///         return true
    ///     default:
    ///         return false // Let SDK handle
    ///     }
    /// }
    /// ```
    func onActionButtonClicked(
        buttonId: String,
        actionText: String,
        title: String,
        notificationData: [String: Any]
    ) -> Bool
}
