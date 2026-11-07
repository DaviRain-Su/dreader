import Foundation

/// pi RPC 协议纯函数层:命令编码 + 事件解析,无 IO,可完整单测。
///
/// pi v1.5.0 RPC 模式实测协议:
/// - 帧 = 单行 JSON(LF 终止),stdin 写命令、stdout 读命令响应与事件
/// - 命令:`prompt` / `set_model` / `get_state` / `get_available_models` / `abort` / `set_thinking_level`
/// - 响应帧带 `id`(与请求关联);事件帧无 id
/// - 关键事件:`agent_start` / `turn_start` / `message_start` / `message_update`(text_delta 增量)/
///   `message_end`(权威文本)/ `agent_settled`(一轮收尾)
enum PiRPCProtocol {
    // MARK: - 命令编码

    /// 编码 `prompt` 命令帧(单行 JSON,含终端 LF)
    static func encodePrompt(text: String, requestID: String) -> Data {
        let payload: [String: Any] = [
            "type": "prompt",
            "message": text,
            "id": requestID,
        ]
        return encodePayload(payload)
    }

    /// 编码 `set_model` 命令帧
    static func encodeSetModel(provider: String, modelID: String, requestID: String) -> Data {
        let payload: [String: Any] = [
            "type": "set_model",
            "provider": provider,
            "modelId": modelID,
            "id": requestID,
        ]
        return encodePayload(payload)
    }

    /// 编码 `abort` 命令帧
    static func encodeAbort(requestID: String) -> Data {
        let payload: [String: Any] = [
            "type": "abort",
            "id": requestID,
        ]
        return encodePayload(payload)
    }

    /// 编码 `get_state` 命令帧
    static func encodeGetState(requestID: String) -> Data {
        let payload: [String: Any] = [
            "type": "get_state",
            "id": requestID,
        ]
        return encodePayload(payload)
    }

    /// 编码 `get_available_models` 命令帧
    static func encodeGetAvailableModels(requestID: String) -> Data {
        encodePayload(["type": "get_available_models", "id": requestID])
    }

    /// 编码 `get_available_models` 命令帧(字典形态,供 sendCommand 注入 id)
    static func encodeGetAvailableModelsDict(requestID: String) -> [String: Any] {
        ["type": "get_available_models", "id": requestID]
    }

    // MARK: - 模型清单/状态解析

    /// pi 模型条目(从 get_available_models 响应提取;纯值 Sendable)
    struct ModelInfo: Equatable, Sendable, Identifiable {
        var provider: String
        var modelID: String
        var name: String

        var id: String { "\(provider)/\(modelID)" }
        /// 展示名:provider 有歧义时带前缀
        var displayLabel: String {
            name.isEmpty ? modelID : name
        }
    }

    /// 解析 get_available_models 响应 → 模型清单
    static func parseAvailableModels(from response: [String: Any]) -> [ModelInfo] {
        guard let data = response["data"] as? [String: Any],
              let models = data["models"] as? [[String: Any]] else { return [] }
        return models.compactMap { m in
            guard let provider = m["provider"] as? String,
                  let modelID = m["id"] as? String else { return nil }
            return ModelInfo(
                provider: provider,
                modelID: modelID,
                name: m["name"] as? String ?? ""
            )
        }
    }

    /// 解析 get_state 响应 → 当前模型(provider/modelID)
    static func parseCurrentModel(from response: [String: Any]) -> (provider: String, modelID: String)? {
        guard let data = response["data"] as? [String: Any],
              let model = data["model"] as? [String: Any],
              let modelID = model["id"] as? String else { return nil }
        return (model["provider"] as? String ?? "", modelID)
    }

    // MARK: - 事件解析

    /// 单帧解析结果(不跨 actor 边界;Sendable 要求只落在 PiEvent 上)
    enum Frame {
        /// 命令响应(带 id)
        case response(id: String, success: Bool, payload: [String: Any])
        /// 会话事件
        case event(PiEvent)
        /// 无法解析的帧
        case unparseable
    }

    /// 解析单行 JSON 帧
    static func parseFrame(_ line: String) -> Frame {
        guard let data = line.data(using: .utf8),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let type = json["type"] as? String else {
            return .unparseable
        }
        if type == "response" {
            let id = json["id"] as? String ?? ""
            let success = json["success"] as? Bool ?? false
            return .response(id: id, success: success, payload: json)
        }
        guard json["id"] == nil else {
            // 带 id 的非响应帧:协议外帧,按事件宽容处理
            return .event(parseEvent(json) ?? .unknown)
        }
        guard let event = parseEvent(json) else {
            return .event(.unknown)
        }
        return .event(event)
    }

    /// 从响应 payload 提取错误消息
    static func errorMessage(from response: [String: Any]) -> String {
        if let error = response["error"] as? String, !error.isEmpty {
            return error
        }
        return "pi 未返回错误详情"
    }

    /// 从原始 json 解析事件帧;响应帧(带 id)返回 nil
    static func parseEvent(from json: [String: Any]) -> PiEvent? {
        if json["type"] as? String == "response" { return nil }
        return parseEvent(json)
    }

    /// 从原始 JSON 行解析事件帧;响应帧返回 nil
    static func parseEvent(fromLine line: String) -> PiEvent? {
        guard let data = line.data(using: .utf8),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        return parseEvent(from: json)
    }

    /// 从 message_end / message_update 提取权威文本
    static func assistantText(from message: [String: Any]) -> String? {
        // pi 的 message 对象:{"role": "assistant", "content": [{"type": "text", "text": "..."}]}
        guard let role = message["role"] as? String, role == "assistant" else { return nil }
        if let content = message["content"] as? [[String: Any]] {
            let text = content.compactMap { block -> String? in
                guard let blockType = block["type"] as? String, blockType == "text",
                      let text = block["text"] as? String else { return nil }
                return text
            }
            .joined()
            return text
        }
        if let text = message["text"] as? String {
            return text
        }
        return nil
    }

    /// 从 message_update 事件提取增量 delta
    static func textDelta(from event: [String: Any]) -> String? {
        guard let delta = event["delta"] as? String else { return nil }
        return delta
    }

    /// assistant 消息是否以错误收场(stopReason == "error",错误详情在 errorMessage 字段)
    static func assistantErrorMessage(from message: [String: Any]) -> String? {
        guard let role = message["role"] as? String, role == "assistant",
              let stopReason = message["stopReason"] as? String, stopReason == "error" else { return nil }
        return message["errorMessage"] as? String ?? "pi assistant 以 error 收场"
    }

    // MARK: - Internals

    private static func encodePayload(_ payload: [String: Any]) -> Data {
        var data = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data("{}".utf8)
        data.append(0x0A)
        return data
    }

    /// 解析会话事件;未知类型返回 nil(调用方决定是否宽容为 unknown)
    private static func parseEvent(_ json: [String: Any]) -> PiEvent? {
        guard let type = json["type"] as? String else { return nil }
        switch type {
        case "agent_start":
            return .agentStart
        case "turn_start":
            return .turnStart
        case "message_start":
            if let role = (json["message"] as? [String: Any])?["role"] as? String {
                return .messageStart(role: role)
            }
            return .messageStart(role: nil)
        case "message_update":
            // pi v1.5.0 实测(rpc.md/json.md 权威形态):增量在嵌套 assistantMessageEvent 字段
            // {"type":"message_update","assistantMessageEvent":{"type":"text_delta","contentIndex":0,"delta":"..."}}
            if let nested = json["assistantMessageEvent"] as? [String: Any] {
                let kind = nested["type"] as? String
                if kind == "text_delta", let delta = nested["delta"] as? String {
                    return .textDelta(delta)
                }
                // text_start / text_end 等非增量形态:无新文本,忽略
                return nil
            }
            // 兼容旧顶层形态(防御:{"type":"message_update","delta":"..."})
            if let delta = json["delta"] as? String {
                return .textDelta(delta)
            }
            return nil
        case "message_end":
            guard let message = json["message"] as? [String: Any] else { return nil }
            // 解析时即提取权威载荷(纯值类型,Sendable);非 assistant 消息不带载荷
            guard let role = message["role"] as? String, role == "assistant" else {
                return .messageEnd(completion: nil)
            }
            let completion = PiAssistantCompletion(
                text: assistantText(from: message) ?? "",
                stopReason: message["stopReason"] as? String ?? "stop",
                errorMessage: assistantErrorMessage(from: message)
            )
            return .messageEnd(completion: completion)
        case "agent_end":
            // 一轮结束:带 messages 数组与 willRetry;错误时 assistant 消息 stopReason=="error"
            return .agentEnd
        case "agent_start_error", "agent_error":
            let error = json["error"] as? String ?? "pi agent 错误"
            return .agentError(error)
        case "agent_settled":
            return .agentSettled
        default:
            return nil
        }
    }
}

/// message_end 提取出的 assistant 权威载荷(纯值类型,Sendable,可跨 actor)
struct PiAssistantCompletion: Equatable, Sendable {
    /// 全部 text 块拼接(权威文本)
    var text: String
    /// stopReason("stop"/"length"/"error"/"aborted"…)
    var stopReason: String
    /// stopReason == "error" 时的错误详情
    var errorMessage: String?
}

/// pi 会话事件(解析后强类型;全部关联值 Sendable,可装进 AsyncStream 跨 actor)
enum PiEvent: Equatable, Sendable {
    case agentStart
    case turnStart
    case messageStart(role: String?)
    /// 增量文本
    case textDelta(String)
    /// 一条消息完成(assistant 权威载荷在解析时已提取)
    case messageEnd(completion: PiAssistantCompletion?)
    /// 一轮结束(agent_end,带 messages;settled 前的最终事件)
    case agentEnd
    case agentError(String)
    /// 一轮收尾(abort 或正常结束都会发)
    case agentSettled
    case unknown

    static func == (lhs: PiEvent, rhs: PiEvent) -> Bool {
        switch (lhs, rhs) {
        case (.agentStart, .agentStart),
             (.turnStart, .turnStart),
             (.agentEnd, .agentEnd),
             (.agentSettled, .agentSettled),
             (.unknown, .unknown):
            return true
        case let (.messageStart(l), .messageStart(r)):
            return l == r
        case let (.textDelta(l), .textDelta(r)):
            return l == r
        case let (.agentError(l), .agentError(r)):
            return l == r
        case let (.messageEnd(l), .messageEnd(r)):
            return l == r
        default:
            return false
        }
    }
}