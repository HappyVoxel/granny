import XCTest
@testable import GrannyCore

/// The contract is data, not Swift: these cases are also the target a Rust or
/// TypeScript engine develops against, so they live outside the test bundle at
/// `tests/engine/contract.jsonl`.
final class EngineProtocolTests: XCTestCase {
    private static let contractLines: [String] = {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // GrannyCoreTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // GrannyAgent
            .deletingLastPathComponent()  // repo root
        let file = root.appendingPathComponent("tests/engine/contract.jsonl")
        let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        return text.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }()

    func testContractFileIsPresent() {
        XCTAssertGreaterThanOrEqual(Self.contractLines.count, 12, "tests/engine/contract.jsonl")
    }

    func testEveryContractLineSurvivesARoundTrip() throws {
        var requests = 0
        var replies = 0
        var pushes = 0
        for (index, line) in Self.contractLines.enumerated() {
            let envelope = try EngineLine.decode(line)
            let reencoded = try EngineLine.encode(envelope)
            let again = try EngineLine.decode(reencoded)
            XCTAssertEqual(envelope, again, "line \(index + 1) does not survive encoding")
            if envelope.isRequest {
                requests += 1
            } else if envelope.isReply {
                replies += 1
            } else {
                pushes += 1
            }
        }
        XCTAssertGreaterThan(requests, 0)
        XCTAssertGreaterThan(replies, 0)
        XCTAssertGreaterThan(pushes, 0)
    }

    func testHandshakeAcceptsAKernelHello() throws {
        let envelope = try EngineLine.decode(Self.contractLines[1])
        let hello = try EngineHandshake.accept(envelope, expecting: .kernel).get()
        XCTAssertEqual(hello.impl, "granny/0.9.0")
        XCTAssertEqual(hello.limits?.nudgesRemaining, 3)
        XCTAssertEqual(hello.limits?.quietStart, 22)
    }

    func testHandshakeRefusesANewerProtocol() throws {
        let hello = EngineHello(role: .kernel, impl: "granny/1.0.0", capabilities: [])
        let envelope = EngineEnvelope(
            v: 2, id: "x", method: "hello", params: try EngineJSON.encoded(hello))
        let failure = EngineHandshake.accept(envelope, expecting: .kernel)
        XCTAssertEqual(failure, .failure(.unsupportedVersion(local: 1, remote: 2)))
    }

    func testHandshakeRefusesTheWrongRole() throws {
        let hello = EngineHello(role: .engine, impl: "granny-engine/0.1.0", capabilities: [])
        let envelope = EngineEnvelope.request(
            id: "x", method: "hello", params: try EngineJSON.encoded(hello))
        XCTAssertEqual(
            EngineHandshake.accept(envelope, expecting: .kernel),
            .failure(.wrongRole(.engine)))
    }

    func testAnInventedMethodHasNoCapability() throws {
        let invented = try EngineLine.decode(
            #"{"v":1,"id":"e-9","method":"state.task.giveup","params":{}}"#)
        XCTAssertNil(invented.capability)
        XCTAssertEqual(invented.method, "state.task.giveup")
    }

    func testDesignedButUnbuiltMethodsAreNotAvailableYet() {
        XCTAssertTrue(EngineProtocol.available.contains(.stateRead))
        XCTAssertTrue(EngineProtocol.available.contains(.modelStream))
        XCTAssertFalse(EngineProtocol.available.contains(.roundStart))
    }

    func testDuplicateCarriesTheFirstResultSoAResumedRunCanContinue() throws {
        let duplicate = try EngineLine.decode(Self.contractLines[7])
        XCTAssertEqual(duplicate.error?.code, .duplicate)
        XCTAssertEqual(duplicate.error?.result, .object(["taskID": .string("t-9")]))
    }

    func testNumbersStayIntegers() throws {
        let text = try EngineLine.encode(
            .push(event: "model.done", params: .object(["usage": .object(["in": .number(42)])])))
        XCTAssertTrue(text.contains(#""in":42"#), text)
    }

    func testBlankLinesAreRejectedRatherThanDecodedIntoNull() {
        XCTAssertThrowsError(try EngineLine.decode("   \n"))
    }
}
