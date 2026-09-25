; Kotlin highlights (C grammar — basic C-like highlighting)
(identifier) @variable

((identifier) @constant
 (#match? @constant "^[A-Z][A-Z\\d_]*$"))

; Kotlin keywords (matched as identifiers by C grammar)
[
  "abstract"
  "annotation"
  "as"
  "break"
  "by"
  "catch"
  "class"
  "companion"
  "const"
  "constructor"
  "continue"
  "data"
  "do"
  "else"
  "enum"
  "false"
  "final"
  "finally"
  "for"
  "fun"
  "if"
  "import"
  "in"
  "init"
  "inner"
  "interface"
  "internal"
  "is"
  "lateinit"
  "null"
  "object"
  "open"
  "operator"
  "out"
  "override"
  "package"
  "private"
  "protected"
  "public"
  "return"
  "sealed"
  "super"
  "suspend"
  "this"
  "throw"
  "true"
  "try"
  "typealias"
  "val"
  "var"
  "when"
  "while"
] @keyword

(string_literal) @string
(null) @constant
(number_literal) @number
(char_literal) @number

(type_identifier) @type
(primitive_type) @type

(call_expression
  function: (identifier) @function)
(function_declarator
  declarator: (identifier) @function)

(comment) @comment
