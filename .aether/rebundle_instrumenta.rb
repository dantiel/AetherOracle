# frozen_string_literal: true

# ── rebundle_cli — rebuild + reinstall the gem, then restart the CLI ──
#
#   rebundle_cli
#   rebundle_cli(install: false)                    # only rebuild the .gem
#   rebundle_cli(restart: false)                    # rebuild + install, no restart
#   rebundle_cli(restart_command: 'ruby ruby/cli.rb')
#
# 1. `gem build <gemspec>` in the project root  → fresh aetheroracle-<ver>.gem
# 2. `gem install --local --force <gem>`        → replace the installed gem
# 3. restart (optional): a detached supervisor sleeps `delay` seconds (enough
#    for this result to flush), kills the current process, and — only when
#    `restart_command` is given — relaunches it.
#
# Restart semantics: with no `restart_command`, the daemon is killed and the
# *native host* restarts it on crash (platform/README.md — the shell owns
# daemon lifecycle). In a bare dev shell, pass `restart_command` to respawn it
# yourself, e.g. `cmd /c bin\aetheroracle.cmd` or `ruby ruby/standalone_daemon.rb`.

require 'open3'
require 'rbconfig'

def _rebundle_capture(cmd, root)
  out, status = Open3.capture2e(*cmd, chdir: root)
  [out, status.exitstatus, status.success?]
rescue StandardError => e
  ["#{e.class}: #{e.message}", 1, false]
end

def _rebundle_schedule_restart(command:, delay:)
  ruby   = RbConfig.ruby
  script = <<~'RUBY'
    delay   = ARGV[0].to_f
    target  = ARGV[1].to_i
    command = ARGV[2].to_s
    sleep delay
    if Gem.win_platform?
      system('taskkill', '/F', '/PID', target.to_s, out: File::NULL, err: File::NULL)
    else
      Process.kill('TERM', target)
    end
    if !command.empty?
      if Gem.win_platform?
        spawn('cmd', '/c', command)
      else
        spawn('/bin/sh', '-c', command)
      end
    end
  RUBY

  pid = Process.spawn(ruby, '-e', script, delay.to_s, Process.pid.to_s, command.to_s,
                      out: File::NULL, err: File::NULL)
  Process.detach(pid)
  pid
end

instrument :rebundle_cli,
           description: "Rebuild + reinstall the aetheroracle gem, then restart the CLI.",
           params: {
             gemspec:         { type: String,   default: 'aetheroracle.gemspec' },
             install:         { type: Boolean,  default: true },
             restart:         { type: Boolean,  default: true },
             restart_command: { type: String,   default: '' },
             delay:           { type: Numeric,  default: 2.0 }
           },
           timeout: 600,
           returns: { status: String, gem_file: String, build_log: String,
                      install_log: String, restart: String } do |gemspec:, install:, restart:, restart_command:, delay:|
  root = File.expand_path(ENV['AETHER_PROJECT_ROOT'] || Dir.pwd)

  build_log, _build_code, build_ok = _rebundle_capture(['gem', 'build', gemspec], root)
  gem_file = Dir.glob(File.join(root, '*.gem')).max_by { |f| File.mtime(f) }

  install_log = nil
  install_ok = true
  if install && build_ok && gem_file
    install_log, _install_code, install_ok = _rebundle_capture(['gem', 'install', '--local', '--force', '--no-document', gem_file], root)
  end

  restart_note = 'skipped'
  if restart
    supervisor = _rebundle_schedule_restart(command: restart_command.to_s, delay: delay)
    restart_note = if restart_command.to_s.empty?
                     "killing pid #{Process.pid} in #{delay}s (host respawns on crash) — supervisor #{supervisor}"
                   else
                     "killing pid #{Process.pid} in #{delay}s then respawning via: #{restart_command} — supervisor #{supervisor}"
                   end
  end

  status = (build_ok && install_ok) ? 'ok' : 'failed'
  {
    status:        status,
    gem_file:      gem_file ? File.basename(gem_file) : nil,
    build_log:     build_log,
    install_log:   install_log,
    restart:       restart_note
  }
end
