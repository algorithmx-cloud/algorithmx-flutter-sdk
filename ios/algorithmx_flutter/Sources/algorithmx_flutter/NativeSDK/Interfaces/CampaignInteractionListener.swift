//
//  CampaignInteractionListener.swift
//  AlgorithmXSDK
//
//  Protocol for observing campaign interactions (WebView, push, etc.)
//

import Foundation

/// Protocol for observing campaign interactions tracked by the SDK.
/// Implement this to be notified when the SDK tracks campaign events like `click`, `submit`, `copy`, `close`, etc.
@objc public protocol CampaignInteractionListener: AnyObject {

    /// Called whenever the SDK tracks a campaign interaction.
    /// - Parameters:
    ///   - campaignId: Campaign identifier.
    ///   - variationId: Variation identifier.
    ///   - interactionType: Interaction type (e.g., `click`, `submit`, `copy`, `close`, `impression`).
    ///   - payload: Interaction payload (may be empty).
    func onCampaignInteraction(
        campaignId: String,
        variationId: String,
        interactionType: String,
        payload: [String: Any]
    )
}

