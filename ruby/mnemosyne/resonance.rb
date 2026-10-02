# frozen_string_literal: true

class Mnemosyne
  # Resonance -- die eine Scoring-Maschine der Kaskade, geteilt von Notes und
  # Fragments (polymorphic memory linkage: one engine, many substrates).
  # Token resonance: content 4x, tags 3x, links 2x, path match +5. Kaskaden-
  # Resonanz: local scope +6, ancestors distance-decayed (+4/d, min +1),
  # children whisper nothing upward -- the parent observes only. Vector cosine
  # (Stufe 3) and fragment freshness (Stufe 2) are additive voices on the
  # same score.
  module Resonance
    module_function

    def sql_filter(query_tokens, fields: %w[content tags links])
      return '' if query_tokens.empty?

      'WHERE ' + (fields.map do |field|
        query_tokens.map { |keyword| "#{field} LIKE '%#{keyword}%'" }.join(' OR ')
      end.join(' OR '))
    end

    def cascade_bonus(scope, context_path)
      return 0 unless scope && context_path

      note_scope = context_path.to_s
      return 6 if note_scope == scope
      return 0 unless scope.start_with?("#{note_scope}/")

      distance = scope.delete_prefix("#{note_scope}/").count('/') + 1
      [4 / distance, 1].max
    end

    def score(row, query_tokens, scope, cosine: 0.0, fresh: 0.0)
      score = 0
      if query_tokens.empty?
        score = 1
      else
        score += 4 * (query_tokens & Mnemosyne.tokenize(row[:content])).size
        score += 3 * (query_tokens & Mnemosyne.tokenize(row[:tags])).size
        score += 2 * (query_tokens & Mnemosyne.tokenize(row[:links])).size
        score += 5 if row[:links] && query_tokens.any? { |token| row[:links].include?(token) }
      end

      score += cascade_bonus(scope, row[:context_path])
      score += 2.0 * cosine if cosine.positive?
      score += fresh if fresh.positive?
      score
    end
  end
end
