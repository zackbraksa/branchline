import Foundation
import XCTest
@testable import Branchline

final class UpdaterConfigurationTests: XCTestCase {
    private let validInformation: [String: Any] = [
        "BranchlineUpdatesEnabled": true,
        "SUFeedURL": "https://branchline.braksa.xyz/updates/appcast.xml",
        "SUPublicEDKey": Data(repeating: 7, count: 32).base64EncodedString()
    ]

    func testValidReleaseConfigurationEnablesUpdater() {
        let configuration = UpdaterConfiguration.resolve(information: validInformation)

        XCTAssertEqual(configuration?.feedURL.absoluteString, "https://branchline.braksa.xyz/updates/appcast.xml")
        XCTAssertEqual(configuration?.publicKey, validInformation["SUPublicEDKey"] as? String)
    }

    func testUpdaterIsDisabledInTests() {
        XCTAssertNil(UpdaterConfiguration.resolve(information: validInformation, isRunningTests: true))
    }

    func testUpdaterIsDisabledWhenReleaseFlagIsMissingOrFalse() {
        var information = validInformation
        information.removeValue(forKey: "BranchlineUpdatesEnabled")
        XCTAssertNil(UpdaterConfiguration.resolve(information: information))

        information["BranchlineUpdatesEnabled"] = false
        XCTAssertNil(UpdaterConfiguration.resolve(information: information))
    }

    func testUpdaterRejectsNonHTTPSOrMalformedFeedURL() {
        for feedURL in ["http://branchline.braksa.xyz/updates/appcast.xml", "not a URL", "https://"] {
            var information = validInformation
            information["SUFeedURL"] = feedURL
            XCTAssertNil(UpdaterConfiguration.resolve(information: information), "Accepted feed URL: \(feedURL)")
        }
    }

    func testUpdaterRejectsInvalidOrWrongLengthPublicKey() {
        for publicKey in ["not base64", Data(repeating: 1, count: 31).base64EncodedString(), Data(repeating: 1, count: 33).base64EncodedString()] {
            var information = validInformation
            information["SUPublicEDKey"] = publicKey
            XCTAssertNil(UpdaterConfiguration.resolve(information: information), "Accepted public key: \(publicKey)")
        }
    }
}
