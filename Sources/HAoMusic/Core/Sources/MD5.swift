import Foundation

/// 纯 Swift 实现的 MD5（RFC 1321），供网易 eapi 签名用。
/// 不用 CommonCrypto 的 CC_MD5（已废弃），且本文件可在 Linux 上单测。
/// 测试向量："" -> d41d8cd98f00b204e9800998ecf8427e；
/// "abc" -> 900150983cd24fb0d6963f7d28e17f72。
enum MD5 {
    private static let s: [UInt32] = [
        7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22,
        5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20,
        4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23,
        6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21,
    ]

    private static let k: [UInt32] = [
        0xd76aa478, 0xe8c7b756, 0x242070db, 0xc1bdceee,
        0xf57c0faf, 0x4787c62a, 0xa8304613, 0xfd469501,
        0x698098d8, 0x8b44f7af, 0xffff5bb1, 0x895cd7be,
        0x6b901122, 0xfd987193, 0xa679438e, 0x49b40821,
        0xf61e2562, 0xc040b340, 0x265e5a51, 0xe9b6c7aa,
        0xd62f105d, 0x02441453, 0xd8a1e681, 0xe7d3fbc8,
        0x21e1cde6, 0xc33707d6, 0xf4d50d87, 0x455a14ed,
        0xa9e3e905, 0xfcefa3f8, 0x676f02d9, 0x8d2a4c8a,
        0xfffa3942, 0x8771f681, 0x6d9d6122, 0xfde5380c,
        0xa4beea44, 0x4bdecfa9, 0xf6bb4b60, 0xbebfbc70,
        0x289b7ec6, 0xeaa127fa, 0xd4ef3085, 0x04881d05,
        0xd9d4d039, 0xe6db99e5, 0x1fa27cf8, 0xc4ac5665,
        0xf4292244, 0x432aff97, 0xab9423a7, 0xfc93a039,
        0x655b59c3, 0x8f0ccc92, 0xffeff47d, 0x85845dd1,
        0x6fa87e4f, 0xfe2ce6e0, 0xa3014314, 0x4e0811a1,
        0xf7537e82, 0xbd3af235, 0x2ad7d2bb, 0xeb86d391,
    ]

    private static func rotateLeft(_ x: UInt32, _ c: UInt32) -> UInt32 {
        (x << c) | (x >> (32 - c))
    }

    static func digestHex(_ string: String) -> String {
        digest(Data(string.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func digest(_ input: Data) -> [UInt8] {
        var message = [UInt8](input)
        let bitLength = UInt64(input.count) * 8
        message.append(0x80)
        while message.count % 64 != 56 {
            message.append(0)
        }
        for i in 0..<8 {
            message.append(UInt8((bitLength >> (8 * i)) & 0xff))
        }

        var a: UInt32 = 0x67452301
        var b: UInt32 = 0xefcdab89
        var c: UInt32 = 0x98badcfe
        var d: UInt32 = 0x10325476

        for chunkStart in stride(from: 0, to: message.count, by: 64) {
            var m = [UInt32](repeating: 0, count: 16)
            for i in 0..<16 {
                let base = chunkStart + i * 4
                m[i] = UInt32(message[base])
                    | (UInt32(message[base + 1]) << 8)
                    | (UInt32(message[base + 2]) << 16)
                    | (UInt32(message[base + 3]) << 24)
            }
            var aa = a, bb = b, cc = c, dd = d
            for i in 0..<64 {
                var f: UInt32
                var g: Int
                switch i / 16 {
                case 0:
                    f = (bb & cc) | (~bb & dd); g = i
                case 1:
                    f = (dd & bb) | (~dd & cc); g = (5 * i + 1) % 16
                case 2:
                    f = bb ^ cc ^ dd; g = (3 * i + 5) % 16
                default:
                    f = cc ^ (bb | ~dd); g = (7 * i) % 16
                }
                let tmp = dd
                dd = cc
                cc = bb
                bb = bb &+ rotateLeft(aa &+ f &+ k[i] &+ m[g], s[i])
                aa = tmp
            }
            a = a &+ aa
            b = b &+ bb
            c = c &+ cc
            d = d &+ dd
        }

        var result = [UInt8]()
        for value in [a, b, c, d] {
            for i in 0..<4 {
                result.append(UInt8((value >> (8 * i)) & 0xff))
            }
        }
        return result
    }
}
