# frozen_string_literal: true

# Vox — the voice that carries the æther into sound.
# macOS text-to-speech via the `say` command.
# Enumerates installed voices and speaks text with a chosen voice,
# without blocking the request thread (fire-and-forget).

require 'open3'

module Vox
  # Each `say -v '?'` line is:  <Name...>  <locale>  # <sample>
  # Names may contain spaces and parentheses (e.g. "Eddy (Deutsch (Deutschland))");
  # the locale is always the token immediately preceding `#`.
  # Locales are `xx_XX` (e.g. de_DE) or `xx_NNN` (personal voices, e.g. ar_001).
  VOICE_LINE = /^(.*?)\s+([a-z]{2}_[A-Z0-9]{2,3})\s+#/

  module_function

  # @return [Array<Hash>] [{ name:, locale:, language: }], German voices first.
  def voices
    out, _err, status = Open3.capture3('say', '-v', '?')
    return [] unless status.success?

    out.each_line.filter_map do |line|
      m = line.match(VOICE_LINE)
      next unless m

      { name: m[1].strip, locale: m[2], language: m[2].split('_').first }
    end.sort_by { |v| [v[:language] == 'de' ? 0 : 1, v[:language], v[:name]] }
  rescue StandardError
    []
  end

  # Speak text asynchronously with the given voice (fire-and-forget).
  # Text is fed via stdin, so arbitrarily long answers never hit ARG_MAX.
  #
  # @param text [String] the text to speak
  # @param voice [String, nil] voice name (nil falls back to the system default)
  # @return [Boolean] whether the speaker was launched
  def speak(text:, voice: nil)
    text = text.to_s.strip
    return false if text.empty?

    reader, writer = IO.pipe
    args = ['say']
    args += ['-v', voice.to_s.strip] unless voice.to_s.strip.empty?

    pid = Process.spawn(*args, in: reader, out: File::NULL, err: File::NULL)
    reader.close
    writer.write(text)
    writer.close
    Process.detach(pid)
    true
  rescue StandardError
    false
  end
end