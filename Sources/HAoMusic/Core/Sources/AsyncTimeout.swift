import Foundation

/// 播放解析时的错误分类：超时和瞬断不记失败记忆，只有硬错误才记。
enum ResolveError: Error, Equatable, Sendable {
    /// 网络瞬断（400ms 后重试一次，Kumone 的规则）。
    case transient(String)
    /// 服务器明确拒绝 / 返回体不对 / 无可播地址：记失败记忆。
    case hard(String)
    /// 单源 8 秒 / 总 15 秒超时（Coda 的规则）：不记失败记忆。
    case timeout
}

/// 带超时的异步执行：到时抛 ResolveError.timeout。
func withTimeout<T: Sendable>(
    seconds: Double,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw ResolveError.timeout
        }
        guard let result = try await group.next() else {
            throw ResolveError.timeout
        }
        group.cancelAll()
        return result
    }
}
