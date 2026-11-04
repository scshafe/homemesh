import Foundation
import HomemeshCore

/// The house document as the on-device engine's typed model, for the editing operations that live there (HomemeshCore's WallOps and friends).
extension HouseDoc {
    func core() throws -> HomemeshCore.House { try HomemeshCore.House.load(lenient: try data()) }

    /// The document after an operation: the typed house written back as the document the screens edit.
    init(core house: HomemeshCore.House) throws { try self.init(data: try house.encoded()) }
}
