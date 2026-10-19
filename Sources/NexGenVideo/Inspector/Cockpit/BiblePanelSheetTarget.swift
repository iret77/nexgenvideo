import Foundation

struct BiblePanelSheetTarget: Equatable, Sendable {
    struct Context: Equatable, Sendable {
        let home: URL?
        let projectID: String?
        let generation: UUID?

        var isReady: Bool {
            home != nil && projectID?.isEmpty == false && generation != nil
        }
    }

    let home: URL
    let locationID: String
    let context: Context

    init?(locationID: String, context: Context) {
        guard context.isReady, let home = context.home, !locationID.isEmpty else { return nil }
        self.home = home
        self.locationID = locationID
        self.context = context
    }

    func isCurrent(_ current: Context) -> Bool {
        current.isReady && context == current
    }
}
