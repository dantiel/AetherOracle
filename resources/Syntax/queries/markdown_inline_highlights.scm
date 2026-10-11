; ── Emphasis / Strong / Strikethrough ──
(emphasis) @text.emphasis
(strong_emphasis) @text.strong
(strikethrough) @text.strikethrough

; ── Delimiters for emphasis / code ──
[
  (emphasis_delimiter)
  (code_span_delimiter)
] @punctuation.delimiter

; ── Inline code ──
(code_span) @markup.raw.inline

; ── Links and autolinks ──
(uri_autolink) @text.uri
(email_autolink) @text.uri
(link_destination) @text.uri

[
  (link_label)
  (link_text)
  (image_description)
] @text.reference

; ── Link / Image bracket punctuation ──
(image
  ["!" "[" "]" "(" ")"] @punctuation.delimiter)

(inline_link
  ["[" "]" "(" ")"] @punctuation.delimiter)

(shortcut_link
  ["[" "]"] @punctuation.delimiter)

; ── Escapes ──
[
  (backslash_escape)
  (hard_line_break)
] @string.escape

; ── HTML entities ──
(entity_reference) @string.escape
(numeric_character_reference) @string.escape
