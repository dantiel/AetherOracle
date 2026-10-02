# frozen_string_literal: true

# ── Test instrumenta — verify project-context instrument loading ──
#
# After a daemon restart, the boot log should print:
#   [AETHER-INSTRUMENTA] 2 instrument(s) from 1 file(s) in .aether
#   [AETHER-INSTRUMENTA] + aether_ping (test_instrumenta.rb)
#   [AETHER-INSTRUMENTA] + aether_greet (test_instrumenta.rb)
#
# Then invoke them to confirm they are registered and validated:
#   aether_ping   -> { pong: "hello oracle", ts: <epoch> }
#   aether_greet  -> { greeting: "Hello, <name>!" }  (name defaults to "oracle")

instrument :aether_ping,
           description: "Test: confirm a project-context instrument is registered.",
           params:      {},
           returns:     { pong: String, ts: Integer } do
  { pong: 'hello oracle', ts: Time.now.to_i }
end

instrument :aether_greet,
           description: "Test: typed param + default value validation.",
           params:      { name: { type: String, default: 'oracle' } },
           returns:     { greeting: String } do |name:|
  { greeting: "Hello, #{name}!" }
end
