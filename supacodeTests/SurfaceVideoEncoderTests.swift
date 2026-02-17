import CoreMedia
import Foundation
import Testing
import VideoToolbox

@testable import supacode

@MainActor
struct SurfaceVideoEncoderTests {
  @Test func encoderInitializesWithDimensions() throws {
    let encoder = try SurfaceVideoEncoder(width: 800, height: 600)
    #expect(encoder.width == 800)
    #expect(encoder.height == 600)
    #expect(encoder.isEncoding == false)
    encoder.stop()
  }

  @Test func encoderProducesParameterSets() throws {
    let encoder = try SurfaceVideoEncoder(width: 800, height: 600)
    let parameterSets = encoder.parameterSetData
    // Parameter sets (SPS/PPS) are available after session creation
    #expect(parameterSets != nil)
    encoder.stop()
  }
}
