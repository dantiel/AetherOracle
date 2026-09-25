# frozen_string_literal: true

require_relative 'instrumentarium/verbum'
require 'shellwords'

# Polymorphic Shell — the single filesystem truth shared by the user's Pythia
# CLI (`$` prompt) and the agent's `run_command` instrument. Both hands hold the
# same @cwd, so a `cd` by either side is visible to the other. This is the seam
# where the Pythia CLI and the agent's shell context become one interface.
class ShellSession
  attr_reader :cwd, :env

  def initialize(root)
    @cwd = File.expand_path(root.to_s)
    @cwd = Dir.pwd unless Dir.exist?(@cwd)
    @env = {}
  end

  def reset(root)
    @cwd = File.expand_path(root.to_s)
    @cwd = Dir.pwd unless Dir.exist?(@cwd)
    @cwd
  end

  # Per-turn branch: a fresh session breathing the same cwd as its parent. The
  # agent mutates this branch during a request; on completion it merges back —
  # git-flow: concurrent branches, linear merge into the trunk. The filesystem
  # itself is shared, so only the cwd carries branch state.
  def branch
    child = self.class.new(@cwd)
    child.instance_variable_set(:@env, @env.dup)
    child
  end

  # Adopt another session's cwd (merge a completed turn back into the trunk).
  def merge_from(other)
    @cwd = other.cwd if other && Dir.exist?(other.cwd.to_s)
    @env = other.env.dup if other && other.respond_to?(:env)
    @cwd
  end

  # `cd`-like commands mutate the session; everything else runs at @cwd.
  # Returns a uniform hash consumable by the framed wire protocol and by
  # the CLI block renderer.
  def run(cmd, env: {}, timeout: 60)
    command = cmd.to_s.strip
    return empty_result if command.empty?

    # Intercept a *pure* `cd [path]` so the session cwd persists. A compound
    # command (`cd /tmp && pwd`) runs in the child shell (cwd does not persist).
    if (m = command.match(/\A\s*cd(?:\s+(.+))?\s*\z/)) && !m[1].to_s.match?(/[;&|<>`$]/)
      return change_dir(m[1])
    end

    # Intercept `export NAME=VAL [NAME2=VAL2 ...]` so the session env persists
    # bidirectionally — the same live env the agent's run_command tool inherits.
    if (m = command.match(/\A\s*export(?:\s+(.+))?\s*\z/)) && !m[1].to_s.match?(/[;&|<>`$]/)
      return export_env(m[1])
    end

    # Intercept `unset NAME [NAME2 ...]`.
    if (m = command.match(/\A\s*unset(?:\s+(.+))?\s*\z/)) && !m[1].to_s.match?(/[;&|<>`$]/)
      return unset_env(m[1])
    end

    # Live session env wins over the static .env.run_command file.
    merged_env = env.merge(@env)
    stdout, stderr, status = Verbum.run_command_in_real_time(
      merged_env, command, chdir: @cwd, timeout_seconds: timeout
    )
    exit_status = status.respond_to?(:exitstatus) ? status.exitstatus : nil
    {
      cwd:         @cwd,
      stdout:      stdout.to_s,
      stderr:      stderr.to_s,
      exit_status: exit_status,
      env:         @env.dup,
      ok:          exit_status == 0
    }
  rescue StandardError => e
    {
      cwd:         @cwd,
      stdout:      '',
      stderr:      e.message.to_s,
      exit_status: 1,
      env:         @env.dup,
      ok:          false
    }
  end

  private

  def empty_result
    { cwd: @cwd, stdout: '', stderr: '', exit_status: 0, env: @env.dup, ok: true }
  end

  def change_dir(target)
    dest = target.to_s.strip
    dest = Dir.home if dest.empty? || dest == '~'
    dest = File.expand_path(dest, @cwd)
    if Dir.exist?(dest)
      @cwd = dest
      { cwd: @cwd, stdout: '', stderr: '', exit_status: 0, env: @env.dup, ok: true }
    else
      {
        cwd:         @cwd,
        stdout:      '',
        stderr:      "cd: no such directory: #{dest}",
        exit_status: 1,
        env:         @env.dup,
        ok:          false
      }
    end
  end

  # Parse `export FOO=bar BAZ="x y"` (Shellwords handles quoting) and persist
  # each pair into the session env. Bare `export NAME` carries ENV's value.
  def export_env(pairs)
    Shellwords.split(pairs.to_s).each do |pair|
      if (m = pair.match(/\A([A-Za-z_][A-Za-z0-9_]*)=(.*)\z/m))
        @env[m[1]] = m[2]
      elsif pair.match?(/\A[A-Za-z_][A-Za-z0-9_]*\z/)
        @env[pair] = ENV[pair].to_s
      end
    end
    { cwd: @cwd, stdout: '', stderr: '', exit_status: 0, env: @env.dup, ok: true }
  end

  def unset_env(names)
    Shellwords.split(names.to_s).each { |n| @env.delete(n) }
    { cwd: @cwd, stdout: '', stderr: '', exit_status: 0, env: @env.dup, ok: true }
  end
end