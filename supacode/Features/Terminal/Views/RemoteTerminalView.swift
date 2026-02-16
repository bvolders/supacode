import CoreVideo
import MetalKit
import SwiftUI

struct RemoteTerminalView: NSViewRepresentable {
  let decoder: SurfaceVideoDecoder

  func makeNSView(context: Context) -> RemoteTerminalMTKView {
    let view = RemoteTerminalMTKView()
    view.isPaused = true
    view.enableSetNeedsDisplay = true
    decoder.onDecodedFrame = { [weak view] pixelBuffer in
      view?.currentPixelBuffer = pixelBuffer
      view?.needsDisplay = true
    }
    return view
  }

  func updateNSView(_ nsView: RemoteTerminalMTKView, context: Context) {}
}

final class RemoteTerminalMTKView: MTKView {
  var currentPixelBuffer: CVPixelBuffer?
  private var textureCache: CVMetalTextureCache?
  private var commandQueue: MTLCommandQueue?

  override init(frame frameRect: CGRect, device: MTLDevice?) {
    let device = device ?? MTLCreateSystemDefaultDevice()
    super.init(frame: frameRect, device: device)
    setup()
  }

  required init(coder: NSCoder) {
    super.init(coder: coder)
    self.device = MTLCreateSystemDefaultDevice()
    setup()
  }

  private func setup() {
    guard let device else { return }
    commandQueue = device.makeCommandQueue()
    CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &textureCache)
    framebufferOnly = false
    colorPixelFormat = .bgra8Unorm
  }

  override func draw(_ dirtyRect: NSRect) {
    guard
      let device,
      let commandQueue,
      let currentDrawable,
      let pixelBuffer = currentPixelBuffer,
      let textureCache
    else { return }

    let width = CVPixelBufferGetWidth(pixelBuffer)
    let height = CVPixelBufferGetHeight(pixelBuffer)

    var cvTexture: CVMetalTexture?
    CVMetalTextureCacheCreateTextureFromImage(
      kCFAllocatorDefault,
      textureCache,
      pixelBuffer,
      nil,
      .bgra8Unorm,
      width,
      height,
      0,
      &cvTexture,
    )
    guard let cvTexture, let sourceTexture = CVMetalTextureGetTexture(cvTexture) else { return }

    let commandBuffer = commandQueue.makeCommandBuffer()
    let blitEncoder = commandBuffer?.makeBlitCommandEncoder()
    let destTexture = currentDrawable.texture

    let sourceSize = MTLSize(
      width: min(width, destTexture.width),
      height: min(height, destTexture.height),
      depth: 1,
    )
    blitEncoder?.copy(
      from: sourceTexture,
      sourceSlice: 0,
      sourceLevel: 0,
      sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
      sourceSize: sourceSize,
      to: destTexture,
      destinationSlice: 0,
      destinationLevel: 0,
      destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0),
    )
    blitEncoder?.endEncoding()
    commandBuffer?.present(currentDrawable)
    commandBuffer?.commit()
  }
}
