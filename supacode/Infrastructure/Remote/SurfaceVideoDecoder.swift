import CoreMedia
import CoreVideo
import Foundation
@preconcurrency import VideoToolbox

@MainActor
@Observable
final class SurfaceVideoDecoder {
  private(set) var isDecoding = false
  private var session: VTDecompressionSession?
  private var formatDescription: CMVideoFormatDescription?

  var onDecodedFrame: ((CVPixelBuffer) -> Void)?

  func configure(sps: Data, pps: Data) throws {
    let spsPointer = Array(sps)
    let ppsPointer = Array(pps)
    let parameterSets: [UnsafePointer<UInt8>] = spsPointer.withUnsafeBufferPointer { spsBuffer in
      ppsPointer.withUnsafeBufferPointer { ppsBuffer in
        [spsBuffer.baseAddress!, ppsBuffer.baseAddress!]
      }
    }
    let parameterSetSizes = [sps.count, pps.count]

    var formatDescription: CMVideoFormatDescription?
    let status = parameterSets.withUnsafeBufferPointer { setsPtr in
      CMVideoFormatDescriptionCreateFromH264ParameterSets(
        allocator: kCFAllocatorDefault,
        parameterSetCount: 2,
        parameterSetPointers: setsPtr.baseAddress!,
        parameterSetSizes: parameterSetSizes,
        nalUnitHeaderLength: 4,
        formatDescriptionOut: &formatDescription
      )
    }
    guard status == noErr, let formatDescription else {
      throw RemoteError.decoderCreationFailed(status)
    }
    self.formatDescription = formatDescription
    try createDecompressionSession(formatDescription: formatDescription)
  }

  func decode(nalData: Data) {
    guard let session, let formatDescription else { return }
    isDecoding = true

    var blockBuffer: CMBlockBuffer?
    nalData.withUnsafeBytes { rawBuffer in
      let ptr = rawBuffer.baseAddress!
      CMBlockBufferCreateWithMemoryBlock(
        allocator: kCFAllocatorDefault,
        memoryBlock: UnsafeMutableRawPointer(mutating: ptr),
        blockLength: nalData.count,
        blockAllocator: kCFAllocatorNull,
        customBlockSource: nil,
        offsetToData: 0,
        dataLength: nalData.count,
        flags: 0,
        blockBufferOut: &blockBuffer
      )
    }
    guard let blockBuffer else { return }

    var sampleBuffer: CMSampleBuffer?
    CMSampleBufferCreateReady(
      allocator: kCFAllocatorDefault,
      dataBuffer: blockBuffer,
      formatDescription: formatDescription,
      sampleCount: 1,
      sampleTimingEntryCount: 0,
      sampleTimingArray: nil,
      sampleSizeEntryCount: 0,
      sampleSizeArray: nil,
      sampleBufferOut: &sampleBuffer
    )
    guard let sampleBuffer else { return }

    VTDecompressionSessionDecodeFrame(
      session,
      sampleBuffer: sampleBuffer,
      flags: [._EnableAsynchronousDecompression],
      infoFlagsOut: nil
    ) { [weak self] status, _, imageBuffer, _, _ in
      guard status == noErr, let imageBuffer else { return }
      Task { @MainActor in
        self?.onDecodedFrame?(imageBuffer)
      }
    }
  }

  func stop() {
    if let session {
      VTDecompressionSessionInvalidate(session)
    }
    session = nil
    formatDescription = nil
    isDecoding = false
  }

  private func createDecompressionSession(
    formatDescription: CMVideoFormatDescription
  ) throws {
    let attributes: [CFString: Any] = [
      kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
      kCVPixelBufferMetalCompatibilityKey: true,
    ]

    var session: VTDecompressionSession?
    let status = VTDecompressionSessionCreate(
      allocator: kCFAllocatorDefault,
      formatDescription: formatDescription,
      decoderSpecification: nil,
      imageBufferAttributes: attributes as CFDictionary,
      outputCallback: nil,
      decompressionSessionOut: &session
    )
    guard status == noErr, let session else {
      throw RemoteError.decoderCreationFailed(status)
    }
    self.session = session
  }
}
