import Foundation

/// Spaced-repetition state for one study tape (SM-2, the algorithm behind Anki/SuperMemo).
struct Review: Codable, Equatable {
    var due: Date
    var interval: Double = 0      // days
    var ease: Double = 2.5
    var reps: Int = 0
    var lapses: Int = 0

    enum Grade: Int, CaseIterable, Identifiable {
        case again = 0, hard = 3, good = 4, easy = 5
        var id: Int { rawValue }
        var title: String {
            switch self {
            case .again: return "Again"
            case .hard: return "Hard"
            case .good: return "Good"
            case .easy: return "Easy"
            }
        }
    }

    static func new(now: Date = Date()) -> Review { Review(due: now) }

    /// Next state after answering. "Again" restarts the card (due in 10 minutes); passing grades grow
    /// the interval 1 → 6 days → interval × ease, with ease adjusted by how hard it felt.
    func answered(_ g: Grade, now: Date = Date()) -> Review {
        var r = self
        let q = Double(g.rawValue)
        if g == .again {
            r.reps = 0
            r.lapses += 1
            r.interval = 0
            r.due = now.addingTimeInterval(10 * 60)
        } else {
            r.reps += 1
            switch r.reps {
            case 1: r.interval = 1
            case 2: r.interval = 6
            default: r.interval = (r.interval * r.ease).rounded()
            }
            if g == .easy { r.interval *= 1.3 }
            r.interval = min(r.interval, 3650)
            r.due = now.addingTimeInterval(r.interval * 86_400)
        }
        r.ease = max(1.3, r.ease + (0.1 - (5 - q) * (0.08 + (5 - q) * 0.02)))
        return r
    }

    func isDue(now: Date = Date()) -> Bool { due <= now }
}

/// Evaluates handwritten arithmetic safely: numbers, + − × ÷ ^, parentheses, %, √. A tiny
/// recursive-descent parser; nothing is ever executed as code.
enum MathEval {
    struct Result: Equatable {
        var expression: String
        var value: Double
        var formatted: String
    }

    /// Normalises OCR'd text ("12 x 3 =" → "12*3") and evaluates it. nil if it isn't a sum.
    static func solve(_ raw: String) -> Result? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let eq = s.firstIndex(of: "=") { s = String(s[..<eq]) } // ignore "= ?" the user wrote
        let map: [Character: String] = ["×": "*", "x": "*", "X": "*", "·": "*", "÷": "/", ":": "/", "−": "-", "–": "-", "—": "-",
                                        ",": ".", "O": "0", "o": "0", "l": "1", "I": "1", "√": "√", "^": "^"]
        var out = ""
        for ch in s {
            if ch.isWhitespace { continue }
            if let m = map[ch] { out += m } else if "0123456789.+-*/()%".contains(ch) { out.append(ch) } else { return nil }
        }
        guard out.contains(where: \.isNumber), out.count <= 200 else { return nil }
        var p = Parser(Array(out))
        guard let v = p.expression(), p.atEnd, v.isFinite else { return nil }
        // Something must actually be computed: a lone number isn't a sum.
        guard out.contains(where: { "+-*/^%√".contains($0) && $0 != "-" }) || out.dropFirst().contains("-") else { return nil }
        return Result(expression: out, value: v, formatted: format(v))
    }

    static func format(_ v: Double) -> String {
        if abs(v - v.rounded()) < 1e-9 && abs(v) < 1e15 { return String(Int64(v.rounded())) }
        var s = String(format: "%.10g", v)
        if s.contains("e") { return s }
        while s.contains(".") && (s.hasSuffix("0") || s.hasSuffix(".")) { s.removeLast() }
        return s
    }

    private struct Parser {
        let c: [Character]
        var i = 0
        var depth = 0
        init(_ c: [Character]) { self.c = c }
        var atEnd: Bool { i == c.count }
        mutating func peek() -> Character? { i < c.count ? c[i] : nil }

        mutating func expression() -> Double? {
            guard var v = term() else { return nil }
            while let ch = peek(), ch == "+" || ch == "-" {
                i += 1
                guard let r = term() else { return nil }
                v = ch == "+" ? v + r : v - r
            }
            return v
        }

        mutating func term() -> Double? {
            guard var v = power() else { return nil }
            while let ch = peek(), ch == "*" || ch == "/" || ch == "(" || ch == "√" {
                if ch == "(" || ch == "√" { // implicit multiplication: 2(3+4), 2√9
                    guard let r = power() else { return nil }
                    v *= r
                    continue
                }
                i += 1
                guard let r = power() else { return nil }
                if ch == "/" { guard r != 0 else { return nil }; v /= r } else { v *= r }
            }
            return v
        }

        mutating func power() -> Double? {
            guard let b = unary() else { return nil }
            if peek() == "^" {
                i += 1
                guard let e = power(), abs(e) < 1000 else { return nil } // right-associative, bounded
                let r = pow(b, e)
                return r.isFinite ? r : nil
            }
            return b
        }

        mutating func unary() -> Double? {
            if peek() == "-" { i += 1; return unary().map { -$0 } }
            if peek() == "+" { i += 1; return unary() }
            if peek() == "√" { i += 1; guard let v = unary(), v >= 0 else { return nil }; return v.squareRoot() }
            guard var v = primary() else { return nil }
            while peek() == "%" { i += 1; v /= 100 }
            return v
        }

        mutating func primary() -> Double? {
            if peek() == "(" {
                depth += 1
                guard depth < 64 else { return nil }
                i += 1
                guard let v = expression(), peek() == ")" else { return nil }
                i += 1
                depth -= 1
                return v
            }
            let start = i
            while let ch = peek(), ch.isNumber || ch == "." { i += 1 }
            guard i > start else { return nil }
            let s = String(c[start..<i])
            guard s.filter({ $0 == "." }).count <= 1 else { return nil }
            return Double(s)
        }
    }
}
