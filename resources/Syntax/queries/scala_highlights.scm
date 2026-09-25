; Scala highlights (C grammar — basic C-like highlighting)
(identifier) @variable

((identifier) @constant
 (#match? @constant "^[A-Z][A-Z\\d_]*$"))

; Scala keywords (matched as identifiers by C grammar)
[
  "abstract"
  "case"
  "catch"
  "class"
  "def"
  "do"
  "else"
  "extends"
  "false"
  "final"
  "finally"
  "for"
  "if"
  "implicit"
  "import"
  "lazy"
  "match"
  "new"
  "null"
  "object"
  "override"
  "package"
  "private"
  "protected"
  "return"
  "sealed"
  "super"
  "this"
  "throw"
  "trait"
  "true"
  "try"
  "type"
  "val"
  "var"
  "while"
  "with"
  "yield"
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
