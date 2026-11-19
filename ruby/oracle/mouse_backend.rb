# frozen_string_literal: true

# Platform seam for terminal mouse capture + selection.
#
# The chamber talks to one interface; each backend hides its OS specifics
# underneath. Capture toggling, clipboard landing and the prompt-block anchor
# row all differ per platform:
#
#   * Windows  → ReadConsoleInputW MOUSE_EVENT records + Win32 clipboard
#   * Terminal → xterm SGR mouse sequences         + pbcopy/wl-copy/xclip
#
# Screen→buffer hit-testing (mapping a click cell back into the editable
# buffer) lives in the chamber, where the rendered geometry is known; the
# backend only supplies raw screen facts (cursor/anchor, on-screen text).
module MouseBackend
  def self.build(win:, mouse:, chamber:)
    (win ? Windows : Terminal).new(mouse: mouse, chamber: chamber)
  end

  class Base
    def initialize(mouse:, chamber:)
      @mouse = mouse
      @chamber = chamber
    end
  end

  # Windows: native console mouse. QuickEdit — the console's built-in
  # drag-select — is switched off while capture is on; the chamber's app-side
  # selection replaces it, so a click places the cursor and a drag extends the
  # selection instead of being swallowed by the OS. `screen_text_at` reads the
  # conhost screen buffer directly, which is how the chamber selects text it
  # did not itself draw (scrolled output).
  class Windows < Base
    def begin_capture
      begin
        ÆtherWinConsole.begin_raw_input(mouse: @mouse)
      rescue StandardError
        # A spawned tool child can momentarily disturb the input handle. Give it
        # one beat and re-enter raw mode before surrendering the native reader.
        sleep 0.02
        begin
          ÆtherWinConsole.begin_raw_input(mouse: @mouse)
        rescue StandardError
          ÆtherWinConsole.disable!
          raise
        end
      end
    end

    def end_capture
      ÆtherWinConsole.end_raw_input
    end

    def disable!
      ÆtherWinConsole.disable!
    end

    def clipboard_copy(text)
      ÆtherWinConsole.clipboard_copy(text)
    end

    def anchor_row
      pos = ÆtherWinConsole.cursor_position
      pos && pos[1]
    end

    def cursor_position
      ÆtherWinConsole.cursor_position
    end

    def screen_text_at(x, y, len)
      ÆtherWinConsole.screen_text_at(x, y, len)
    end
  end

  # Terminal: xterm SGR mouse over ANSI. Button-event tracking (1002) is
  # enabled so a drag emits motion events while a button is held — without it
  # Unix terminals report only press/release and drag-select never extends.
  class Terminal < Base
    def begin_capture
      @chamber.enable_mouse
    end

    def end_capture
      @chamber.disable_mouse
    end

    def disable!
      end_capture
    end

    def clipboard_copy(text)
      @chamber.copy_to_clipboard_unix(text)
    end

    def anchor_row
      pos = @chamber.query_cursor_position
      pos && pos[0] - 1
    end

    def cursor_position
      @chamber.query_cursor_position
    end

    def screen_text_at(_x, _y, _len)
      nil # no screen-buffer read on Unix; the chamber tracks what it renders
    end
  end
end
