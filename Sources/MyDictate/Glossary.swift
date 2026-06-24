import Foundation

/// Пользовательский словарь замен: приводит распознанные слова к правильному
/// написанию (напр. «Оду» → «Odoo», «Odoo Flow» → «Oduflow»).
/// Правила хранятся как текст, по строке на правило: «что => на_что».
enum Glossary {
    static let defaultRules = """
    Оду => Odoo
    Odu => Odoo
    оду => Odoo
    Одду => Odoo
    Odoo Flow => Oduflow
    Оду Флоу => Oduflow
    Одуфлоу => Oduflow
    Одуфлов => Oduflow
    """

    struct Rule { let from: String; let to: String }

    static func rules() -> [Rule] {
        let raw = UserDefaults.standard.string(forKey: "glossary") ?? defaultRules
        let parsed: [Rule] = raw.split(whereSeparator: \.isNewline).compactMap { line in
            let parts = line.components(separatedBy: "=>")
            guard parts.count == 2 else { return nil }
            let from = parts[0].trimmingCharacters(in: .whitespaces)
            let to = parts[1].trimmingCharacters(in: .whitespaces)
            guard !from.isEmpty else { return nil }
            return Rule(from: from, to: to)
        }
        // Сначала более длинные шаблоны (чтобы «Odoo Flow» обработался раньше «Odoo»).
        return parsed.sorted { $0.from.count > $1.from.count }
    }

    /// Морфологическая детерминированная замена: правило «Клод => Claude» ловит корень
    /// + русское падежное окончание (Клод/Клода/Клоду/Клодом/Клоде → Claude),
    /// регистронезависимо, по границам слова, с учётом кириллицы. Надёжно и мгновенно.
    static func apply(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        var result = text
        for rule in rules() {
            let words = rule.from.split(whereSeparator: { $0 == " " })
                .map { NSRegularExpression.escapedPattern(for: String($0)) }
            guard !words.isEmpty else { continue }
            let core = words.joined(separator: "\\s+")
            // Опциональное русское окончание (0–3 кириллических буквы) на хвосте + границы слова.
            let pattern = "(?<![\\p{L}\\p{N}])\(core)[а-яёА-ЯЁ]{0,3}(?![\\p{L}\\p{N}])"
            guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let range = NSRange(result.startIndex..., in: result)
            let template = NSRegularExpression.escapedTemplate(for: rule.to)
            result = re.stringByReplacingMatches(in: result, range: range, withTemplate: template)
        }
        return result
    }

    /// Подсказка модели в LLM-промпте (термины + частые слова). Дублирует замену на
    /// уровне LLM, но детерминированный apply() остаётся гарантией.
    static func promptHint() -> String {
        var parts: [String] = []
        let r = rules()
        if !r.isEmpty {
            let pairs = r.prefix(40).map { "\($0.from) → \($0.to)" }.joined(separator: "; ")
            parts.append("В тексте встречаются имена/названия, которые в русской речи склоняются. ОБЯЗАТЕЛЬНО заменяй ЛЮБУЮ их форму (любой падеж и окончание, включая дательный «кому?») на правую часть; НИКОГДА не оставляй кириллический вариант этих слов: \(pairs).")
        }
        let words = Vocabulary.words()
        if !words.isEmpty {
            parts.append("Часто встречающиеся слова и имена — пиши их именно так, исправляй похожие на них ошибки распознавания: \(words.prefix(60).joined(separator: ", ")).")
        }
        return parts.joined(separator: " ")
    }
}

/// Частые слова и имена пользователя (для подсказки LLM).
enum Vocabulary {
    static func words() -> [String] {
        let raw = UserDefaults.standard.string(forKey: "vocabulary") ?? ""
        var seen = Set<String>(); var out: [String] = []
        for w in raw.split(whereSeparator: { $0 == "," || $0.isNewline })
            .map({ $0.trimmingCharacters(in: .whitespaces) })
            .filter({ !$0.isEmpty }) where seen.insert(w.lowercased()).inserted {
            out.append(w)
        }
        return out
    }
}
