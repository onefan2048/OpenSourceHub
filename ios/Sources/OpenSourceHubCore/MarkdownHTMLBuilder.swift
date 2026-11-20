import Foundation

/// Converts GitHub Markdown + raw HTML + LaTeX math into responsive HTML for WKWebView.
/// Crucial feature: rewrites ALL relative `src`, `href`, AND `srcset` attributes (including
/// `<picture><source media="(prefers-color-scheme: dark)" srcset="...">`) to GitHub raw/blob URLs,
/// preventing broken localhost requests in dark mode.
public enum MarkdownHTMLBuilder {
    public static func resolveURL(_ rawUrl: String, owner: String?, repo: String?, branch: String?, isRawAsset: Bool) -> String {
        let u = rawUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        if u.isEmpty || u.hasPrefix("#") || u.lowercased().hasPrefix("http://") || u.lowercased().hasPrefix("https://") || u.lowercased().hasPrefix("mailto:") || u.lowercased().hasPrefix("data:") {
            return u
        }
        if u.hasPrefix("//") { return "https:\(u)" }
        guard let owner = owner, let repo = repo, !owner.isEmpty, !repo.isEmpty else { return u }
        let br = (branch?.isEmpty == false) ? branch! : "HEAD"
        let clean = u.hasPrefix("./") ? String(u.dropFirst(2)) : (u.hasPrefix("/") ? String(u.dropFirst()) : u)
        if isRawAsset {
            return "https://raw.githubusercontent.com/\(owner)/\(repo)/\(br)/\(clean)"
        } else {
            return "https://github.com/\(owner)/\(repo)/blob/\(br)/\(clean)"
        }
    }

    public static func rewriteSrcSet(_ srcset: String, owner: String?, repo: String?, branch: String?) -> String {
        let parts = srcset.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let rewritten = parts.map { candidate -> String in
            let pieces = candidate.split(whereSeparator: { $0.isWhitespace })
            guard let first = pieces.first else { return candidate }
            let resolved = resolveURL(String(first), owner: owner, repo: repo, branch: branch, isRawAsset: true)
            if pieces.count > 1 {
                return ([resolved] + pieces.dropFirst().map(String.init)).joined(separator: " ")
            }
            return resolved
        }
        return rewritten.joined(separator: ", ")
    }

    /// Rewrites relative `src`, `srcset`, and `href` attributes inside HTML tags (including `<picture><source srcset>`).
    public static func rewriteHTMLAttributes(_ html: String, owner: String?, repo: String?, branch: String?) -> String {
        var out = html
        // Rewrite srcset="..." and srcset='...'
        out = replaceRegex(out, pattern: #"(?i)\b(srcset)\s*=\s*"([^"]+)""#) { m in
            let val = rewriteSrcSet(m[2], owner: owner, repo: repo, branch: branch)
            return "\(m[1])=\"\(val)\""
        }
        out = replaceRegex(out, pattern: #"(?i)\b(srcset)\s*=\s*'([^']+)'"#) { m in
            let val = rewriteSrcSet(m[2], owner: owner, repo: repo, branch: branch)
            return "\(m[1])='\(val)'"
        }
        // Rewrite src="..." and src='...'
        out = replaceRegex(out, pattern: #"(?i)\b(src)\s*=\s*"([^"]+)""#) { m in
            let val = resolveURL(m[2], owner: owner, repo: repo, branch: branch, isRawAsset: true)
            return "\(m[1])=\"\(val)\""
        }
        out = replaceRegex(out, pattern: #"(?i)\b(src)\s*=\s*'([^']+)'"#) { m in
            let val = resolveURL(m[2], owner: owner, repo: repo, branch: branch, isRawAsset: true)
            return "\(m[1])='\(val)'"
        }
        // Rewrite href="..." and href='...'
        out = replaceRegex(out, pattern: #"(?i)\b(href)\s*=\s*"([^"]+)""#) { m in
            let val = resolveURL(m[2], owner: owner, repo: repo, branch: branch, isRawAsset: false)
            return "\(m[1])=\"\(val)\""
        }
        out = replaceRegex(out, pattern: #"(?i)\b(href)\s*=\s*'([^']+)'"#) { m in
            let val = resolveURL(m[2], owner: owner, repo: repo, branch: branch, isRawAsset: false)
            return "\(m[1])='\(val)'"
        }
        // Strip script/iframe tags for safety
        out = replaceRegex(out, pattern: #"(?is)<(script|iframe|object|embed)\b[^>]*>.*?</\1>"#) { _ in "" }
        return out
    }

    public static func buildDocument(
        markdown: String,
        owner: String? = nil,
        repo: String? = nil,
        branch: String? = nil,
        isDark: Bool = false
    ) -> String {
        let htmlBody = renderMarkdownToHTML(markdown, owner: owner, repo: repo, branch: branch)
        let bg = isDark ? "#1E211F" : "#FFFFFF"
        let fg = isDark ? "#E6ECE8" : "#1C2420"
        let muted = isDark ? "#9AA8A0" : "#5B6760"
        let border = isDark ? "rgba(255,255,255,0.12)" : "rgba(0,0,0,0.09)"
        let codeBg = isDark ? "rgba(255,255,255,0.08)" : "rgba(0,0,0,0.05)"
        let accent = isDark ? "#43B58F" : "#256B53"
        let colorScheme = isDark ? "dark" : "light"

        return """
        <!doctype html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
        <meta name="color-scheme" content="\(colorScheme)">
        <link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/katex@0.16.11/dist/katex.min.css">
        <style>
          :root { color-scheme: \(colorScheme); }
          * { box-sizing: border-box; }
          html, body {
            margin: 0; padding: 0;
            background: \(bg); color: \(fg);
            font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", "PingFang SC", sans-serif;
            font-size: 15px; line-height: 1.65;
            word-wrap: break-word; overflow-wrap: anywhere;
          }
          h1, h2, h3, h4 { margin: 16px 0 8px; line-height: 1.3; font-weight: 700; }
          h1 { font-size: 1.45em; border-bottom: 1px solid \(border); padding-bottom: 6px; }
          h2 { font-size: 1.25em; border-bottom: 1px solid \(border); padding-bottom: 4px; }
          h3 { font-size: 1.1em; }
          p { margin: 8px 0; }
          a { color: \(accent); text-decoration: none; }
          a:hover { text-decoration: underline; }
          img, picture img { max-width: 100%; height: auto; border-radius: 8px; }
          code {
            font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
            font-size: 0.88em; background: \(codeBg);
            padding: 2px 5px; border-radius: 5px;
          }
          pre {
            background: \(codeBg); padding: 12px; border-radius: 10px;
            overflow-x: auto; border: 1px solid \(border);
          }
          pre code { background: none; padding: 0; font-size: 13px; }
          blockquote {
            margin: 10px 0; padding: 4px 12px;
            border-left: 3px solid \(accent); color: \(muted);
            background: \(codeBg); border-radius: 0 8px 8px 0;
          }
          ul, ol { padding-left: 20px; margin: 8px 0; }
          li { margin: 4px 0; }
          table { width: 100%; border-collapse: collapse; margin: 12px 0; display: block; overflow-x: auto; font-size: 13.5px; }
          th, td { border: 1px solid \(border); padding: 6px 10px; text-align: left; }
          th { background: \(codeBg); font-weight: 600; }
          hr { border: none; border-top: 1px solid \(border); margin: 16px 0; }
          .math-display { overflow-x: auto; text-align: center; margin: 12px 0; padding: 6px; }
          .math-inline { font-family: "Times New Roman", serif; }
        </style>
        </head>
        <body>
        <div id="content">\(htmlBody)</div>
        <script defer src="https://cdn.jsdelivr.net/npm/katex@0.16.11/dist/katex.min.js"></script>
        <script defer src="https://cdn.jsdelivr.net/npm/katex@0.16.11/dist/contrib/auto-render.min.js" onload="renderMath()"></script>
        <script>
          function notifyHeight() {
            var h = Math.ceil(document.getElementById('content').scrollHeight) + 12;
            if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.heightChanged) {
              window.webkit.messageHandlers.heightChanged.postMessage(h);
            }
          }
          function renderMath() {
            try {
              if (window.renderMathInElement) {
                window.renderMathInElement(document.getElementById('content'), {
                  delimiters: [
                    {left: '$$', right: '$$', display: true},
                    {left: '$', right: '$', display: false},
                    {left: '\\\\[', right: '\\\\]', display: true},
                    {left: '\\\\(', right: '\\\\)', display: false}
                  ],
                  throwOnError: false
                });
              }
            } catch (e) {}
            notifyHeight();
          }
          window.addEventListener('load', function() {
            notifyHeight();
            setTimeout(notifyHeight, 350);
            setTimeout(notifyHeight, 1200);
          });
          new ResizeObserver(notifyHeight).observe(document.getElementById('content'));
        </script>
        </body>
        </html>
        """
    }

    // MARK: - Lightweight GFM + Raw HTML Markdown Converter

    private static func renderMarkdownToHTML(_ md: String, owner: String?, repo: String?, branch: String?) -> String {
        let lines = md.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var html: [String] = []
        var i = 0
        var inCode = false
        var codeLang = ""
        var codeBuf: [String] = []
        var inUL = false
        var inOL = false

        func closeLists() {
            if inUL { html.append("</ul>"); inUL = false }
            if inOL { html.append("</ol>"); inOL = false }
        }

        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Fenced code blocks
            if trimmed.hasPrefix("```") {
                if !inCode {
                    closeLists()
                    inCode = true
                    codeLang = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                    codeBuf = []
                } else {
                    let escaped = escapeHTML(codeBuf.joined(separator: "\n"))
                    html.append("<pre><code class=\"language-\(escapeHTML(codeLang))\">\(escaped)</code></pre>")
                    inCode = false
                }
                i += 1
                continue
            }
            if inCode {
                codeBuf.append(line)
                i += 1
                continue
            }

            // Raw HTML block lines (e.g. <p align="center">, <picture>, <source>, <img>, <div...>, <details>, <table>)
            if trimmed.hasPrefix("<") && !trimmed.hasPrefix("<http") && !trimmed.hasPrefix("<mailto:") {
                closeLists()
                html.append(rewriteHTMLAttributes(line, owner: owner, repo: repo, branch: branch))
                i += 1
                continue
            }

            // Empty line
            if trimmed.isEmpty {
                closeLists()
                i += 1
                continue
            }

            // Horizontal rule
            if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                closeLists()
                html.append("<hr>")
                i += 1
                continue
            }

            // GFM Table
            if line.contains("|"), i + 1 < lines.count, isTableSeparator(lines[i + 1]) {
                closeLists()
                let headers = splitTableRow(line)
                var table = "<table><thead><tr>" + headers.map { "<th>\(renderInline($0, owner: owner, repo: repo, branch: branch))</th>" }.joined() + "</tr></thead><tbody>"
                i += 2
                while i < lines.count && lines[i].contains("|") && !lines[i].trimmingCharacters(in: .whitespaces).isEmpty {
                    let cols = splitTableRow(lines[i])
                    table += "<tr>" + cols.map { "<td>\(renderInline($0, owner: owner, repo: repo, branch: branch))</td>" }.joined() + "</tr>"
                    i += 1
                }
                table += "</tbody></table>"
                html.append(table)
                continue
            }

            // Headings
            if let hm = matchHeading(trimmed) {
                closeLists()
                html.append("<h\(hm.level)>\(renderInline(hm.text, owner: owner, repo: repo, branch: branch))</h\(hm.level)>")
                i += 1
                continue
            }

            // Blockquote
            if trimmed.hasPrefix("> ") || trimmed == ">" {
                closeLists()
                let qText = trimmed.hasPrefix("> ") ? String(trimmed.dropFirst(2)) : ""
                html.append("<blockquote>\(renderInline(qText, owner: owner, repo: repo, branch: branch))</blockquote>")
                i += 1
                continue
            }

            // Unordered list
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") {
                if inOL { html.append("</ol>"); inOL = false }
                if !inUL { html.append("<ul>"); inUL = true }
                var itemText = String(trimmed.dropFirst(2))
                if itemText.hasPrefix("[ ] ") { itemText = "☐ " + String(itemText.dropFirst(4)) }
                else if itemText.lowercased().hasPrefix("[x] ") { itemText = "☑ " + String(itemText.dropFirst(4)) }
                html.append("<li>\(renderInline(itemText, owner: owner, repo: repo, branch: branch))</li>")
                i += 1
                continue
            }

            // Ordered list
            if let olText = matchOrderedList(trimmed) {
                if inUL { html.append("</ul>"); inUL = false }
                if !inOL { html.append("<ol>"); inOL = true }
                html.append("<li>\(renderInline(olText, owner: owner, repo: repo, branch: branch))</li>")
                i += 1
                continue
            }

            // Normal paragraph
            closeLists()
            html.append("<p>\(renderInline(line, owner: owner, repo: repo, branch: branch))</p>")
            i += 1
        }
        closeLists()
        if inCode {
            html.append("<pre><code>\(escapeHTML(codeBuf.joined(separator: "\n")))</code></pre>")
        }
        return html.joined(separator: "\n")
    }

    private static func renderInline(_ text: String, owner: String?, repo: String?, branch: String?) -> String {
        var s = rewriteHTMLAttributes(text, owner: owner, repo: repo, branch: branch)
        // Images: ![alt](url)
        s = replaceRegex(s, pattern: #"!\[([^\]]*)\]\(([^)\s]+)(?:\s+"[^"]*")?\)"#) { m in
            let url = resolveURL(m[2], owner: owner, repo: repo, branch: branch, isRawAsset: true)
            return "<img src=\"\(url)\" alt=\"\(escapeHTML(m[1]))\" loading=\"lazy\">"
        }
        // Links: [text](url)
        s = replaceRegex(s, pattern: #"\[([^\]]+)\]\(([^)\s]+)(?:\s+"[^"]*")?\)"#) { m in
            let url = resolveURL(m[2], owner: owner, repo: repo, branch: branch, isRawAsset: false)
            return "<a href=\"\(url)\">\(m[1])</a>"
        }
        // Inline code: `code`
        s = replaceRegex(s, pattern: #"`([^`]+)`"#) { m in
            "<code>\(escapeHTML(m[1]))</code>"
        }
        // Bold **text**
        s = replaceRegex(s, pattern: #"\*\*([^*]+)\*\*"#) { m in "<strong>\(m[1])</strong>" }
        // Italic *text*
        s = replaceRegex(s, pattern: #"(?<!\*)\*([^*]+)\*(?!\*)"#) { m in "<em>\(m[1])</em>" }
        // Strikethrough ~~text~~
        s = replaceRegex(s, pattern: #"~~([^~]+)~~"#) { m in "<del>\(m[1])</del>" }
        return s
    }

    private static func matchHeading(_ line: String) -> (level: Int, text: String)? {
        for level in (1...4).reversed() {
            let prefix = String(repeating: "#", count: level) + " "
            if line.hasPrefix(prefix) {
                return (level, String(line.dropFirst(prefix.count)))
            }
        }
        return nil
    }

    private static func matchOrderedList(_ line: String) -> String? {
        guard let range = line.range(of: #"^\d+\.\s+"#, options: .regularExpression) else { return nil }
        return String(line[range.upperBound...])
    }

    private static func isTableSeparator(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        return t.contains("-") && t.range(of: #"^\|?[\s:|\-]+\|?$"#, options: .regularExpression) != nil
    }

    private static func splitTableRow(_ line: String) -> [String] {
        var t = line.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("|") { t = String(t.dropFirst()) }
        if t.hasSuffix("|") { t = String(t.dropLast()) }
        return t.split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func escapeHTML(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func replaceRegex(_ input: String, pattern: String, transform: ([String]) -> String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return input }
        let ns = input as NSString
        let matches = regex.matches(in: input, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return input }
        var result = input
        for m in matches.reversed() {
            var groups: [String] = []
            for idx in 0..<m.numberOfRanges {
                let r = m.range(at: idx)
                groups.append(r.location != NSNotFound ? ns.substring(with: r) : "")
            }
            if let swiftRange = Range(m.range, in: result) {
                result.replaceSubrange(swiftRange, with: transform(groups))
            }
        }
        return result
    }
}
