#if canImport(CommonCrypto)
import CommonCrypto
#endif
import Foundation

/// 网易 eapi 加密（公开协议，自己实现；不抄任何仓库的代码）。
///
/// 算法（与公开文档一致，2026-11-26 已用 Python + Node 对真实接口验证过）：
///   text = JSON(请求体)
///   digest = MD5("nobody" + url + "use" + text + "md5forencrypt")
///   data = url + "-36cd479b6b5-" + text + "-36cd479b6b5-" + digest
///   params = AES-128-ECB(key="e82ckenh8dichen8", PKCS7) 加密后转大写十六进制
/// 域名直接写明文（不学 Kumone 的算术题混淆）。
/// 本文件只含 CommonCrypto 调用，Linux 上只能做 swiftc -parse，不能类型检查。
enum NeteaseCrypto {
    /// 网易接口域名（明文）。
    static let apiHost = "https://interface.music.163.com"
    static let webHost = "https://music.163.com"

    /// eapi 公开协议常量。
    static let eapiKey = "e82ckenh8dichen8"
    private static let eapiSeparator = "36cd479b6b5"

    /// eapi 请求体：返回 ["params": 大写十六进制]。
    static func eapiParams(url: String, object: [String: Any]) -> [String: String]? {
        guard let textData = try? JSONSerialization.data(
            withJSONObject: object, options: [.sortedKeys]),
            let text = String(data: textData, encoding: .utf8) else {
            return nil
        }
        // MD5 对下面这段 data 里的同一份 text 算，key 顺序不影响
        // （服务端解密后按同一份 text 重算 MD5 比对）。
        let message = "nobody\(url)use\(text)md5forencrypt"
        let digest = MD5.digestHex(message)
        let data = "\(url)-\(eapiSeparator)-\(text)-\(eapiSeparator)-\(digest)"
        guard let encryptedData = aesECBEncrypt(Data(data.utf8)) else {
            return nil
        }
        return ["params": encryptedData.map { String(format: "%02X", $0) }.joined()]
    }

    /// eapi 请求里带的 header（每次现算 requestId）。
    static func eapiHeader() -> [String: Any] {
        let requestId = "\(Int(Date().timeIntervalSince1970 * 1000))_\(Int.random(in: 0..<1000))"
        return [
            "os": "pc",
            "appver": "",
            "osver": "",
            "deviceId": "pyncmd",
            "requestId": requestId,
        ]
    }

    static func defaultHeaders() -> [String: String] {
        [
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
                + "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36",
            "Referer": "https://music.163.com/",
        ]
    }

    /// AES-128-ECB，PKCS7 填充（与 Node/OpenSSL 默认一致）。
    static func aesECBEncrypt(_ data: Data) -> Data? {
        #if canImport(CommonCrypto)
        let keyData = Data(eapiKey.utf8)
        var out = Data(count: data.count + kCCBlockSizeAES128)
        var outLength = 0
        let status = keyData.withUnsafeBytes { keyPtr in
            data.withUnsafeBytes { dataPtr in
                out.withUnsafeMutableBytes { outPtr in
                    CCCrypt(
                        CCEncrypt,
                        CCAlgorithm(kCCAlgorithmAES128),
                        CCOptions(kCCOptionPKCS7Padding | kCCOptionECBMode),
                        keyPtr.baseAddress, keyData.count,
                        nil,
                        dataPtr.baseAddress, data.count,
                        outPtr.baseAddress, out.count,
                        &outLength
                    )
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        out.count = outLength
        return out
        #else
        return nil
        #endif
    }
}
