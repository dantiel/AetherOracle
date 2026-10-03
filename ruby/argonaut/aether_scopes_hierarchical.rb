# frozen_string_literal: true

# AETHER SCOPES HIERARCHICAL - Enhanced Symbolic Analysis Engine
# Language-agnostic hierarchical parsing with import/export tracking

# Language-agnostic hierarchical symbolic analysis

require_relative '../mnemosyne/mnemosyne'
# require_relative '../argonaut/argonaut'



module AetherScopesHierarchical
  # Language-specific patterns for hierarchical analysis
  LANGUAGE_PATTERNS = {
    # Ruby patterns
    ruby:         {
      hierarchy: [
        { type: :module, pattern: /^\s*module\s+(\w+)/, level: :container },
        { type: :class, pattern: /^\s*class\s+(\w+)/, level: :container },
        { type: :singleton_method, pattern: /^\s*def\s+self\.(\w+)/, level: :member },
        { type: :class_method, pattern: /^\s*def\s+([A-Z]\w*\.\w+)/, level: :member },
        { type: :method, pattern: /^\s*def\s+(\w+)/, level: :member },
        { type: :constant, pattern: /^\s*([A-Z][A-Z0-9_]*)\s*=/, level: :member },
        { type:         :instance_variable,
          pattern:      /^\s*@(\w+)\s*=/,
          level:        :variable,
          parent_scope: true },
        { type: :class_variable, pattern: /^\s*@@(\w+)\s*=/, level: :variable, parent_scope: true },
        { type:         :global_variable,
          pattern:      /^\s*\$(\w+)\s*=/,
          level:        :variable,
          parent_scope: true },
        { type:         :local_variable,
          pattern:      /^\s*(\w+)\s*=[^=>]*$/,
          level:        :variable,
          parent_scope: true }
      ],
      imports:   [
        { type: :require, pattern: /^\s*require\s+['"]([^'"]+)['"]/ },
        { type: :require_relative, pattern: /^\s*require_relative\s+['"]([^'"]+)['"]/ },
        { type: :load, pattern: /^\s*load\s+['"]([^'"]+)['"]/ }
      ],
      exports:   [
        { type: :module_function, pattern: /^\s*module_function/ },
        { type: :public, pattern: /^\s*public/ },
        { type: :private, pattern: /^\s*private/ },
        { type: :protected, pattern: /^\s*protected/ }
      ]
    },

    # JavaScript patterns
    javascript:   {
      hierarchy: [
        { type: :class, pattern: /^\s*(?:export\s+)?class\s+(\w+)/, level: :container },
        { type: :function, pattern: /^\s*(?:export\s+)?(?:async\s+)?function\s+(\w+)/, level: :member },
        { type:    :arrow_function,
          pattern: /^\s*(?:export\s+)?const\s+(\w+)\s*=\s*(?:async\s*)?\([^)]*\)\s*=>/,
          level:   :member },
        { type: :const, pattern: /^\s*(?:export\s+)?const\s+(\w+)\s*=/, level: :member },
        { type: :let, pattern: /^\s*(?:export\s+)?let\s+(\w+)\s*=/, level: :member },
        { type: :var, pattern: /^\s*(?:export\s+)?var\s+(\w+)\s*=/, level: :member }
      ],
      imports:   [
        { type: :import, pattern: /^\s*import\s+(?:[^'"\n]+from\s+)?['"]([^'"]+)['"]/ },
        { type: :require, pattern: /^\s*const\s+\w+\s*=\s*require\(['"]([^'"]+)['"]\)/ }
      ],
      exports:   [
        { type: :export, pattern: /^\s*export\s+(?:default\s+)?(?:class|function|const|let|var)/ },
        { type: :module_exports, pattern: /^\s*module\.exports\s*=/ }
      ]
    },

    # Python patterns
    python:       {
      hierarchy: [
        { type: :class, pattern: /^\s*class\s+(\w+)/, level: :container },
        { type: :function, pattern: /^\s*def\s+(\w+)/, level: :member },
        { type: :async_function, pattern: /^\s*async\s+def\s+(\w+)/, level: :member }
      ],
      imports:   [
        { type: :import, pattern: /^\s*import\s+(\w+)/ },
        { type: :from_import, pattern: /^\s*from\s+(\w+)\s+import/ }
      ],
      exports:   [
        { type: :__all__, pattern: /^\s*__all__\s*=/ }
      ]
    },

    # HTML patterns
    html:         {
      hierarchy: [
        { type: :element, pattern: /<([\w:-]+)/, level: :container },
        { type: :id, pattern: /id=['"]([^'"]+)['"]/, level: :attribute },
        { type: :class, pattern: /class=['"]([^'"]+)['"]/, level: :attribute }
      ],
      imports:   [
        { type: :link, pattern: /<link[^>]*href=['"]([^'"]+)['"]/ },
        { type: :script, pattern: /<script[^>]*src=['"]([^'"]+)['"]/ }
      ],
      exports:   []
    },

    # CSS patterns
    css:          {
      hierarchy: [
        { type: :selector, pattern: /^([^{]+)\{/, level: :container },
        { type: :at_rule, pattern: /^@(\w+)/, level: :directive }
      ],
      imports:   [
        { type: :import, pattern: /@import\s+(?:url\()?['"]([^'"]+)['"]/ }
      ],
      exports:   []
    },

    # CoffeeScript patterns
    coffeescript: {
      hierarchy: [
        { type: :class, pattern: /^\s*class\s+(\w+)/, level: :container },
        { type: :function, pattern: /^\s*(\w+)\s*[:=]\s*\([^)]*\)\s*->/, level: :member },
        { type: :function, pattern: /^\s*(\w+)\s*=\s*\([^)]*\)\s*->/, level: :member },
        { type: :variable, pattern: /^\s*(\w+)\s*=\s*[^->]/, level: :member },
        { type: :constant, pattern: /^\s*([A-Z][A-Z0-9_]*)\s*=/, level: :member }
      ],
      imports:   [
        { type: :require, pattern: /^\s*require\s+['"]([^'"]+)['"]/ },
        { type: :require_relative, pattern: /^\s*require_relative\s+['"]([^'"]+)['"]/ },
        { type: :import, pattern: /^\s*import\s+['"]([^'"]+)['"]/ }
      ],
      exports:   [
        { type: :module_export, pattern: /^\s*module\.exports\s*=/ },
        { type: :export, pattern: /^\s*export\s+default/ }
      ]
    },

    # C patterns (.c/.h)
    c:            {
      hierarchy: [
        { type: :function, pattern: /^\s*[A-Za-z_]\w*\s+(\w+)\s*\([^;]*\)\s*\{/, level: :member },
        { type: :struct, pattern: /^\s*struct\s+(\w+)/, level: :container },
        { type: :enum, pattern: /^\s*enum\s+(\w+)/, level: :container },
        { type: :typedef, pattern: /^\s*typedef\s+/, level: :directive },
        { type: :macro, pattern: /^\s*#define\s+(\w+)/, level: :directive }
      ],
      imports:   [
        { type: :include, pattern: /^\s*#include\s+[<"]([^>"]+)[>"]/ }
      ],
      exports:   []
    },

    # Objective-C patterns (.m/.mm)
    objective_c:  {
      hierarchy: [
        { type: :interface, pattern: /^\s*@interface\s+(\w+)/, level: :container },
        { type: :implementation, pattern: /^\s*@implementation\s+(\w+)/, level: :container },
        { type: :protocol, pattern: /^\s*@protocol\s+(\w+)/, level: :container },
        { type: :method, pattern: /^\s*[-+]\s*\([^)]*\)\s*(\w+)/, level: :member }
      ],
      imports:   [
        { type: :import, pattern: /^\s*#import\s+[<"]([^>"]+)[>"]/ },
        { type: :include, pattern: /^\s*#include\s+[<"]([^>"]+)[>"]/ }
      ],
      exports:   []
    },

    # Swift patterns (.swift)
    swift:        {
      hierarchy: [
        { type: :class, pattern: /^\s*class\s+(\w+)/, level: :container },
        { type: :struct, pattern: /^\s*struct\s+(\w+)/, level: :container },
        { type: :enum, pattern: /^\s*enum\s+(\w+)/, level: :container },
        { type: :protocol, pattern: /^\s*protocol\s+(\w+)/, level: :container },
        { type: :extension, pattern: /^\s*extension\s+(\w+)/, level: :container },
        { type: :func, pattern: /^\s*func\s+(\w+)/, level: :member },
        { type: :let, pattern: /^\s*let\s+(\w+)\s*=/, level: :member },
        { type: :var, pattern: /^\s*var\s+(\w+)\s*=/, level: :member }
      ],
      imports:   [
        { type: :import, pattern: /^\s*import\s+(\w+)/ }
      ],
      exports:   [
        { type: :public, pattern: /^\s*public/ },
        { type: :open, pattern: /^\s*open/ }
      ]
    },

    # JSON patterns (.json)
    json:         {
      hierarchy: [
        { type: :key, pattern: /^\s*"(\w+)"\s*:/, level: :member }
      ],
      imports:   [],
      exports:   []
    },

    # YAML patterns (.yml/.yaml)
    yaml:         {
      hierarchy: [
        { type: :key, pattern: /^\s*([A-Za-z_][\w-]*)\s*:/, level: :member },
        { type: :anchor, pattern: /&(\w+)/, level: :attribute }
      ],
      imports:   [],
      exports:   []
    },

    # Markdown patterns (.md/.markdown)
    markdown:     {
      hierarchy: [
        { type: :heading, pattern: /^(\#{1,6})\s+(.+)/, level: :container }
      ],
      imports:   [],
      exports:   []
    },

    # Shell patterns (.sh/.bash/.zsh/.fish)
    shell:        {
      hierarchy: [
        { type: :function, pattern: /^\s*(\w+)\s*\(\)\s*\{/, level: :member },
        { type: :variable, pattern: /^\s*(\w+)=/, level: :variable }
      ],
      imports:   [
        { type: :source, pattern: /^\s*(?:source|\.)\s+([^\s]+)/ }
      ],
      exports:   []
    },

    # TypeScript patterns (.ts/.tsx/.mts/.cts)
    typescript:   {
      hierarchy: [
        { type: :interface, pattern: /^\s*(?:export\s+)?interface\s+(\w+)/, level: :container },
        { type: :class, pattern: /^\s*(?:export\s+)?(?:abstract\s+)?class\s+(\w+)/, level: :container },
        { type: :enum, pattern: /^\s*(?:export\s+)?enum\s+(\w+)/, level: :container },
        { type: :type_alias, pattern: /^\s*(?:export\s+)?type\s+(\w+)\s*=/, level: :member },
        { type: :function, pattern: /^\s*(?:export\s+)?(?:async\s+)?function\s+(\w+)/, level: :member },
        { type: :arrow_function, pattern: /^\s*(?:export\s+)?const\s+(\w+)\s*=\s*(?:async\s*)?\([^)]*\)\s*=>/, level: :member },
        { type: :const, pattern: /^\s*(?:export\s+)?const\s+(\w+)\s*[:=]/, level: :member },
        { type: :let, pattern: /^\s*(?:export\s+)?let\s+(\w+)\s*[:=]/, level: :member }
      ],
      imports:   [
        { type: :import, pattern: /^\s*import\s+(?:[^'"\n]+from\s+)?['"]([^'"]+)['"]/ }
      ],
      exports:   [
        { type: :export, pattern: /^\s*export\s+(?:default\s+)?(?:class|function|const|let|var|interface|type|enum)/ }
      ]
    },

    # Go patterns (.go)
    go:           {
      hierarchy: [
        { type: :func, pattern: /^\s*func\s+(?:\([^)]*\)\s+)?(\w+)/, level: :member },
        { type: :struct, pattern: /^\s*type\s+(\w+)\s+struct/, level: :container },
        { type: :interface, pattern: /^\s*type\s+(\w+)\s+interface/, level: :container },
        { type: :type, pattern: /^\s*type\s+(\w+)\s+/, level: :member },
        { type: :const, pattern: /^\s*const\s+(?:\(?\s*)?(\w+)/, level: :member },
        { type: :var, pattern: /^\s*var\s+(\w+)/, level: :member }
      ],
      imports:   [
        { type: :import, pattern: /^\s*import\s+(?:\w+\s+)?['"]([^'"]+)['"]/ }
      ],
      exports:   []
    },

    # Rust patterns (.rs)
    rust:         {
      hierarchy: [
        { type: :struct, pattern: /^\s*(?:pub\s+)?struct\s+(\w+)/, level: :container },
        { type: :enum, pattern: /^\s*(?:pub\s+)?enum\s+(\w+)/, level: :container },
        { type: :trait, pattern: /^\s*(?:pub\s+)?trait\s+(\w+)/, level: :container },
        { type: :impl, pattern: /^\s*impl(?:<[^>]*>)?\s+(\w+)/, level: :container },
        { type: :fn, pattern: /^\s*(?:pub\s+)?(?:async\s+)?fn\s+(\w+)/, level: :member },
        { type: :const, pattern: /^\s*(?:pub\s+)?const\s+(\w+)/, level: :member },
        { type: :static, pattern: /^\s*(?:pub\s+)?static\s+(\w+)/, level: :member },
        { type: :let, pattern: /^\s*let\s+(\w+)/, level: :member }
      ],
      imports:   [
        { type: :use, pattern: /^\s*use\s+([^;]+)/ },
        { type: :mod, pattern: /^\s*mod\s+(\w+)/ }
      ],
      exports:   [
        { type: :pub, pattern: /^\s*pub\s+/ }
      ]
    },

    # Java patterns (.java)
    java:         {
      hierarchy: [
        { type: :class, pattern: /^\s*(?:(?:public|private|protected|abstract|final|static|sealed)\s+)*(?:class|interface|enum|record)\s+(\w+)/, level: :container },
        { type: :method, pattern: /^\s*(?:[\w<>\[\]]+\s+)+(\w+)\s*\(/, level: :member },
        { type: :annotation, pattern: /^\s*@(\w+)/, level: :directive }
      ],
      imports:   [
        { type: :import, pattern: /^\s*import\s+(?:static\s+)?([\w.]+)/ }
      ],
      exports:   [
        { type: :package, pattern: /^\s*package\s+/ }
      ]
    },

    # Kotlin patterns (.kt/.kts)
    kotlin:       {
      hierarchy: [
        { type: :class, pattern: /^\s*(?:(?:data|sealed|abstract|open|annotation|private|internal|public|inner|enum)\s+)*(?:class|interface|object)\s+(\w+)/, level: :container },
        { type: :fun, pattern: /^\s*(?:(?:override|open|suspend|inline|private|public|internal|protected|abstract|final|tailrec|operator|infix)\s+)*fun\s+(\w+)/, level: :member },
        { type: :val, pattern: /^\s*(?:val|var)\s+(\w+)/, level: :member }
      ],
      imports:   [
        { type: :import, pattern: /^\s*import\s+([\w.]+)/ }
      ],
      exports:   []
    },

    # C++ patterns (.cpp/.cc/.cxx/.hpp/.hh/.hxx)
    cpp:          {
      hierarchy: [
        { type: :namespace, pattern: /^\s*namespace\s+(\w+)/, level: :container },
        { type: :class, pattern: /^\s*(?:template\s*<[^>]*>\s*)?(?:class|struct)\s+(\w+)/, level: :container },
        { type: :function, pattern: /^\s*(?:[\w:<>]+\s+)+(\w+)\s*\(/, level: :member },
        { type: :typedef, pattern: /^\s*typedef\s+/, level: :directive },
        { type: :using, pattern: /^\s*using\s+namespace\s+(\w+)/, level: :directive },
        { type: :macro, pattern: /^\s*#define\s+(\w+)/, level: :directive }
      ],
      imports:   [
        { type: :include, pattern: /^\s*#include\s+[<"]([^>"]+)[>"]/ }
      ],
      exports:   []
    },

    # C# patterns (.cs)
    csharp:       {
      hierarchy: [
        { type: :namespace, pattern: /^\s*namespace\s+([\w.]+)/, level: :container },
        { type: :class, pattern: /^\s*(?:(?:public|private|protected|internal|abstract|sealed|static|partial)\s+)*(?:class|interface|struct|enum|record)\s+(\w+)/, level: :container },
        { type: :method, pattern: /^\s*(?:[\w<>\[\]]+\s+)+(\w+)\s*\(/, level: :member },
      ],
      imports:   [
        { type: :using, pattern: /^\s*using\s+([\w.]+);/ }
      ],
      exports:   []
    },

    # PHP patterns (.php)
    php:          {
      hierarchy: [
        { type: :class, pattern: /^\s*(?:abstract\s+|final\s+)?class\s+(\w+)/, level: :container },
        { type: :interface, pattern: /^\s*interface\s+(\w+)/, level: :container },
        { type: :trait, pattern: /^\s*trait\s+(\w+)/, level: :container },
        { type: :function, pattern: /^\s*(?:(?:public|private|protected|static)\s+)*function\s+(\w+)/, level: :member },
        { type: :const, pattern: /^\s*const\s+(\w+)/, level: :member }
      ],
      imports:   [
        { type: :namespace, pattern: /^\s*namespace\s+([\w\\]+)/ },
        { type: :use, pattern: /^\s*use\s+([\w\\]+)/ },
        { type: :require, pattern: /^\s*(?:require|include)(?:_once)?\s+['"]([^'"]+)['"]/ }
      ],
      exports:   []
    },

    # SQL patterns (.sql)
    sql:          {
      hierarchy: [
        { type: :table, pattern: /^\s*CREATE\s+(?:OR\s+REPLACE\s+)?TABLE\s+(?:IF\s+NOT\s+EXISTS\s+)?([\w."]+)/i, level: :container },
        { type: :view, pattern: /^\s*CREATE\s+(?:OR\s+REPLACE\s+)?VIEW\s+([\w."]+)/i, level: :container },
        { type: :function, pattern: /^\s*CREATE\s+(?:OR\s+REPLACE\s+)?FUNCTION\s+([\w."]+)/i, level: :member },
        { type: :index, pattern: /^\s*CREATE\s+(?:UNIQUE\s+)?INDEX\s+([\w."]+)/i, level: :member }
      ],
      imports:   [],
      exports:   []
    },

    # TOML patterns (.toml)
    toml:         {
      hierarchy: [
        { type: :array_table, pattern: /^\s*\[\[([^\]]+)\]\]/, level: :container },
        { type: :table, pattern: /^\s*\[([^\]]+)\]/, level: :container },
        { type: :key, pattern: /^\s*([A-Za-z_][\w-]*)\s*=/, level: :member }
      ],
      imports:   [],
      exports:   []
    },

    # XML patterns (.xml/.svg/.xhtml)
    xml:          {
      hierarchy: [
        { type: :element, pattern: /<([\w:-]+)/, level: :container }
      ],
      imports:   [],
      exports:   []
    },

    # Elixir patterns (.ex/.exs)
    elixir:       {
      hierarchy: [
        { type: :module, pattern: /^\s*defmodule\s+([\w.]+)/, level: :container },
        { type: :defmacro, pattern: /^\s*defmacro\s+(\w+)/, level: :member },
        { type: :def, pattern: /^\s*def\s+(\w+)/, level: :member },
        { type: :defp, pattern: /^\s*defp\s+(\w+)/, level: :member }
      ],
      imports:   [
        { type: :import, pattern: /^\s*import\s+([\w.]+)/ },
        { type: :alias, pattern: /^\s*alias\s+([\w.]+)/ },
        { type: :require, pattern: /^\s*require\s+([\w.]+)/ }
      ],
      exports:   []
    },

    # Lua patterns (.lua)
    lua:          {
      hierarchy: [
        { type: :function, pattern: /^\s*function\s+([\w.:]+)/, level: :member },
        { type: :local_function, pattern: /^\s*local\s+function\s+(\w+)/, level: :member },
        { type: :local, pattern: /^\s*local\s+(\w+)\s*=/, level: :variable }
      ],
      imports:   [
        { type: :require, pattern: /^\s*[\w]+\s*=\s*require\s*\(?['"]([^'"]+)['"]/ }
      ],
      exports:   []
    },

    # Makefile patterns (Makefile/makefile/GNUmakefile/.mk)
    makefile:     {
      hierarchy: [
        { type: :target, pattern: /^\.?([A-Za-z_][\w.%-]*)\s*:/, level: :container },
        { type: :variable, pattern: /^([A-Za-z_][\w]*)\s*[:?+]?=/, level: :member }
      ],
      imports:   [
        { type: :include, pattern: /^-?include\s+([^\s]+)/ }
      ],
      exports:   []
    },

    # Dockerfile patterns (Dockerfile/Containerfile/.dockerfile)
    dockerfile:   {
      hierarchy: [
        { type: :stage, pattern: /^\s*FROM\s+([^\s]+)/i, level: :container },
        { type: :instruction, pattern: /^\s*(RUN|COPY|ADD|ENV|ARG|LABEL|EXPOSE|WORKDIR|CMD|ENTRYPOINT|VOLUME|USER|HEALTHCHECK)\s/i, level: :member }
      ],
      imports:   [
        { type: :from, pattern: /^\s*FROM\s+([^\s]+)/i }
      ],
      exports:   []
    },

    # Plain text (.txt/.text) — no structure to extract
    text:         {
      hierarchy: [],
      imports:   [],
      exports:   []
    }
  }.freeze

  # Extension → language map for the corpus scanner's primary detection path.
  # Unambiguous extensions resolve here; content signatures only disambiguate
  # the few ambiguous ones (`.h`) and extensionless files.
  EXTENSION_LANGUAGE = {
    '.coffee' => :coffeescript, '.litcoffee' => :coffeescript,
    '.js' => :javascript, '.mjs' => :javascript, '.cjs' => :javascript,
    '.jsx' => :javascript,
    '.rb' => :ruby, '.rake' => :ruby, '.gemspec' => :ruby, '.ru' => :ruby,
    '.py' => :python, '.pyw' => :python,
    '.html' => :html, '.htm' => :html,
    '.css' => :css, '.scss' => :css, '.sass' => :css, '.less' => :css,
    '.c' => :c,
    '.h' => :c, # disambiguated to :cpp by content when C++ markers present
    '.cpp' => :cpp, '.cc' => :cpp, '.cxx' => :cpp, '.c++' => :cpp,
    '.hpp' => :cpp, '.hh' => :cpp, '.hxx' => :cpp,
    '.swift' => :swift,
    '.m' => :objective_c, '.mm' => :objective_c,
    '.json' => :json,
    '.yml' => :yaml, '.yaml' => :yaml,
    '.md' => :markdown, '.markdown' => :markdown,
    '.sh' => :shell, '.bash' => :shell, '.zsh' => :shell, '.fish' => :shell,
    '.ts' => :typescript, '.tsx' => :typescript, '.mts' => :typescript, '.cts' => :typescript,
    '.go' => :go,
    '.rs' => :rust,
    '.java' => :java,
    '.kt' => :kotlin, '.kts' => :kotlin,
    '.cs' => :csharp,
    '.php' => :php,
    '.sql' => :sql,
    '.toml' => :toml,
    '.xml' => :xml, '.svg' => :xml, '.xhtml' => :xml,
    '.ex' => :elixir, '.exs' => :elixir,
    '.lua' => :lua,
    '.mk' => :makefile,
    '.txt' => :text, '.text' => :text,
    '.dockerfile' => :dockerfile
  }.freeze

  # Well-known extensionless build/config files, matched by basename (downcased).
  FILENAME_LANGUAGE = {
    'makefile' => :makefile, 'gnumakefile' => :makefile,
    'dockerfile' => :dockerfile, 'containerfile' => :dockerfile
  }.freeze

  # Symbol levels (container/member/variable/attribute/directive) are declared
  # per LANGUAGE_PATTERNS entry and drive summary counting. Nesting itself
  # follows source indentation — see HierarchicalParser#add_to_hierarchy.



  class HierarchicalParser
    def initialize(content, language = nil, file_path = nil)
      @content = content
      @file_path = file_path
      @language = language || detect_language(content)
      @lines = content.lines
      @hierarchy = []
      @imports = []
      @exports = []
      @current_scope = []
    end


    def parse
      @lines.each_with_index do |line, index|
        line_number = index + 1

        # Parse hierarchy elements
        parse_hierarchy line, line_number

        # Parse imports and exports
        parse_imports line, line_number
        parse_exports line, line_number
      end

      # Close any scope still open at end-of-file so spans never dangle.
      @current_scope.reverse_each { |scope| close_scope(scope, @lines.size) }

      {
        language:  @language,
        hierarchy: @hierarchy,
        imports:   @imports,
        exports:   @exports,
        structure: analyze_structure
      }
    end

    private


    def detect_language(content)
      # Extension-first detection: an unambiguous file extension is the
      # strongest signal available. Content signatures only disambiguate the
      # few ambiguous extensions (`.h`) and handle extensionless files.
      lines = content.lines
      sample = lines[0..19].join
      ext = @file_path ? File.extname(@file_path).downcase : nil
      base = @file_path ? File.basename(@file_path).downcase : nil

      # 1. Well-known extensionless build files, by basename.
      if base && (lang = FILENAME_LANGUAGE[base])
        return lang
      end

      # 2. Extensionless scripts: the shebang is the only reliable signal.
      if ext.nil? || ext.empty?
        return :shell if sample =~ /^#!.*\b(?:sh|bash|zsh|fish)\b/
        return :python if sample =~ /^#!.*\bpython/
        return :ruby if sample =~ /^#!.*\bruby/
        return detect_by_content(sample)
      end

      # 3. Ambiguous extension: `.h` may be a C or a C++ header.
      return detect_c_vs_cpp(sample) if ext == '.h'

      # 4. Unambiguous extension: resolve directly.
      lang = EXTENSION_LANGUAGE[ext]
      return lang if lang

      # 5. Unknown extension: fall back to content heuristics.
      detect_by_content(sample)
    end


    def detect_c_vs_cpp(sample)
      if sample =~ /^\s*(?:class|namespace|template)\s+|^\s*#include\s*[<"](?:string|vector|iostream|memory|map|set|algorithm|utility|fstream|sstream|cstdint|functional)>/
        :cpp
      else
        :c
      end
    end


    def detect_by_content(sample)
      # CoffeeScript's `->` arrows are unambiguous.
      if sample =~ /^\s*\w+\s*[:=]\s*\([^)]*\)\s*->/ ||
         (sample =~ /^\s*class\s+\w+/ && sample =~ /\bconstructor:\s*->/) ||
         sample =~ /^\s*\w+\s*=\s*\([^)]*\)\s*->/

        return :coffeescript
      end

      case sample
      when /^---\s*$/ then :yaml
      when /\A\s*[{\[]/ then :json
      when /^\s*<\?xml/ then :xml
      when /<html|<!DOCTYPE/i then :html
      when /^\s*#include\s*[<"]/ then :c
      when /^\s*#import\s*[<"]/ then :objective_c
      when /^\s*import\s+(?:Foundation|UIKit|SwiftUI|AppKit|Swift)\b|^\s*func\s+\w+/ then :swift
      when /^\s*package\s+\w+/ then :go
      when /^\s*use\s+\w+::|^\s*(?:pub\s+)?(?:async\s+)?fn\s+\w+|^\s*(?:pub\s+)?struct\s+\w+/ then :rust
      when /^\s*defmodule\s+|^\s*defmacro\s+/ then :elixir
      when /^\s*namespace\s+\w+\./ then :csharp
      when /^\s*<\?php/i then :php
      when /^\s*(?:CREATE|SELECT|INSERT|UPDATE|DELETE|ALTER|DROP|WITH)\s/i then :sql
      when /^\s*interface\s+\w+|^\s*type\s+\w+\s*=/ then :typescript
      when /^\s*function\s+\w+|^\s*const\s+\w+\s*=|^\s*let\s+\w+\s*=|^\s*import\s+[^'"\n]+from\s+['"]/ then :javascript
      when /^\s*def\s+\w+\s*\(.*\)\s*:|^\s*class\s+\w+\s*(?:\(.*\))?\s*:/ then :python
      when /^\s*def\s+\w+|^\s*class\s+\w+|^\s*module\s+\w+/ then :ruby
      when /@import|^[^{]*\{[^}]*\}/ then :css
      else :ruby
      end
    end


    def parse_hierarchy(line, line_number)
      patterns = LANGUAGE_PATTERNS[@language]&.[](:hierarchy) || []

      patterns.each do |pattern|
        # puts "    Testing pattern: #{pattern[:type]} - #{pattern[:pattern].source}"
        next unless (match = line.match pattern[:pattern])

        # puts "    Pattern #{pattern[:type]} matched! Captured: #{match[1]}"

        # Handle special cases for naming
        name = match[1]

        # puts "    Raw captured name: #{name.inspect}, pattern type: #{pattern[:type]}"

        # Fix class method names (extract just the method name from "ClassName.method_name")
        if :class_method == pattern[:type] && name.include?('.')
          name = name.split('.').last
          # puts "    After class method fix: #{name}"
        end

        # Fix singleton method names (extract just the method name from "self.method_name")
        if :singleton_method == pattern[:type] && name.start_with?('self.')
          name = name.sub('self.', '')
          # puts "    After singleton method fix: #{name}"
        end

        element = {
          type:         pattern[:type],
          name:         name,
          line:         line_number,
          indent:       line[/^\s*/].length,
          level:        pattern[:level],
          children:     [],
          parent_scope: pattern[:parent_scope] || false
        }

        # Add to hierarchy with proper nesting
        add_to_hierarchy element
        break
      end
    end


    def add_to_hierarchy(element)
      # Variables attach to the innermost open scope (method/class/module).
      if element[:parent_scope] && !@current_scope.empty?
        parent = @current_scope.last
        element[:parent_name] = parent[:name]
        element[:parent_type] = parent[:type]
        element[:qualified_name] = qualified_name_for(element, parent)
        parent[:children] << element
        return
      end

      # Pop scopes at the same-or-deeper indentation: those are siblings, not
      # ancestors. Indentation is the structural signal the flat regex scan
      # otherwise loses — it restores true nesting (class in module, method in
      # class) that the old level-weight heuristic flattened.
      while !@current_scope.empty? &&
            @current_scope.last[:indent] >= element[:indent]

        close_scope(@current_scope.pop, element[:line])
      end

      parent = @current_scope.last
      if parent
        element[:parent_name] = parent[:name]
        element[:parent_type] = parent[:type]
        element[:qualified_name] = qualified_name_for(element, parent)
        parent[:children] << element
      else
        element[:qualified_name] = element[:name].to_s
        @hierarchy << element
      end

      # Containers and members open a scope for their children.
      return unless %i[container member].include? element[:level]

      @current_scope << element
    end


    # A scope closes the line before its first successor at the same-or-higher
    # level. Regex parsing cannot see an `end` keyword, so this is a best-effort
    # span — precise enough to bound a symbol's body without a grammar.
    def close_scope(scope, at_line)
      scope[:end_line] ||= at_line - 1
    end


    # Ancestry chain: container nesting uses `::`, methods `#`, leaves `.`.
    # Mirrors the grammar-tree `ancestor_matching` insight from the retired
    # Textpow parser, but stays a plain string — no object back-references.
    def qualified_name_for(element, parent)
      sep = case element[:level]
            when :container then '::'
            when :member then '#'
            else '.'
            end
      prefix = parent[:qualified_name] || parent[:name].to_s
      "#{prefix}#{sep}#{element[:name]}"
    end


    def parse_imports(line, line_number)
      patterns = LANGUAGE_PATTERNS[@language]&.[](:imports) || []

      patterns.each do |pattern|
        next unless (match = line.match pattern[:pattern])

        @imports << {
          type:   pattern[:type],
          target: match[1],
          line:   line_number
        }
        break
      end
    end


    def parse_exports(line, line_number)
      patterns = LANGUAGE_PATTERNS[@language]&.[](:exports) || []

      patterns.each do |pattern|
        next unless (match = line.match pattern[:pattern])

        @exports << {
          type: pattern[:type],
          line: line_number
        }
        break
      end
    end


    def analyze_structure
      {
        total_lines:       @lines.size,
        significant_lines: @hierarchy.size + @imports.size + @exports.size,
        import_count:      @imports.size,
        export_count:      @exports.size,
        symbol_count:      count_symbols(@hierarchy)
      }
    end


    def count_symbols(hierarchy)
      count = hierarchy.size
      hierarchy.each { |item| count += count_symbols item[:children] }
      count
    end
  end


  # Main API for file overview integration - hierarchical and language-aware
  def self.structural_overview(project_root, file_path, content = nil, max_depth: nil)
    full_path = File.join project_root, file_path
    content ||= (File.read full_path if File.exist? full_path)
    return empty_analysis unless content

    parser = HierarchicalParser.new content, nil, full_path
    analysis = parser.parse

    # Apply depth reduction if specified
    analysis[:hierarchy] = reduce_hierarchy_depth(analysis[:hierarchy], max_depth) if max_depth

    # Debug: check what the parser returns
    # puts "DEBUG: analysis[:hierarchy] = #{analysis[:hierarchy].inspect}"
    # puts "DEBUG: analysis[:imports] = #{analysis[:imports].inspect}"
    # puts "DEBUG: analysis[:exports] = #{analysis[:exports].inspect}"

    line_hints = generate_line_hints analysis
    navigation_hints = generate_navigation_hints analysis

    # puts "DEBUG: line_hints = #{line_hints.inspect}"
    # puts "DEBUG: navigation_hints = #{navigation_hints.inspect}"

    {
      file:             file_path,
      language:         analysis[:language],
      hierarchy:        analysis[:hierarchy],
      imports:          analysis[:imports],
      exports:          analysis[:exports],
      structure:        analysis[:structure],
      summary:          generate_summary(analysis),
      line_hints:       line_hints,
      navigation_hints: navigation_hints
    }
  end


  def self.generate_summary(analysis)
    {
      language:      analysis[:language],
      containers:    count_by_type(analysis[:hierarchy], [:container]),
      members:       count_by_type(analysis[:hierarchy], %i[member attribute directive]),
      imports:       analysis[:imports].size,
      exports:       analysis[:exports].size,
      total_symbols: analysis[:structure][:symbol_count]
    }
  end


  def self.count_by_type(hierarchy, types)
    count = 0
    hierarchy.each do |item|
      count += 1 if types.include? item[:level]
      count += count_by_type item[:children], types
    end
    count
  end


  def self.generate_line_hints(analysis)
    hints = Hash.new { |h, k| h[k] = [] }

    # Add hierarchy elements
    extract_all_elements(analysis[:hierarchy]).each do |element|
      line_key = element[:line].to_s
      hints[line_key] << "#{element[:type]}: #{element[:name]}"
    end

    # Add imports and exports
    (analysis[:imports] + analysis[:exports]).each do |item|
      line_key = item[:line].to_s
      desc = item[:target] ? "#{item[:type]} -> #{item[:target]}" : item[:type]
      hints[line_key] << desc
    end

    # Convert to sorted hash with guaranteed arrays
    hints.sort.to_h
  end


  def self.generate_navigation_hints(analysis)
    # Hierarchy navigation
    hints = extract_all_elements(analysis[:hierarchy]).map do |element|
      {
        type:        :structure,
        target:      "#{element[:type]}:#{element[:name]}",
        line:        element[:line],
        level:       element[:level],
        description: "Navigate to #{element[:type]} #{element[:name]}"
      }
    end

    # Import navigation
    analysis[:imports].each do |import|
      hints << {
        type:        :dependency,
        target:      import[:target],
        line:        import[:line],
        description: "Import: #{import[:type]} -> #{import[:target]}"
      }
    end

    # Export navigation
    analysis[:exports].each do |export|
      hints << {
        type:        :export,
        target:      'export',
        line:        export[:line],
        description: "Export: #{export[:type]}"
      }
    end

    hints.sort_by { |h| h[:line] }
  end


  def self.extract_all_elements(hierarchy, depth = 0)
    elements = []
    hierarchy.each do |item|
      new_item = item.clone
      new_item[:depth] = depth
      elements << new_item
      elements.concat extract_all_elements(item[:children], depth + 1)
    end
    elements
  end


  def self.empty_analysis
    {
      language:  :unknown,
      hierarchy: [],
      imports:   [],
      exports:   [],
      structure: {
        total_lines:       0,
        significant_lines: 0,
        import_count:      0,
        export_count:      0,
        symbol_count:      0
      }
    }
  end


  # Enhanced integration with file_overview tool - hierarchical and language-aware
  def self.for_file_overview(project_root,
                             file_path,
                             max_notes: 3,
                             max_content_length: 150,
                             max_depth: nil)
    overview = structural_overview project_root, file_path, nil, max_depth: max_depth

    # Get all notes related to this file
    notes = Mnemosyne.recall_notes file_path, limit: 50

    # Generate tag cloud and file cloud from notes instead of full note content
    tag_cloud = generate_tag_cloud notes
    file_cloud = generate_file_cloud notes
    
    # Generate hermetic symbolic overview using LexiconResonantia
    symbolic_overview = LexiconResonantia.generate_from_notes(notes)

    # Format for AI consumption - enhanced with hierarchical data
    {
      language:               overview[:language],
      structural_summary:     overview[:summary],
      hierarchy:              overview[:hierarchy],
      imports:                overview[:imports],
      exports:                overview[:exports],
      navigation_hints:       overview[:navigation_hints],
      significant_lines:      (overview[:line_hints] || {}).keys.map(&:to_i).sort,
      tag_cloud:,
      file_cloud:,
      tag_cloud_text:         tag_cloud.map { |tag| "#{tag[0]}: #{tag[1]}" }.join("\n"),
      file_cloud_text:        file_cloud.map { |tag| "#{tag[0]}: #{tag[1]}" }.join("\n"),
      symbolic_overview_text: generate_symbolic_overview_text(overview),
      hermetic_overview:      symbolic_overview.join("\n")
    }
  end


  def self.extract_symbol_names(hierarchy)
    names = []
    hierarchy.each do |item|
      names << item[:name] if item[:name]
      names.concat extract_symbol_names(item[:children])
    end
    names
  end


  def self.generate_symbolic_overview_text(overview)
    # Add hierarchy elements in compact format
    lines = extract_all_elements(overview[:hierarchy]).map do |element|
      "#{'  ' * element[:depth]}#{element[:line]}: #{element[:type][..2]} #{element[:name]}"
    end

    # Add imports
    overview[:imports].each do |import|
      lines << "#{import[:line]}: import #{import[:type]} -> #{import[:target]}"
    end

    # Add exports
    overview[:exports].each do |export|
      lines << "#{export[:line]}: export #{export[:type]}"
    end

    lines.join "\n"
  end


  # Generate tag cloud from notes related to this file
  def self.generate_tag_cloud(notes)
    # Extract and count tags
    tag_counts = Hash.new 0
    notes.each do |note|
      next unless note[:tags]

      tags = note[:tags].is_a?(String) ? note[:tags].split(',') : note[:tags]
      tags.each { |tag| tag_counts[tag.strip] += 1 }
    end

    # Convert to array of [tag, count] sorted by frequency
    tag_counts.sort_by { |_tag, count| -count }
  end


  # Generate file cloud showing related files based on note links
  def self.generate_file_cloud(notes)
    # Extract file links from notes
    file_counts = Hash.new 0
    notes.each do |note|
      next unless note[:links]

      links = note[:links].is_a?(String) ? note[:links].split(',') : note[:links]
      links.each do |link|
        # Only count files, not other types of links
        # if link.include?('/') || link.include?('.') || link.include?('_') || link.include?('-') || link.include?(' ')
          file_counts[link.strip] += 1
        # end
      end
    end

    # Convert to array of [file, count] sorted by frequency
    file_counts.sort_by { |_file, count| -count }
  end


  # Reduce hierarchy depth by truncating nested children beyond max_depth
  def self.reduce_hierarchy_depth(hierarchy, max_depth, current_depth = 1)
    return [] if hierarchy.empty? || current_depth > max_depth

    hierarchy.map do |item|
      if current_depth == max_depth
        # At max depth, remove children but keep the item
        { **item, children: [] }
      else
        # Recursively reduce children depth
        {
          **item,
          children: reduce_hierarchy_depth(item[:children], max_depth, current_depth + 1)
        }
      end
    end
  end
end

# Test the enhanced hierarchical implementation
if __FILE__ == $PROGRAM_NAME
  test_file = __FILE__
  overview = AetherScopesHierarchical.structural_overview test_file

  puts '=== AetherScopesHierarchical Test ==='
  puts "File: #{overview[:file]}"
  puts "Language: #{overview[:language]}"
  puts "Summary: #{overview[:summary]}"

  puts "\nHierarchical Structure:"
  def print_hierarchy(hierarchy, indent = 0)
    hierarchy.each do |item|
      puts ('  ' * indent) + "#{item[:type]} #{item[:name]} @ line #{item[:line]} (#{item[:level]})"
      print_hierarchy item[:children], indent + 1
    end
  end
  print_hierarchy overview[:hierarchy]

  puts "\nImports:"
  overview[:imports].each { |imp| puts "  #{imp[:type]} -> #{imp[:target]} @ line #{imp[:line]}" }

  puts "\nExports:"
  overview[:exports].each { |exp| puts "  #{exp[:type]} @ line #{exp[:line]}" }

  puts "\nNavigation Hints:"
  overview[:navigation_hints].each do |hint|
    puts "  Line #{hint[:line]}: #{hint[:description]}"
  end
end