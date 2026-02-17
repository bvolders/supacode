import Foundation
import Security

enum TLSError: Error {
  case keyGenerationFailed(String)
  case certificateCreationFailed
  case keychainStoreFailed(OSStatus)
  case identityNotFound
  case signatureFailed(String)
}

@MainActor
@Observable
final class TLSCertificateManager {
  static let keychainLabel = "com.supacode.remote-tls"

  private let logger = SupaLogger("TLS")

  func loadOrCreateIdentity() throws -> SecIdentity {
    if let existing = try? loadExistingIdentity() {
      logger.info("Loaded existing TLS identity from Keychain")
      return existing
    }
    logger.info("Creating new self-signed TLS certificate")
    return try createAndStoreIdentity()
  }

  func deleteIdentity() {
    let keyQuery: [String: Any] = [
      kSecClass as String: kSecClassKey,
      kSecAttrLabel as String: Self.keychainLabel,
    ]
    SecItemDelete(keyQuery as CFDictionary)

    let certQuery: [String: Any] = [
      kSecClass as String: kSecClassCertificate,
      kSecAttrLabel as String: Self.keychainLabel,
    ]
    SecItemDelete(certQuery as CFDictionary)

    logger.info("Deleted TLS identity from Keychain")
  }

  // MARK: - Private

  private func loadExistingIdentity() throws -> SecIdentity {
    let query: [String: Any] = [
      kSecClass as String: kSecClassIdentity,
      kSecAttrLabel as String: Self.keychainLabel,
      kSecReturnRef as String: true,
    ]
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    guard status == errSecSuccess, let identity = result else {
      throw TLSError.identityNotFound
    }
    // swiftlint:disable:next force_cast
    return identity as! SecIdentity
  }

  private func createAndStoreIdentity() throws -> SecIdentity {
    let privateKey = try generateKeyPair()
    let certificateData = try buildSelfSignedCertificate(privateKey: privateKey)

    guard let certificate = SecCertificateCreateWithData(nil, certificateData as CFData) else {
      throw TLSError.certificateCreationFailed
    }

    try storeCertificate(certificate)
    return try loadExistingIdentity()
  }

  private func generateKeyPair() throws -> SecKey {
    let attributes: [String: Any] = [
      kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
      kSecAttrKeySizeInBits as String: 2048,
      kSecAttrLabel as String: Self.keychainLabel,
      kSecPrivateKeyAttrs as String: [
        kSecAttrIsPermanent as String: true,
        kSecAttrLabel as String: Self.keychainLabel,
      ],
    ]

    var error: Unmanaged<CFError>?
    guard let privateKey = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
      let message = error?.takeRetainedValue().localizedDescription ?? "Unknown error"
      throw TLSError.keyGenerationFailed(message)
    }
    return privateKey
  }

  private func storeCertificate(_ certificate: SecCertificate) throws {
    let addQuery: [String: Any] = [
      kSecClass as String: kSecClassCertificate,
      kSecValueRef as String: certificate,
      kSecAttrLabel as String: Self.keychainLabel,
    ]
    let status = SecItemAdd(addQuery as CFDictionary, nil)
    guard status == errSecSuccess || status == errSecDuplicateItem else {
      throw TLSError.keychainStoreFailed(status)
    }
  }

  // MARK: - X.509 Certificate Builder

  private func buildSelfSignedCertificate(privateKey: SecKey) throws -> Data {
    let now = Date()
    let oneYearFromNow = Calendar.current.date(byAdding: .year, value: 1, to: now)!

    // TBSCertificate
    var tbs = Data()

    // Version: v3 (2) — explicit tag [0]
    tbs.append(ASN1.contextTag(0, content: ASN1.integer(Data([0x02]))))

    // Serial number
    let serial = Data([0x01])
    tbs.append(ASN1.integer(serial))

    // Signature algorithm: SHA256WithRSA (1.2.840.113549.1.1.11)
    tbs.append(ASN1.sha256WithRSAAlgorithm())

    // Issuer: CN=supacode-remote
    let issuerCN = ASN1.rdnSequence(commonName: "supacode-remote")
    tbs.append(issuerCN)

    // Validity
    tbs.append(ASN1.validity(notBefore: now, notAfter: oneYearFromNow))

    // Subject: CN=supacode-remote
    tbs.append(issuerCN)

    // Subject public key info
    guard let publicKey = SecKeyCopyPublicKey(privateKey) else {
      throw TLSError.keyGenerationFailed("Cannot extract public key")
    }
    var keyError: Unmanaged<CFError>?
    guard let publicKeyData = SecKeyCopyExternalRepresentation(publicKey, &keyError) as Data? else {
      let message = keyError?.takeRetainedValue().localizedDescription ?? "Unknown error"
      throw TLSError.keyGenerationFailed(message)
    }
    tbs.append(ASN1.rsaPublicKeyInfo(publicKeyData))

    let tbsSequence = ASN1.sequence(tbs)

    // Sign the TBSCertificate
    let signature = try signData(tbsSequence, with: privateKey)

    // Build full certificate
    var cert = Data()
    cert.append(tbsSequence)
    cert.append(ASN1.sha256WithRSAAlgorithm())
    cert.append(ASN1.bitString(signature))

    return ASN1.sequence(cert)
  }

  private func signData(_ data: Data, with privateKey: SecKey) throws -> Data {
    var error: Unmanaged<CFError>?
    guard
      let signature = SecKeyCreateSignature(
        privateKey,
        .rsaSignatureMessagePKCS1v15SHA256,
        data as CFData,
        &error,
      ) as Data?
    else {
      let message = error?.takeRetainedValue().localizedDescription ?? "Unknown error"
      throw TLSError.signatureFailed(message)
    }
    return signature
  }
}

// MARK: - ASN.1 DER Helpers

private enum ASN1 {
  static func sequence(_ content: Data) -> Data {
    tag(0x30, content: content)
  }

  static func set(_ content: Data) -> Data {
    tag(0x31, content: content)
  }

  static func integer(_ bytes: Data) -> Data {
    // Ensure positive integer (add leading zero if high bit set)
    var value = bytes
    if let first = value.first, first & 0x80 != 0 {
      value.insert(0x00, at: 0)
    }
    return tag(0x02, content: value)
  }

  static func bitString(_ content: Data) -> Data {
    var payload = Data([0x00])  // unused bits count
    payload.append(content)
    return tag(0x03, content: payload)
  }

  static func objectIdentifier(_ oid: [UInt]) -> Data {
    var encoded = Data()
    guard oid.count >= 2 else { return tag(0x06, content: encoded) }
    encoded.append(UInt8(oid[0] * 40 + oid[1]))
    for index in 2..<oid.count {
      encoded.append(contentsOf: encodeOIDComponent(oid[index]))
    }
    return tag(0x06, content: encoded)
  }

  static func utf8String(_ string: String) -> Data {
    tag(0x0C, content: Data(string.utf8))
  }

  static func utcTime(_ date: Date) -> Data {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyMMddHHmmss'Z'"
    formatter.timeZone = TimeZone(identifier: "UTC")
    let str = formatter.string(from: date)
    return tag(0x17, content: Data(str.utf8))
  }

  static func contextTag(_ tagNumber: UInt8, content: Data) -> Data {
    let tagByte: UInt8 = 0xA0 | tagNumber
    return tag(tagByte, content: content)
  }

  static func sha256WithRSAAlgorithm() -> Data {
    // OID 1.2.840.113549.1.1.11 (sha256WithRSAEncryption)
    var alg = Data()
    alg.append(objectIdentifier([1, 2, 840, 113_549, 1, 1, 11]))
    alg.append(tag(0x05, content: Data()))  // NULL parameter
    return sequence(alg)
  }

  static func rdnSequence(commonName: String) -> Data {
    // OID 2.5.4.3 (commonName)
    var atv = Data()
    atv.append(objectIdentifier([2, 5, 4, 3]))
    atv.append(utf8String(commonName))
    return sequence(set(sequence(atv)))
  }

  static func validity(notBefore: Date, notAfter: Date) -> Data {
    var validityData = Data()
    validityData.append(utcTime(notBefore))
    validityData.append(utcTime(notAfter))
    return sequence(validityData)
  }

  static func rsaPublicKeyInfo(_ publicKeyData: Data) -> Data {
    // AlgorithmIdentifier for RSA: OID 1.2.840.113549.1.1.1
    var algId = Data()
    algId.append(objectIdentifier([1, 2, 840, 113_549, 1, 1, 1]))
    algId.append(tag(0x05, content: Data()))  // NULL
    let algSequence = sequence(algId)

    // The public key data from SecKeyCopyExternalRepresentation is already
    // a DER-encoded RSAPublicKey (SEQUENCE { modulus INTEGER, exponent INTEGER })
    // Wrap it in a BIT STRING
    let keyBitString = bitString(publicKeyData)

    var spki = Data()
    spki.append(algSequence)
    spki.append(keyBitString)
    return sequence(spki)
  }

  // MARK: - Primitives

  private static func tag(_ tagByte: UInt8, content: Data) -> Data {
    var result = Data()
    result.append(tagByte)
    result.append(contentsOf: encodeLength(content.count))
    result.append(content)
    return result
  }

  private static func encodeLength(_ length: Int) -> Data {
    if length < 128 {
      return Data([UInt8(length)])
    }
    var len = length
    var bytes: [UInt8] = []
    while len > 0 {
      bytes.insert(UInt8(len & 0xFF), at: 0)
      len >>= 8
    }
    var result = Data([UInt8(0x80 | bytes.count)])
    result.append(contentsOf: bytes)
    return result
  }

  private static func encodeOIDComponent(_ value: UInt) -> [UInt8] {
    if value < 128 {
      return [UInt8(value)]
    }
    var result: [UInt8] = []
    var remaining = value
    result.append(UInt8(remaining & 0x7F))
    remaining >>= 7
    while remaining > 0 {
      result.insert(UInt8((remaining & 0x7F) | 0x80), at: 0)
      remaining >>= 7
    }
    return result
  }
}
