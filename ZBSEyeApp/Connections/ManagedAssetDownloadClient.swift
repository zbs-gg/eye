import Foundation

/// Neutral names for the hardened resumable transport that originally landed
/// with the optional generative model. Speech and generative assets now share
/// the same redirect, ETag, range, capacity, and partial-file rules without
/// sharing activation state.
typealias ManagedAssetDownloadPlan = BuiltInDownloadPlan
typealias ManagedAssetDownloadResumeState = BuiltInDownloadResumeState
typealias ManagedAssetDownloadProgress = BuiltInDownloadCapacityProgress
typealias ManagedAssetDownloadDecision = BuiltInDownloadCapacityDecision
typealias ManagedAssetDownloadOutcome = BuiltInDownloadOutcome
typealias ManagedAssetDownloadClient = BuiltInDownloadClient
typealias ManagedAssetDownloadError = BuiltInDownloadError
