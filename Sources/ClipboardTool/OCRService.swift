import Foundation
import AppKit
import Vision

// MARK: - OCR 服务（v2.0：Vision 框架本地识别，离线免费）
// 功能清单 12.2：钉图 / 历史图片划选区域 → 本地识别

enum OCRLanguage: String, CaseIterable {
    case auto, zhHans, zhHant, en, ja, ko

    var label: String {
        switch self {
        case .auto: return "自动检测"
        case .zhHans: return "简体中文"
        case .zhHant: return "繁体中文"
        case .en: return "英文"
        case .ja: return "日文"
        case .ko: return "韩文"
        }
    }

    var visionLanguages: [String]? {
        switch self {
        case .auto: return ["zh-Hans", "zh-Hant", "en", "ja", "ko"]
        case .zhHans: return ["zh-Hans"]
        case .zhHant: return ["zh-Hant"]
        case .en: return ["en"]
        case .ja: return ["ja"]
        case .ko: return ["ko"]
        }
    }
}

struct OCRResult {
    let lines: [String]
    var text: String { lines.joined(separator: "\n") }
}

enum OCRError: LocalizedError {
    case noImage
    case regionTooSmall

    var errorDescription: String? {
        switch self {
        case .noImage: return "无法读取图片"
        case .regionTooSmall: return "选中区域太小，请重新划选"
        }
    }
}

final class OCRService {
    static let shared = OCRService()

    private init() {}

    var language: OCRLanguage {
        OCRLanguage(rawValue: UserDefaults.standard.string(forKey: "ocr.language") ?? "auto") ?? .auto
    }

    /// 识别图片文字；rect 为视图坐标（原点左上，nil = 整图）
    func recognize(image: NSImage, rect: CGRect? = nil, completion: @escaping (Result<OCRResult, Error>) -> Void) {
        guard let cg = image.cgImage() else {
            completion(.failure(OCRError.noImage))
            return
        }
        let full = CGRect(origin: .zero, size: CGSize(width: cg.width, height: cg.height))
        var crop = full
        if let r = rect {
            crop = r.intersection(full)
            guard crop.width >= 4, crop.height >= 4 else {
                completion(.failure(OCRError.regionTooSmall))
                return
            }
        }
        // Vision 坐标原点在左下 → 翻转视图坐标
        let flipped = Self.flippedRect(crop, height: CGFloat(cg.height))
        let roi = CGRect(x: flipped.minX / CGFloat(cg.width),
                         y: flipped.minY / CGFloat(cg.height),
                         width: flipped.width / CGFloat(cg.width),
                         height: flipped.height / CGFloat(cg.height))

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        if let langs = language.visionLanguages {
            request.recognitionLanguages = langs
        }
        request.regionOfInterest = roi

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let handler = VNImageRequestHandler(cgImage: cg, options: [:])
                try handler.perform([request])
                let observations = (request.results ?? []).sorted { a, b in
                    if abs(a.boundingBox.midY - b.boundingBox.midY) > 0.01 {
                        return a.boundingBox.midY > b.boundingBox.midY   // 上 → 下
                    }
                    return a.boundingBox.minX < b.boundingBox.minX       // 左 → 右
                }
                let lines = observations.compactMap { $0.topCandidates(1).first?.string }
                completion(.success(OCRResult(lines: lines)))
            } catch {
                completion(.failure(error))
            }
        }
    }

    /// 视图坐标（左上原点）→ Vision 坐标（左下原点）
    static func flippedRect(_ r: CGRect, height: CGFloat) -> CGRect {
        CGRect(x: r.minX, y: height - r.maxY, width: r.width, height: r.height)
    }
}

// MARK: - NSImage → CGImage

extension NSImage {
    func cgImage() -> CGImage? {
        var rect = CGRect(origin: .zero, size: size)
        return cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }
}
