# frozen_string_literal: true

# Backward-compatibility shim. The canonical importer is `Mnemosyne::Import`
# (mnemosyne/import.rb); `Mnemosyne::Legacy` remains as an alias so any older
# caller or standalone `ruby mnemosyne_legacy.rb` invocation keeps working.
require_relative 'import'

class Mnemosyne
  Legacy = Import unless const_defined?(:Legacy)
end

if __FILE__ == $PROGRAM_NAME
  result = Mnemosyne::Legacy.import(path: ENV['TM_AI_MEMORY_DB'] || File.join(Mnemosyne::Legacy.project_root, '.tm-ai', 'memory.db'))
  puts "Source:  #{ENV['TM_AI_MEMORY_DB'] || File.join(Mnemosyne::Legacy.project_root, '.tm-ai', 'memory.db')}"
  puts "Imported:"
  puts "  project_notes:   #{result[:project_notes]}"
  puts "  companion_state: #{result[:companion_state]}"
end
