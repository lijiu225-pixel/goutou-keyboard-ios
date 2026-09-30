import Foundation

struct AppGroupProbe: Codable, Equatable {
    let source: String
    let timestamp: String
    let value: String
}

enum AppGroupDiagnosticError: Error, LocalizedError {
    case unavailable, missing, invalid, readFailed, writeFailed
    var errorDescription: String? {
        switch self {
        case .unavailable: return "共享容器不可用：请检查两端重签权限与键盘完全访问。"
        case .missing: return "容器可用，但没有测试文件；请先在主 App 写入测试数据。"
        case .invalid: return "测试文件内容异常，请在主 App 重新写入。"
        case .readFailed: return "测试文件读取失败，请检查签名和容器访问权限。"
        case .writeFailed: return "测试数据写入失败，请检查签名和容器访问权限。"
        }
    }
}

struct AppGroupDiagnostics {
    private let resolveContainer: () -> URL?

    init() {
        resolveContainer = {
            FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: SharedConstants.appGroupID
            )
        }
    }

    // Only for isolated filesystem tests; production always uses init(). No fallback.
    init(testContainer: URL?) { resolveContainer = { testContainer } }

    func sharedContainerURL() -> URL? { resolveContainer() }

    private func probeURL() throws -> URL {
        guard let container = sharedContainerURL() else {
            throw AppGroupDiagnosticError.unavailable
        }
        return container.appendingPathComponent(SharedConstants.probeDirectory, isDirectory: true)
            .appendingPathComponent(SharedConstants.probeFilename)
    }

    @discardableResult
    func writeProbe(now: Date = Date()) throws -> AppGroupProbe {
        let url = try probeURL()
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let probe = AppGroupProbe(source: "main-app", timestamp: formatter.string(from: now),
                                  value: "goutou-app-group-test")
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try JSONEncoder().encode(probe).write(to: url, options: .atomic)
        } catch { throw AppGroupDiagnosticError.writeFailed }
        return probe
    }

    func readProbe() throws -> AppGroupProbe {
        let url = try probeURL()
        let data: Data
        do {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size > 0, size <= 4096 else { throw AppGroupDiagnosticError.invalid }
            data = try Data(contentsOf: url)
        } catch let error as AppGroupDiagnosticError { throw error }
        catch {
            if (error as NSError).domain == NSCocoaErrorDomain,
               (error as NSError).code == NSFileReadNoSuchFileError {
                throw AppGroupDiagnosticError.missing
            }
            throw AppGroupDiagnosticError.readFailed
        }
        guard data.count <= 4096,
              let probe = try? JSONDecoder().decode(AppGroupProbe.self, from: data),
              probe.source == "main-app", probe.value == "goutou-app-group-test",
              ISO8601DateFormatter.probeFormatter.date(from: probe.timestamp) != nil else {
            throw AppGroupDiagnosticError.invalid
        }
        return probe
    }
}

private extension ISO8601DateFormatter {
    static var probeFormatter: ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }
}
