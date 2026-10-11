; CoffeeHaml highlights (HTML grammar — HAML structures + CoffeeScript embedded)
; CoffeeHaml files use the HTML grammar for tag structure; CoffeeScript scopes
; are handled by heuristic engine (keywords, strings, comments, etc.)

; HTML-like tags
(start_tag (tag_name) @tag)
(end_tag (tag_name) @tag)
(self_closing_tag (tag_name) @tag)

; Attributes
(attribute_name) @attribute
(attribute_value) @string

; Comments
(comment) @comment

; Text content
(text) @none
