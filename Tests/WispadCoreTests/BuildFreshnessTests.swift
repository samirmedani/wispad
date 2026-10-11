import Foundation
import XCTest
@testable import WispadCore

final class BuildFreshnessTests: XCTestCase {
    private func freshness(_ json: String, status: Int = 200) -> BuildFreshness {
        BuildFreshnessCheck.freshness(statusCode: status, data: Data(json.utf8))
    }

    func testUpToDateWhenMainHasNoNewCommit() {
        XCTAssertEqual(freshness(#"{"status":"identical","ahead_by":0,"behind_by":0}"#), .upToDate)
        // Version compilée depuis une branche en avance sur main : rien à rattraper.
        XCTAssertEqual(freshness(#"{"status":"behind","ahead_by":0,"behind_by":3}"#), .upToDate)
    }

    func testBehindCountsCommitsOfMainMissingFromTheBuild() {
        XCTAssertEqual(freshness(#"{"status":"ahead","ahead_by":12,"behind_by":0}"#), .behind(12))
        XCTAssertEqual(freshness(#"{"status":"diverged","ahead_by":4,"behind_by":2}"#), .behind(4))
    }

    func testSingleCommitBehind() {
        XCTAssertEqual(freshness(#"{"status":"ahead","ahead_by":1,"behind_by":0}"#), .behind(1))
    }

    func testPrivateRepositoryOrUnknownCommitShowsOnlyTheVersion() {
        XCTAssertEqual(freshness(#"{"message":"Not Found","status":"404"}"#, status: 404), .unknown)
        XCTAssertEqual(freshness(#"{"message":"rate limit exceeded"}"#, status: 403), .unknown)
        XCTAssertEqual(freshness("", status: 0), .unknown)
    }

    func testUnreadableResponseShowsOnlyTheVersion() {
        XCTAssertEqual(freshness("<html>erreur</html>"), .unknown)
        XCTAssertEqual(freshness(#"{"status":"ahead"}"#), .unknown)
        XCTAssertEqual(freshness(#"{"ahead_by":"12"}"#), .unknown)
        XCTAssertEqual(freshness(#"{"ahead_by":true}"#), .unknown)
        XCTAssertEqual(freshness(#"{"ahead_by":-1}"#), .unknown)
        XCTAssertEqual(freshness("[]"), .unknown)
    }

    func testBuildCommitMustBeAGitHash() {
        XCTAssertEqual(BuildFreshnessCheck.shortCommit("0123ABCdef4567"), "0123abc")
        XCTAssertEqual(BuildFreshnessCheck.shortCommit(" 0123abc\n"), "0123abc")
        XCTAssertNil(BuildFreshnessCheck.shortCommit(nil))
        XCTAssertNil(BuildFreshnessCheck.shortCommit(""))
        XCTAssertNil(BuildFreshnessCheck.shortCommit("012345"))
        XCTAssertNil(BuildFreshnessCheck.shortCommit("$(WISPAD_BUILD_COMMIT)"))
        XCTAssertNil(BuildFreshnessCheck.shortCommit("main...x"))
    }

    func testCompareURLTargetsThePublicRepository() {
        XCTAssertEqual(
            BuildFreshnessCheck.compareURL(commit: "0123abcdef")?.absoluteString,
            "https://api.github.com/repos/samirmedani/wispad/compare/0123abc...main"
        )
        XCTAssertNil(BuildFreshnessCheck.compareURL(commit: "../../user"))
    }
}
