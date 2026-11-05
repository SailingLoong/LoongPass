import Foundation
import CryptoKit
import CommonCrypto
import Darwin

/// Reads the official client's existing byteCrypto format. LoongPass itself
/// stores private JSON; this is not a new encryption or Keychain subsystem.
enum TraeLocalAuthorization {
    enum Failure: Error { case unavailable }
    private static func bytes(_ hex: String) -> [UInt8] {
        stride(from: 0, to: hex.count, by: 2).map { offset in
            let start = hex.index(hex.startIndex, offsetBy: offset)
            return UInt8(hex[start..<hex.index(start, offsetBy: 2)], radix: 16)!
        }
    }
    static func decode(_ encoded: String) throws -> [String: Any] {
        guard encoded.utf8.count <= 1_000_000, let packed = Data(base64Encoded: encoded),
            packed.count >= 118, (packed.count - 38) % 16 == 0 else { throw Failure.unavailable }
        let salt: [UInt8]
        switch Array(packed.prefix(6)) {
        case [116, 99, 5, 16, 0, 0]:
            salt = bytes("4dd4c2e6b83162090e52b3c7a6733ba41cb2462b829ab58a196b39db57177524f49baf7f08e8d68d26a72e37c1a95a2f1f05a51892aef2949732b62a38aadd58")
        case [18, 57, 32, 32, 2, 3]:
            salt = bytes("490cc21292b05d0cc06ccbe91fb92e21b5a7c538811dc85e27a96e28104e1cf69c7166efab232807390da78a8b91e49c44b49a43feb941a1e46f2656e613e47b")
        default: throw Failure.unavailable
        }
        let derived = Array(SHA512.hash(data: Data(SHA512.hash(data: packed[6..<38])) + Data(salt)))
        let key = Array(derived[0..<16]), iv = Array(derived[16..<32]), cipher = Array(packed.dropFirst(38))
        var clear = [UInt8](repeating: 0, count: cipher.count + 16), count = 0
        let capacity = clear.count
        let status = key.withUnsafeBytes { keyBytes in iv.withUnsafeBytes { ivBytes in
            cipher.withUnsafeBytes { input in clear.withUnsafeMutableBytes { output in
                CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                    keyBytes.baseAddress, 16, ivBytes.baseAddress, input.baseAddress, cipher.count,
                    output.baseAddress, capacity, &count)
            }}
        }}
        defer { _ = clear.withUnsafeMutableBytes { $0.initializeMemory(as: UInt8.self, repeating: 0) } }
        guard status == kCCSuccess, count >= 64 else { throw Failure.unavailable }
        let payload = Data(clear[64..<count])
        let digest = Array(SHA512.hash(data: payload))
        var difference: UInt8 = 0
        for index in 0..<64 { difference |= digest[index] ^ clear[index] }
        guard difference == 0, String(data: payload, encoding: .utf8) != nil,
            let value = try JSONSerialization.jsonObject(with: payload) as? [String: Any] else { throw Failure.unavailable }
        return value
    }
    static func read(_ url: URL) throws -> [String: Any] {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw Failure.unavailable }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
            info.st_uid == geteuid(), info.st_size <= 8 * 1024 * 1024,
            let data = try file.readToEnd(), data.count <= 8 * 1024 * 1024,
            let source = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let encoded = source["iCubeAuthInfo://icube.cloudide"] as? String,
            let machine = source["telemetry.machineId"] as? String, !machine.isEmpty else { throw Failure.unavailable }
        let user = try decode(encoded)
        guard let account = user["account"] as? [String: Any], account["scope"] as? String == "marscode",
            account["loginScope"] as? String == "trae", user["host"] as? String == "https://api.trae.cn",
            let uid = user["userId"] as? String, !uid.isEmpty,
            let token = user["token"] as? String, !token.isEmpty,
            let expiry = expiryMilliseconds(user["expiredAt"]) else { throw Failure.unavailable }
        let keys = source.keys.filter { $0.hasPrefix("iCubeAuthInfo://icube-dc:") }
        guard keys.count == 1, let encodedKey = source[keys[0]] as? String else { throw Failure.unavailable }
        let keyPair = try decode(encodedKey)
        guard let privatePEM = keyPair["privateKeyPEM"] as? String,
            let publicPEM = keyPair["publicKeyPEM"] as? String else { throw Failure.unavailable }
        let privateKey = try P256.Signing.PrivateKey(pemRepresentation: privatePEM)
        let publicKey = try P256.Signing.PublicKey(pemRepresentation: publicPEM)
        guard privateKey.publicKey.derRepresentation == publicKey.derRepresentation else { throw Failure.unavailable }
        let deviceID = String(keys[0].dropFirst("iCubeAuthInfo://icube-dc:".count))
        guard !deviceID.isEmpty else { throw Failure.unavailable }
        let app = Bundle(path: "/Applications/Trae CN.app")
        guard let version = app?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String else { throw Failure.unavailable }
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let device: [String: Any] = ["DeviceID": deviceID, "MachineID": machine,
            "PlatformCode": "IDE_PC", "DeviceType": "PC", "DeviceName": Host.current().localizedName ?? "Mac",
            "DeviceModel": systemString("hw.model"), "ClientVersion": version,
            "DevicePublicKey": publicPEM, "DeviceBrand": "Apple", "DeviceCPU": systemString("machdep.cpu.brand_string"),
            "OSInfo": "macOS", "OSVersion": "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"]
        // Never copy the official client's rotating refresh token. Independent
        // LoongPass browser grants may use this same genuine device key.
        return ["account": ["uid": uid, "token": token, "expiresAt": expiry,
            "label": account["username"] as? String ?? uid, "owner": "officialClient"],
            "device": device, "privateKeyPEM": privatePEM, "version": version]
    }
    static func expiryMilliseconds(_ value: Any?) -> Int64? {
        if let number = value as? NSNumber, number.doubleValue.isFinite, number.doubleValue > 0 {
            return number.int64Value
        }
        guard let string = value as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) { return Int64(date.timeIntervalSince1970 * 1000) }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string).map { Int64($0.timeIntervalSince1970 * 1000) }
    }
    private static func systemString(_ name: String) -> String {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0, size < 4096 else { return "" }
        var value = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return "" }
        return String(cString: value)
    }
    static func refreshProof(privatePEM: String, refreshToken: String) throws -> [String: Any] {
        guard privatePEM.utf8.count < 16384, !refreshToken.isEmpty, refreshToken.utf8.count <= 16384 else { throw Failure.unavailable }
        let key = try P256.Signing.PrivateKey(pemRepresentation: privatePEM)
        var generator = SystemRandomNumberGenerator()
        let nonce = (0..<16).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max, using: &generator)) }.joined()
        let timestamp = Int(Date().timeIntervalSince1970)
        let message = ["POST", "/trae/api/v3/oauth/ExchangeToken", "ono9krqynydwx5", refreshToken, String(timestamp), nonce].joined(separator: "\n")
        let signature = try key.signature(for: Data(message.utf8)).derRepresentation.base64EncodedString()
        return ["Signature": signature, "Timestamp": timestamp, "Nonce": nonce]
    }
}
