; ── ATX Headings (h1–h6) ──
; heading_content is a field name wrapping (inline) — use inline directly
(atx_heading
  (atx_h1_marker) @text.title.1
  (inline) @text.title.1)
(atx_heading
  (atx_h2_marker) @text.title.2
  (inline) @text.title.2)
(atx_heading
  (atx_h3_marker) @text.title.3
  (inline) @text.title.3)
(atx_heading
  (atx_h4_marker) @text.title.4
  (inline) @text.title.4)
(atx_heading
  (atx_h5_marker) @text.title.5
  (inline) @text.title.5)
(atx_heading
  (atx_h6_marker) @text.title.6
  (inline) @text.title.6)

; ── Setext Headings ──
(setext_heading
  (paragraph (inline) @text.title))

; ── Block Quotes ──
(block_quote) @text.quote
(block_continuation) @text.quote

; ── Thematic Break ──
(thematic_break) @text.rule

; ── List Markers ──
(list_marker_dot) @punctuation.delimiter
(list_marker_minus) @punctuation.delimiter
(list_marker_plus) @punctuation.delimiter
(list_marker_star) @punctuation.delimiter
(list_marker_parenthesis) @punctuation.delimiter

; ─── Fenced Code Blocks ───
; Capture the full fenced_code_block — the SyntaxEngine clip logic
; (pairedFenceRanges + clipCodeBlock) bounds it against known fences.
(fenced_code_block) @markup.raw.block
(fenced_code_block_delimiter) @punctuation.delimiter
(info_string) @text.uri

; ── Indented Code Blocks ──
(indented_code_block) @markup.raw.block

; ── Tables (GFM) — disabled: grammar version doesn't support pipe_table nodes ──
; (pipe_table_delimiter_row) @text.rule
; (pipe_table_header (inline) @text.table.header)
; (pipe_table_delimiter) @punctuation.table

; ── HTML Blocks ──
(html_block) @markup.raw.block

; ── Link Reference Definitions ──
(link_reference_definition
  (link_label) @text.reference
  (link_destination) @text.uri
  (link_title) @string)