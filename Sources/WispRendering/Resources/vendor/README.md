# Bundled answer-rendering dependencies

These files ship with Wisp so rendering works offline. No CDN or package manager is used at runtime or build time.

| Library | Version | Upstream | License |
| --- | --- | --- | --- |
| KaTeX | 0.16.22 | https://github.com/KaTeX/KaTeX | `KATEX-LICENSE` (MIT) |
| Marked | 15.0.12 | https://github.com/markedjs/marked | `MARKED-LICENSE` (MIT) |

Files are copied unchanged from the npm release archives:

- `https://registry.npmjs.org/katex/-/katex-0.16.22.tgz`: `dist/katex.min.js`, `dist/katex.min.css`, `dist/fonts/*`, `LICENSE`.
- `https://registry.npmjs.org/marked/-/marked-15.0.12.tgz`: `lib/marked.umd.js`, `LICENSE.md`.

When updating, retain licenses and fonts, update this version table, and run `make test`, `make lint`, and `make app`. The WebKit tests exercise the actual bundled scripts, styles, and fonts.
