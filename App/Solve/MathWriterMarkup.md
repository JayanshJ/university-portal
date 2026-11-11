# Handwriting Renderer — Markup Reference

Solution text is plain text with inline tags. Paragraphs are separated by blank
lines; each line renders left-to-right with word wrap.

## Tags

| Tag | Meaning | Example | Renders as |
|-----|---------|---------|------------|
| `~~text~~` | Underlined header (own line) | `~~Aufgabe 1~~` | header + hand-drawn underline |
| `[F]num\|den[/F]` | Fraction | `[F]1\|3[/F]` | 1 over 3 with bar |
| `[M]r1c1,r1c2;r2c1,r2c2[/M]` | Matrix | `[M]1,2;3,4[/M]` | 2×2 with hand parens |
| `[M]...,\|,...[/M]` | Augmented matrix | `[M]1,2,\|,3;4,5,\|,6[/M]` | vertical bar between cols |
| `[S]lower\|upper[/S]` | Sum Σ with limits | `[S]k=0\|n[/S]` | Σ, k=0 below, n above |
| `[I]lower\|upper[/I]` | Integral ∫ with limits | `[I]0\|1[/I]` | ∫, 0 bottom-right, 1 top-right |
| `[B]text[/B]` | Boxed answer | `[B]d = 3[/B]` | hand-drawn box |
| `[T]h1\|h2 \n r1\|r2[/T]` | Table (rows on lines, cells by `\|`) | | hand-drawn table |
| `[X]text[/X]` | Strikethrough (fake mistake) | `[X]symmetric[/X]` | crossed out |
| `[V]text[/V]` | Vector arrow above | `[V]AB[/V]` | AB with → on top |
| `[H]text[/H]` | Hat ^ above | `[H]i[/H]` | î |
| `[R]content[/R]` | Square root with overbar | `[R]7[/R]` | √7 with bar over 7 |
| `[D]text[/D]` | Subscript group (below line) | `lim[D]h→0⁺[/D]` | h→0⁺ under lim |
| `[U]text[/U]` | Superscript group (above line) | `e[U]−t[/U]` | e^(−t) |

Nesting works: `[B]c = ± [F]1|5[/F][/B]`, `[F]e[U]x[/U] − 1|x[/F]`.

## Special characters (auto-rendered, no tag needed)

- `→ -> => ⇒` — hand-drawn/glyph arrow
- `≈` — hand-drawn double tilde
- `∫` — real handwritten glyph (use `[I]a|b[/I]` when it has limits!)
- `≠ ≤ ≥ < > + − * ÷ = ( ) [ ] { } | / ' " . , ; : ! ?` — real glyphs
- `α β γ θ ν ω π λ ∞ ∈ ∉ ⊂ ⊆ ∪ ∩ ∀ ∃ ^ √ ä ö ü ß Ä Ö Ü Σ ← ✓` — real glyphs
- Unicode subscripts `₀₁₂₃₄₅₆₇₈₉ ₊₋₌₍₎ ᵢⱼₖₙₘₐ` — small, below baseline
- Unicode superscripts `⁰¹²³⁴⁵⁶⁷⁸⁹ ⁺⁻⁼⁽⁾ ⁱⁿᵃᵇᵏᵐ ᵀ` — small, above baseline

## Escaping

- Inside `[F]`/`[S]`/`[I]` bodies, a literal `|` (absolute value) must be
  escaped as `\|`:  `[F]\|a + 2x\||x[/F]` = |a+2x| over x.

## DO NOT (recurring past bugs)

- ❌ `=/=` or `=!=` → use `≠`
- ❌ `lim_(h→0)` → use `lim[D]h→0[/D]`
- ❌ `∫[D]a[/D][U]b[/U]` → use `[I]a|b[/I]`
- ❌ `Σ[D]k=0[/D][U]n[/U]` → use `[S]k=0|n[/S]`
- ❌ bare `√7` / `√(x+1)` → use `[R]7[/R]` / `[R]x+1[/R]`
  (a bare `√` glyph has no overbar)
- ❌ `x^2` / `e^(−t)` with caret → use `x²` or `x[U]2[/U]` / `e[U]−t[/U]`
  (the `^` renders literally as a caret glyph)
- ❌ `×` and `·` — both fall back to `*`; write `*` directly
- ❌ Greek capitals `Π Φ Δ Λ Γ Ω Θ Ξ Ψ` — only mapped to lookalikes; prefer
  lowercase π etc. where semantically OK
- ❌ `%` `#` `&` `@` `\` — only crude fallbacks exist

## Rendering pipeline

`solve.py <textfile>` → validate → render → save PDF + previews + gap report.
Or in Python: `from render import render_to_pdf; render_to_pdf(text, out_path)`.

Config lives in the defaults of `render_pages()` (scale=1.45, iPad-style
white grid paper, Apple-Pencil blue ink #0F46B4).
