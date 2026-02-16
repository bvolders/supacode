import AppKit
import CoreVideo
import MetalKit
import SwiftUI

struct RemoteTerminalView: NSViewRepresentable {
  let decoder: SurfaceVideoDecoder
  var onInputEvent: ((RemoteInputEvent) -> Void)?

  func makeNSView(context: Context) -> RemoteTerminalMTKView {
    let view = RemoteTerminalMTKView()
    view.isPaused = true
    view.enableSetNeedsDisplay = true
    view.onInputEvent = onInputEvent
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
  var onInputEvent: ((RemoteInputEvent) -> Void)?
  private var textureCache: CVMetalTextureCache?
  private var commandQueue: MTLCommandQueue?

  override var acceptsFirstResponder: Bool { true }

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

  // MARK: - Input Handling

  override func keyDown(with event: NSEvent) {
    let remoteEvent = RemoteKeyEvent(
      keyCode: event.keyCode,
      characters: event.characters,
      modifiers: Self.remoteModifiers(from: event),
      isKeyDown: true,
    )
    onInputEvent?(.key(remoteEvent))
  }

  override func keyUp(with event: NSEvent) {
    let remoteEvent = RemoteKeyEvent(
      keyCode: event.keyCode,
      characters: event.characters,
      modifiers: Self.remoteModifiers(from: event),
      isKeyDown: false,
    )
    onInputEvent?(.key(remoteEvent))
  }

  override func mouseDown(with event: NSEvent) {
    let point = convert(event.locationInWindow, from: nil)
    let remoteEvent = RemoteMouseEvent(
      x: point.x,
      y: point.y,
      button: event.buttonNumber,
      isDown: true,
      modifiers: Self.remoteModifiers(from: event),
    )
    onInputEvent?(.mouse(remoteEvent))
  }

  override func mouseUp(with event: NSEvent) {
    let point = convert(event.locationInWindow, from: nil)
    let remoteEvent = RemoteMouseEvent(
      x: point.x,
      y: point.y,
      button: event.buttonNumber,
      isDown: false,
      modifiers: Self.remoteModifiers(from: event),
    )
    onInputEvent?(.mouse(remoteEvent))
  }

  private static func remoteModifiers(from event: NSEvent) -> Set<RemoteModifier> {
    var mods = Set<RemoteModifier>()
    if event.modifierFlags.contains(.shift) { mods.insert(.shift) }
    if event.modifierFlags.contains(.control) { mods.insert(.control) }
    if event.modifierFlags.contains(.option) { mods.insert(.option) }
    if event.modifierFlags.contains(.command) { mods.insert(.command) }
    return mods
  }

  // MARK: - Rendering

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
