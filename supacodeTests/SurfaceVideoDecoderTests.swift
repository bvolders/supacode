import Foundation
import Testing

@testable import supacode

@MainActor
struct SurfaceVideoDecoderTests {
  @Test func decoderInitializes() {
    let decoder = SurfaceVideoDecoder()
    #expect(decoder.isDecoding == false)
  }
}
