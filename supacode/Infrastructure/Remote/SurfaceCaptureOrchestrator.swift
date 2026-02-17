import AppKit
@preconcurrency import Foundation

@MainActor
@Observable
final class SurfaceCaptureOrchestrator {
  private var encoders: [String: SurfaceVideoEncoder] = [:]  // worktreeID → encoder
  private var captureTimers: [String: Timer] = [:]
  private var captureSurfaces: [String: NSView] = [:]
  private let server: WebSocketServer
  private let bitrateController = AdaptiveBitrateController()
  private var evaluationTimer: Timer?
  private let logger = SupaLogger("Remote")

  init(server: WebSocketServer) {
    self.server = server

    bitrateController.onBitrateChanged = { [weak self] bps in
      self?.updateAllEncoderBitrates(bps)
    }
    bitrateController.onFrameIntervalChanged = { [weak self] interval in
      self?.updateAllCaptureTimers(interval)
    }
  }

  func startStreaming(worktreeID: String, surface: NSView) throws {
    guard encoders[worktreeID] == nil else { return }
    guard surface.layer != nil else {
      logger.warning("No layer found for worktree \(worktreeID)")
      return
    }

    let bounds = surface.bounds
    let encoder = try SurfaceVideoEncoder(
      width: Int(bounds.width),
      height: Int(bounds.height),
    )

    // Send parameter sets to client first
    if let parameterSets = encoder.parameterSetData {
      server.send(type: .videoConfig, payload: parameterSets)
    }

    encoder.onEncodedFrame = { [weak self] data, _ in
      self?.server.send(type: .videoFrame, payload: data)
    }
    encoders[worktreeID] = encoder
    captureSurfaces[worktreeID] = surface

    startCaptureTimer(
      worktreeID: worktreeID,
      surface: surface,
      interval: bitrateController.currentFrameInterval,
    )
    startEvaluationTimerIfNeeded()
    logger.info("Started streaming worktree \(worktreeID)")
  }

  func stopStreaming(worktreeID: String) {
    captureTimers[worktreeID]?.invalidate()
    captureTimers.removeValue(forKey: worktreeID)
    captureSurfaces.removeValue(forKey: worktreeID)
    encoders[worktreeID]?.stop()
    encoders.removeValue(forKey: worktreeID)

    if encoders.isEmpty {
      stopEvaluationTimer()
    }
    logger.info("Stopped streaming worktree \(worktreeID)")
  }

  func stopAll() {
    let worktreeIDs = Array(encoders.keys)
    for id in worktreeIDs {
      stopStreaming(worktreeID: id)
    }
    stopEvaluationTimer()
  }

  // MARK: - Capture Timer Management

  private func startCaptureTimer(worktreeID: String, surface: NSView, interval: TimeInterval) {
    captureTimers[worktreeID]?.invalidate()
    let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self, weak surface] _ in
      Task { @MainActor in
        guard let surface, let layer = surface.layer else { return }
        self?.encoders[worktreeID]?.encode(layer: layer)
      }
    }
    captureTimers[worktreeID] = timer
  }

  private func updateAllCaptureTimers(_ interval: TimeInterval) {
    for (worktreeID, surface) in captureSurfaces {
      startCaptureTimer(worktreeID: worktreeID, surface: surface, interval: interval)
    }
    logger.debug("All capture timers updated to interval \(interval)")
  }

  private func updateAllEncoderBitrates(_ bps: Int) {
    for encoder in encoders.values {
      encoder.updateBitrate(bps)
    }
    logger.debug("All encoder bitrates updated to \(bps)")
  }

  // MARK: - Evaluation Timer

  private func startEvaluationTimerIfNeeded() {
    guard evaluationTimer == nil else { return }
    evaluationTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
      Task { @MainActor in
        guard let self else { return }
        self.bitrateController.pendingSendCount = self.server.pendingSendCount
        self.bitrateController.evaluate()
      }
    }
  }

  private func stopEvaluationTimer() {
    evaluationTimer?.invalidate()
    evaluationTimer = nil
  }
}
