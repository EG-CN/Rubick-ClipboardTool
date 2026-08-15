import Foundation
import Translation

// MARK: - 翻译服务（v2.0：Apple 离线默认 + OpenAI 兼容大模型可选）
// 功能清单 12.3：历史文本条目右键翻译 / OCR 结果一键翻译

enum TranslateDirection: String, CaseIterable {
    case auto = "auto"      // 自动检测：外文 → 中文；中文 → 英文
    case zhToEn = "zh2en"
    case enToZh = "en2zh"

    var label: String {
        switch self {
        case .auto: return "自动检测 → 中文"
        case .zhToEn: return "中文 → 英文"
        case .enToZh: return "英文 → 中文"
        }
    }
}

struct LLMConfig: Equatable {
    var baseURL: String
    var model: String
    var apiKey: String

    var isValid: Bool {
        !baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

enum TranslateError: LocalizedError {
    case noEngine
    case appleUnavailable
    case needsMacOS15
    case badResponse
    case emptyResult

    var errorDescription: String? {
        switch self {
        case .noEngine: return "未配置翻译引擎"
        case .appleUnavailable: return "Apple 离线翻译暂不可用（可在设置中配置大模型引擎）"
        case .needsMacOS15: return "Apple 离线翻译需要 macOS 26+，可在设置中改用大模型翻译"
        case .badResponse: return "大模型返回异常"
        case .emptyResult: return "翻译结果为空"
        }
    }
}

final class TranslationService {
    static let shared = TranslationService()

    private init() {}

    // MARK: 配置

    var usesLLM: Bool {
        UserDefaults.standard.string(forKey: "translate.engine") == "llm" && llmConfig().isValid
    }

    var direction: TranslateDirection {
        TranslateDirection(rawValue: UserDefaults.standard.string(forKey: "translate.direction") ?? "auto") ?? .auto
    }

    func llmConfig() -> LLMConfig {
        LLMConfig(baseURL: UserDefaults.standard.string(forKey: "llm.baseURL") ?? "",
                  model: UserDefaults.standard.string(forKey: "llm.model") ?? "",
                  apiKey: UserDefaults.standard.string(forKey: "llm.apiKey") ?? "")
    }

    var engineLabel: String { usesLLM ? "大模型" : "Apple 离线" }

    // MARK: 翻译入口

    func translate(_ text: String, completion: @escaping (Result<String, Error>) -> Void) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            completion(.failure(TranslateError.emptyResult))
            return
        }
        if usesLLM {
            llmTranslate(trimmed, completion: completion)
        } else {
            appleTranslate(trimmed, completion: completion)
        }
    }

    // MARK: Apple 离线翻译（TranslationSession，macOS 15+）
    // 注：macOS 26 SDK 已移除旧 MLTranslator API 且 TranslationSession 需 installedSource 构造；
    // 离线翻译自 v2.0 起要求 macOS 26+，更老系统可改用大模型翻译。

    private func appleTranslate(_ text: String, completion: @escaping (Result<String, Error>) -> Void) {
        guard #available(macOS 26.0, *) else {
            completion(.failure(TranslateError.needsMacOS15))
            return
        }
        let pair = Self.detectPair(text, direction: direction)
        Task {
            do {
                let status = await LanguageAvailability().status(from: pair.source, to: pair.target)
                guard status != .unsupported else {
                    completion(.failure(TranslateError.appleUnavailable))
                    return
                }
                #if compiler(>=6.2)
                // macOS 26 SDK：TranslationSession 需 installedSource 构造
                let session = TranslationSession(installedSource: pair.source, target: pair.target)
                #else
                // macOS 15 SDK（CI macos-14 runner）
                let session = TranslationSession(sourceLanguage: pair.source, targetLanguage: pair.target)
                #endif
                let chunks = Self.chunks(text)
                var parts: [String] = []
                for chunk in chunks {
                    let response = try await session.translate(chunk)
                    parts.append(response.targetText)
                }
                let joined = parts.joined(separator: "\n")
                guard !joined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw TranslateError.emptyResult
                }
                completion(.success(joined))
            } catch {
                completion(.failure(error))
            }
        }
    }

    // MARK: 大模型翻译（OpenAI 兼容协议）

    private func llmTranslate(_ text: String, completion: @escaping (Result<String, Error>) -> Void) {
        let cfg = llmConfig()
        let target = Self.targetLanguageText(direction: direction)
        guard let req = try? Self.llmRequest(
            config: cfg,
            systemPrompt: "你是专业翻译。把用户文本翻译成\(target)，只输出译文本身，不要任何解释、引号或额外符号。",
            userText: text) else {
            completion(.failure(TranslateError.badResponse))
            return
        }
        URLSession.shared.dataTask(with: req) { data, _, err in
            if let err = err {
                completion(.failure(err))
                return
            }
            guard let data = data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = obj["choices"] as? [[String: Any]],
                  let msg = choices.first?["message"] as? [String: Any],
                  let content = msg["content"] as? String else {
                completion(.failure(TranslateError.badResponse))
                return
            }
            let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
            completion(trimmed.isEmpty ? .failure(TranslateError.emptyResult) : .success(trimmed))
        }.resume()
    }

    // MARK: 纯函数（可测试）

    /// 语言方向解析：auto = 外文→中文；中文→英文
    static func detectPair(_ text: String, direction: TranslateDirection) -> (source: Locale.Language, target: Locale.Language) {
        let zh = Locale.Language(identifier: "zh-Hans")
        let en = Locale.Language(identifier: "en")
        switch direction {
        case .zhToEn: return (zh, en)
        case .enToZh: return (en, zh)
        case .auto:
            let cjk = text.unicodeScalars.filter { s in
                (0x4E00...0x9FFF).contains(s.value) || (0x3400...0x4DBF).contains(s.value)
            }.count
            let latin = text.unicodeScalars.filter { s in
                (0x41...0x5A).contains(s.value) || (0x61...0x7A).contains(s.value)
            }.count
            return (cjk > 0 && cjk * 2 >= latin) ? (zh, en) : (en, zh)
        }
    }

    static func targetLanguageText(direction: TranslateDirection) -> String {
        direction == .zhToEn ? "英文" : "简体中文"
    }

    /// 超长文本按段落切块（Apple 翻译按块处理，避免超长请求）；超长段落按 maxLen 硬切
    static func chunks(_ text: String, maxLen: Int = 1500) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        var chunks: [String] = []
        var current = ""
        func flush() {
            if !current.isEmpty {
                chunks.append(current)
                current = ""
            }
        }
        for para in trimmed.components(separatedBy: "\n") {
            if para.count > maxLen {
                flush()
                var idx = para.startIndex
                while idx < para.endIndex {
                    let end = para.index(idx, offsetBy: maxLen, limitedBy: para.endIndex) ?? para.endIndex
                    chunks.append(String(para[idx..<end]))
                    idx = end
                }
            } else {
                if !current.isEmpty && (current + "\n" + para).count > maxLen { flush() }
                current += (current.isEmpty ? "" : "\n") + para
            }
        }
        flush()
        return chunks
    }

    /// 构造 OpenAI 兼容 chat/completions 请求（可测试）
    static func llmRequest(config: LLMConfig, systemPrompt: String, userText: String) throws -> URLRequest {
        let base = config.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: base + "/chat/completions") else { throw TranslateError.badResponse }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 60
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(config.apiKey.trimmingCharacters(in: .whitespacesAndNewlines))",
                     forHTTPHeaderField: "Authorization")
        let body: [String: Any] = [
            "model": config.model,
            "stream": false,
            "max_tokens": 4096,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userText]
            ]
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { throw TranslateError.badResponse }
        req.httpBody = data
        return req
    }
}
