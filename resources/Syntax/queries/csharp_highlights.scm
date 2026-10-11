; C# highlights (C grammar — basic C-like highlighting)
(identifier) @variable

((identifier) @constant
 (#match? @constant "^[A-Z][A-Z\\d_]*$"))

; C# keywords (matched as identifiers by C grammar)
[
  "abstract"
  "as"
  "base"
  "bool"
  "break"
  "byte"
  "case"
  "catch"
  "char"
  "checked"
  "class"
  "const"
  "continue"
  "decimal"
  "default"
  "delegate"
  "do"
  "double"
  "else"
  "enum"
  "event"
  "explicit"
  "extern"
  "false"
  "finally"
  "fixed"
  "float"
  "for"
  "foreach"
  "goto"
  "if"
  "implicit"
  "in"
  "int"
  "interface"
  "internal"
  "is"
  "lock"
  "long"
  "namespace"
  "new"
  "null"
  "object"
  "operator"
  "out"
  "override"
  "params"
  "private"
  "protected"
  "public"
  "readonly"
  "ref"
  "return"
  "sbyte"
  "sealed"
  "short"
  "sizeof"
  "stackalloc"
  "static"
  "string"
  "struct"
  "switch"
  "this"
  "throw"
  "true"
  "try"
  "typeof"
  "uint"
  "ulong"
  "unchecked"
  "unsafe"
  "ushort"
  "using"
  "var"
  "virtual"
  "void"
  "volatile"
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
