#if os(iOS)
import XCTest
@testable import ColumbaApp

@available(iOS 17.0, *)
final class MapStyleURLTests: XCTestCase {

    func testStyleURL_lightMode() {
        XCTAssertEqual(
            mapStyleURL(forDarkMode: false).absoluteString,
            "https://tiles.openfreemap.org/styles/liberty"
        )
    }

    func testStyleURL_darkMode() {
        XCTAssertEqual(
            mapStyleURL(forDarkMode: true).absoluteString,
            "https://tiles.openfreemap.org/styles/dark"
        )
    }
}
#endif
