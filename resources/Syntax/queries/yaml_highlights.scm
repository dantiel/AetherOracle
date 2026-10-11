; YAML highlights (C grammar — basic C-like highlighting)
; YAML files are primarily heuristic-highlighted; this provides fallback tokenization
(identifier) @variable

((identifier) @constant
 (#match? @constant "^[A-Z][A-Z\\d_]*$"))

(string_literal) @string
(null) @constant
(number_literal) @number

(comment) @comment
