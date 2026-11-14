import Foundation
import RemoraCore
import Testing
import VNCSession

private struct ResolverFrames: FrameSink { func consume(_ frame: BorrowedFrame) {} }

@Test @MainActor func vncResolverPolicyDenialOffersRecovery() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    if ProcessInfo.processInfo.environment["REMORA_RESOLVER_FIXTURE"] == "1" {
        for mode in ["immediate-policy", "callback-policy", "mixed-policy", "process-policy", "missing"] {
            let session = VNCSession(
                configuration: .init(host: "\(mode).remora-test.local", port: 5900, username: "", desktopSize: .init(width: 16, height: 16)),
                frameSink: ResolverFrames(), certificateStoreURL: directory)
            let fallback = Task {
                do {
                    try await Task.sleep(for: .seconds(8))
                    session.disconnect()
                } catch {}
            }
            defer { fallback.cancel() }
            session.connect()
            var reasons: [DisconnectReason?] = []
            for await event in session.events {
                if case .stateChanged(.disconnected(let reason)) = event { reasons.append(reason) }
            }
            #expect(reasons == [mode == "missing" ? .hostNotFound : .localNetworkDenied], "Resolver mode: \(mode)")
        }
        return
    }

    // Interpose the real DNS-SD boundary only in a child running this test. The
    // child exercises the public session API and all native error propagation.
    let fixture = try #require(Bundle.module.url(forResource: "resolver_policy", withExtension: "c", subdirectory: "Fixtures"))
    let library = directory.appendingPathComponent("resolver_policy.dylib")
    let compiler = Process()
    compiler.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    compiler.arguments = ["clang", "-dynamiclib", "-Werror", fixture.path, "-o", library.path]
    try compiler.run()
    compiler.waitUntilExit()
    try #require(compiler.terminationStatus == 0)

    let arguments = CommandLine.arguments
    let bundleIndex = try #require(arguments.firstIndex(of: "--test-bundle-path"))
    let bundle = arguments[bundleIndex + 1]
    let child = Process()
    child.executableURL = URL(fileURLWithPath: arguments[0])
    child.arguments = ["--test-bundle-path", bundle, "--filter", "vncResolverPolicyDenialOffersRecovery", bundle, "--testing-library", "swift-testing"]
    var environment = ProcessInfo.processInfo.environment
    environment["REMORA_RESOLVER_FIXTURE"] = "1"
    environment["DYLD_INSERT_LIBRARIES"] = library.path
    child.environment = environment
    let output = Pipe()
    child.standardOutput = output
    child.standardError = output
    try child.run()
    let report = output.fileHandleForReading.readDataToEndOfFile()
    child.waitUntilExit()
    #expect(child.terminationStatus == 0, "\(String(decoding: report, as: UTF8.self))")
}
