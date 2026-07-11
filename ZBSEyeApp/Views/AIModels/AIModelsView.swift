import SwiftUI

/// Navigation entry point. The provider-first implementation lives in a
/// focused screen file so setup state and card hierarchy stay reviewable.
struct AIModelsView: View {
    var body: some View {
        ProviderFirstAIModelsScreen()
    }
}
