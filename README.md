# turin-mode

Play guided tours of a codebase from inside Emacs.

A tour is a sequence of stops; each stop points at a location in the project and carries a markdown commentary body. The plugin opens the source file for the current stop, jumps the cursor to the resolved location, overlays a highlight on the relevant region, and shows the commentary in a side window.

This is the Emacs editor integration for [Turin](https://github.com/afsharalex/turin).

## Requirements

- Emacs 28.1+ (uses `json-parse-buffer`).
- For `treesitter` anchors: Emacs 29+ with the relevant tree-sitter grammars installed (`treesit-language-available-p`). `pattern` and `line` anchors work without any extra setup.

## Installation

Drop `turin-mode.el` somewhere on your `load-path`, then:

```elisp
(require 'turin-mode)
```

Or with `use-package`:

```elisp
(use-package turin-mode
  :commands (turin-start turin-next turin-next-commentary
             turin-prev turin-prev-commentary turin-goto turin-quit turin-list))
```

No additional setup is required.

## Commands

| Command          | Behavior                                                               |
| ---------------- | ---------------------------------------------------------------------- |
| `M-x turin-start`| Locate `.turin/` upward from the current buffer, load it, jump to stop 1. |
| `M-x turin-next` | Advance to the next stop.                                              |
| `M-x turin-prev` | Retreat to the previous stop.                                          |
| `M-x turin-goto` | Prompt for an index and jump to that stop.                             |
| `M-x turin-quit` | Close the side window, remove highlights, end the session.             |
| `M-x turin-list` | Show all stops in the minibuffer.                                      |

While a tour is active, the commentary buffer enables `turin-commentary-mode`, which binds:

| Key | Action      |
| --- | ----------- |
| `n` | next stop   |
| `N` | next stop, keep focus in commentary |
| `p` | previous    |
| `P` | previous, keep focus in commentary |
| `g` | goto N      |
| `l` | list stops  |
| `q` | quit tour   |

The source buffer gets no key rebindings, so you can read and edit code freely while the commentary is up.

## Tour format

Tours live in `.turin/` at the project root:

```
<project-root>/
└── .turin/
    ├── tour.json     # ordered list of stop filenames + tour metadata
    ├── entry.md      # one stop
    ├── dispatch.md   # one stop
    └── buffer.md     # one stop
```

`tour.json`:

```json
{
  "tour": {
    "title": "Lexer architecture",
    "description": "How the hand-written lexer feeds the streaming parser."
  },
  "stops": [
    "entry.md",
    "dispatch.md",
    "buffer.md"
  ]
}
```

Each stop is markdown with TOML frontmatter:

```markdown
---
id = "entry"
file = "src/parser/lexer.rs"
anchor = { kind = "pattern", value = "fn tokenize" }
title = "Entry point"
highlight = { lines = 8 }
---

The lexer is hand-written rather than generated.
Note how it returns an iterator instead of a Vec —
this matters later for the streaming parser.
```

### Anchor kinds

- `{ kind = "line", value = N }` — go to that line directly.
- `{ kind = "pattern", value = "..." }` — Emacs regex; first match wins.
- `{ kind = "treesitter", query = "(function_item name: (identifier) @n (#eq? @n \"tokenize\"))" }` — tree-sitter S-expression query, run via the buffer's tree-sitter parser. Requires Emacs 29+ with the language grammar installed.

### Highlight

`highlight = { lines = N }` highlights N lines starting at the resolved anchor.

## Configuration

```elisp
;; Show commentary on the left instead of the right
(setq turin-commentary-side 'left)

;; Make the commentary window 30% of the frame width
(setq turin-commentary-size 0.3)

;; Customize the highlight face
(set-face-attribute 'turin-highlight-face nil
                    :background "#1e3a5f")
```

## Files

```
turin-mode/
├── turin-mode.el -- single-file package (loader, parser, anchor resolver,
│                    commands, commentary mode)
├── LICENSE
└── README.md
```
