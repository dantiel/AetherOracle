; Swift highlights -- AetherCodex ABI 14 grammar
; Tailored to our vendored tree-sitter-swift (76 named nodes, 109 anon tokens).
; Every node name and token string verified against node-types.json.

; -- Comments --
(comment) @comment

; -- Strings --
(string) @string
(static_string_literal) @string

; -- Numbers / Booleans --
(number) @number
(boolean_literal) @boolean
(boolean) @boolean
"true" @boolean
"false" @boolean

; -- Nil --
(nil) @constantBuiltin

; -- Keywords --
"let" @keyword
"var" @keyword
"func" @keywordType        ; gray-blue like struct/class
"return" @keywordReturn
"for" @keywordRepeat
"while" @keywordRepeat
"repeat" @keywordRepeat
"if" @keywordConditional
"else" @keywordConditional
"guard" @keywordConditional
"switch" @keywordConditional
"case" @keyword
"default" @keyword
"break" @keyword
"continue" @keyword
"defer" @keyword
"in" @keyword
"is" @keyword
"as" @keyword
"do" @keyword
"catch" @keyword
"throw" @keyword
"throws" @keyword
"rethrows" @keyword
"init" @constructor
"deinit" @keywordType
"subscript" @keyword
"import" @keywordImport
"class" @keywordType
"struct" @keywordType
"enum" @keywordType
"typealias" @keywordType
"protocol" @keyword
"extension" @keyword
"associatedtype" @keyword

; -- Modifiers --
"public" @keywordModifier
"private" @keywordModifier
"internal" @keywordModifier
"fileprivate" @keywordModifier
"open" @keywordModifier
"static" @keywordModifier
"final" @keywordModifier
"indirect" @keywordModifier
"infix" @keywordModifier
"prefix" @keywordModifier
"postfix" @keywordModifier
"fileprivate(set)" @keywordModifier
"internal(set)" @keywordModifier
"private(set)" @keywordModifier

; -- Type identifiers --
(type_identifier) @type
(standard_type) @typeBuiltin

; -- Function / init declarations --
(function_declaration "func" (identifier) @functionMethod)
(protocol_method_declaration "func" (identifier) @functionMethod)
(initializer_declaration "init" @constructor)

; -- Parameters --
(parameter_declaration (identifier) @variableParameter)

; -- Type declarations --
(class_declaration "class" (identifier) @type)
(struct_declaration "struct" (identifier) @type)
(enum_declaration "enum" (identifier) @type)
(protocol_declaration "protocol" (identifier) @type)
(extension_declaration "extension" (type_identifier) @type)
(typealias_declaration "typealias" (identifier) @type)

; -- Import type references --
(import_declaration (identifier) @type)

; -- Variable / constant declarations (override catch-all -- black) --
(variable_declaration (identifier) @variable)
(constant_declaration (identifier) @variable)

; -- Operators (grammar-confirmed tokens only) --
["*" "=" "<" ">" "!" "?" "->" ">=" "&&" "||"] @operator

; -- Punctuation --
["." "," ";" ":"] @punctuationDelimiter
["(" ")" "[" "]" "{" "}"] @punctuationBracket

; -- Directives --
["#if" "#else" "#elseif" "#endif" "#available" "#error" "#warning" "#line"] @keywordDirective

; -- Types in collections --
(array_type (type_identifier) @type)
(dictionary_type (type_identifier) @type)

; -- Labels --
(labeled_statement (identifier) @label)

; -- Wildcard / special --
(wildcard_pattern) @characterSpecial
"_" @characterSpecial

; -- Catch-all identifier (LAST — only matches if no specific pattern above captured it) --
; Unmatched identifiers default to .variable → black foreground.
; Specific patterns above (variable_declaration, class_declaration, parameter_declaration, etc.)
; take precedence via SyntaxEngine dedup.
(identifier) @variable