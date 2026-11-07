import XCTest
@testable import DReader

/// pi RPC 协议纯函数层:命令编码 + 事件解析(以 pi v1.5.0 实测事件流为权威)
final class PiRPCProtocolTests: XCTestCase {

    // MARK: - 命令编码

    func testEncodePromptIsSingleLFFramedLine() throws {
        let data = PiRPCProtocol.encodePrompt(text: "你好\n世界", requestID: "req-1")
        let line = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(line.hasSuffix("\n"), "帧必须 LF 终止")
        XCTAssertEqual(line.filter { $0 == "\n" }.count, 1, "一帧只允许一个 LF")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["type"] as? String, "prompt")
        XCTAssertEqual(json["message"] as? String, "你好\n世界")
        XCTAssertEqual(json["id"] as? String, "req-1")
    }

    func testEncodeSetModelAndAbort() throws {
        let setModel = String(decoding: PiRPCProtocol.encodeSetModel(
            provider: "magpie", modelID: "zai-glm", requestID: "r2"), as: UTF8.self)
        let setJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(setModel.utf8)) as? [String: Any])
        XCTAssertEqual(setJSON["provider"] as? String, "magpie")
        XCTAssertEqual(setJSON["modelId"] as? String, "zai-glm")

        let abort = String(decoding: PiRPCProtocol.encodeAbort(requestID: "r3"), as: UTF8.self)
        let abortJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(abort.utf8)) as? [String: Any])
        XCTAssertEqual(abortJSON["type"] as? String, "abort")
    }

    // MARK: - 事件解析

    func testParseResponseFrameCarriesIDAndSuccess() {
        let line = #"{"id":"dreader-req-1","type":"response","command":"prompt","success":true,"data":{"disposition":"started"}}"#
        guard case let .response(id, success, payload) = PiRPCProtocol.parseFrame(line) else {
            return XCTFail("响应帧应解析为 .response")
        }
        XCTAssertEqual(id, "dreader-req-1")
        XCTAssertTrue(success)
        let data = try? XCTUnwrap(payload["data"] as? [String: Any])
        XCTAssertEqual(data?["disposition"] as? String, "started")
    }

    func testParseFrameRejectsGarbage() {
        guard case .unparseable = PiRPCProtocol.parseFrame("not json at all") else {
            return XCTFail("非 JSON 行应返回 .unparseable")
        }
    }

    /// 实测事件流:agent_start → turn_start → message_start/end(system→user→assistant)
    /// → message_update(嵌套 assistantMessageEvent)→ turn_end → agent_end → agent_settled
    func testParseFullEventSequenceFromRealProbe() {
        let sequence: [(String, PiEvent?)] = [
            (#"{"type":"agent_start"}"#, .agentStart),
            (#"{"type":"turn_start"}"#, .turnStart),
            (#"{"type":"message_start","message":{"role":"system"}}"#, .messageStart(role: "system")),
            (#"{"type":"message_start","message":{"role":"user"}}"#, .messageStart(role: "user")),
            (#"{"type":"message_start","message":{"role":"assistant"}}"#, .messageStart(role: "assistant")),
            (
                #"{"type":"message_update","assistantMessageEvent":{"type":"text_start","contentIndex":0}}"#,
                nil
            ),
            (
                #"{"type":"message_update","assistantMessageEvent":{"type":"text_delta","contentIndex":0,"delta":"OK"}}"#,
                .textDelta("OK")
            ),
            (
                #"{"type":"message_update","assistantMessageEvent":{"type":"text_end","contentIndex":0,"content":"OK"}}"#,
                nil
            ),
            (
                #"{"type":"message_end","message":{"role":"assistant","content":[{"type":"text","text":"OK"}],"stopReason":"stop"}}"#,
                .messageEnd(completion: PiAssistantCompletion(text: "OK", stopReason: "stop", errorMessage: nil))
            ),
            (#"{"type":"turn_end"}"#, nil),
            (#"{"type":"agent_end"}"#, .agentEnd),
            (#"{"type":"agent_settled","aborted":false}"#, .agentSettled),
        ]
        for (line, expected) in sequence {
            guard case let .event(event) = PiRPCProtocol.parseFrame(line) else {
                return XCTFail("事件帧应解析为 .event:\(line.prefix(60))")
            }
            if let expected {
                XCTAssertEqual(event, expected, "事件不匹配:\(line.prefix(80))")
            }
        }
    }

    /// 增量在嵌套 assistantMessageEvent 字段(pi 文档权威形态)
    func testMessageUpdateDeltaLivesInNestedAssistantMessageEvent() {
        let line = #"{"type":"message_update","assistantMessageEvent":{"type":"text_delta","contentIndex":3,"delta":"片段"}}"#
        guard case let .event(.textDelta(delta)) = PiRPCProtocol.parseFrame(line) else {
            return XCTFail("嵌套 text_delta 应解析为 .textDelta")
        }
        XCTAssertEqual(delta, "片段")
    }

    /// 防御:顶层 delta 旧形态仍宽容兼容
    func testMessageUpdateToleratesLegacyTopLevelDelta() {
        let line = #"{"type":"message_update","delta":"旧形态"}"#
        guard case let .event(.textDelta(delta)) = PiRPCProtocol.parseFrame(line) else {
            return XCTFail("顶层 delta 应宽容兼容")
        }
        XCTAssertEqual(delta, "旧形态")
    }

    func testMessageEndCarriesAuthoritativeAssistantText() {
        let line = #"{"type":"message_end","message":{"role":"assistant","content":[{"type":"text","text":"权威译文"}],"stopReason":"stop"}}"#
        guard case let .event(.messageEnd(completion)) = PiRPCProtocol.parseFrame(line) else {
            return XCTFail("message_end 应携带 completion")
        }
        XCTAssertEqual(completion?.text, "权威译文")
        XCTAssertEqual(completion?.stopReason, "stop")
        XCTAssertNil(completion?.errorMessage)
    }

    /// 非 assistant 消息的 message_end 不带载荷
    func testMessageEndForUserMessageHasNoCompletion() {
        let line = #"{"type":"message_end","message":{"role":"user","content":[{"type":"text","text":"问"}]}}"#
        guard case let .event(.messageEnd(completion)) = PiRPCProtocol.parseFrame(line) else {
            return XCTFail("message_end 应解析为事件")
        }
        XCTAssertNil(completion)
    }

    /// stopReason=="error" 的 assistant 消息带 errorMessage 详情
    func testAssistantErrorMessageExtractedFromStopReason() {
        let error = ["role": "assistant", "stopReason": "error", "errorMessage": "网关超时"] as [String: Any]
        XCTAssertEqual(PiRPCProtocol.assistantErrorMessage(from: error), "网关超时")

        let ok = ["role": "assistant", "stopReason": "stop"] as [String: Any]
        XCTAssertNil(PiRPCProtocol.assistantErrorMessage(from: ok))

        let user = ["role": "user", "stopReason": "error"] as [String: Any]
        XCTAssertNil(PiRPCProtocol.assistantErrorMessage(from: user))
    }

    // MARK: - assistantText 提取

    func testAssistantTextJoinsTextBlocksAndSkipsThinking() {
        let message: [String: Any] = [
            "role": "assistant",
            "content": [
                ["type": "thinking", "thinking": "推理过程"],
                ["type": "text", "text": "第一段"],
                ["type": "text", "text": "第二段"],
            ],
        ]
        XCTAssertEqual(PiRPCProtocol.assistantText(from: message), "第一段第二段")
    }

    func testAssistantTextReturnsNilForNonAssistant() {
        let user: [String: Any] = ["role": "user", "content": [["type": "text", "text": "问"]]]
        XCTAssertNil(PiRPCProtocol.assistantText(from: user))
        XCTAssertNil(PiRPCProtocol.assistantText(from: [:]))
    }

    // MARK: - U+2028 帧完整性(协议层防御的字节级分割由连接层负责,这里验证解析端宽容)

    /// pi 的 JSON.stringify 不转义 U+2028;解析端 JSONSerialization 原生兼容,
    /// 帧撕裂风险在连接层(lfSplitFrames),此处验证含该字符的行仍能完整解析。
    func testParseEventToleratesU2028InsideJSONStrings() {
        let line = "{\"type\":\"message_update\",\"assistantMessageEvent\":{\"type\":\"text_delta\",\"delta\":\"前\u{2028}后\"}}"
        guard case let .event(.textDelta(delta)) = PiRPCProtocol.parseFrame(line) else {
            return XCTFail("含 U+2028 的帧应完整解析(行分割由连接层字节级处理)")
        }
        XCTAssertEqual(delta, "前\u{2028}后")
    }
}
