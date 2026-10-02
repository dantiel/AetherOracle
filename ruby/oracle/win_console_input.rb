# frozen_string_literal: true

require 'fiddle/import'

# Windows-native key reader built on ReadConsoleInputW.
#
# tty-reader's WinConsole reads keys through msvcrt `_getch`, which strips the
# Ctrl/Alt modifier state from the arrow/edit keys. That is why Ctrl+←/→,
# Alt+←/→ and Ctrl+Backspace never reached the chamber's prompt editor: the
# modifier information is simply not present in `_getch`'s return value.
#
# ReadConsoleInputW surfaces KEY_EVENT records instead. Each record carries
# `dwControlKeyState` (LEFT/RIGHT CTRL+ALT bits) and `wVirtualKeyCode`, so a
# key and its modifiers are decoded unambiguously. Pasted text arrives as a
# batch of queued events, which lets us detect multi-line pastes and fold them
# into a single `[PASTED_CONTENT_n]` tag instead of mangling the single-line
# editor with literal newlines.
module ÆtherWinConsole
  extend Fiddle::Importer
  dlload 'kernel32'

  extern 'void* GetStdHandle(int)'
  extern 'int ReadConsoleInputW(void*, void*, int, int*)'
  extern 'int GetNumberOfConsoleInputEvents(void*, int*)'
  extern 'int GetConsoleMode(void*, int*)'
  extern 'int SetConsoleMode(void*, int)'
  extern 'int SetConsoleCP(int)'
  extern 'int SetConsoleOutputCP(int)'
  extern 'int WaitForSingleObject(void*, int)'

  # dwControlKeyState bits
  RIGHT_ALT_PRESSED  = 0x0001
  LEFT_ALT_PRESSED   = 0x0002
  RIGHT_CTRL_PRESSED = 0x0004
  LEFT_CTRL_PRESSED  = 0x0008
  SHIFT_PRESSED      = 0x0010
  CTRL_MASK          = LEFT_CTRL_PRESSED | RIGHT_CTRL_PRESSED
  ALT_MASK           = LEFT_ALT_PRESSED | RIGHT_ALT_PRESSED

  # Console input-mode bits cleared while the prompt editor owns the console.
  ENABLE_PROCESSED_INPUT = 0x0001
  ENABLE_LINE_INPUT      = 0x0002
  ENABLE_ECHO_INPUT      = 0x0004
  INPUT_MASK = ENABLE_PROCESSED_INPUT | ENABLE_LINE_INPUT | ENABLE_ECHO_INPUT

  # Virtual-key codes we interpret
  VK_BACK    = 0x08
  VK_TAB     = 0x09
  VK_RETURN  = 0x0D
  VK_ESCAPE  = 0x1B
  VK_PRIOR   = 0x21
  VK_NEXT    = 0x22
  VK_END     = 0x23
  VK_HOME    = 0x24
  VK_LEFT    = 0x25
  VK_UP      = 0x26
  VK_RIGHT   = 0x27
  VK_DOWN    = 0x28
  VK_INSERT  = 0x2D
  VK_DELETE  = 0x2E

  # Pure modifier keys. These arrive as their own KEY_DOWN records when held
  # (Shift, Ctrl, Alt, …), so read_event must skip them — otherwise a Shift+Tab
  # press is read as Shift-down first and the Tab is misclassified as a literal.
  VK_SHIFT    = 0x10
  VK_CONTROL  = 0x11
  VK_MENU     = 0x12
  VK_CAPITAL  = 0x14
  VK_NUMLOCK  = 0x90
  VK_SCROLL   = 0x91
  VK_LWIN     = 0x5B
  VK_RWIN     = 0x5C
  VK_LSHIFT   = 0xA0
  VK_RSHIFT   = 0xA1
  VK_LCONTROL = 0xA2
  VK_RCONTROL = 0xA3
  VK_LMENU    = 0xA4
  VK_RMENU    = 0xA5

  MODIFIER_VKS = [
    VK_SHIFT, VK_CONTROL, VK_MENU, VK_CAPITAL, VK_NUMLOCK, VK_SCROLL,
    VK_LWIN, VK_RWIN,
    VK_LSHIFT, VK_RSHIFT, VK_LCONTROL, VK_RCONTROL, VK_LMENU, VK_RMENU
  ].freeze

  # Ctrl+<letter> editing shortcuts (chamber-style, complementing Ctrl+C/D).
  CTRL_ACTIONS = {
    0x41 => :ctrl_a, # Ctrl+A → start of line
    0x43 => :ctrl_c, # Ctrl+C → clear line
    0x44 => :ctrl_d, # Ctrl+D → delete char / EOF on empty
    0x45 => :ctrl_e, # Ctrl+E → end of line
    0x4B => :ctrl_k, # Ctrl+K → kill to end of line
    0x55 => :ctrl_u, # Ctrl+U → kill to start of line
    0x57 => :ctrl_w  # Ctrl+W → delete word left
  }.freeze

  KEY_EVENT         = 0x0001
  INPUT_RECORD_SIZE = 20
  # EventType (WORD) + padding (WORD), bKeyDown (BOOL), wRepeatCount (WORD),
  # wVirtualKeyCode (WORD), wVirtualScanCode (WORD), UnicodeChar (WORD),
  # dwControlKeyState (DWORD) — little-endian, 20 bytes total. The padding is
  # consumed as a WORD (always 0) rather than skipped, so `unpack` yields one
  # value per field — skipping with `x2` would shift every downstream field.
  PACK = 'S<S<L<S<S<S<S<L<'

  PASTE_MAX_EVENTS = 8192

  # Raised when the native console reader cannot read from the console input
  # handle (invalid handle, detached console, redirected stdin, …). The chamber
  # catches this and falls back to TTY::Reader / line input instead of crashing.
  class ConsoleInputError < StandardError
    attr_reader :code

    def initialize(message, code = nil)
      super(message)
      @code = code
    end
  end

  # Common Win32 errors surfaced by ReadConsoleInputW / SetConsoleMode.
  ERROR_TEXT = {
    6   => 'ERROR_INVALID_HANDLE',
    38  => 'ERROR_HANDLE_EOF',
    87  => 'ERROR_INVALID_PARAMETER',
    109 => 'ERROR_BROKEN_PIPE',
    232 => 'ERROR_NO_DATA'
  }.freeze

  class << self
    def console_handle
      @console_handle ||= GetStdHandle(-10).to_i # STD_INPUT_HANDLE, as an address
    end

    # One byte from msvcrt `_getch` (0..255). Used to complete a truncated
    # extended-key read in the tty-reader fallback: tty-reader's WinConsole
    # probes `_kbhit` (non-blocking) for the second byte of Shift+Tab/arrow
    # keys, but `_kbhit` is already 0 because `_getch` consumed the KEY_EVENT —
    # the scan code lives only in the CRT's cache. A blocking `_getch` still
    # returns it, so we recover `\xE0\x0F` / `\x00\x0F` here instead of losing
    # the second byte.
    def crt_getch
      @crt_handle ||= begin
        Fiddle::Handle.new('msvcrt')
      rescue StandardError
        Fiddle::Handle.new('crtdll')
      end
      @crt_getch ||= Fiddle::Function.new(@crt_handle['_getch'], [], Fiddle::TYPE_INT)
      @crt_getch.call
    rescue StandardError
      nil
    end

    # Switch the console to UTF-8 (codepage 65001) so umlauts/emoji typed at the
    # prompt and rendered into the terminal survive the legacy CP850 default.
    # SetConsoleCP governs input translation, SetConsoleOutputCP the screen.
    def force_utf8!
      SetConsoleCP(65001)
      SetConsoleOutputCP(65001)
      true
    end

    # Non-blocking readiness probe: WaitForSingleObject on the console input
    # handle returns immediately (WAIT_OBJECT_0) when records are buffered,
    # WAIT_TIMEOUT otherwise. Lets the chamber poll for Tab while the agent
    # works without a blocking ReadConsoleInputW.
    def input_ready?
      WaitForSingleObject(console_handle, 0).zero?
    rescue StandardError
      false
    end

    # Human-readable Win32 error. `code` comes from Fiddle.win32_last_error,
    # which Fiddle captures immediately after the failing FFI call — before any
    # Ruby-side allocation can clobber the thread's last error.
    def describe_error(code)
      name = ERROR_TEXT[code]
      name ? "#{name} (#{code})" : "Win32 error #{code}"
    end

    # True when the console input handle is a genuine console (so
    # ReadConsoleInputW will work). Probes GetConsoleMode, which fails on
    # pipes/files — the classic failure when `ae` runs under mintty / MSYS2 /
    # Cygwin / ConPTY hosts where `$stdin.tty?` is true but STD_INPUT_HANDLE is
    # a pipe rather than a console.
    def available?
      return @available unless @available.nil?

      h = console_handle
      return @available = false if h.nil? || h.zero?

      get_mode(h)
      @available = true
    rescue StandardError
      @available = false
    end

    # Permanently disable the native reader for the rest of the process — used
    # once a read has failed, so the chamber does not retry (and re-fail) on
    # every subsequent prompt.
    def disable!
      @available = false
    end

    def get_mode(handle)
      m = "\0" * 8
      raise 'GetConsoleMode failed' if GetConsoleMode(handle, m).zero?

      m.unpack1('L<')
    end

    def set_mode(handle, mode)
      SetConsoleMode(handle, mode)
    end

    # Switch the console out of line/echo/processed mode for the duration of
    # the prompt editor, so ReadConsoleInputW sees raw key events (and Ctrl+C
    # arrives as a key event instead of a signal). Restores on end_raw_input.
    # Ref-counted and thread-safe: the chamber's foreground browse-poll and the
    # agent's background ask_user menu may both enter raw mode, so only the
    # outermost end_raw_input restores the original console mode.
    def begin_raw_input
      raw_mutex.synchronize do
        if @raw_depth.to_i.zero?
          mode = get_mode(console_handle)
          ok = set_mode(console_handle, mode & ~INPUT_MASK)
          if ok.nil? || ok.zero?
            err = Fiddle.win32_last_error
            raise ConsoleInputError.new("SetConsoleMode failed: #{describe_error(err)}", err)
          end
          @raw_saved_mode = mode
        end
        @raw_depth = @raw_depth.to_i + 1
        @raw_saved_mode
      end
    end

    def end_raw_input
      raw_mutex.synchronize do
        return if @raw_depth.to_i.zero?

        @raw_depth -= 1
        if @raw_depth.zero? && @raw_saved_mode
          set_mode(console_handle, @raw_saved_mode)
          @raw_saved_mode = nil
        end
      end
    end

    def raw_mutex
      @raw_mutex ||= Mutex.new
    end

    # One raw INPUT_RECORD as { type:, down:, vk:, unichar:, ctrl:, alt:, shift: }.
    def read_record
      buf = "\0" * INPUT_RECORD_SIZE
      nread = "\0" * 8
      ok = ReadConsoleInputW(console_handle, buf, 1, nread)
      if ok.nil? || ok.zero?
        err = Fiddle.win32_last_error
        raise ConsoleInputError.new("ReadConsoleInputW failed: #{describe_error(err)}", err)
      end

      type, _pad, down, _rep, vk, _scan, unichar, state = buf.unpack(PACK)
      { type: type, down: down == 1, vk: vk, unichar: unichar,
        ctrl: (state & CTRL_MASK) != 0,
        alt:  (state & ALT_MASK) != 0,
        shift: (state & SHIFT_PRESSED) != 0 }
    end

    # The next KEY_DOWN record, skipping key-up and non-key records.
    def read_event
      loop do
        e = read_record
        return e if e[:type] == KEY_EVENT && e[:down] && !MODIFIER_VKS.include?(e[:vk])
      end
    end

    def pending_count
      n = "\0" * 8
      GetNumberOfConsoleInputEvents(console_handle, n)
      n.unpack1('L<')
    end

    # The unified input the prompt editor consumes:
    #   { kind: :key, action: Symbol, char: String }   a single editing key
    #   { kind: :literal, text: String }               a batch of typed chars
    #   { kind: :paste, text: String }                 a multi-line paste
    def next_input
      first = read_event
      events = [first]

      # Pastes arrive as a burst of queued records; a single keystroke arrives
      # alone. Drain every record already queued (key-down records only) so a
      # paste is captured whole rather than char-by-char. Reads are guarded by
      # pending_count, so a trailing key-up record never triggers a blocking
      # read (ReadConsoleInputW blocks on an empty buffer).
      drained = 0
      while pending_count.positive? && drained < PASTE_MAX_EVENTS
        e = read_record
        drained += 1
        events << e if e[:type] == KEY_EVENT && e[:down]
      end

      text = events.map { |e| char_for(e) }.join
      if events.size > 1
        return { kind: :paste, text: text.gsub(/\r\n?/, "\n") } if text.include?("\n")

        return { kind: :literal, text: text }
      end

      classify_key(first)
    end

    # The printable character a key event represents (empty when none).
    def char_for(e)
      return "\n" if e[:vk] == VK_RETURN
      return "\t" if e[:vk] == VK_TAB

      u = e[:unichar]
      return '' if u.nil? || u.zero?
      return '' if u >= 0xD800 && u <= 0xDFFF # lone surrogate

      [u].pack('U')
    rescue StandardError
      ''
    end

    def classify_key(e)
      vk   = e[:vk]
      ctrl = e[:ctrl]
      alt  = e[:alt]

      case vk
      when VK_RETURN then { kind: :key, action: :enter }
      when VK_TAB    then { kind: :key, action: e[:shift] ? :back_tab : :tab }
      when VK_ESCAPE then { kind: :key, action: :escape }
      when VK_BACK   then { kind: :key, action: (ctrl || alt) ? :word_backspace : :backspace }
      when VK_DELETE then { kind: :key, action: (ctrl || alt) ? :word_delete : :delete }
      when VK_LEFT   then { kind: :key, action: (ctrl || alt) ? :word_left : :left }
      when VK_RIGHT  then { kind: :key, action: (ctrl || alt) ? :word_right : :right }
      when VK_UP     then { kind: :key, action: :up }
      when VK_DOWN   then { kind: :key, action: :down }
      when VK_HOME   then { kind: :key, action: ctrl ? :ctrl_home : :home }
      when VK_END    then { kind: :key, action: ctrl ? :ctrl_end : :end }
      when VK_PRIOR  then { kind: :key, action: :page_up }
      when VK_NEXT   then { kind: :key, action: :page_down }
      when VK_INSERT then { kind: :key, action: :ignore }
      else
        if ctrl
          act = CTRL_ACTIONS[vk]
          return { kind: :key, action: act } if act

          return { kind: :key, action: :ignore }
        end

        ch = char_for(e)
        ch.empty? ? { kind: :key, action: :ignore } : { kind: :key, action: :literal, char: ch }
      end
    end
  end
end