import AppKit
import Foundation

@MainActor
@Observable
final class SurfaceCaptureOrchestrator {
  private var encoders: [String: SurfaceVideoEncoder] = [:]  // worktreeID → encoder
  private var captureTimers: [String: Timer] = [:]
  private let server: WebSocketServer
  private let logger = SupaLogger("Remote")

  init(server: WebSocketServer) {
    self.server = server
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

    encoder.onEncodedFrame = { [weak self] data, isKeyFrame in
      self?.server.send(type: .videoFrame, payload: data)
    }
    encoders[worktreeID] = encoder

    // Start a 30fps timer for frame capture
    let timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self, weak surface] _ in
      Task { @MainActor in
        guard let surface, let layer = surface.layer else { return }
        self?.encoders[worktreeID]?.encode(layer: layer)
      }
    }
    captureTimers[worktreeID] = timer
    logger.info("Started streaming worktree \(worktreeID)")
  }

  func stopStreaming(worktreeID: String) {
    captureTimers[worktreeID]?.invalidate()
    captureTimers.removeValue(forKey: worktreeID)
    encoders[worktreeID]?.stop()
    encoders.removeValue(forKey: worktreeID)
    logger.info("Stopped streaming worktree \(worktreeID)")
  }

  func stopAll() {
    let worktreeIDs = Array(encoders.keys)
    for id in worktreeIDs {
      stopStreaming(worktreeID: id)
    }
  }
}
