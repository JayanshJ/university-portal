import Foundation

/// The renderer's character set (port of Math Writer's `charset.py`).
/// Shared by the renderer (glyph selection) and the validator.
enum HandwritingCharset {
    /// Characters with no dedicated glyph that map to another real glyph.
    static let fallbacks: [Character: Character] = [
        "×": "*", "—": "-", "–": "-", "−": "-",
        "\u{2019}": "'", "\u{2018}": "'", "\u{201C}": "\"", "\u{201D}": "\"",
        "·": "*", "±": "+",
        "_": "-", "\t": " ",
        "%": "/", "#": "+", "\\": "/", "@": "a", "&": "+",
        // Greek capitals that have no glyph map to similar shapes.
        "Π": "π",
        "Φ": "F", "Δ": "D", "Λ": "A", "Γ": "T", "Ω": "O",
        "Θ": "θ", "Ξ": "E", "Ψ": "Y", "Σ": "S",
    ]

    static let superscriptMap: [Character: Character] = [
        "⁰": "0", "¹": "1", "²": "2", "³": "3", "⁴": "4", "⁵": "5",
        "⁶": "6", "⁷": "7", "⁸": "8", "⁹": "9",
        "⁺": "+", "⁻": "-", "⁼": "=", "⁽": "(", "⁾": ")",
        "ⁱ": "i", "ⁿ": "n", "ᵃ": "a", "ᵇ": "b", "ᵏ": "k", "ᵐ": "m",
        "ᵀ": "T",
    ]

    static let subscriptMap: [Character: Character] = [
        "₀": "0", "₁": "1", "₂": "2", "₃": "3", "₄": "4", "₅": "5",
        "₆": "6", "₇": "7", "₈": "8", "₉": "9",
        "₊": "+", "₋": "−", "₌": "=", "₍": "(", "₎": ")",
        "ᵢ": "i", "ⱼ": "j", "ₖ": "k", "ₙ": "n", "ₘ": "m", "ₐ": "a",
    ]

    /// Characters drawn procedurally (not from a glyph image).
    static let procedural: Set<Character> = ["→", "≈", "∫", "✓"]

    static let whitespace: Set<Character> = [" ", "\n", "\t"]

    static let subSup: Set<Character> = Set(superscriptMap.keys).union(subscriptMap.keys)

    /// Letters that may be joined by a connector stroke.
    static let connectable: Set<Character> = Set("abcdefghijklmnopqrstuvwxyzäöü")
    /// Letters whose pen lifts (closed shape or descender).
    static let noRightConnect: Set<Character> = Set("bdgjopqysz")
    /// Letters that don't naturally accept a connection from the left.
    static let noLeftConnect: Set<Character> = Set("iv")
}
