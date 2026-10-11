#if DEVELOPMENT_BUILD
import SwiftUI

struct DevelopmentDiagnosticsEntry: View {
    let composition: AppComposition
    private var label: String {
        Bundle.main.localizedString(forKey: "diagnostics", value: nil, table: "DevelopmentDiagnostics")
    }
    var body: some View {
        NavigationLink {
            DiagnosticsView(composition: composition)
        } label: {
            Text(label)
        }
        .accessibilityLabel(label)
    }
}
#endif
