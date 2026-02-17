import Testing

@testable import supacode

@MainActor
struct AdaptiveBitrateControllerTests {
  @Test func initialBitrateIsDefault() {
    let controller = AdaptiveBitrateController()
    #expect(controller.currentBitrate == 1_000_000)
    #expect(controller.currentFrameInterval == 1.0 / 30.0)
  }

  @Test func bitrateDecreasesWhenCongested() {
    let controller = AdaptiveBitrateController()
    controller.pendingSendCount = 4
    controller.evaluate()
    #expect(controller.currentBitrate == 750_000)
  }

  @Test func bitrateDoesNotDropBelowMinimum() {
    let controller = AdaptiveBitrateController()
    controller.currentBitrate = 200_000
    controller.pendingSendCount = 5
    controller.evaluate()
    #expect(controller.currentBitrate == 200_000)
  }

  @Test func bitrateIncreasesAfterConsecutiveLowPending() {
    let controller = AdaptiveBitrateController()
    controller.currentBitrate = 500_000
    controller.pendingSendCount = 0
    controller.evaluate()
    controller.evaluate()
    controller.evaluate()
    #expect(controller.currentBitrate == 625_000)
  }

  @Test func bitrateDoesNotExceedMaximum() {
    let controller = AdaptiveBitrateController()
    controller.currentBitrate = 5_000_000
    controller.pendingSendCount = 0
    controller.evaluate()
    controller.evaluate()
    controller.evaluate()
    #expect(controller.currentBitrate == 5_000_000)
  }

  @Test func frameRateHalvesOnSevereCongestion() {
    let controller = AdaptiveBitrateController()
    controller.pendingSendCount = 9
    controller.evaluate()
    #expect(controller.currentFrameInterval == 1.0 / 15.0)
  }

  @Test func frameRateRestoresAfterConsecutiveLowPending() {
    let controller = AdaptiveBitrateController()
    controller.currentFrameInterval = 1.0 / 15.0
    controller.pendingSendCount = 0
    for _ in 0..<5 {
      controller.evaluate()
    }
    #expect(controller.currentFrameInterval == 1.0 / 30.0)
  }

  @Test func frameRateDoesNotDropBelowMinimum() {
    let controller = AdaptiveBitrateController()
    controller.currentFrameInterval = 1.0 / 10.0
    controller.pendingSendCount = 9
    controller.evaluate()
    #expect(controller.currentFrameInterval == 1.0 / 10.0)
  }
}
