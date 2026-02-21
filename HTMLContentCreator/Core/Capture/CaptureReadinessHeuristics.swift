import Foundation

struct CaptureDOMStabilitySample {
    let ready: Bool
    let nodes: Int
    let textLength: Int
    let mediaCount: Int
    let imagesTotal: Int
    let imagesLoaded: Int
    let mutationIdleMilliseconds: Int

    var imagesMostlyLoaded: Bool {
        if imagesTotal == 0 {
            return true
        }

        let ratio = Double(imagesLoaded) / Double(imagesTotal)
        return ratio >= 0.92
    }

    var hasSubstantialContent: Bool {
        if nodes >= 60 { return true }
        if textLength >= 180 { return true }
        if mediaCount >= 6 { return true }
        return false
    }
}

enum CaptureReadinessHeuristics {
    static func isSampleReadyForStabilityCheck(
        _ sample: CaptureDOMStabilitySample,
        minimumMutationIdleMilliseconds: Int
    ) -> Bool {
        guard sample.ready else { return false }
        guard sample.hasSubstantialContent else { return false }
        guard sample.mutationIdleMilliseconds >= minimumMutationIdleMilliseconds else { return false }
        guard sample.imagesMostlyLoaded else { return false }
        return true
    }

    static func isStablePair(
        previous: CaptureDOMStabilitySample,
        current: CaptureDOMStabilitySample
    ) -> Bool {
        let nodeDelta = abs(current.nodes - previous.nodes)
        let textDelta = abs(current.textLength - previous.textLength)
        let mediaDelta = abs(current.mediaCount - previous.mediaCount)
        let loadedImageDelta = abs(current.imagesLoaded - previous.imagesLoaded)

        return nodeDelta <= 24 &&
            textDelta <= 90 &&
            mediaDelta <= 2 &&
            loadedImageDelta <= 1
    }
}
