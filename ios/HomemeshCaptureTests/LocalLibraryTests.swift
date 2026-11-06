import HomemeshCore
import XCTest
@testable import HomemeshCapture

final class LocalLibraryTests: XCTestCase {
    static let kitchenScan = #"{"format": "homemesh-capture-1", "rooms": [{"identifier": "A", "walls": [{"identifier": "A-s", "category": {"wall": {}}, "confidence": {"high": {}}, "dimensions": [4, 2.5, 0], "transform": [1,0,0,0, 0,1,0,0, 0,0,1,0, 2,1.25,0,1]}, {"identifier": "A-e", "category": {"wall": {}}, "confidence": {"high": {}}, "dimensions": [3, 2.5, 0], "transform": [0,0,1,0, 0,1,0,0, -1,0,0,0, 4,1.25,1.5,1]}, {"identifier": "A-n", "category": {"wall": {}}, "confidence": {"high": {}}, "dimensions": [4, 2.5, 0], "transform": [1,0,0,0, 0,1,0,0, 0,0,1,0, 2,1.25,3,1]}, {"identifier": "A-w", "category": {"wall": {}}, "confidence": {"high": {}}, "dimensions": [3, 2.5, 0], "transform": [0,0,1,0, 0,1,0,0, -1,0,0,0, 0,1.25,1.5,1]}], "doors": [{"identifier": "A-door0", "category": {"door": {"isOpen": false}}, "confidence": {"high": {}}, "dimensions": [0.9, 2, 0], "transform": [0,0,1,0, 0,1,0,0, -1,0,0,0, 4,1,1.5,1]}], "windows": [], "openings": [], "objects": []}]}"#

    private func tempAPI() -> LocalAPI {
        LocalAPI(root: FileManager.default.temporaryDirectory.appendingPathComponent("homemesh-test-\(UUID().uuidString)"))
    }

    func testTheDemoHousesComeFromTheBundleAndAreAddedOnce() throws {
        let api = tempAPI()
        let bundle = Bundle(for: LocalLibraryTests.self)
        let added = try LocalLibrary.addDemoHouses(into: api, bundle: bundle)
        XCTAssertEqual(Set(added), ["synthetic-box", "synthetic-two-floor"])
        XCTAssertEqual(api.houseIds(), ["synthetic-box", "synthetic-two-floor"])
        XCTAssertEqual(try LocalLibrary.addDemoHouses(into: api, bundle: bundle), [])
    }

    func testTheAppsClientTalksToTheLocalAPIAsToTheServer() async throws {
        let api = tempAPI()
        let client = HomemeshCapture.Client(local: api)
        _ = try await client.createHouse(id: "home", name: "Home")
        _ = try await client.addLevel(house: "home", name: "First")
        let houses = try await client.houses()
        XCTAssertEqual(houses.map(\.id), ["home"])
        XCTAssertEqual(houses[0].levels.map(\.name), ["Ground", "First"])
        do { _ = try await client.createHouse(id: "home", name: "Again"); XCTFail("a second house with the same id must be refused") }
        catch { XCTAssertTrue(error.localizedDescription.contains("exists"), error.localizedDescription) }
    }

    func testAScanUploadedToTheLibraryCanBeNamedAndItsDoorsRead() async throws {
        let api = tempAPI()
        let client = HomemeshCapture.Client(local: api)
        _ = try await client.createHouse(id: "home", name: "Home")
        let scan = LocalLibraryTests.kitchenScan
        let uploader = Uploader(house: "home", local: api)
        let blob = try await uploader.upload(json: Data(scan.utf8), usdz: nil, name: "Kitchen scan", level: "L0")
        let metas = try await client.captures(house: "home")
        XCTAssertEqual(metas.map(\.blob), [blob])
        XCTAssertEqual(metas[0].roomCount, 1)
        _ = try await client.nameRooms(house: "home", blob: blob, names: ["Kitchen"])
        let doors = try await client.doors(house: "home", blob: blob)
        XCTAssertEqual(doors.doors.count, 1)
        XCTAssertEqual(doors.rooms, ["Kitchen"])
        let placement = try JSONDecoder().decode(HomemeshCapture.Placement.self, from: try await client.call("POST", "/api/houses/home/captures/\(blob)/place?level=L0"))
        XCTAssertEqual(placement.confidence, "auto")   // the first scan of an empty floor lands as it is
    }
}

final class LeftoverAdoptionTests: XCTestCase {
    func testAScanLeftByAnEarlierBuildIsSavedIntoItsHouseAndRemoved() async throws {
        let api = LocalAPI(root: FileManager.default.temporaryDirectory.appendingPathComponent("homemesh-test-\(UUID().uuidString)"))
        let client = HomemeshCapture.Client(local: api)
        _ = try await client.createHouse(id: "home", name: "Home")
        LeftoverScans.root = FileManager.default.temporaryDirectory.appendingPathComponent("leftover-\(UUID().uuidString)", isDirectory: true)
        let p = PendingUpload(id: "1", house: "home", name: "Kitchen scan", level: "L0", replaces: "", created: Date())
        let dir = LeftoverScans.root.appendingPathComponent(p.id, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(LocalLibraryTests.kitchenScan.utf8).write(to: dir.appendingPathComponent("scan.json"))
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(p).write(to: dir.appendingPathComponent("meta.json"))
        let other = PendingUpload(id: "2", house: "elsewhere", name: "x", level: "", replaces: "", created: Date())
        let dir2 = LeftoverScans.root.appendingPathComponent(other.id, isDirectory: true)
        try FileManager.default.createDirectory(at: dir2, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: dir2.appendingPathComponent("scan.json"))
        try enc.encode(other).write(to: dir2.appendingPathComponent("meta.json"))

        let n = await LeftoverScans.adopt(into: api)
        XCTAssertEqual(n, 1)
        XCTAssertEqual(try await client.captures(house: "home").count, 1)
        XCTAssertEqual(LeftoverScans.all().map(\.id), ["2"])   // the one for a house that is not here stays
    }
}

final class EditorBridgeTests: XCTestCase {
    func testAnOperationOfTheEngineRunsOnTheDocumentTheScreensEdit() throws {
        let url = try XCTUnwrap(Bundle(for: LocalLibraryTests.self).url(forResource: "one_floor_box", withExtension: "json"))
        let doc = try HouseDoc(data: Data(contentsOf: url))
        let core = try doc.core()
        let before = core.walls.count
        let split = try XCTUnwrap(WallOps.split(core, wall: "p0", at: Vec2(5, 2)))
        let after = try HouseDoc(core: split)
        XCTAssertEqual(try after.core().walls.count, before + 1)
        XCTAssertEqual(try after.core().validate(), [])
        // a wall traced on the plan becomes walls with the chosen material, and the house stays sound
        var next = 0
        let walls = Draw.trace(points: [Vec2(1, 1), Vec2(3, 1), Vec2(3, 3)], closed: true, level: "L0", material: "drywall", thickness: 0.1, height: 2.5) { next += 1; return "n\(next)" }
        XCTAssertEqual(walls.count, 3)
        var h = core
        h.walls += walls
        XCTAssertEqual(h.validate(), [])
    }
}
