import Foundation

struct LyricsLine: Identifiable, Equatable {
    let id = UUID()
    let time: Double // 秒
    let text: String
}

/// 最小 LRC 解析：[mm:ss.xx]歌词，只认时间标签行。纯 Foundation，可本地验。
enum LyricsParser {
    static func parse(lrc: String) -> [LyricsLine] {
        var lines: [LyricsLine] = []
        for raw in lrc.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("["), let close = line.firstIndex(of: "]") else { continue }
            let tag = String(line[line.index(after: line.startIndex)..<close])
            guard let seconds = timeInterval(from: tag) else { continue }
            let text = String(line[line.index(after: close)...]).trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }
            lines.append(LyricsLine(time: seconds, text: text))
        }
        return lines.sorted { $0.time < $1.time }
    }

    /// "mm:ss" 或 "mm:ss.xx" -> 秒；非法返回 nil。
    static func timeInterval(from tag: String) -> Double? {
        let parts = tag.split(separator: ":")
        guard parts.count == 2,
              let minutes = Double(parts[0]) else { return nil }
        let secParts = parts[1].split(separator: ".")
        guard let seconds = Double(secParts[0]) else { return nil }
        var value = minutes * 60 + seconds
        if secParts.count == 2, let fraction = Double("0.\(secParts[1])") {
            value += fraction
        }
        return value
    }

    /// 当前时间对应的歌词行下标（无歌词返回 nil）。
    static func activeIndex(in lines: [LyricsLine], at time: Double) -> Int? {
        var result: Int?
        for (index, line) in lines.enumerated() where line.time <= time {
            result = index
        }
        return result
    }
}
