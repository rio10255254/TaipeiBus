import XCTest
@testable import TransitCore

final class MapPlacePriorityTests: XCTestCase {
    private let ximen = Coordinate(latitude: 25.0422, longitude: 121.5076)
    private let none = KnownPlaces([])
    private func place(_ kind: String, _ subclass: String = "", name: String = "某地", english: String? = nil,
                       at coordinate: Coordinate? = nil, rank: Double = 1) -> MapPlace {
        var names = ["name": name]
        if let english { names["name:en"] = english }
        return MapPlace(id: "\(kind):\(name)", coordinate: coordinate ?? ximen, kind: kind, subclass: subclass, rank: rank, names: names)
    }
    private func priority(_ place: MapPlace, known: KnownPlaces? = nil) -> MapPlacePriority? {
        MapPlacePriority(place, known: known ?? none)
    }

    func testSightsThenFoodAndDrinkThenEverydayPlaces() throws {
        // The tile ranks a cell's clinic and shop ahead of its restaurant; riders look for the restaurant.
        let museum = try XCTUnwrap(priority(place("museum", "museum", rank: 40)))
        let restaurant = try XCTUnwrap(priority(place("restaurant", "restaurant", rank: 30)))
        let cafe = try XCTUnwrap(priority(place("cafe", "cafe", rank: 31)))
        let bar = try XCTUnwrap(priority(place("bar", "bar", rank: 32)))
        let shop = try XCTUnwrap(priority(place("shop", "convenience", rank: 2)))
        let clinic = try XCTUnwrap(priority(place("hospital", "clinic", rank: 1)))
        XCTAssertEqual(museum.tier, .sight)
        XCTAssertEqual([restaurant.tier, cafe.tier, bar.tier], [.food, .food, .food])
        XCTAssertEqual(shop.tier, .everyday)
        XCTAssertEqual(clinic.tier, .minor)
        XCTAssertLessThan(museum.score, restaurant.score)
        XCTAssertEqual(restaurant.score, cafe.score)
        XCTAssertEqual(restaurant.score, bar.score)
        XCTAssertLessThan(restaurant.score, shop.score)
        XCTAssertLessThan(shop.score, clinic.score)
        XCTAssertLessThan(restaurant.minimumZoom, clinic.minimumZoom)
    }
    func testHospitalsStayLandmarksButClinicsDoNot() throws {
        let hospital = try XCTUnwrap(priority(place("hospital", "hospital", english: "National Taiwan University Hospital")))
        XCTAssertEqual(hospital.tier, .sight)
        XCTAssertEqual(hospital.minimumZoom, 14)
        XCTAssertEqual(priority(place("hospital", "clinic"))?.minimumZoom, 16.5)
    }
    func testMetroStationsAndUndrawnKindsAreLeftOut() {
        // The app draws metro stations from the official network; OSM's copy would label them twice.
        XCTAssertNil(priority(place("railway", "subway", name: "西門")))
        XCTAssertEqual(priority(place("railway", "station", name: "臺北"))?.tier, .sight)
        XCTAssertNil(priority(place("bus", "bus_stop")))
        XCTAssertNil(priority(place("office", "company")))
    }
    func testAnEnglishNameBringsFoodInEarlier() {
        XCTAssertEqual(priority(place("restaurant", "restaurant", name: "鼎泰豐", english: "Din Tai Fung"))?.minimumZoom, 15)
        XCTAssertEqual(priority(place("restaurant", "restaurant", name: "巷口麵店"))?.minimumZoom, 15.5)
        // A copy of the Chinese name in the English field is not an English name.
        XCTAssertEqual(priority(place("restaurant", "restaurant", name: "巷口麵店", english: "巷口麵店"))?.minimumZoom, 15.5)
        let known = priority(place("cafe", "cafe", english: "Louisa Coffee"))!, plain = priority(place("cafe", "cafe"))!
        XCTAssertLessThan(known.score, plain.score)
    }
    func testGalleriesAndTheatresNeedToBeNotable() {
        XCTAssertEqual(priority(place("art_gallery", "gallery", name: "名山藝術"))?.tier, .minor)
        XCTAssertEqual(priority(place("art_gallery", "arts_centre", name: "中山堂", english: "Zhongshan Hall"))?.tier, .sight)
        XCTAssertEqual(priority(place("art_gallery", "artwork", name: "雕塑", english: "Sculpture"))?.tier, .minor)
    }
    func testTourismListingPromotesTheTempleItNames() throws {
        let listing = VoicePlaces.Place(name: "艋舺龍山寺", coordinate: Coordinate(latitude: 25.0372, longitude: 121.4999), kind: "spot")
        let known = KnownPlaces([listing])
        let temple = try XCTUnwrap(priority(place("place_of_worship", "buddhist", name: "艋舺龍山寺",
                                                  at: Coordinate(latitude: 25.0371, longitude: 121.5000)), known: known))
        XCTAssertEqual(temple.tier, .sight)
        XCTAssertEqual(temple.minimumZoom, 14)
        // Many temples share a name; one across the city is not the listed one.
        let namesake = try XCTUnwrap(priority(place("place_of_worship", "buddhist", name: "艋舺龍山寺",
                                                    at: Coordinate(latitude: 25.0880, longitude: 121.5241)), known: known))
        XCTAssertEqual(namesake.tier, .everyday)
        // A listed restaurant stays food, shown early.
        let food = KnownPlaces([VoicePlaces.Place(name: "阿宗麵線", coordinate: ximen, kind: "food")])
        XCTAssertEqual(priority(place("restaurant", "restaurant", name: "阿宗麵線"), known: food)?.tier, .food)
        XCTAssertEqual(priority(place("restaurant", "restaurant", name: "阿宗麵線"), known: food)?.minimumZoom, 15)
    }
    func testListedNamesMatchWithoutBracketsOrVariantCharacters() {
        XCTAssertEqual(KnownPlaces.key("國家攝影文化中心（原大阪商船株式會社臺北支店）"), "國家攝影文化中心")
        XCTAssertEqual(KnownPlaces.key("臺北市立 動物園"), KnownPlaces.key("台北市立動物園"))
        XCTAssertEqual(KnownPlaces.key("Taipei 101"), "taipei101")
    }
    func testZoomBandsFollowTheSteps() {
        XCTAssertEqual(MapPlacePriority.band(13.9), 0)
        XCTAssertEqual(MapPlacePriority.band(14), 1)
        XCTAssertEqual(MapPlacePriority.band(15.2), 2)
        XCTAssertEqual(MapPlacePriority.band(15.5), 3)
        XCTAssertEqual(MapPlacePriority.band(17), 4)
        XCTAssertEqual(MapPlacePriority.band(19), 5)
        XCTAssertEqual(MapPlacePriority.band(.nan), 0)
        // Every place becomes eligible exactly at one of the steps the map reloads at.
        for kind in ["museum", "restaurant", "cafe", "shop", "hospital", "lodging", "park", "dentist"] {
            for subclass in ["", "hospital", "clinic", "hotel", "dormitory", "viewpoint"] {
                for english in [nil, "Name"] {
                    if let value = priority(place(kind, subclass, english: english)) {
                        XCTAssertTrue(MapPlacePriority.zoomSteps.contains(value.minimumZoom), "\(kind)/\(subclass)")
                    }
                }
            }
        }
    }
}
