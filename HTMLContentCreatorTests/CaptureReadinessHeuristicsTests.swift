import XCTest
@testable import HTMLContentCreator

final class CaptureReadinessHeuristicsTests: XCTestCase {
    func testSampleReadyRequiresMutationIdleAndLoadedImages() {
        let sample = CaptureDOMStabilitySample(
            ready: true,
            nodes: 300,
            textLength: 2400,
            mediaCount: 10,
            imagesTotal: 8,
            imagesLoaded: 8,
            mutationIdleMilliseconds: 900
        )

        XCTAssertTrue(
            CaptureReadinessHeuristics.isSampleReadyForStabilityCheck(
                sample,
                minimumMutationIdleMilliseconds: 700
            )
        )
    }

    func testSampleNotReadyWhenImagesStillLoading() {
        let sample = CaptureDOMStabilitySample(
            ready: true,
            nodes: 300,
            textLength: 2400,
            mediaCount: 10,
            imagesTotal: 8,
            imagesLoaded: 2,
            mutationIdleMilliseconds: 900
        )

        XCTAssertFalse(
            CaptureReadinessHeuristics.isSampleReadyForStabilityCheck(
                sample,
                minimumMutationIdleMilliseconds: 700
            )
        )
    }

    func testStablePairDetectsMinorDeltasAsStable() {
        let previous = CaptureDOMStabilitySample(
            ready: true,
            nodes: 560,
            textLength: 5600,
            mediaCount: 18,
            imagesTotal: 12,
            imagesLoaded: 11,
            mutationIdleMilliseconds: 840
        )
        let current = CaptureDOMStabilitySample(
            ready: true,
            nodes: 568,
            textLength: 5644,
            mediaCount: 18,
            imagesTotal: 12,
            imagesLoaded: 12,
            mutationIdleMilliseconds: 940
        )

        XCTAssertTrue(CaptureReadinessHeuristics.isStablePair(previous: previous, current: current))
    }

    func testStablePairDetectsLargeDeltasAsUnstable() {
        let previous = CaptureDOMStabilitySample(
            ready: true,
            nodes: 120,
            textLength: 800,
            mediaCount: 3,
            imagesTotal: 4,
            imagesLoaded: 2,
            mutationIdleMilliseconds: 120
        )
        let current = CaptureDOMStabilitySample(
            ready: true,
            nodes: 360,
            textLength: 2600,
            mediaCount: 14,
            imagesTotal: 10,
            imagesLoaded: 10,
            mutationIdleMilliseconds: 1200
        )

        XCTAssertFalse(CaptureReadinessHeuristics.isStablePair(previous: previous, current: current))
    }
}
