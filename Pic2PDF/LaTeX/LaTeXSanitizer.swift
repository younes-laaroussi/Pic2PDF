//
//  LaTeXSanitizer.swift
//  Pic2PDF
//
//  Rewrites LaTeX that latex.js can't render (packages, figures, tables, equation/align-style
//  environments) into what it can. Shared by the preview and the auto-fixer.
//

import Foundation

enum LaTeXSanitizer {
    static func clean(_ latex: String) -> String {
        var cleaned = latex
        
        // Remove entire lines with unsupported packages
        cleaned = cleaned.replacingOccurrences(of: #"\\usepackage\{graphicx\}\n?"#, with: "", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: #"\\usepackage\{geometry\}\n?"#, with: "", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: #"\\usepackage\{fancyhdr\}\n?"#, with: "", options: .regularExpression)
        
        // Remove geometry command with any arguments
        cleaned = cleaned.replacingOccurrences(of: #"\\geometry\{[^\}]+\}\n?"#, with: "", options: .regularExpression)
        
        // Remove ALL fancy header related lines (line by line)
        cleaned = cleaned.replacingOccurrences(of: #"\\pagestyle\{fancy\}\n?"#, with: "", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: #"\\fancyhf\{\}\n?"#, with: "", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: #"\\renewcommand\{[^\}]+\}\{[^\}]+\}\n?"#, with: "", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: #"\\fancyhead\[[^\]]+\]\{[^\n]+\}\n?"#, with: "", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: #"\\fancyfoot\[[^\]]+\]\{[^\n]+\}\n?"#, with: "", options: .regularExpression)
        
        // Remove includegraphics (replace with placeholder text)
        cleaned = cleaned.replacingOccurrences(of: #"\\includegraphics(\[[^\]]*\])?\{[^\}]+\}"#, with: "[Image]", options: .regularExpression)
        
        // Remove tabular environments (replace with plain text)
        cleaned = cleaned.replacingOccurrences(of: #"\\begin\{tabular\}[^\n]*\n([^\\]*)(\\end\{tabular\})"#, with: "[Table data removed - not supported]", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: #"\\begin\{table\}[^\n]*\n([^\\]*)(\\end\{table\})"#, with: "[Table removed - not supported]", options: .regularExpression)
        
        // Remove tikz environments (replace with plain text)
        cleaned = cleaned.replacingOccurrences(of: #"\\begin\{tikzpicture\}[\s\S]*?\\end\{tikzpicture\}"#, with: "[Figure removed - not supported]", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: #"\\usepackage\{tikz\}\n?"#, with: "", options: .regularExpression)
        
        // ===== REMOVE UNSUPPORTED MATH ENVIRONMENTS (equation, align, etc.) =====
        // Replace equation environment with \[ \] display math
        cleaned = replaceEnvironment(in: cleaned, name: "equation", removeAlignMarkers: false)
        
        // Replace align environment with \[ \] display math (remove & markers)
        cleaned = replaceEnvironment(in: cleaned, name: "align", removeAlignMarkers: true)
        
        // Replace gather environment with \[ \] display math
        cleaned = replaceEnvironment(in: cleaned, name: "gather", removeAlignMarkers: false)
        
        // Replace multline environment with \[ \] display math
        cleaned = replaceEnvironment(in: cleaned, name: "multline", removeAlignMarkers: false)
        
        // Remove other specific unsupported environments (but preserve document, itemize, enumerate)
        let unsupportedEnvs = ["figure", "table", "tabular", "tikzpicture", "minipage", "verbatim", "lstlisting"]
        for env in unsupportedEnvs {
            cleaned = cleaned.replacingOccurrences(
                of: #"\\begin\{\#(env)\*?\}[\s\S]*?\\end\{\#(env)\*?\}"#,
                with: "[Environment '\(env)' removed - not supported]",
                options: .regularExpression
            )
        }
        
        // Remove multiple blank lines
        cleaned = cleaned.replacingOccurrences(of: #"\n\n\n+"#, with: "\n\n", options: .regularExpression)
        
        return cleaned
    }
    
    /// Rewrites a display-math environment latex.js doesn't know (equation, align, gather, multline) as
    /// `\\[ ... \\]`. Multi-row content keeps its rows: it goes into KaTeX's `aligned` (for align) or
    /// `gathered` environment, which latex.js renders, instead of being flattened into one line.
    private static func replaceEnvironment(in text: String, name: String, removeAlignMarkers: Bool) -> String {
        let pattern = #"\\begin\{\#(name)\*?\}[\s\S]*?\\end\{\#(name)\*?\}"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return text
        }

        let nsText = text as NSString
        let matches = regex.matches(in: text, options: [], range: NSRange(location: 0, length: nsText.length))

        var result = text
        // Process matches in reverse to maintain correct indices
        for match in matches.reversed() {
            let matchRange = match.range
            let matchText = nsText.substring(with: matchRange)

            // Extract content between \begin and \end
            var content = matchText
                .replacingOccurrences(of: #"\\begin\{\#(name)\*?\}\s*"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"\s*\\end\{\#(name)\*?\}"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)

            // Blank lines are paragraph breaks, which aren't allowed inside math.
            content = content.replacingOccurrences(of: #"\n\s*\n"#, with: "\n", options: .regularExpression)

            let hasRows = content.contains("\\\\")
            let hasRowEnvironment = content.range(of: #"\\begin\{(aligned|gathered|split|array|cases|[pbBvV]?matrix)\}"#, options: .regularExpression) != nil
            if hasRows && !hasRowEnvironment {
                // align keeps its & alignment points; the others center each row.
                let inner = removeAlignMarkers ? "aligned" : "gathered"
                if !removeAlignMarkers { content = content.replacingOccurrences(of: "&", with: "") }
                content = "\\begin{\(inner)}\n\(content)\n\\end{\(inner)}"
            } else if removeAlignMarkers && !hasRowEnvironment {
                content = content.replacingOccurrences(of: "&", with: "")
            }

            let replacement = "\\[\n\(content)\n\\]"

            if let range = Range(matchRange, in: result) {
                result = result.replacingCharacters(in: range, with: replacement)
            }
        }

        return result
    }
}
