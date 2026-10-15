import Combine
import Foundation

/// Implemented by composition, with an installation/account policy chosen by the caller.
/// The package writes only this dismissal flag, never another person's card.
@MainActor
public protocol SampleEncounterDismissalStore {
    var isSampleEncounterDismissed: Bool { get }
    func dismissSampleEncounter()
}

public enum SampleEncounterContext: Sendable { case emptyFeed, discoveryOff, populatedFeed }

@MainActor
public final class SampleEncounterModel: ObservableObject {
    @Published public private(set) var isDismissed: Bool
    public let isNewUser: Bool
    private let store: any SampleEncounterDismissalStore

    public init(store: any SampleEncounterDismissalStore, isNewUser: Bool) {
        self.store = store; self.isNewUser = isNewUser
        isDismissed = store.isSampleEncounterDismissed
    }

    public func isVisible(in context: SampleEncounterContext) -> Bool {
        guard !isDismissed, !store.isSampleEncounterDismissed else { return false }
        switch context {
        case .emptyFeed: return true
        case .discoveryOff: return isNewUser
        case .populatedFeed: return false
        }
    }

    public func dismiss() {
        store.dismissSampleEncounter()
        isDismissed = true
    }
}

/// Separate from EncounterCard: there is no invented encounter ID, day, kind or contact.
public struct SampleEncounterPresentation: Equatable, Sendable {
    public let displayName: String
    public let introduction: String
    public let interests: [InterestOption]
    public let purposes: Set<ProfilePurpose>
    public let links: [EncounterLinkCard]

    public static func fixture(language: String) -> Self {
        func text(_ key: DiscoverString) -> String {
            DiscoverStrings.localized(key.rawValue, language: language.hasPrefix("ja") ? "ja" : "en") ?? key.rawValue
        }
        return Self(displayName: text(.sampleName), introduction: text(.sampleIntroduction),
                    interests: [], purposes: [.discovery], links: [
                        EncounterLinkCard(id: "sample-example-work", source: text(.sampleSource),
                                          title: text(.sampleWork), description: text(.sampleDescription),
                                          url: URL(string: "https://example.com")!)
                    ])
    }
}
