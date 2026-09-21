import XCTest
@testable import ClassNote

/// Regressions for the engine-layer bugs: a venv whose interpreter vanished, a
/// half-downloaded Hugging Face snapshot reported as ready, and a stored STT
/// backend that no longer names a real engine.
///
/// Deliberately pure — no network, no sidecar, no Application Support — so they
/// run on a CI machine with nothing installed.
final class VenvRebuildTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("classnote-venv-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// Writes an executable stub that answers `--version` like CPython does.
    private func makeFakePython(_ path: URL, reporting version: String) throws {
        try "#!/bin/sh\necho \"Python \(version)\"\n".write(to: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
    }

    func testNoVenvNeedsRebuild() {
        XCTAssertTrue(LocalASREnvironment.needsRebuild(
            pythonBinPath: root.appendingPathComponent("bin/python3").path,
            venvExists: false))
    }

    /// The actual bug: the base interpreter was deleted, so `bin/python3` is a
    /// symlink to nothing. `fileExists` follows symlinks and reported "absent",
    /// which sent `install()` down the create-in-place path, and `python -m venv`
    /// will not replace a destination that is already a symlink.
    func testDanglingInterpreterSymlinkNeedsRebuild() throws {
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let python = bin.appendingPathComponent("python3")
        try FileManager.default.createSymbolicLink(
            atPath: python.path,
            withDestinationPath: root.appendingPathComponent("gone/python3").path)

        XCTAssertTrue(LocalASREnvironment.needsRebuild(pythonBinPath: python.path, venvExists: true))
    }

    func testTooOldInterpreterNeedsRebuild() throws {
        let python = root.appendingPathComponent("python3")
        try makeFakePython(python, reporting: "3.9.6")
        XCTAssertTrue(LocalASREnvironment.needsRebuild(pythonBinPath: python.path, venvExists: true))
    }

    func testUsableInterpreterIsKept() throws {
        let python = root.appendingPathComponent("python3")
        try makeFakePython(python, reporting: "3.11.4")
        XCTAssertFalse(LocalASREnvironment.needsRebuild(pythonBinPath: python.path, venvExists: true))
    }
}

final class HuggingFaceCacheTests: XCTestCase {
    private var snapshot: URL!

    override func setUpWithError() throws {
        snapshot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("classnote-hf-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: snapshot)
    }

    private func write(_ name: String) throws {
        try Data("x".utf8).write(to: snapshot.appendingPathComponent(name))
    }

    /// `hf_hub_download` creates `snapshots/<revision>/` before the first byte
    /// arrives, so an empty one proved nothing and Settings reported a model
    /// that was still downloading as ready.
    func testEmptySnapshotIsIncomplete() {
        XCTAssertFalse(HuggingFaceCache.snapshotIsComplete(at: snapshot))
    }

    func testConfigWithoutWeightsIsIncomplete() throws {
        try write("config.json")
        try write("tokenizer.json")
        XCTAssertFalse(HuggingFaceCache.snapshotIsComplete(at: snapshot))
    }

    func testWeightsWithoutTokenizerIsIncomplete() throws {
        try write("config.json")
        try write("model.safetensors")
        XCTAssertFalse(HuggingFaceCache.snapshotIsComplete(at: snapshot))
    }

    func testCompleteSnapshot() throws {
        try write("config.json")
        try write("tokenizer.json")
        try write("model-00001-of-00002.safetensors")
        XCTAssertTrue(HuggingFaceCache.snapshotIsComplete(at: snapshot))
    }

    /// A pointer file whose blob never landed: `fileExists` resolves the symlink,
    /// so the snapshot must read as incomplete.
    func testDanglingPointerIsIncomplete() throws {
        try write("config.json")
        try write("model.safetensors")
        try FileManager.default.createSymbolicLink(
            atPath: snapshot.appendingPathComponent("tokenizer.json").path,
            withDestinationPath: snapshot.appendingPathComponent("../blobs/missing").path)
        XCTAssertFalse(HuggingFaceCache.snapshotIsComplete(at: snapshot))
    }

    func testRepoDirectoryNameMatchesHubLayout() {
        XCTAssertEqual(HuggingFaceCache.repoURL("mlx-community/Hy-MT2-1.8B-4bit").lastPathComponent,
                       "models--mlx-community--Hy-MT2-1.8B-4bit")
    }
}

final class SttBackendResolveTests: XCTestCase {
    func testUnknownValueFallsBackToCloud() {
        XCTAssertEqual(SttBackend.resolve("whisperkit"), .openAICompatible)
        XCTAssertEqual(SttBackend.resolve(""), .openAICompatible)
    }

    /// Both cases drive the same sidecar now, and only `.funasr` is offered, so
    /// a stored "nemotron" has to fold — `saveConfig` used to skip this and
    /// republished a value the picker cannot display.
    func testRetiredNemotronFoldsOntoFunasr() {
        XCTAssertEqual(SttBackend.resolve("nemotron"), .funasr)
    }

    func testKnownValuesRoundTrip() {
        for backend in SttBackend.selectableCases {
            XCTAssertEqual(SttBackend.resolve(backend.rawValue), backend)
        }
    }

    func testLocalSidecarClassification() {
        XCTAssertTrue(SttBackend.funasr.isLocalSidecar)
        XCTAssertFalse(SttBackend.openAICompatible.isLocalSidecar)
        XCTAssertFalse(SttBackend.appleSpeech.isLocalSidecar)
    }
}

final class LLMBackendTests: XCTestCase {
    func testRawValuesMatchTheStoredStrings() {
        XCTAssertEqual(LLMBackend(rawValue: "openai"), .openAICompatible)
        XCTAssertEqual(LLMBackend(rawValue: "mlx"), .localMLX)
        XCTAssertNil(LLMBackend(rawValue: "whatever"))
    }

    func testOnlyTheMLXBackendIsALocalSidecar() {
        XCTAssertTrue(LLMBackend.localMLX.isLocalSidecar)
        XCTAssertFalse(LLMBackend.openAICompatible.isLocalSidecar)
    }
}

final class EngineErrorLocalizationTests: XCTestCase {
    /// The five engine errors reach the user verbatim through `setError`, so
    /// they have to come out of L10n with their argument filled in rather than
    /// with a literal placeholder.
    func testArgumentsAreInterpolated() {
        let message = EngineError.networkError("timed out").errorDescription ?? ""
        XCTAssertTrue(message.contains("timed out"), message)
        XCTAssertFalse(message.contains("%@"), message)
    }

    func testHttpErrorFillsBothPlaceholders() {
        let message = EngineError.httpError(status: 429, body: "slow down").errorDescription ?? ""
        XCTAssertTrue(message.contains("429"), message)
        XCTAssertTrue(message.contains("slow down"), message)
        XCTAssertFalse(message.contains("%@"), message)
    }

    func testMissingApiKeyIsNotTheRawKey() {
        let message = EngineError.missingApiKey.errorDescription ?? ""
        XCTAssertFalse(message.isEmpty)
        XCTAssertNotEqual(message, "engine.error.missingApiKey")
    }
}

final class SidecarErrorCodeTests: XCTestCase {
    /// The sidecar's `message` is a developer string (a path, an exception).
    /// A known `code` is what the user should see instead.
    func testKnownCodeIsLocalized() {
        let error = LocalASRConnectionError.sidecar(code: "file.missing",
                                                    message: "file not found: /tmp/x.wav")
        let message = error.errorDescription ?? ""
        XCTAssertFalse(message.contains("/tmp/x.wav"), message)
        XCTAssertNotEqual(message, "localASR.error.file.missing")
    }

    func testUnknownCodeFallsBackToTheRawMessage() {
        let error = LocalASRConnectionError.sidecar(code: "some.future.code", message: "raw detail")
        XCTAssertEqual(error.errorDescription, "raw detail")
    }

    func testMissingCodeFallsBackToTheRawMessage() {
        let error = LocalASRConnectionError.sidecar(code: nil, message: "raw detail")
        XCTAssertEqual(error.errorDescription, "raw detail")
    }
}
