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
    var certificate: SecCertificate?
    let status = SecIdentityCopyCertificate(identity, &certificate)
    #expect(status == errSecSuccess)
    #expect(certificate != nil)
    manager.deleteIdentity()
  }

  @Test func reusesExistingCertificate() throws {
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
}
