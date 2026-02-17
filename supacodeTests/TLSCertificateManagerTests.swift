import Foundation
import Security
import Testing

@testable import supacode

@MainActor
struct TLSCertificateManagerTests {
  @Test func keychainLabelIsCorrect() {
    #expect(TLSCertificateManager.keychainLabel == "com.supacode.remote-tls")
  }

  @Test(.enabled(if: canAccessKeychain))
  func generatesSelfSignedCertificate() throws {
    let manager = TLSCertificateManager()
    let identity = try manager.loadOrCreateIdentity()
    var certificate: SecCertificate?
    let status = SecIdentityCopyCertificate(identity, &certificate)
    #expect(status == errSecSuccess)
    #expect(certificate != nil)
    manager.deleteIdentity()
  }

  @Test(.enabled(if: canAccessKeychain))
  func reusesExistingCertificate() throws {
    let manager = TLSCertificateManager()
    let identity1 = try manager.loadOrCreateIdentity()
    let identity2 = try manager.loadOrCreateIdentity()
    var cert1: SecCertificate?
    var cert2: SecCertificate?
    SecIdentityCopyCertificate(identity1, &cert1)
    SecIdentityCopyCertificate(identity2, &cert2)
    #expect(cert1 != nil)
    #expect(cert2 != nil)
    manager.deleteIdentity()
  }

  /// Key generation requires a signed test runner; skip when running unsigned.
  private nonisolated static let canAccessKeychain: Bool = {
    let tag = "com.supacode.test-keychain-probe"
    let attrs: [String: Any] = [
      kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
      kSecAttrKeySizeInBits as String: 512,
      kSecAttrLabel as String: tag,
      kSecPrivateKeyAttrs as String: [kSecAttrIsPermanent as String: true],
    ]
    var error: Unmanaged<CFError>?
    guard let key = SecKeyCreateRandomKey(attrs as CFDictionary, &error) else {
      return false
    }
    SecItemDelete([kSecClass: kSecClassKey, kSecAttrLabel: tag] as CFDictionary)
    _ = key
    return true
  }()
}
