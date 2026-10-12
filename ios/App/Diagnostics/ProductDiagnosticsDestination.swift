#if DEVELOPMENT_BUILD || INTERNAL_BUILD
import SwiftUI

/// A typed destination so tab reselect also pops the diagnostics screen.
@MainActor
struct ProductDiagnosticsDestination: View {
    let composition: AppComposition
    var body: some View { DiagnosticsView(composition: composition) }
}
#endif
