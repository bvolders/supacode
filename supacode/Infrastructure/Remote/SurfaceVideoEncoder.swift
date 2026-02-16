import AppKit
import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

@MainActor
final class SurfaceVideoEncoder {
  let width: Int
  let height: Int
  private(set) var isEncoding = false
  private var session: VTCompressionSession?
  private(set) var parameterSetData: Data?
  private let logger = SupaLogger("Remote")

  var onEncodedFrame: ((Data, Bool) -> Void)?  // (nalData, isKeyFrame)

  init(width: Int, height: Int) throws {
    self.width = width
    self.height = height
    try createSession()
  }

  private func createSession() throws {
    var session: VTCompressionSession?
    let status = VTCompressionSessionCreate(
      allocator: kCFAllocatorDefault,
      width: Int32(width),
      height: Int32(height),
      codecType: kCMVideoCodecType_H264,
      encoderSpecification: nil,
      imageBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey: width,
        kCVPixelBufferHeightKey: height,
      ] as CFDictionary,
      compressedDataAllocator: nil,
      outputCallback: nil,
      refcon: nil,
      compressionSessionOut: &session,
    )
    guard status == noErr, let session else {
      throw RemoteError.encoderCreationFailed(status)
    }

    VTSessionSetProperty(
      session,
      key: kVTCompressionPropertyKey_RealTime,
      value: kCFBooleanTrue,
    )
    VTSessionSetProperty(
      session,
      key: kVTCompressionPropertyKey_ProfileLevel,
      value: kVTProfileLevel_H264_Baseline_AutoLevel,
    )
    VTSessionSetProperty(
      session,
      key: kVTCompressionPropertyKey_AllowFrameReordering,
      value: kCFBooleanFalse,
    )
    VTSessionSetProperty(
      session,
      key: kVTCompressionPropertyKey_MaxKeyFrameInterval,
      value: 60 as CFNumber,
    )
    VTSessionSetProperty(
      session,
      key: kVTCompressionPropertyKey_AverageBitRate,
      value: 1_000_000 as CFNumber,
    )

    VTCompressionSessionPrepareToEncodeFrames(session)
    self.session = session
    extractParameterSets()
  }

  func encode(layer: CALayer) {
    guard let session else { return }

    var pixelBuffer: CVPixelBuffer?
    let status = CVPixelBufferCreate(
      kCFAllocatorDefault,
      width,
      height,
      kCVPixelFormatType_32BGRA,
      [kCVPixelBufferCGImageCompatibilityKey: true] as CFDictionary,
      &pixelBuffer,
    )
    guard status == kCVReturnSuccess, let pixelBuffer else { return }

    CVPixelBufferLockBaseAddress(pixelBuffer, [])
    if let context = CGContext(
      data: CVPixelBufferGetBaseAddress(pixelBuffer),
      width: width,
      height: height,
      bitsPerComponent: 8,
      bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
        | CGBitmapInfo.byteOrder32Little.rawValue,
    ) {
      layer.render(in: context)
    }
    CVPixelBufferUnlockBaseAddress(pixelBuffer, [])

    let timestamp = CMTime(
      value: Int64(CACurrentMediaTime() * 1000),
      timescale: 1000,
    )

    VTCompressionSessionEncodeFrame(
      session,
      imageBuffer: pixelBuffer,
      presentationTimeStamp: timestamp,
      duration: .invalid,
      frameProperties: nil,
      infoFlagsOut: nil,
    ) { [weak self] status, _, sampleBuffer in
      guard status == noErr, let sampleBuffer else { return }
      Task { @MainActor in
        self?.handleEncodedFrame(sampleBuffer)
      }
    }
    isEncoding = true
  }

  func stop() {
    if let session {
      VTCompressionSessionInvalidate(session)
    }
    session = nil
    isEncoding = false
  }

  private func handleEncodedFrame(_ sampleBuffer: CMSampleBuffer) {
    guard let dataBuffer = sampleBuffer.dataBuffer else { return }
    var totalLength = 0
    var dataPointer: UnsafeMutablePointer<CChar>?
    CMBlockBufferGetDataPointer(
      dataBuffer,
      atOffset: 0,
      lengthAtOffsetOut: nil,
      totalLengthOut: &totalLength,
      dataPointerOut: &dataPointer,
    )
    guard let dataPointer, totalLength > 0 else { return }

    let data = Data(bytes: dataPointer, count: totalLength)
    let attachments = CMSampleBufferGetSampleAttachmentsArray(
      sampleBuffer,
      createIfNecessary: false,
    ) as? [[CFString: Any]]
    let isKeyFrame = !(
      attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false
    )

    onEncodedFrame?(data, isKeyFrame)
  }

  private func extractParameterSets() {
    guard let session else { return }

    // Encode a blank frame to force the encoder to produce parameter sets
    var pixelBuffer: CVPixelBuffer?
    let createStatus = CVPixelBufferCreate(
      kCFAllocatorDefault,
      width,
      height,
      kCVPixelFormatType_32BGRA,
      nil,
      &pixelBuffer,
    )
    guard createStatus == kCVReturnSuccess, let pixelBuffer else {
      logger.warning("Failed to create pixel buffer for parameter sets")
      return
    }

    let timestamp = CMTime(value: 0, timescale: 1000)
    var formatDesc: CMFormatDescription?

    VTCompressionSessionEncodeFrame(
      session,
      imageBuffer: pixelBuffer,
      presentationTimeStamp: timestamp,
      duration: .invalid,
      frameProperties: nil,
      infoFlagsOut: nil,
    ) { _, _, sampleBuffer in
      if let sampleBuffer {
        formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer)
      }
    }

    // Flush to ensure the callback fires synchronously
    VTCompressionSessionCompleteFrames(
      session,
      untilPresentationTimeStamp: .invalid,
    )

    guard let formatDesc else {
      logger.warning("Could not obtain format description for parameter sets")
      return
    }

    var parameterData = Data()
    var paramSetCount = 0
    // Get the count of parameter sets from the first call
    _ = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
      formatDesc,
      parameterSetIndex: 0,
      parameterSetPointerOut: nil,
      parameterSetSizeOut: nil,
      parameterSetCountOut: &paramSetCount,
      nalUnitHeaderLengthOut: nil,
    )

    for index in 0..<paramSetCount {
      var parameterSetPointer: UnsafePointer<UInt8>?
      var parameterSetLength = 0
      let status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
        formatDesc,
        parameterSetIndex: index,
        parameterSetPointerOut: &parameterSetPointer,
        parameterSetSizeOut: &parameterSetLength,
        parameterSetCountOut: nil,
        nalUnitHeaderLengthOut: nil,
      )
      guard status == noErr, let parameterSetPointer else { continue }
      // Write Annex B start code before each parameter set
      parameterData.append(contentsOf: [0x00, 0x00, 0x00, 0x01])
      parameterData.append(
        parameterSetPointer,
        count: parameterSetLength,
      )
    }

    if !parameterData.isEmpty {
      parameterSetData = parameterData
      logger.debug(
        "Extracted \(paramSetCount) H.264 parameter sets"
      )
    }
  }
}

enum RemoteError: Error {
  case encoderCreationFailed(OSStatus)
  case decoderCreationFailed(OSStatus)
}
