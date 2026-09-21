// Ad-hoc request bodies shared by several API files (the js source inlines
// them as object literals per call site; three drifting Swift copies of each
// is worse than one).

import Foundation

struct TeamBody: Encodable {
    let teamId: String
    enum CodingKeys: String, CodingKey { case teamId = "team_id" }
}

struct VisibilityBody: Encodable {
    let visibility: String
}
