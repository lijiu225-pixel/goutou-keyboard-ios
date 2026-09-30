import Foundation

func expectError(_ expected: AppGroupDiagnosticError, _ operation: () throws -> Void) {
    do { try operation(); fatalError("Expected error: \(expected)") }
    catch let error as AppGroupDiagnosticError {
        precondition(String(describing: error) == String(describing: expected))
    } catch { fatalError("Unexpected error: \(error)") }
}
let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: temporary) }
let writer = AppGroupDiagnostics(testContainer: temporary)
let reader = AppGroupDiagnostics(testContainer: temporary)
expectError(.unavailable) { _ = try AppGroupDiagnostics(testContainer: nil).writeProbe() }
expectError(.unavailable) { _ = try AppGroupDiagnostics(testContainer: nil).readProbe() }
expectError(.missing) { _ = try reader.readProbe() }
let first = try writer.writeProbe(now: Date(timeIntervalSince1970: 1000))
let readFirst = try reader.readProbe()
precondition(readFirst == first)
let second = try writer.writeProbe(now: Date(timeIntervalSince1970: 2000))
let readSecond = try reader.readProbe()
precondition(readSecond == second)
precondition(first.timestamp != second.timestamp)
let file = temporary.appendingPathComponent(SharedConstants.probeDirectory)
    .appendingPathComponent(SharedConstants.probeFilename)
for content in ["{}", "broken", String(repeating: "x", count: 5000)] {
    try Data(content.utf8).write(to: file)
    expectError(.invalid) { _ = try reader.readProbe() }
}
for probe in [AppGroupProbe(source: "keyboard", timestamp: second.timestamp, value: second.value),
              AppGroupProbe(source: second.source, timestamp: second.timestamp, value: "wrong"),
              AppGroupProbe(source: second.source, timestamp: "bad-date", value: second.value)] {
    try JSONEncoder().encode(probe).write(to: file)
    expectError(.invalid) { _ = try reader.readProbe() }
}
let blocker = temporary.appendingPathComponent("blocker")
try Data("file".utf8).write(to: blocker)
expectError(.writeFailed) { _ = try AppGroupDiagnostics(testContainer: blocker).writeProbe() }
print("AppGroupProbeCheck passed (filesystem contract only; phone entitlement access is unverified)")
