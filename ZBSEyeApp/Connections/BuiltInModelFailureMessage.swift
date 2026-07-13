import Foundation

enum BuiltInModelFailureContext: Sendable {
    case operation
    case download
    case verification
    case runtimeLoad
    case removal
}

/// Converts lower-level failures into stable user-facing copy. Unknown Cocoa,
/// POSIX, MLX, and filesystem errors often embed absolute paths in their
/// descriptions, so they must never be rendered or persisted verbatim.
enum BuiltInModelFailureMessage {
    static func userFacing(
        _ error: any Error,
        context: BuiltInModelFailureContext
    ) -> String {
        if let error = error as? BuiltInModelManagerError {
            return error.errorDescription
                ?? String(localized: "The built-in model operation failed.")
        }
        if let error = error as? BuiltInDownloadError {
            return error.errorDescription
                ?? String(localized: "The model download failed.")
        }
        if error is BuiltInModelVerificationError {
            return String(localized: "The downloaded model did not pass integrity verification.")
        }
        if let error = error as? LocalInferenceError {
            return error.errorDescription
                ?? String(localized: "The built-in model could not complete the request.")
        }
        if let error = error as? MLXLocalRuntimeDriverError {
            switch error {
            case .notLoaded:
                return String(localized: "The built-in model is not loaded.")
            case .generationAlreadyActive:
                return String(localized: "The built-in model is already processing another request.")
            case .invalidMemoryEnvelope:
                return String(localized: "The built-in model cannot use the configured memory envelope.")
            case .runtimeDrainUnconfirmed:
                return String(localized: "The built-in model did not release its runtime resources in time.")
            case .unsupportedToolCallFormat,
                 .prefixRoundTripFailed,
                 .insufficientOutputTokenBudget,
                 .incompatibleKVQuantization:
                return String(localized: "The built-in model could not complete the request.")
            }
        }

        return switch context {
        case .operation:
            String(localized: "The built-in model operation failed.")
        case .download:
            String(localized: "The model download failed.")
        case .verification:
            String(localized: "The downloaded model did not pass integrity verification.")
        case .runtimeLoad:
            String(localized: "The built-in model could not be loaded.")
        case .removal:
            String(localized: "The built-in model could not be removed.")
        }
    }
}
