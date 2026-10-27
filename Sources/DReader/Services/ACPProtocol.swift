import Foundation

/// Supported Agent execution drivers
enum AgentDriverType: String, CaseIterable, Identifiable, Codable {
    case acpStdio = "ACP 标准协议 (Stdio)"
    case cliStreaming = "CLI 独立流式驱动"
    case httpAdapter = "HTTP / 本地端口"
    case embedded = "内置离线伴读"

    var id: String { rawValue }
}

/// Agent Presets supporting all user requested agents: Grok, Pi, Claude Code, Codex, Cursor, Kimi
struct ACPAgentPreset: Identifiable, Hashable {
    let id: String
    let name: String
    let command: String
    let description: String
    let driverType: AgentDriverType
    let defaultBin: String
    let iconName: String

    static let allPresets: [ACPAgentPreset] = [
        ACPAgentPreset(
            id: "kimi",
            name: "Kimi (K3.1 Pro)",
            command: "kimi -m kimi-code/k3.1-pro acp",
            description: "Moonshot Kimi Code (K3.1 Pro 超强旗舰推理) 原生 ACP 协议服务",
            driverType: .acpStdio,
            defaultBin: "kimi",
            iconName: "sparkles"
        ),
        ACPAgentPreset(
            id: "grok",
            name: "Grok",
            command: "grok agent stdio",
            description: "xAI Grok 原生 ACP (Agent Client Protocol) 接口",
            driverType: .acpStdio,
            defaultBin: "grok",
            iconName: "bolt.badge.automatic"
        ),
        ACPAgentPreset(
            id: "claude",
            name: "Claude Code",
            command: "claude -p",
            description: "Anthropic Claude Code CLI 驱动",
            driverType: .cliStreaming,
            defaultBin: "claude",
            iconName: "brain"
        ),
        ACPAgentPreset(
            id: "pi",
            name: "Pi",
            command: "pi -p",
            description: "Pi AI 极速伴读与编码 Agent CLI",
            driverType: .cliStreaming,
            defaultBin: "pi",
            iconName: "waveform.path.ecg"
        ),
        ACPAgentPreset(
            id: "codex",
            name: "Codex",
            command: "codex exec",
            description: "OpenAI Codex CLI 命令行交互",
            driverType: .cliStreaming,
            defaultBin: "codex",
            iconName: "chevron.left.forwardslash.chevron.right"
        ),
        ACPAgentPreset(
            id: "cursor",
            name: "Cursor",
            command: "agent -p",
            description: "Cursor Agent (CLI / agent -p) 驱动",
            driverType: .cliStreaming,
            defaultBin: "agent",
            iconName: "cursorarrow.rays"
        ),
        ACPAgentPreset(
            id: "devin",
            name: "Devin",
            command: "devin acp",
            description: "Cognition Devin 原生 ACP 协议服务",
            driverType: .acpStdio,
            defaultBin: "devin",
            iconName: "cpu"
        ),
        ACPAgentPreset(
            id: "ollama",
            name: "Ollama (本地模型)",
            command: "http://localhost:11434",
            description: "本地 Llama 3.2 / Qwen 2.5 / DeepSeek 直连",
            driverType: .httpAdapter,
            defaultBin: "ollama",
            iconName: "server.rack"
        ),
        ACPAgentPreset(
            id: "lmstudio",
            name: "LM Studio",
            command: "http://localhost:1234/v1",
            description: "LM Studio / Jan 本地 API 兼容端口",
            driverType: .httpAdapter,
            defaultBin: "",
            iconName: "network"
        ),
        ACPAgentPreset(
            id: "embedded",
            name: "内置伴读引擎",
            command: "acp://embedded",
            description: "开箱即用，无需外部配置即可体验完整伴读",
            driverType: .embedded,
            defaultBin: "",
            iconName: "book.pages"
        )
    ]
}
