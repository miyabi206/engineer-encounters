import SwiftUI

public struct WelcomeView<Trailing: View>: View {
    private let trailing: Trailing

    public init(@ViewBuilder trailing: () -> Trailing) {
        self.trailing = trailing()
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("welcome.title", bundle: .module)
                    .font(.largeTitle.bold())
                    .accessibilityAddTraits(.isHeader)
                Text("welcome.introduction", bundle: .module)
                    .font(.body)
                trailing
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
    }
}

extension WelcomeView where Trailing == EmptyView {
    public init() { self.init { EmptyView() } }
}

enum WelcomeStrings {
    static func localized(_ key: String, language: String) -> String? {
        guard let path = Bundle.module.path(forResource: language, ofType: "lproj"),
              let bundle = Bundle(path: path) else { return nil }
        return bundle.localizedString(forKey: key, value: nil, table: nil)
    }
}
