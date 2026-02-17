import Foundation

@MainActor
@Observable
final class AdaptiveBitrateController {
  static let minBitrate = 200_000
  static let maxBitrate = 5_000_000
  static let defaultBitrate = 1_000_000
  static let defaultFrameInterval: TimeInterval = 1.0 / 30.0
  static let minFrameInterval: TimeInterval = 1.0 / 10.0

  private static let congestedThreshold = 3
  private static let severeCongestedThreshold = 8
  private static let increaseAfterConsecutiveIdle = 3
  private static let frameRestoreAfterConsecutiveIdle = 5

  var currentBitrate: Int = AdaptiveBitrateController.defaultBitrate
  var currentFrameInterval: TimeInterval = AdaptiveBitrateController.defaultFrameInterval
  var pendingSendCount = 0

  private var consecutiveIdleEvaluations = 0
  private let logger = SupaLogger("Remote")

  var onBitrateChanged: ((Int) -> Void)?
  var onFrameIntervalChanged: ((TimeInterval) -> Void)?

  func evaluate() {
    if pendingSendCount > Self.severeCongestedThreshold {
      decreaseBitrate()
      halveFrameRate()
      consecutiveIdleEvaluations = 0
    } else if pendingSendCount > Self.congestedThreshold {
      decreaseBitrate()
      consecutiveIdleEvaluations = 0
    } else if pendingSendCount == 0 {
      consecutiveIdleEvaluations += 1
      if consecutiveIdleEvaluations >= Self.frameRestoreAfterConsecutiveIdle {
        restoreFrameRate()
      }
      if consecutiveIdleEvaluations >= Self.increaseAfterConsecutiveIdle {
        increaseBitrate()
      }
    } else {
      consecutiveIdleEvaluations = 0
    }
  }

  private func decreaseBitrate() {
    let newBitrate = max(currentBitrate * 3 / 4, Self.minBitrate)
    if newBitrate != currentBitrate {
      currentBitrate = newBitrate
      logger.debug("Bitrate decreased to \(currentBitrate)")
      onBitrateChanged?(currentBitrate)
    }
  }

  private func increaseBitrate() {
    let newBitrate = min(currentBitrate * 5 / 4, Self.maxBitrate)
    if newBitrate != currentBitrate {
      currentBitrate = newBitrate
      logger.debug("Bitrate increased to \(currentBitrate)")
      onBitrateChanged?(currentBitrate)
    }
  }

  private func halveFrameRate() {
    let newInterval = min(currentFrameInterval * 2, Self.minFrameInterval)
    if newInterval != currentFrameInterval {
      currentFrameInterval = newInterval
      logger.debug("Frame interval increased to \(currentFrameInterval)")
      onFrameIntervalChanged?(currentFrameInterval)
    }
  }

  private func restoreFrameRate() {
    if currentFrameInterval != Self.defaultFrameInterval {
      currentFrameInterval = Self.defaultFrameInterval
      logger.debug("Frame interval restored to \(currentFrameInterval)")
      onFrameIntervalChanged?(currentFrameInterval)
    }
  }
}
