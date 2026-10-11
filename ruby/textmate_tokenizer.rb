# frozen_string_literal: true

# TextMate grammar tokenizer — the breadth engine for "almost all languages".
#
# AetherCodex already carries a TextMate-grammar interpreter in its vendored
# bundle: the `textpow` gem. On Ruby >= 1.9 textpow does NOT need the native
# `oniguruma` extension — it drives Ruby's own Onigmo engine (a drop-in
# Oniguruma fork), so it parses real .tmLanguage files (begin/end, captures,
# contentName, repository) at full fidelity.
#
# This module adapts textpow's open/close-tag stream into a flat token list:
#   [{ "start" => int, "end" => int, "scope" => "keyword.control" }, ...]
#
# Offsets are ABSOLUTE Unicode-codepoint positions (not bytes, not UTF-16).
# The Swift side converts them to UTF-16 (NSRange) offsets because NSString
# indexes by UTF-16 code units.

require 'textpow'
require 'yaml'

# Oniguruma vs Onigmo dialect shim.
#
# textpow drives Ruby's native regex engine (Onigmo — a fork of Oniguruma).
# The two share almost all syntax, but official TextMate grammars lean on a few
# Oniguruma-only escapes that Onigmo rejects. The common offender is `\x{HHHH}`
# (hex codepoint in braces), which Onigmo spells `\xHH` (2 digits) or
# `\u{HHHH}` (multi-digit). Translate at parse time so grammars load unmodified.
module TextmateRegexCompat
  module_function

  def translate(pattern)
    pattern.gsub(/\\x\{([0-9A-Fa-f]{1,8})\}/) do
      hex = Regexp.last_match(1)
      hex.length <= 2 ? "\\x#{hex.rjust(2, '0')}" : "\\u{#{hex}}"
    end
  end
end

# textpow calls MatchData#to_index to resolve the index of a *named* capture
# group (see SyntaxNode#match_captures). That method existed on the old
# `oniguruma` C-extension but was never part of Ruby's own MatchData, so under
# Onigmo it raises NoMethodError and kills tokenization for any grammar with a
# named capture (`(?<inc>…)` in C, Swift, C#, Go, Haskell, …). Re-add it as a
# pure-Ruby shim: return the 1-based group number of the named capture.
class MatchData
  def to_index(name)
    idx = names.index(name.to_s)
    idx.nil? ? nil : idx + 1
  end
end

module Textpow
  class SyntaxNode
    alias_method :__textmate_parse_regex, :parse_regex
    alias_method :__textmate_parse_and_store, :parse_and_store_syntax_info

    def parse_regex(value)
      __textmate_parse_regex(TextmateRegexCompat.translate(value))
    rescue Textpow::ParsingError, RegexpError, ArgumentError => e
      # Onigmo rejects a handful of TextMate/VSCode constructs that upstream
      # grammars use: variable-length lookbehind (`(?<!\\.\s*)`), numbered
      # backreferences beside named groups, and a few possessive subexpression
      # calls. Rather than dropping the whole grammar (which falls back to the
      # heuristic engine and loses *all* colour, including comments), neutralise
      # just the offending pattern so the rest of the grammar still loads.
      warn "[TextmateTokenizer] neutralizing incompatible regex: #{e.message[0, 90]}" if $DEBUG
      /(?!)/ # matches nothing
    end

    def parse_and_store_syntax_info(table)
      __textmate_parse_and_store(table)
      # VSCode grammars express "match to end of line" as a `begin` with no
      # `end` (e.g. C# `//`). textpow opens such a span and never closes it, so
      # the scope is dropped AND the open span swallows every following line.
      # Reclassify a begin-only leaf (no end, no nested patterns, no contentName)
      # as a plain `match` rule so it emits a single closed token.
      if @begin && (@end.nil? || @end.to_s.empty?) && !@contentName &&
         (@patterns.nil? || @patterns.empty?)
        @match = @begin
        @begin = nil
        @captures ||= @beginCaptures
        @beginCaptures = nil
        @endCaptures = nil
      end
    end

    # textpow compiles `end` patterns fresh via `Regexp.new(regstring)` and then
    # `match(string, position)`. Under Onigmo `\G` anchors to `position` (the
    # start of the current match attempt); under TextMate's Oniguruma it anchors
    # to the end of the `begin` match. Many grammars lean on that for line-
    # comment wrappers: `begin: (?=//)`, `end: (?!\G)` with an inner `//…\n`
    # rule. With Onigmo's semantics `(?!\G)` never fires at the right offset, the
    # wrapper stays stuck on the parse stack and swallows the *next* line's block
    # comment. Translate `\G` to an exact-position assertion so wrappers close.
    alias_method :__textmate_match_end, :match_end

    def match_end(string, match, position)
      regstring = self.end.clone
      regstring.gsub!( /\\([1-9])/ ) { |s| match[$1.to_i] }
      regstring.gsub!( /\\k<(.*?)>/ ) { |s| match[$1.to_sym] }
      if regstring.include?('\\G')
        prev_end = (match.respond_to?(:offset) && match.offset(0)) ? match.offset(0).last : 0
        # `(?<=\A.{N})(?<!\A.{N+1})` matches exactly at offset N.
        regstring = regstring.gsub('\\G', "(?<=\\A.{#{prev_end}})(?<!\\A.{#{prev_end + 1}})")
      end
      Regexp.new( regstring ).match( string, position )
    end
  end
end

module TextmateTokenizer
  # Flattens textpow's nested tag stream into non-overlapping, properly-ordered
  # scope tokens with absolute codepoint offsets. textpow drives a LIFO stack:
  # outer scopes open first and close last, so emitting on close yields the
  # innermost scopes first and outermost last — exactly the precedence the
  # renderer wants (later token = higher priority).
  class FlatProcessor
    attr_reader :tokens

    def initialize
      @tokens = []
      @stack  = []
      @line_start = 0
      @next_start = 0
    end

    def start_parsing(_scope)
      @tokens = []
      @stack  = []
      @line_start = 0
      @next_start = 0
    end

    def new_line(line)
      @line_start = @next_start
      @next_start = @line_start + line.length
    end

    def open_tag(name, pos)
      return if name.nil? || name.empty?

      @stack << [name, @line_start + pos]
    end

    def close_tag(name, pos)
      return if name.nil? || name.empty?
      return if @stack.empty?

      abs_end = @line_start + pos
      open_name, abs_start = @stack.pop
      @tokens << [abs_start, abs_end, open_name] if abs_end > abs_start
    end

    def end_parsing(_scope); end
  end

  module_function

  def grammar_cache
    @grammar_cache ||= {}
  end

  def load_grammar(path)
    grammar_cache[path] ||= begin
      raw = File.binread(path)
      table = if raw.lstrip.start_with?('<?xml', '<plist', '<!DOCTYPE')
                require 'plist'
                Plist.parse_xml(raw)
              else
                YAML.load(raw) # JSON is a valid YAML subset
              end
      Textpow::SyntaxNode.new(table)
    end
  end

  # Tokenize `text` with the grammar at `path`.
  #
  # Returns one of:
  #   { "tokens" => [{ "start" =>, "end" =>, "scope" => }, ...] }
  #   { "error"  => "..." }
  def tokenize(path, text)
    node = load_grammar(path)
    processor = FlatProcessor.new
    node.parse(text, processor)
    {
      'tokens' => processor.tokens.map do |s, e, scope|
        { 'start' => s, 'end' => e, 'scope' => scope }
      end
    }
  rescue Exception => e # rubocop:disable Lint/RescueException — the daemon must never die on a grammar quirk
    { 'error' => "#{e.class}: #{e.message}" }
  end
end