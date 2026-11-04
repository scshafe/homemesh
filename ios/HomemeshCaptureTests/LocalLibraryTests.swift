import HomemeshCore
import XCTest
@testable import HomemeshCapture

final class LocalLibraryTests: XCTestCase {
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
        XCTAssertTrue(client.isLocal)
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
        let scan = #"{"format": "homemesh-capture-1", "rooms": [{"identifier": "A", "walls": [{"identifier": "A-s", "category": {"wall": {}}, "confidence": {"high": {}}, "dimensions": [4, 2.5, 0], "transform": [1,0,0,0, 0,1,0,0, 0,0,1,0, 2,1.25,0,1]}, {"identifier": "A-e", "category": {"wall": {}}, "confidence": {"high": {}}, "dimensions": [3, 2.5, 0], "transform": [0,0,1,0, 0,1,0,0, -1,0,0,0, 4,1.25,1.5,1]}, {"identifier": "A-n", "category": {"wall": {}}, "confidence": {"high": {}}, "dimensions": [4, 2.5, 0], "transform": [1,0,0,0, 0,1,0,0, 0,0,1,0, 2,1.25,3,1]}, {"identifier": "A-w", "category": {"wall": {}}, "confidence": {"high": {}}, "dimensions": [3, 2.5, 0], "transform": [0,0,1,0, 0,1,0,0, -1,0,0,0, 0,1.25,1.5,1]}], "doors": [{"identifier": "A-door0", "category": {"door": {"isOpen": false}}, "confidence": {"high": {}}, "dimensions": [0.9, 2, 0], "transform": [0,0,1,0, 0,1,0,0, -1,0,0,0, 4,1,1.5,1]}], "windows": [], "openings": [], "objects": []}]}"#
        let uploader = Uploader(server: "", house: "home", token: { "" }, local: api)
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
