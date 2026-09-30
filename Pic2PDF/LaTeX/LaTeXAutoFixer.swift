//
//  LaTeXAutoFixer.swift
//  Pic2PDF
//
//  Repairs model output so latex.js can render it. latex.js does the diagnosis (LaTeXValidator);
//  this file applies one targeted fix per reported error and re-checks. Most latex.js errors read
//  "\end{document} missing" but point at the real culprit, so fixes key on the character at the
//  reported position rather than on the message text.
//

import Foundation

struct LaTeXFixReport: Codable, Equatable {
    var steps: [String] = []
    var remainingError: String?
    var usedModelRepair = false
    var isValid: Bool { remainingError == nil }
}

enum LaTeXAutoFixer {
    static let maxDeterministicPasses = 8

    /// Validates `latex`, repairs what it can, and optionally asks the model for a final repair.
    /// - Parameter modelRepair: called with (latex, error) when deterministic fixes run out.
    @MainActor
    static func fix(_ latex: String,
                    validator: LaTeXValidator = .shared,
                    modelRepair: ((String, String) async -> String?)? = nil) async -> (latex: String, report: LaTeXFixReport) {
        var report = LaTeXFixReport()
        var current = prepare(latex, report: &report)

        for _ in 0..<maxDeterministicPasses {
            guard let issue = await validator.validate(current) else { return (current, report) }
            guard let (fixed, step) = repair(current, issue: issue), fixed != current else {
                report.remainingError = describe(issue)
                break
            }
            current = fixed
            report.steps.append(step)
        }

        if report.remainingError == nil, let issue = await validator.validate(current) {
            report.remainingError = describe(issue)
        }

        if let error = report.remainingError, let modelRepair {
            if let repaired = await modelRepair(current, error) {
                var scratch = LaTeXFixReport()
                let candidate = prepare(repaired, report: &scratch)
                if await validator.validate(candidate) == nil {
                    report.usedModelRepair = true
                    report.steps.append("Model repaired: \(error)")
                    report.remainingError = nil
                    return (candidate, report)
                }
                report.steps.append("Model repair didn't produce valid LaTeX")
            } else {
                report.steps.append("Model repair skipped (document too long or model unavailable)")
            }
        }
        return (current, report)
    }

    static func describe(_ issue: LaTeXValidator.Issue) -> String {
        if let line = issue.line { return "line \(line): \(issue.message)" }
        return issue.message
    }

    // MARK: - Always-on cleanup

    static func prepare(_ latex: String, report: inout LaTeXFixReport) -> String {
        var text = latex
        let (trimmed, removed) = trimRepetition(text)
        if removed > 0 {
            text = trimmed
            report.steps.append("Removed \(removed) repeated line\(removed == 1 ? "" : "s")")
        }
        let (deduped, removedBlocks) = removeDuplicateBlocks(text)
        if removedBlocks > 0 {
            text = deduped
            report.steps.append("Removed \(removedBlocks) repeated block\(removedBlocks == 1 ? "" : "s")")
        }
        let (untruncated, droppedTail) = dropUnclosedTrailingBlock(text)
        if droppedTail {
            text = untruncated
            report.steps.append("Removed an incomplete last block (output was cut off)")
        }
        // Convert equation/align-style wrappers to \\[ \\] first, so the next step sees every display block.
        let sanitized = LaTeXSanitizer.clean(text)
        if sanitized != text {
            text = sanitized
            report.steps.append("Converted environments latex.js doesn't support")
        }
        let (closed, closedCount) = closeEnvironmentsInDisplayMath(text)
        if closedCount > 0 {
            text = closed
            report.steps.append("Closed \(closedCount) unclosed environment\(closedCount == 1 ? "" : "s") inside display math")
        }
        // Closing environments can turn a damaged copy into an exact duplicate of an earlier block.
        let (dedupedAgain, removedAgain) = removeDuplicateBlocks(text)
        if removedAgain > 0 {
            text = dedupedAgain
            report.steps.append("Removed \(removedAgain) repeated block\(removedAgain == 1 ? "" : "s")")
        }
        let wrapped = ensureDocument(text)
        if wrapped != text {
            text = wrapped
            report.steps.append("Completed the document preamble/ending")
        }
        return text
    }

    /// Greedy decoding can loop, repeating the same block until the token limit. Keep the first copy.
    static func trimRepetition(_ text: String) -> (String, Int) {
        let lines = text.components(separatedBy: "\n")
        guard lines.count > 8 else { return (text, 0) }
        var result: [String] = []
        var i = 0
        var removed = 0
        while i < lines.count {
            var skipped = false
            // Look for a block of 2...12 non-blank lines that immediately repeats.
            for size in stride(from: min(12, (lines.count - i) / 2), through: 2, by: -1) {
                let block = Array(lines[i..<(i + size)])
                guard block.contains(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else { continue }
                var j = i + size
                var repeats = 0
                while j + size <= lines.count, Array(lines[j..<(j + size)]) == block {
                    repeats += 1
                    j += size
                }
                if repeats > 0 {
                    result.append(contentsOf: block)
                    removed += repeats * size
                    i = j
                    skipped = true
                    break
                }
            }
            if !skipped {
                result.append(lines[i])
                i += 1
            }
        }
        return (result.joined(separator: "\n"), removed)
    }

    /// Greedy decoding also loops over *sets* of blocks (A, B, A, B, ...), sometimes with a broken copy.
    /// Drops any paragraph block (text between blank lines) that repeats an earlier one.
    static func removeDuplicateBlocks(_ text: String) -> (String, Int) {
        let blocks = text.components(separatedBy: "\n\n")
        guard blocks.count > 3 else { return (text, 0) }
        var seen = Set<String>()
        var kept: [String] = []
        var removed = 0
        for block in blocks {
            let key = block.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: "\n")
            let isStructural = key.isEmpty || key.hasPrefix("\\documentclass") || key.hasPrefix("\\end{document}") || key.count < 12
            if !isStructural && seen.contains(key) {
                removed += 1
                continue
            }
            seen.insert(key)
            kept.append(block)
        }
        return (kept.joined(separator: "\n\n"), removed)
    }

    /// A reply cut off at the token limit ends mid-formula. If the last block (before \end{document})
    /// opens more environments or \[ than it closes, it can't be completed reliably, so drop it.
    static func dropUnclosedTrailingBlock(_ text: String) -> (String, Bool) {
        var lines = text.components(separatedBy: "\n")
        let endDoc = lines.lastIndex(where: { $0.contains("\\end{document}") }) ?? lines.count
        // Last non-blank line before \end{document}, then walk back to the blank line that starts its block.
        var last = endDoc - 1
        while last >= 0, lines[last].trimmingCharacters(in: .whitespaces).isEmpty { last -= 1 }
        guard last >= 0 else { return (text, false) }
        var first = last
        while first > 0, !lines[first - 1].trimmingCharacters(in: .whitespaces).isEmpty { first -= 1 }
        let block = lines[first...last].joined(separator: "\n")
        guard first > 0, !block.contains("\\begin{document}") else { return (text, false) }
        let opens = occurrences(of: #"\\begin\{"#, in: block) + occurrences(of: #"\\\["#, in: block)
        let closes = occurrences(of: #"\\end\{"#, in: block) + occurrences(of: #"\\\]"#, in: block)
        guard opens > closes else { return (text, false) }
        // Never drop most of the document: only a trailing fragment.
        let contentChars = lines.joined().count
        guard block.count * 3 < contentChars else { return (text, false) }
        lines.removeSubrange(first...last)
        return (lines.joined(separator: "\n"), true)
    }

    /// Inside each \[ ... \], closes environments that were opened but never closed (e.g. a looping reply
    /// that dropped \end{aligned}).
    static func closeEnvironmentsInDisplayMath(_ text: String) -> (String, Int) {
        guard let regex = try? NSRegularExpression(pattern: #"\\\[([\s\S]*?)\\\]"#) else { return (text, 0) }
        let ns = text as NSString
        var result = text
        var total = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed() {
            let inner = ns.substring(with: match.range(at: 1))
            var stack: [String] = []
            if let envRegex = try? NSRegularExpression(pattern: #"\\(begin|end)\{([^}]+)\}"#) {
                let innerNS = inner as NSString
                for m in envRegex.matches(in: inner, range: NSRange(location: 0, length: innerNS.length)) {
                    let kind = innerNS.substring(with: m.range(at: 1))
                    let name = innerNS.substring(with: m.range(at: 2))
                    if kind == "begin" { stack.append(name) } else if stack.last == name { stack.removeLast() }
                }
            }
            guard !stack.isEmpty else { continue }
            total += stack.count
            let closing = stack.reversed().map { "\\end{\($0)}" }.joined(separator: "\n")
            let fixedInner = inner.trimmingCharacters(in: .whitespacesAndNewlines) + "\n" + closing
            if let range = Range(match.range, in: result) {
                result.replaceSubrange(range, with: "\\[\n" + fixedInner + "\n\\]")
            }
        }
        return (result, total)
    }

    private static func occurrences(of pattern: String, in text: String) -> Int {
        (try? NSRegularExpression(pattern: pattern))?.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text)) ?? 0
    }

    static func ensureDocument(_ text: String) -> String {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.contains("\\begin{document}") {
            let body = t.replacingOccurrences(of: #"\\documentclass(\[[^\]]*\])?\{[^}]*\}\s*"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"\\usepackage(\[[^\]]*\])?\{[^}]*\}\s*"#, with: "", options: .regularExpression)
            t = "\\documentclass{article}\n\\usepackage{amsmath}\n\\usepackage{amssymb}\n\\begin{document}\n\n\(body)\n\n\\end{document}"
        } else if !t.contains("\\end{document}") {
            t += "\n\\end{document}"
        }
        return t
    }

    // MARK: - Targeted repairs

    /// One fix for one latex.js error, or nil if there's nothing safe to do.
    static func repair(_ latex: String, issue: LaTeXValidator.Issue) -> (String, String)? {
        var lines = latex.components(separatedBy: "\n")

        // "environment 'X' is missing its end, found 'Y' instead"
        if let (open, found) = match(issue.message, #"environment '([^']+)' is missing its end, found '([^']+)' instead"#) {
            if found == "document", let end = lines.lastIndex(where: { $0.contains("\\end{document}") }) {
                lines.insert("\\end{\(open)}", at: end)
                return (lines.joined(separator: "\n"), "Closed unclosed \\begin{\(open)}")
            }
            if let idx = lines.firstIndex(where: { $0.contains("\\end{\(found)}") }) {
                lines[idx] = lines[idx].replacingOccurrences(of: "\\end{\(found)}", with: "\\end{\(open)}")
                return (lines.joined(separator: "\n"), "Matched \\end{\(found)} to \\begin{\(open)}")
            }
        }

        // "unknown environment: X" → display math if it looks like math, else drop the wrapper.
        if let (env, _) = match(issue.message, #"unknown environment: ([A-Za-z*]+)"#) {
            let e = NSRegularExpression.escapedPattern(for: env)
            let text = lines.joined(separator: "\n")
            let mathEnvs = ["equation", "align", "gather", "multline", "eqnarray", "aligned", "split", "cases"]
            let replacementOpen = mathEnvs.contains(where: { env.hasPrefix($0) }) ? "\\\\[" : ""
            let replacementClose = mathEnvs.contains(where: { env.hasPrefix($0) }) ? "\\\\]" : ""
            let fixed = text
                .replacingOccurrences(of: "\\\\begin\\{\(e)\\*?\\}", with: replacementOpen, options: .regularExpression)
                .replacingOccurrences(of: "\\\\end\\{\(e)\\*?\\}", with: replacementClose, options: .regularExpression)
            if fixed != text {
                return (fixed, "Replaced unsupported environment '\(env)'")
            }
        }

        // KaTeX render errors (from the validator) have no line: repair the display block with the snippet.
        if issue.message.hasPrefix("Math error:") {
            let (closed, count) = closeEnvironmentsInDisplayMath(latex)
            if count > 0 { return (closed, "Closed \(count) unclosed math environment\(count == 1 ? "" : "s")") }
            if let snippetRange = issue.message.range(of: " in: ") {
                let snippet = String(issue.message[snippetRange.upperBound...]).prefix(25)
                if !snippet.isEmpty, let idx = lines.firstIndex(where: { $0.contains(snippet.trimmingCharacters(in: .whitespaces)) }) {
                    let balanced = balance(lines[idx])
                    if balanced != lines[idx] {
                        lines[idx] = balanced
                        return (lines.joined(separator: "\n"), "Balanced math on line \(idx + 1)")
                    }
                }
            }
            return nil
        }

        guard let lineNo = issue.line, lineNo >= 1, lineNo <= lines.count, let col = issue.column else {
            // Parse ran off the end: close the document.
            if issue.message.contains("\\end{document} missing"), !latex.contains("\\end{document}") {
                return (latex + "\n\\end{document}", "Added missing \\end{document}")
            }
            return nil
        }
        let idx = lineNo - 1
        let line = lines[idx]
        let chars = Array(line)
        let at: Character? = (col >= 1 && col <= chars.count) ? chars[col - 1] : nil

        switch at {
        case "$" where unescapedCount(of: "$", in: line) % 2 == 1:
            // Unclosed inline math: close it at the end of the line (inside any unclosed braces).
            lines[idx] = balance(line) + "$"
            return (lines.joined(separator: "\n"), "Closed inline math on line \(lineNo)")
        case "&":
            lines[idx] = replaceChar(in: line, at: col - 1, with: "\\&")
            return (lines.joined(separator: "\n"), "Escaped & on line \(lineNo)")
        case "_", "^":
            // Math outside math mode: wrap the surrounding token in $...$.
            lines[idx] = wrapToken(in: line, at: col - 1)
            return (lines.joined(separator: "\n"), "Put \(at!) on line \(lineNo) into math mode")
        case "#", "%":
            lines[idx] = replaceChar(in: line, at: col - 1, with: "\\\(at!)")
            return (lines.joined(separator: "\n"), "Escaped \(at!) on line \(lineNo)")
        case "}":
            lines[idx] = replaceChar(in: line, at: col - 1, with: "")
            return (lines.joined(separator: "\n"), "Removed unmatched } on line \(lineNo)")
        default:
            break
        }

        // Unbalanced braces or \[ usually show up on the offending line, or at the start of the next one.
        for target in [idx, previousContentLine(lines, before: idx)].compactMap({ $0 }) {
            let balanced = balance(lines[target])
            if balanced != lines[target] {
                lines[target] = balanced
                return (lines.joined(separator: "\n"), "Balanced delimiters on line \(target + 1)")
            }
        }
        return dropTruncatedLastBlock(latex, errorLine: lineNo)
    }

    /// A reply cut off at the token limit ends mid-equation. If the error is in the last content block,
    /// drop that block rather than guess how it ended.
    static func dropTruncatedLastBlock(_ latex: String, errorLine: Int) -> (String, String)? {
        var lines = latex.components(separatedBy: "\n")
        guard let endDoc = lines.lastIndex(where: { $0.contains("\\end{document}") }) else { return nil }
        // Start of the last block: the line after the last blank line before \end{document}.
        var start = endDoc - 1
        while start >= 0, lines[start].trimmingCharacters(in: .whitespaces).isEmpty { start -= 1 }
        let lastContent = start
        while start > 0, !lines[start - 1].trimmingCharacters(in: .whitespaces).isEmpty { start -= 1 }
        guard lastContent >= start, errorLine - 1 >= start, lines[start...lastContent].count < lines.count / 2,
              !lines[start].contains("\\begin{document}") else { return nil }
        lines.removeSubrange(start...lastContent)
        return (lines.joined(separator: "\n"), "Removed an incomplete last block (output was cut off)")
    }

    private static func match(_ text: String, _ pattern: String) -> (String, String)? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let m = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        let g1 = m.numberOfRanges > 1 ? Range(m.range(at: 1), in: text).map { String(text[$0]) } ?? "" : ""
        let g2 = m.numberOfRanges > 2 ? Range(m.range(at: 2), in: text).map { String(text[$0]) } ?? "" : ""
        return (g1, g2)
    }

    private static func previousContentLine(_ lines: [String], before idx: Int) -> Int? {
        var i = idx - 1
        while i >= 0 {
            if !lines[i].trimmingCharacters(in: .whitespaces).isEmpty { return i }
            i -= 1
        }
        return nil
    }

    private static func replaceChar(in line: String, at offset: Int, with replacement: String) -> String {
        var chars = Array(line)
        guard offset >= 0, offset < chars.count else { return line }
        chars.replaceSubrange(offset...offset, with: Array(replacement))
        return String(chars)
    }

    private static func wrapToken(in line: String, at offset: Int) -> String {
        let chars = Array(line)
        guard offset >= 0, offset < chars.count else { return line }
        var start = offset, end = offset
        let isTokenChar: (Character) -> Bool = { !$0.isWhitespace && $0 != "$" }
        while start > 0, isTokenChar(chars[start - 1]) { start -= 1 }
        while end + 1 < chars.count, isTokenChar(chars[end + 1]) { end += 1 }
        return String(chars[..<start]) + "$" + String(chars[start...end]) + "$" + String(chars[(end + 1)...])
    }

    private static func unescapedCount(of target: Character, in line: String) -> Int {
        var count = 0, escaped = false
        for c in line {
            if escaped { escaped = false; continue }
            if c == "\\" { escaped = true; continue }
            if c == target { count += 1 }
        }
        return count
    }

    /// Removes unmatched `}` and closes unbalanced `{`, `\[` and `\(` on a single line.
    static func balance(_ line: String) -> String {
        var kept: [Character] = []
        var depth = 0
        var escaped = false
        for c in line {
            if escaped { escaped = false; kept.append(c); continue }
            if c == "\\" { escaped = true; kept.append(c); continue }
            if c == "{" { depth += 1 }
            if c == "}" {
                if depth == 0 { continue }  // stray closing brace
                depth -= 1
            }
            kept.append(c)
        }
        var result = String(kept)
        if depth > 0 {
            // Close braces before a trailing math delimiter ($, \], \)) so they stay inside the math.
            let braces = String(repeating: "}", count: depth)
            let trimmed = result.trimmingCharacters(in: .whitespaces)
            if let closer = ["\\]", "\\)", "$"].first(where: { trimmed.hasSuffix($0) }),
               let range = result.range(of: closer, options: .backwards) {
                result.replaceSubrange(range, with: braces + " " + closer)
            } else {
                result += braces
            }
        }
        let opensDisplay = result.components(separatedBy: "\\[").count - 1
        let closesDisplay = result.components(separatedBy: "\\]").count - 1
        if opensDisplay > closesDisplay { result += " \\]" }
        let opensInline = result.components(separatedBy: "\\(").count - 1
        let closesInline = result.components(separatedBy: "\\)").count - 1
        if opensInline > closesInline { result += " \\)" }
        return result
    }
}
