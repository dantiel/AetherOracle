; Haskell highlights (C grammar — basic C-like highlighting)
(identifier) @variable

((identifier) @constant
 (#match? @constant "^[A-Z][A-Z\\d_]*$"))

; Haskell keywords (matched as identifiers by C grammar)
[
  "as"
  "case"
  "class"
  "data"
  "default"
  "deriving"
  "do"
  "else"
  "if"
  "import"
  "in"
  "infix"
  "infixl"
  "infixr"
  "instance"
  "let"
  "module"
  "newtype"
  "of"
  "qualified"
  "then"
  "type"
  "where"
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
