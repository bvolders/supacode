# Remote Control — Phase 4 Polish Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add adaptive bitrate, TLS encryption with pairing code auth, and manual host:port connection support to the remote control feature.

**Architecture:** Three independent enhancements: (1) `AdaptiveBitrateController` monitors WebSocket send-queue depth and adjusts encoder bitrate/frame rate, (2) `TLSCertificateManager` + protocol changes add encrypted connections with pairing code verification, (3) `connectToAddress` action enables manual host:port entry bypassing Bonjour.

**Tech Stack:** Network.framework (NWProtocolTLS), VideoToolbox (VTSessionSetProperty), Security.framework (SecKey, SecCertificate), TCA, SwiftUI

**Design doc:** `docs/plans/2026-02-17-remote-polish-design.md`

---

## Task 25: Adaptive Bitrate Controller

### Task 25a: AdaptiveBitrateController — Core Decision Logic

**Files:**
- Create: `supacode/Infrastructure/Remote/AdaptiveBitrateController.swift`
- Create: `supacodeTests/AdaptiveBitrateControllerTests.swift`

**Step 1: Write the failing tests**

Create test file:
- Create: `supacodeTests/AdaptiveBitrateControllerTests.swift`

```swift
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
```

**Step 2: Run test to verify it fails**

```bash
xcodebuild test -project supacode.xcodeproj -scheme supacode -destination "platform=macOS" \
  -only-testing:supacodeTests/AdaptiveBitrateControllerTests \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" -skipMacroValidation
```

Expected: FAIL — `AdaptiveBitrateController` not found

**Step 3: Write AdaptiveBitrateController.swift**

```swift
import Foundation

@MainActor
@Observable
final class AdaptiveBitrateController {
  static let minBitrate = 200_000
  static let maxBitrate = 5_000_000
  static let defaultBitrate = 1_000_000
  static let defaultFrameInterval: TimeInterval = 1.0 / 30.0
  static let minFrameInterval: TimeInterval = 1.0 / 10.0  // 10 fps floor

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
      // Severe congestion: reduce bitrate AND halve frame rate
      decreaseBitrate()
      halveFrameRate()
      consecutiveIdleEvaluations = 0
    } else if pendingSendCount > Self.congestedThreshold {
      // Moderate congestion: reduce bitrate only
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
```

**Step 4: Run test to verify it passes**

```bash
xcodebuild test -project supacode.xcodeproj -scheme supacode -destination "platform=macOS" \
  -only-testing:supacodeTests/AdaptiveBitrateControllerTests \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" -skipMacroValidation
```

Expected: PASS

**Step 5: Commit**

```bash
git add supacode/Infrastructure/Remote/AdaptiveBitrateController.swift supacodeTests/AdaptiveBitrateControllerTests.swift
git commit -m "feat(remote): add AdaptiveBitrateController with send-queue monitoring"
```

---

### Task 25b: Wire Pending Send Tracking into WebSocketServer

**Files:**
- Modify: `supacode/Infrastructure/Remote/WebSocketServer.swift`

**Step 1: Add pending send count to WebSocketServer**

In `WebSocketServer.swift`, add a `pendingSendCount` property and update the `send` method to track pending sends.

Add after `var onMessageReceived`:

```swift
private(set) var pendingSendCount = 0
```

Replace the `send(type:payload:)` method body to track pending sends:

```swift
func send(type: RemoteMessageType, payload: Data) {
  guard let connection else { return }
  var frame = Self.encodeFrameHeader(type: type, payloadLength: payload.count)
  frame.append(payload)
  let metadata = NWProtocolWebSocket.Metadata(
    opCode: type == .videoFrame || type == .videoConfig ? .binary : .text,
  )
  let context = NWConnection.ContentContext(
    identifier: "remote",
    metadata: [metadata],
  )
  pendingSendCount += 1
  connection.send(
    content: frame,
    contentContext: context,
    isComplete: true,
    completion: .contentProcessed { [weak self] error in
      Task { @MainActor in
        self?.pendingSendCount -= 1
        if let error {
          self?.logger.warning("Send error: \(error)")
        }
      }
    },
  )
}
```

**Step 2: Build to verify compilation**

```bash
make build-app
```

Expected: BUILD SUCCEEDED

**Step 3: Commit**

```bash
git add supacode/Infrastructure/Remote/WebSocketServer.swift
git commit -m "feat(remote): add pending send count tracking to WebSocketServer"
```

---

### Task 25c: Add Dynamic Bitrate to SurfaceVideoEncoder

**Files:**
- Modify: `supacode/Infrastructure/Remote/SurfaceVideoEncoder.swift`

**Step 1: Add updateBitrate method**

Add this method to `SurfaceVideoEncoder` after the `stop()` method:

```swift
func updateBitrate(_ bps: Int) {
  guard let session else { return }
  let status = VTSessionSetProperty(
    session,
    key: kVTCompressionPropertyKey_AverageBitRate,
    value: bps as CFNumber,
  )
  if status != noErr {
    logger.warning("Failed to update bitrate to \(bps): \(status)")
  }
}
```

**Step 2: Build to verify compilation**

```bash
make build-app
```

Expected: BUILD SUCCEEDED

**Step 3: Commit**

```bash
git add supacode/Infrastructure/Remote/SurfaceVideoEncoder.swift
git commit -m "feat(remote): add dynamic bitrate adjustment to SurfaceVideoEncoder"
```

---

### Task 25d: Wire AdaptiveBitrateController into SurfaceCaptureOrchestrator

**Files:**
- Modify: `supacode/Infrastructure/Remote/SurfaceCaptureOrchestrator.swift`

**Step 1: Add the controller and wire frame interval changes**

Add `bitrateController` property and an evaluation timer. Wire the controller's callbacks to update encoders and capture timers.

Replace the full `SurfaceCaptureOrchestrator` class with:

```swift
import AppKit
import Foundation

@MainActor
@Observable
final class SurfaceCaptureOrchestrator {
  private var encoders: [String: SurfaceVideoEncoder] = [:]  // worktreeID → encoder
  private var captureTimers: [String: Timer] = [:]
  private var captureSurfaces: [String: NSView] = [:]
  private let server: WebSocketServer
  private let bitrateController: AdaptiveBitrateController
  private var evaluationTimer: Timer?
  private let logger = SupaLogger("Remote")

  init(server: WebSocketServer) {
    self.server = server
    self.bitrateController = AdaptiveBitrateController()

    bitrateController.onBitrateChanged = { [weak self] bps in
      self?.updateAllEncoderBitrates(bps)
    }
    bitrateController.onFrameIntervalChanged = { [weak self] interval in
      self?.updateAllCaptureTimers(interval)
    }

    evaluationTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
      Task { @MainActor in
        guard let self else { return }
        self.bitrateController.pendingSendCount = self.server.pendingSendCount
        self.bitrateController.evaluate()
      }
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

    encoder.onEncodedFrame = { [weak self] data, isKeyFrame in
      self?.server.send(type: .videoFrame, payload: data)
    }
    encoders[worktreeID] = encoder
    captureSurfaces[worktreeID] = surface

    // Start capture timer at current interval
    startCaptureTimer(
      worktreeID: worktreeID,
      surface: surface,
      interval: bitrateController.currentFrameInterval,
    )
    logger.info("Started streaming worktree \(worktreeID)")
  }

  func stopStreaming(worktreeID: String) {
    captureTimers[worktreeID]?.invalidate()
    captureTimers.removeValue(forKey: worktreeID)
    captureSurfaces.removeValue(forKey: worktreeID)
    encoders[worktreeID]?.stop()
    encoders.removeValue(forKey: worktreeID)
    logger.info("Stopped streaming worktree \(worktreeID)")
  }

  func stopAll() {
    evaluationTimer?.invalidate()
    evaluationTimer = nil
    let worktreeIDs = Array(encoders.keys)
    for id in worktreeIDs {
      stopStreaming(worktreeID: id)
    }
  }

  private func startCaptureTimer(
    worktreeID: String,
    surface: NSView,
    interval: TimeInterval
  ) {
    captureTimers[worktreeID]?.invalidate()
    let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) {
      [weak self, weak surface] _ in
      Task { @MainActor in
        guard let surface, let layer = surface.layer else { return }
        self?.encoders[worktreeID]?.encode(layer: layer)
      }
    }
    captureTimers[worktreeID] = timer
  }

  private func updateAllEncoderBitrates(_ bps: Int) {
    for (_, encoder) in encoders {
      encoder.updateBitrate(bps)
    }
  }

  private func updateAllCaptureTimers(_ interval: TimeInterval) {
    for (worktreeID, surface) in captureSurfaces {
      startCaptureTimer(worktreeID: worktreeID, surface: surface, interval: interval)
    }
  }
}
```

**Step 2: Build to verify compilation**

```bash
make build-app
```

Expected: BUILD SUCCEEDED

**Step 3: Commit**

```bash
git add supacode/Infrastructure/Remote/SurfaceCaptureOrchestrator.swift
git commit -m "feat(remote): wire AdaptiveBitrateController into capture orchestrator"
```

---

## Task 26: TLS + Pairing Code

### Task 26a: TLSCertificateManager

**Files:**
- Create: `supacode/Infrastructure/Remote/TLSCertificateManager.swift`
- Create: `supacodeTests/TLSCertificateManagerTests.swift`

**Step 1: Write the failing tests**

```swift
import Security
import Testing

@testable import supacode

@MainActor
struct TLSCertificateManagerTests {
  @Test func keychainLabelIsCorrect() {
    #expect(TLSCertificateManager.keychainLabel == "com.supacode.remote-tls")
  }

  @Test func generatesSelfSignedCertificate() throws {
    let manager = TLSCertificateManager()
    let identity = try manager.loadOrCreateIdentity()
    // Verify we got a valid identity
    var certificate: SecCertificate?
    let status = SecIdentityCopyCertificate(identity, &certificate)
    #expect(status == errSecSuccess)
    #expect(certificate != nil)
    // Clean up test cert
    manager.deleteIdentity()
  }

  @Test func reusesExistingCertificate() throws {
    let manager = TLSCertificateManager()
    let identity1 = try manager.loadOrCreateIdentity()
    let identity2 = try manager.loadOrCreateIdentity()
    // Both should return successfully (same underlying cert)
    var cert1: SecCertificate?
    var cert2: SecCertificate?
    SecIdentityCopyCertificate(identity1, &cert1)
    SecIdentityCopyCertificate(identity2, &cert2)
    #expect(cert1 != nil)
    #expect(cert2 != nil)
    manager.deleteIdentity()
  }
}
```

**Step 2: Run test — expected FAIL**

**Step 3: Write TLSCertificateManager.swift**

```swift
import Foundation
import Security

@MainActor
final class TLSCertificateManager {
  static let keychainLabel = "com.supacode.remote-tls"
  private let logger = SupaLogger("Remote")

  func loadOrCreateIdentity() throws -> SecIdentity {
    if let existing = loadExistingIdentity() {
      return existing
    }
    return try createSelfSignedIdentity()
  }

  func deleteIdentity() {
    let query: [CFString: Any] = [
      kSecClass: kSecClassIdentity,
      kSecAttrLabel: Self.keychainLabel,
    ]
    SecItemDelete(query as CFDictionary)
  }

  private func loadExistingIdentity() -> SecIdentity? {
    let query: [CFString: Any] = [
      kSecClass: kSecClassIdentity,
      kSecAttrLabel: Self.keychainLabel,
      kSecReturnRef: true,
    ]
    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    guard status == errSecSuccess else { return nil }
    return (item as! SecIdentity)
  }

  private func createSelfSignedIdentity() throws -> SecIdentity {
    // Generate RSA 2048 key pair
    let keyAttributes: [CFString: Any] = [
      kSecAttrKeyType: kSecAttrKeyTypeRSA,
      kSecAttrKeySizeInBits: 2048,
      kSecAttrLabel: Self.keychainLabel,
      kSecPrivateKeyAttrs: [
        kSecAttrIsPermanent: true,
        kSecAttrLabel: Self.keychainLabel,
      ] as [CFString: Any],
    ]

    var error: Unmanaged<CFError>?
    guard let privateKey = SecKeyCreateRandomKey(keyAttributes as CFDictionary, &error) else {
      let cfError = error?.takeRetainedValue()
      throw TLSError.keyGenerationFailed(cfError.map { String(describing: $0) } ?? "unknown")
    }

    guard let publicKey = SecKeyCopyPublicKey(privateKey) else {
      throw TLSError.keyGenerationFailed("Could not extract public key")
    }

    // Create self-signed certificate using SecCertificateCreateSelfSigned (macOS 26+)
    // Fallback: generate a minimal ASN.1 DER certificate manually
    let certificate = try createCertificate(publicKey: publicKey, privateKey: privateKey)

    // Store certificate in Keychain
    let certAddQuery: [CFString: Any] = [
      kSecClass: kSecClassCertificate,
      kSecValueRef: certificate,
      kSecAttrLabel: Self.keychainLabel,
    ]
    let addStatus = SecItemAdd(certAddQuery as CFDictionary, nil)
    guard addStatus == errSecSuccess || addStatus == errSecDuplicateItem else {
      throw TLSError.keychainStoreFailed(addStatus)
    }

    // Retrieve the identity (private key + certificate combo)
    guard let identity = loadExistingIdentity() else {
      throw TLSError.identityNotFound
    }

    logger.info("Created new self-signed TLS certificate")
    return identity
  }

  private func createCertificate(
    publicKey: SecKey,
    privateKey: SecKey
  ) throws -> SecCertificate {
    // Use the Certificate Signing Request approach:
    // 1. Build a minimal X.509 certificate DER
    // 2. Sign it with the private key
    //
    // For simplicity, we use the system's ability to create an identity
    // via SecIdentityCreateWithCertificate after creating key + cert separately.
    //
    // On macOS, the most reliable approach is to use the `openssl` equivalent
    // via Security.framework's SecCertificateCreateWithData after constructing DER.

    let subjectDER = buildSubjectDER(commonName: "supacode-remote")
    let publicKeyData = SecKeyCopyExternalRepresentation(publicKey, nil)! as Data
    let tbsCertificate = buildTBSCertificate(
      subject: subjectDER,
      publicKeyData: publicKeyData,
    )

    // Sign the TBS certificate
    let signature = try signData(tbsCertificate, with: privateKey)

    // Build the full certificate DER
    let certDER = buildCertificateDER(
      tbsCertificate: tbsCertificate,
      signature: signature,
    )

    guard let certificate = SecCertificateCreateWithData(nil, certDER as CFData) else {
      throw TLSError.certificateCreationFailed
    }
    return certificate
  }

  // MARK: - ASN.1 DER Helpers

  private func buildSubjectDER(commonName: String) -> Data {
    let cnOID: [UInt8] = [0x55, 0x04, 0x03]  // id-at-commonName
    let cnValue = Data(commonName.utf8)

    // UTF8String tag (0x0C) + length + value
    var attrValue = Data([0x0C])
    attrValue.append(contentsOf: derLength(cnValue.count))
    attrValue.append(cnValue)

    // OID tag (0x06) + length + value
    var oid = Data([0x06])
    oid.append(contentsOf: derLength(cnOID.count))
    oid.append(contentsOf: cnOID)

    // SEQUENCE { OID, value }
    var attrTypeAndValue = Data()
    attrTypeAndValue.append(oid)
    attrTypeAndValue.append(attrValue)
    let attrSeq = derSequence(attrTypeAndValue)

    // SET { SEQUENCE }
    let rdn = derSet(attrSeq)

    // SEQUENCE { SET }
    return derSequence(rdn)
  }

  private func buildTBSCertificate(
    subject: Data,
    publicKeyData: Data
  ) -> Data {
    var tbs = Data()

    // Version: v3 (explicit tag [0])
    let version = Data([0xA0, 0x03, 0x02, 0x01, 0x02])
    tbs.append(version)

    // Serial number
    let serial = Data([0x02, 0x01, 0x01])
    tbs.append(serial)

    // Signature algorithm: SHA256WithRSA
    let sigAlg = derSequence(
      Data([0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x0B, 0x05, 0x00])
    )
    tbs.append(sigAlg)

    // Issuer (same as subject for self-signed)
    tbs.append(subject)

    // Validity (1 year from now)
    let validity = buildValidity()
    tbs.append(validity)

    // Subject
    tbs.append(subject)

    // Subject Public Key Info (RSA)
    let spki = buildSPKI(publicKeyData: publicKeyData)
    tbs.append(spki)

    return derSequence(tbs)
  }

  private func buildValidity() -> Data {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyMMddHHmmss'Z'"
    formatter.timeZone = TimeZone(identifier: "UTC")

    let now = Date()
    let oneYear = Calendar.current.date(byAdding: .year, value: 1, to: now)!

    let notBefore = formatter.string(from: now)
    let notAfter = formatter.string(from: oneYear)

    var validity = Data()
    // UTCTime tag (0x17)
    var nb = Data([0x17])
    let nbData = Data(notBefore.utf8)
    nb.append(contentsOf: derLength(nbData.count))
    nb.append(nbData)
    validity.append(nb)

    var na = Data([0x17])
    let naData = Data(notAfter.utf8)
    na.append(contentsOf: derLength(naData.count))
    na.append(naData)
    validity.append(na)

    return derSequence(validity)
  }

  private func buildSPKI(publicKeyData: Data) -> Data {
    // Algorithm identifier: RSA
    let algId = derSequence(
      Data([0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01, 0x05, 0x00])
    )

    // BIT STRING wrapping the public key
    var bitString = Data([0x03])
    bitString.append(contentsOf: derLength(publicKeyData.count + 1))
    bitString.append(0x00)  // no unused bits
    bitString.append(publicKeyData)

    var spki = Data()
    spki.append(algId)
    spki.append(bitString)
    return derSequence(spki)
  }

  private func buildCertificateDER(tbsCertificate: Data, signature: Data) -> Data {
    // Signature algorithm
    let sigAlg = derSequence(
      Data([0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x0B, 0x05, 0x00])
    )

    // Signature as BIT STRING
    var sigBitString = Data([0x03])
    sigBitString.append(contentsOf: derLength(signature.count + 1))
    sigBitString.append(0x00)
    sigBitString.append(signature)

    var cert = Data()
    cert.append(tbsCertificate)
    cert.append(sigAlg)
    cert.append(sigBitString)

    return derSequence(cert)
  }

  private func signData(_ data: Data, with privateKey: SecKey) throws -> Data {
    var error: Unmanaged<CFError>?
    guard let signature = SecKeyCreateSignature(
      privateKey,
      .rsaSignatureMessagePKCS1v15SHA256,
      data as CFData,
      &error
    ) else {
      let cfError = error?.takeRetainedValue()
      throw TLSError.signatureFailed(cfError.map { String(describing: $0) } ?? "unknown")
    }
    return signature as Data
  }

  private func derSequence(_ content: Data) -> Data {
    var seq = Data([0x30])
    seq.append(contentsOf: derLength(content.count))
    seq.append(content)
    return seq
  }

  private func derSet(_ content: Data) -> Data {
    var set = Data([0x31])
    set.append(contentsOf: derLength(content.count))
    set.append(content)
    return set
  }

  private func derLength(_ length: Int) -> [UInt8] {
    if length < 128 {
      return [UInt8(length)]
    } else if length < 256 {
      return [0x81, UInt8(length)]
    } else {
      return [0x82, UInt8(length >> 8), UInt8(length & 0xFF)]
    }
  }
}

enum TLSError: Error {
  case keyGenerationFailed(String)
  case certificateCreationFailed
  case keychainStoreFailed(OSStatus)
  case identityNotFound
  case signatureFailed(String)
}
```

**Step 4: Run test — expected PASS**

```bash
xcodebuild test -project supacode.xcodeproj -scheme supacode -destination "platform=macOS" \
  -only-testing:supacodeTests/TLSCertificateManagerTests \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" -skipMacroValidation
```

Expected: PASS

**Step 5: Commit**

```bash
git add supacode/Infrastructure/Remote/TLSCertificateManager.swift supacodeTests/TLSCertificateManagerTests.swift
git commit -m "feat(remote): add TLSCertificateManager for self-signed certificate generation"
```

---

### Task 26b: Add Pairing Code to HelloMessage and Protocol

**Files:**
- Modify: `supacode/Features/Remote/Models/RemoteProtocol.swift`
- Modify: `supacodeTests/RemoteProtocolTests.swift`

**Step 1: Add test for HelloMessage with pairing code**

Add to `RemoteProtocolTests.swift`:

```swift
@Test func helloMessageWithPairingCodeRoundTrips() throws {
  let hello = HelloMessage(
    protocolVersion: 1,
    appVersion: "0.6.0",
    clientName: "Test MacBook",
    pairingCode: "123456",
  )
  let data = try JSONEncoder().encode(hello)
  let decoded = try JSONDecoder().decode(HelloMessage.self, from: data)
  #expect(decoded.pairingCode == "123456")
}

@Test func helloMessageWithoutPairingCodeRoundTrips() throws {
  let hello = HelloMessage(
    protocolVersion: 1,
    appVersion: "0.6.0",
    clientName: "Test MacBook",
  )
  let data = try JSONEncoder().encode(hello)
  let decoded = try JSONDecoder().decode(HelloMessage.self, from: data)
  #expect(decoded.pairingCode == nil)
}
```

**Step 2: Run test — expected FAIL**

**Step 3: Add pairingCode to HelloMessage**

In `RemoteProtocol.swift`, update `HelloMessage`:

```swift
nonisolated struct HelloMessage: Codable, Sendable {
  let protocolVersion: Int
  let appVersion: String
  let clientName: String
  var pairingCode: String?
}
```

**Step 4: Run test — expected PASS**

**Step 5: Commit**

```bash
git add supacode/Features/Remote/Models/RemoteProtocol.swift supacodeTests/RemoteProtocolTests.swift
git commit -m "feat(remote): add pairingCode field to HelloMessage"
```

---

### Task 26c: Add TLS to BonjourAdvertiser

**Files:**
- Modify: `supacode/Infrastructure/Remote/BonjourAdvertiser.swift`

**Step 1: Add TLS identity parameter to start()**

Update `BonjourAdvertiser.start()` to accept an optional `SecIdentity` and configure TLS when provided:

Replace the `start()` method:

```swift
func start(
  port: UInt16 = BonjourAdvertiser.defaultPort,
  tlsIdentity: SecIdentity? = nil,
  onNewConnection: @escaping @Sendable (NWConnection) -> Void
) throws {
  let params: NWParameters
  if let tlsIdentity {
    let tlsOptions = NWProtocolTLS.Options()
    sec_protocol_options_set_local_identity(
      tlsOptions.securityProtocolOptions,
      sec_identity_create(tlsIdentity)!,
    )
    params = NWParameters(tls: tlsOptions)
  } else {
    params = NWParameters.tcp
  }
  let wsOptions = NWProtocolWebSocket.Options()
  wsOptions.autoReplyPing = true
  params.defaultProtocolStack.applicationProtocols.insert(wsOptions, at: 0)

  let nwPort = NWEndpoint.Port(rawValue: port)!
  let listener = try NWListener(using: params, on: nwPort)
  listener.service = NWListener.Service(
    name: serverName,
    type: Self.serviceType,
  )
  listener.stateUpdateHandler = { [weak self] state in
    Task { @MainActor in
      guard let self else { return }
      switch state {
      case .ready:
        self.isAdvertising = true
        self.logger.info("Server advertising as '\(self.serverName)'")
      case .failed(let error):
        self.logger.warning("Listener failed: \(error)")
        self.isAdvertising = false
      case .cancelled:
        self.isAdvertising = false
      default:
        break
      }
    }
  }
  listener.newConnectionHandler = { connection in
    onNewConnection(connection)
  }
  listener.start(queue: .main)
  self.listener = listener
}
```

**Step 2: Build to verify compilation**

```bash
make build-app
```

Expected: BUILD SUCCEEDED (existing callers pass no `tlsIdentity`, so the default `nil` works)

**Step 3: Commit**

```bash
git add supacode/Infrastructure/Remote/BonjourAdvertiser.swift
git commit -m "feat(remote): add TLS identity support to BonjourAdvertiser"
```

---

### Task 26d: Add TLS Trust Override to WebSocketClient

**Files:**
- Modify: `supacode/Infrastructure/Remote/WebSocketClient.swift`

**Step 1: Update connect() to accept all server certs**

In `WebSocketClient.swift`, replace the `connect(to:)` method:

```swift
func connect(to server: DiscoveredServer) {
  let tlsOptions = NWProtocolTLS.Options()
  sec_protocol_options_set_verify_block(
    tlsOptions.securityProtocolOptions,
    { _, _, completion in
      // Accept all server certs (self-signed for LAN use)
      completion(true)
    },
    .main,
  )
  let params = NWParameters(tls: tlsOptions)
  let wsOptions = NWProtocolWebSocket.Options()
  wsOptions.autoReplyPing = true
  params.defaultProtocolStack.applicationProtocols.insert(wsOptions, at: 0)

  let connection = NWConnection(to: server.endpoint, using: params)
  connection.stateUpdateHandler = { [weak self] state in
    Task { @MainActor in
      guard let self else { return }
      switch state {
      case .ready:
        self.isConnected = true
        self.connectedServerName = server.name
        self.logger.info("Connected to '\(server.name)'")
        self.sendHello()
      case .failed(let error):
        self.logger.warning("Connection failed: \(error)")
        self.handleDisconnect()
      case .cancelled:
        self.handleDisconnect()
      default:
        break
      }
    }
  }
  connection.start(queue: .main)
  self.connection = connection
  receiveMessages(on: connection)
}
```

**Step 2: Add pairing code to sendHello()**

Replace the `sendHello()` method to include the pairing code:

```swift
var pairingCode: String?

private func sendHello() {
  let hello = HelloMessage(
    protocolVersion: 1,
    appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev",
    clientName: Host.current().localizedName ?? "Supacode Client",
    pairingCode: pairingCode,
  )
  sendJSON(type: .hello, value: hello)
}
```

**Step 3: Build to verify compilation**

```bash
make build-app
```

Expected: BUILD SUCCEEDED

**Step 4: Commit**

```bash
git add supacode/Infrastructure/Remote/WebSocketClient.swift
git commit -m "feat(remote): add TLS trust override and pairing code to WebSocketClient"
```

---

### Task 26e: Add Pairing State and Actions to RemoteFeature

**Files:**
- Modify: `supacode/Features/Remote/Reducer/RemoteFeature.swift`
- Modify: `supacodeTests/RemoteFeatureTests.swift`

**Step 1: Write the failing tests**

Add to `RemoteFeatureTests.swift`:

```swift
// MARK: - Pairing Code Tests

@Test func clientConnectedGeneratesPairingCode() async {
  let store = TestStore(initialState: RemoteFeature.State()) {
    RemoteFeature()
  }

  await store.send(.remoteServerEvent(.clientConnected(name: "iPhone"))) {
    $0.pendingConnectionName = "iPhone"
    // Pairing code should be a 6-digit string
    #expect($0.activePairingCode?.count == 6)
    #expect(Int($0.activePairingCode ?? "") != nil)
  }
}

@Test func approveConnectionClearsPairingCode() async {
  var state = RemoteFeature.State()
  state.pendingConnectionName = "iPhone"
  state.activePairingCode = "123456"

  let store = TestStore(initialState: state) {
    RemoteFeature()
  }

  await store.send(.approveConnection) {
    $0.connectedClientName = "iPhone"
    $0.pendingConnectionName = nil
    $0.activePairingCode = nil
  }
}

@Test func denyConnectionClearsPairingCode() async {
  let disconnectClientCalled = LockIsolated(false)
  var state = RemoteFeature.State()
  state.pendingConnectionName = "iPhone"
  state.activePairingCode = "123456"

  let store = TestStore(initialState: state) {
    RemoteFeature()
  } withDependencies: {
    $0.remoteServerClient.disconnectClient = { disconnectClientCalled.withValue { $0 = true } }
  }

  await store.send(.denyConnection) {
    $0.pendingConnectionName = nil
    $0.activePairingCode = nil
  }
  #expect(disconnectClientCalled.value)
}

@Test func toggleServerOffClearsPairingCode() async {
  var state = RemoteFeature.State()
  state.isServerEnabled = true
  state.activePairingCode = "123456"
  state.pendingConnectionName = "iPhone"

  let store = TestStore(initialState: state) {
    RemoteFeature()
  } withDependencies: {
    $0.remoteServerClient.stop = {}
  }

  await store.send(.toggleServer) {
    $0.isServerEnabled = false
    $0.pendingConnectionName = nil
    $0.activePairingCode = nil
  }
}
```

**Step 2: Run tests — expected FAIL**

**Step 3: Update RemoteFeature with pairing state**

In `RemoteFeature.swift`, add to State:

```swift
var activePairingCode: String?
```

Update the `clientConnected` case in `remoteServerEvent`:

```swift
case .clientConnected(let name):
  state.pendingConnectionName = name
  state.activePairingCode = String(format: "%06d", Int.random(in: 0...999_999))
  return .none
```

Update `approveConnection`:

```swift
case .approveConnection:
  if let name = state.pendingConnectionName {
    state.connectedClientName = name
    state.pendingConnectionName = nil
    state.activePairingCode = nil
  }
  return .none
```

Update `denyConnection`:

```swift
case .denyConnection:
  state.pendingConnectionName = nil
  state.activePairingCode = nil
  remoteServerClient.disconnectClient()
  return .none
```

Update `toggleServer` off branch:

```swift
remoteServerClient.stop()
state.connectedClientName = nil
state.pendingConnectionName = nil
state.activePairingCode = nil
return .none
```

**Step 4: Run tests — expected PASS**

Note: The existing `serverEventClientConnectedSetsPendingState` test needs updating since it now also sets `activePairingCode`. Update it to also verify the pairing code:

```swift
@Test func serverEventClientConnectedSetsPendingState() async {
  let store = TestStore(initialState: RemoteFeature.State()) {
    RemoteFeature()
  }

  await store.send(.remoteServerEvent(.clientConnected(name: "iPhone"))) {
    $0.pendingConnectionName = "iPhone"
    // Pairing code is randomly generated
    #expect($0.activePairingCode?.count == 6)
  }
}
```

And update `serverEventClientDisconnectedClearsPendingConnection` to also account for `activePairingCode`:

```swift
@Test func serverEventClientDisconnectedClearsPendingConnection() async {
  var state = RemoteFeature.State()
  state.pendingConnectionName = "iPhone"
  state.activePairingCode = "123456"

  let store = TestStore(initialState: state) {
    RemoteFeature()
  }

  await store.send(.remoteServerEvent(.clientDisconnected)) {
    $0.pendingConnectionName = nil
    $0.activePairingCode = nil
  }
}
```

Also update the `clientDisconnected` case in the reducer to clear `activePairingCode`:

```swift
case .clientDisconnected:
  state.connectedClientName = nil
  state.pendingConnectionName = nil
  state.activePairingCode = nil
  return .none
```

**Step 5: Run all RemoteFeature tests — expected PASS**

```bash
xcodebuild test -project supacode.xcodeproj -scheme supacode -destination "platform=macOS" \
  -only-testing:supacodeTests/RemoteFeatureTests \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" -skipMacroValidation
```

**Step 6: Commit**

```bash
git add supacode/Features/Remote/Reducer/RemoteFeature.swift supacodeTests/RemoteFeatureTests.swift
git commit -m "feat(remote): add pairing code generation to RemoteFeature"
```

---

### Task 26f: PairingCodeView

**Files:**
- Create: `supacode/Features/Remote/Views/PairingCodeView.swift`

**Step 1: Write PairingCodeView.swift**

```swift
import SwiftUI

struct PairingCodeView: View {
  let code: String
  let clientName: String
  let onApprove: () -> Void
  let onDeny: () -> Void

  var body: some View {
    VStack(spacing: 16) {
      Image(systemName: "lock.shield")
        .font(.system(size: 40))
        .foregroundStyle(.secondary)

      Text("Pairing Request")
        .font(.headline)

      Text("\(clientName) wants to connect.")
        .font(.body)
        .multilineTextAlignment(.center)
        .foregroundStyle(.secondary)

      Text("Verify this code matches on the client:")
        .font(.caption)
        .foregroundStyle(.tertiary)

      Text(code)
        .font(.system(size: 36).monospaced())
        .tracking(8)
        .padding(.vertical, 8)

      HStack(spacing: 12) {
        Button("Deny") {
          onDeny()
        }
        .keyboardShortcut(.escape)

        Button("Allow") {
          onApprove()
        }
        .keyboardShortcut(.defaultAction)
      }
    }
    .padding(24)
    .frame(width: 320)
  }
}
```

**Step 2: Build to verify compilation**

```bash
make build-app
```

Expected: BUILD SUCCEEDED

**Step 3: Commit**

```bash
git add supacode/Features/Remote/Views/PairingCodeView.swift
git commit -m "feat(remote): add PairingCodeView for pairing code display"
```

---

## Task 27: Tailscale/Tunnel Support (Manual Connection)

### Task 27a: Add connectToAddress Action to RemoteFeature

**Files:**
- Modify: `supacode/Features/Remote/Reducer/RemoteFeature.swift`
- Modify: `supacodeTests/RemoteFeatureTests.swift`

**Step 1: Write the failing tests**

Add to `RemoteFeatureTests.swift`:

```swift
// MARK: - Manual Connection Tests

@Test func connectToAddressWithValidHostPort() async {
  let connectedServer = LockIsolated<DiscoveredServer?>(nil)
  let store = TestStore(initialState: RemoteFeature.State()) {
    RemoteFeature()
  } withDependencies: {
    $0.remoteConnectionClient.connect = { server in
      connectedServer.withValue { $0 = server }
    }
  }

  await store.send(.connectToAddress("192.168.1.100:9847")) {
    $0.lastConnectedServer = DiscoveredServer(
      id: "manual-192.168.1.100:9847",
      name: "192.168.1.100:9847",
      endpoint: NWEndpoint.hostPort(
        host: NWEndpoint.Host("192.168.1.100"),
        port: NWEndpoint.Port(rawValue: 9847)!,
      ),
    )
  }
  #expect(connectedServer.value?.id == "manual-192.168.1.100:9847")
}

@Test func connectToAddressWithHostname() async {
  let connectedServer = LockIsolated<DiscoveredServer?>(nil)
  let store = TestStore(initialState: RemoteFeature.State()) {
    RemoteFeature()
  } withDependencies: {
    $0.remoteConnectionClient.connect = { server in
      connectedServer.withValue { $0 = server }
    }
  }

  await store.send(.connectToAddress("my-mac.tail12345.ts.net:9847")) {
    $0.lastConnectedServer = DiscoveredServer(
      id: "manual-my-mac.tail12345.ts.net:9847",
      name: "my-mac.tail12345.ts.net:9847",
      endpoint: NWEndpoint.hostPort(
        host: NWEndpoint.Host("my-mac.tail12345.ts.net"),
        port: NWEndpoint.Port(rawValue: 9847)!,
      ),
    )
  }
  #expect(connectedServer.value?.name == "my-mac.tail12345.ts.net:9847")
}

@Test func connectToAddressWithInvalidFormat() async {
  let store = TestStore(initialState: RemoteFeature.State()) {
    RemoteFeature()
  }

  // Missing port — should not crash, should not change state
  await store.send(.connectToAddress("192.168.1.100"))
}

@Test func connectToAddressWithInvalidPort() async {
  let store = TestStore(initialState: RemoteFeature.State()) {
    RemoteFeature()
  }

  // Port out of range
  await store.send(.connectToAddress("192.168.1.100:99999"))
}

@Test func connectToAddressWithIPv6() async {
  let connectedServer = LockIsolated<DiscoveredServer?>(nil)
  let store = TestStore(initialState: RemoteFeature.State()) {
    RemoteFeature()
  } withDependencies: {
    $0.remoteConnectionClient.connect = { server in
      connectedServer.withValue { $0 = server }
    }
  }

  await store.send(.connectToAddress("[::1]:9847")) {
    $0.lastConnectedServer = DiscoveredServer(
      id: "manual-[::1]:9847",
      name: "[::1]:9847",
      endpoint: NWEndpoint.hostPort(
        host: NWEndpoint.Host("::1"),
        port: NWEndpoint.Port(rawValue: 9847)!,
      ),
    )
  }
  #expect(connectedServer.value != nil)
}
```

**Step 2: Run tests — expected FAIL**

**Step 3: Add connectToAddress to RemoteFeature**

In `RemoteFeature.swift`, add the action:

```swift
case connectToAddress(String)
```

Add the reducer case:

```swift
case .connectToAddress(let address):
  guard let server = Self.parseAddress(address) else {
    return .none
  }
  state.lastConnectedServer = server
  remoteConnectionClient.connect(server)
  return .none
```

Add the static parser method to `RemoteFeature`:

```swift
private static func parseAddress(_ address: String) -> DiscoveredServer? {
  let host: String
  let portString: String

  if address.hasPrefix("[") {
    // IPv6: [::1]:9847
    guard let closeBracket = address.firstIndex(of: "]") else { return nil }
    host = String(address[address.index(after: address.startIndex)..<closeBracket])
    let afterBracket = address.index(after: closeBracket)
    guard afterBracket < address.endIndex, address[afterBracket] == ":" else { return nil }
    portString = String(address[address.index(after: afterBracket)...])
  } else {
    // IPv4 or hostname: host:port
    guard let lastColon = address.lastIndex(of: ":") else { return nil }
    host = String(address[..<lastColon])
    portString = String(address[address.index(after: lastColon)...])
  }

  guard let portNumber = UInt16(portString), portNumber > 0 else { return nil }
  guard let nwPort = NWEndpoint.Port(rawValue: portNumber) else { return nil }

  let id = "manual-\(address)"
  return DiscoveredServer(
    id: id,
    name: address,
    endpoint: .hostPort(host: NWEndpoint.Host(host), port: nwPort),
  )
}
```

Add `import Network` at the top of `RemoteFeature.swift` if not already present.

**Step 4: Run tests — expected PASS**

```bash
xcodebuild test -project supacode.xcodeproj -scheme supacode -destination "platform=macOS" \
  -only-testing:supacodeTests/RemoteFeatureTests \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" -skipMacroValidation
```

**Step 5: Commit**

```bash
git add supacode/Features/Remote/Reducer/RemoteFeature.swift supacodeTests/RemoteFeatureTests.swift
git commit -m "feat(remote): add connectToAddress for manual host:port connection"
```

---

### Task 28: Final Checkpoint — Build, Test, Lint

**Step 1: Run full build**

```bash
make build-app
```

Expected: BUILD SUCCEEDED

**Step 2: Run full test suite**

```bash
make test
```

Expected: All tests pass

**Step 3: Run lint/format**

```bash
make check
```

Expected: No warnings or errors

**Step 4: Update PR**

Update PR #1 title and description to cover the full remote control feature (Phases 1–4), then push.

```bash
gh pr edit 1 --title "feat(remote): add remote control with H.264 streaming, TLS, and adaptive bitrate"
```
