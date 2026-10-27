import Foundation

/// Supported AI Agent Providers
enum AIAgentProvider: String, CaseIterable, Identifiable, Codable {
    case ollama = "Ollama (本地)"
    case openAICompatible = "LM Studio / 本地 API"
    case builtIn = "内置智能导读 (离线体验)"

    var id: String { rawValue }

    var defaultEndpoint: String {
        switch self {
        case .ollama:
            return "http://localhost:11434"
        case .openAICompatible:
            return "http://localhost:1234/v1"
        case .builtIn:
            return "local://built-in"
        }
    }

    var defaultModel: String {
        switch self {
        case .ollama:
            return "llama3.2"
        case .openAICompatible:
            return "local-model"
        case .builtIn:
            return "dreader-reader-agent"
        }
    }
}

/// Agent Personas / Roles
enum AIAgentRole: String, CaseIterable, Identifiable, Codable {
    case deepReader = "深度导读"
    case criticalThinker = "批判思考"
    case ideaExtractor = "灵感提炼"
    case translator = "沉浸翻译"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .deepReader: return "brain.head.profile"
        case .criticalThinker: return "magnifyingglass"
        case .ideaExtractor: return "sparkles"
        case .translator: return "character.book.closed"
        }
    }

    var systemPrompt: String {
        switch self {
        case .deepReader:
            return "你是一位精通中外文学、哲学与社科历史的深度导读学者。你的目标是帮助读者深入理解书中文字的深层寓意、历史背景与哲学脉络。回答逻辑清晰、生动优美、充满见地。"
        case .criticalThinker:
            return "你是一位思维严密的学术辩论家与批判性思考者。你会审视作者的论证逻辑、识别潜藏的前设与偏见，并向读者提出具有启发性的反例或反向思考视角。"
        case .ideaExtractor:
            return "你是一位高效的知识萃取师与行动力顾问。你会从阅读内容中提炼出核心思想、结构化要点以及可以在现实工作与生活中实践的灵感与行动指南。"
        case .translator:
            return "你是一位兼备信达雅的文学翻译名家。请将选中文本进行原汁原味且富有语境感的双语对照翻译，并附带关键修辞与文化背景解析。"
        }
    }
}

/// A chat message in the conversation
struct ChatMessage: Identifiable, Hashable, Sendable {
    let id: UUID
    let role: Role
    var content: String
    let quoteContext: String?
    let timestamp: Date

    enum Role: String, Codable, Sendable {
        case user
        case assistant
        case system
    }

    init(
        id: UUID = UUID(),
        role: Role,
        content: String,
        quoteContext: String? = nil,
        timestamp: Date = Date()
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.quoteContext = quoteContext
        self.timestamp = timestamp
    }
}
