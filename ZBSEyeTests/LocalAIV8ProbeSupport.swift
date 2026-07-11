import Foundation

/// Immutable bounded preflight selection. These are existing V8 fixture cases;
/// the probe does not define a smaller protocol or alter release qualification.
enum LocalAIV8ProbeSupport {
    static let caseIDs = [
        "v6-en-ask-01",
        "v6-en-insights-01",
        "v6-en-summary-01",
        "v6-en-label-01",
        "v6-ru-ask-01",
        "v6-ru-insights-01",
        "v6-ru-summary-01",
        "v6-ru-label-01",
    ]

    static let caseIDSet = Set(caseIDs)
}
