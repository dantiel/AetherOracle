# frozen_string_literal: true

class Mnemosyne
  # FlashAegis — the Aegis re-forged by the fast model. The deep mind no longer
  # has to remember to call `aegis(summary:)`: after a prompt is entered the
  # turn is auto-digested and woven into the current orientation, so the Aegis
  # "flashes" onto a new course on its own. Two rites:
  #   * pre_turn_intent  — the prompt is distilled into a transient intent
  #     (in-memory only, gated by `flash.intent`, off by default: it adds
  #     pre-turn latency).
  #   * post_turn_sediment — the completed turn is condensed into a new summary
  #     + focus tags and persisted (gated by `flash.sediment`, on by default).
  class FlashAegis
    INTENT_SYSTEM = <<~TEXT.freeze
      You are the Aegis pre-turn weaver. Distill the user's prompt into ONE
      short current-intent line (what the practitioner is trying to do right
      now) and 2-5 focus tags. Reply with exactly two lines:
      INTENT: <one line>
      TAGS: tag1, tag2, tag3
    TEXT

    SEDIMENT_SYSTEM = <<~TEXT.freeze
      You are the Aegis post-turn weaver. Condense the completed turn into a
      2-4 line current-state summary of what was just decided/changed/built, and
      2-6 focus tags for the new course. Reply with exactly two lines:
      SUMMARY: <2-4 lines>
      TAGS: tag1, tag2, tag3
    TEXT

    class << self
      # Pre-turn: digest the prompt into a transient intent. Weaves into the
      # in-memory orientation only (no persisted state row) so the current turn
      # can see it without inflating the chronicle.
      def pre_turn_intent(prompt)
        return unless Mnemosyne.flash_available?(:intent)
        return if prompt.to_s.strip.empty?

        text = flash_ask(INTENT_SYSTEM, prompt, max_tokens: 120)
        return unless text

        intent, tags = parse_two_fields(text, 'INTENT', 'TAGS')
        Mnemosyne.aegis[:intent] = intent if intent && !intent.empty?
        Mnemosyne.aegis[:focus_tags] = split_tags(tags) if tags
        intent
      end

      # Post-turn: digest the turn into a new summary and weave it into the
      # persisted Aegis (the "new course").
      def post_turn_sediment(prompt, answer)
        return unless Mnemosyne.flash_available?(:sediment)
        return if prompt.to_s.strip.empty? && answer.to_s.strip.empty?

        text = flash_ask(SEDIMENT_SYSTEM, "PROMPT:\n#{prompt}\n\nANSWER:\n#{answer}", max_tokens: 256)
        return unless text

        summary, tags = parse_two_fields(text, 'SUMMARY', 'TAGS')
        summary = summary.to_s.strip
        tag_list = split_tags(tags)

        changed = false
        unless summary.empty?
          Mnemosyne.aegis[:summary] = summary
          changed = true
        end
        unless tag_list.empty?
          Mnemosyne.aegis[:tags] = tag_list
          changed = true
        end
        Mnemosyne.save_aegis_state(**Mnemosyne.aegis) if changed
        summary
      end

      private

      def flash_ask(system, user, max_tokens:)
        return nil unless Mnemosyne.flash_available?

        Conduit.flash(
          [{ role: 'system', content: system }, { role: 'user', content: user }],
          max_tokens: max_tokens, temperature: 0.2
        )
      end

      # Parse a "FIELD: value" pair out of a two-field flash reply. The value
      # may span multiple lines until the next "FIELD:" line.
      def parse_two_fields(text, field_a, field_b)
        [extract_field(text, field_a), extract_field(text, field_b)]
      end

      def extract_field(text, field)
        return nil if text.nil?

        m = text.match(/#{Regexp.escape(field)}:\s*(.*?)(?=\n\s*[A-Z]+:|$)/m)
        m && m[1].to_s.strip
      end

      def split_tags(tags)
        return [] if tags.nil?

        tags.to_s.split(',').map(&:strip).reject(&:empty?)
      end
    end
  end
end