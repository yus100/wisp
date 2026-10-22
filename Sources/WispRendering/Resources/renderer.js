/* global marked, katex */
"use strict";

(() => {
    const escapeHTML = text => text.replace(/[&<>"']/g, c => ({
        "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;"
    }[c]));

    function mathToken(src) {
        const opener = ["\\[", "\\(", "$$", "$"].find(delimiter => src.startsWith(delimiter));
        if (!opener) return;
        const display = opener === "\\[" || opener === "$$";
        const closer = { "\\[": "\\]", "\\(": "\\)", "$$": "$$", "$": "$" }[opener];
        if (opener === "$" && /^\s/.test(src.slice(1))) return;
        for (let i = opener.length; i < src.length; i++) {
            if (!display && src[i] === "\n" && opener === "$") return;
            if (src.startsWith(closer, i)) {
                if (opener === "$" && (/\s/.test(src[i - 1]) || /[\d$]/.test(src[i + 1] || ""))) return;
                const tex = src.slice(opener.length, i);
                // Bare amounts such as $5$ stay readable as currency. Use \(5\) for numeric math.
                if (opener === "$" && /^[\d,.]+$/.test(tex)) return;
                return { type: "math", raw: src.slice(0, i + closer.length), tex, display, complete: true };
            }
            if (src[i] === "\\") i++;
        }
        // Keep explicit unfinished equations verbatim until the closing delimiter arrives.
        if (opener !== "$") return { type: "math", raw: src, display, complete: false };
    }

    function renderMath(token) {
        if (token.complete) {
            try {
                return katex.renderToString(token.tex, {
                    displayMode: token.display, throwOnError: true, trust: false,
                    strict: "ignore", maxExpand: 1000, maxSize: 20, output: "htmlAndMathml"
                });
            } catch (_) { /* Unsupported or malformed TeX stays readable. */ }
        }
        return `<span class="math-source${token.display ? " math-display" : ""}">${escapeHTML(token.raw)}</span>`;
    }

    const parser = new marked.Marked({ gfm: true, breaks: false });
    parser.use({
        extensions: [{
            name: "math", level: "inline",
            start: src => src.search(/\\[([]|\$/),
            tokenizer: mathToken,
            renderer: renderMath
        }, {
            name: "displayMath", level: "block",
            // Paragraph interruption would split multiline code spans; inline math handles those paragraphs.
            tokenizer(src) {
                const leading = src.match(/^ {0,3}(?=\\\[|\$\$)/);
                if (!leading) return;
                const token = mathToken(src.slice(leading[0].length));
                if (!token) return;
                return { ...token, type: "displayMath", raw: leading[0] + token.raw };
            },
            renderer: renderMath
        }],
        renderer: {
            // Model output is untrusted. Only Markdown-generated markup enters the document.
            html: ({ text }) => escapeHTML(text),
            link({ href, tokens }) {
                const label = this.parser.parseInline(tokens);
                return /^(https?:|mailto:)/i.test(href)
                    ? `<a href="${escapeHTML(href)}">${label}</a>` : label;
            },
            image: ({ text }) => escapeHTML(text)
        }
    });

    // Also exported for the dependency-free Node regression suite.
    const render = text => parser.parse(text);
    if (typeof module !== "undefined") module.exports = { render };
    if (typeof document === "undefined") return;

    const answer = document.getElementById("answer");
    let previousHeight = 0;
    function reportHeight() {
        const height = Math.ceil(answer.getBoundingClientRect().height);
        if (height !== previousHeight) {
            previousHeight = height;
            window.webkit?.messageHandlers?.height?.postMessage(height);
        }
    }
    window.renderAnswer = async (text, dark) => {
        document.documentElement.dataset.theme = dark ? "dark" : "light";
        answer.innerHTML = render(text);
        reportHeight();
        await document.fonts.ready;
        reportHeight();
    };
    new ResizeObserver(reportHeight).observe(answer);
})();
