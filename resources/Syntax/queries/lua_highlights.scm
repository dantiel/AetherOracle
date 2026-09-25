; Lua highlights (C grammar — basic C-like highlighting)
(identifier) @variable

((identifier) @constant
 (#match? @constant "^[A-Z][A-Z\\d_]*$"))

; Lua keywords (matched as identifiers by C grammar)
[
  "and"
  "break"
  "do"
  "else"
  "elseif"
  "end"
  "false"
  "for"
  "function"
  "goto"
  "if"
  "in"
  "local"
  "nil"
  "not"
  "or"
  "repeat"
  "return"
  "then"
  "true"
  "until"
  "while"
] @keyword

(string_literal) @string
(null) @constant
(number_literal) @number

(type_identifier) @type
(primitive_type) @type

(call_expression
  function: (identifier) @function)
(function_declarator
  declarator: (identifier) @function)

(comment) @comment
