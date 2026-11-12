# frozen_string_literal: true

# ─── Coverage (must start before loading main.rb) ─────────────────────────────
unless defined?(Coverage) && Coverage.running?
  require 'coverage'
  Coverage.start
end

# ─── Dependencies ─────────────────────────────────────────────────────────────
require 'rspec'
require 'rspec/core/formatters/base_formatter'
require 'open3'
require 'fileutils'
require 'tmpdir'
require 'rbconfig'

MAIN_RB      = File.expand_path('../main.rb', __dir__)
PROJECT_ROOT = File.dirname(MAIN_RB)

# If the top-level guard is ever lost, requiring main.rb runs the step and its
# `abort` / `exit 0` would end this suite early (or with a false green).
# Fail loudly instead.
begin
  require MAIN_RB
rescue SystemExit => e
  abort "main.rb ran its step on require (exit #{e.status}); top-level code must stay inside `if __FILE__ == $PROGRAM_NAME`."
end

# ─── Custom Formatter ─────────────────────────────────────────────────────────
class ReadableFormatter < RSpec::Core::Formatters::BaseFormatter
  RSpec::Core::Formatters.register(
    self,
    :example_group_started,
    :example_group_finished,
    :example_passed,
    :example_failed,
    :example_pending,
    :dump_summary
  )

  PASS  = "\e[32;1m[ PASS ]\e[0m"
  FAIL  = "\e[31;1m[ FAIL ]\e[0m"
  ERROR = "\e[31;1m[ERROR ]\e[0m"
  SKIP  = "\e[33;1m[ SKIP ]\e[0m"

  DIVIDER     = "\e[90m#{'─' * 72}\e[0m"
  DIVIDER_FAT = "\e[90m#{'═' * 72}\e[0m"

  def initialize(output)
    super
    @depth    = 0
    @failures = []
    @counts   = { passed: 0, failed: 0, pending: 0 }
  end

  # Top-level describe groups cycle through distinct colors
  GROUP_COLORS = [
    "\e[34;1m",  # bold blue
    "\e[35;1m",  # bold magenta
    "\e[36;1m",  # bold cyan
    "\e[33;1m",  # bold yellow
  ].freeze

  def example_group_started(notification)
    group = notification.group
    if group.parent_groups.size <= 1
      output.puts if @depth.zero?
      color = GROUP_COLORS[@depth % GROUP_COLORS.size]
      output.puts "  #{color}#{group.description}\e[0m"
    else
      output.puts "    #{'  ' * (@depth - 1)}\e[90m▸ \e[0m\e[37m#{group.description}\e[0m"
    end
    @depth += 1
  end

  def example_group_finished(_notification)
    @depth -= 1 if @depth > 0
  end

  def example_passed(notification)
    @counts[:passed] += 1
    print_example(PASS, notification.example)
  end

  def example_failed(notification)
    @counts[:failed] += 1
    ex    = notification.example
    exc   = ex.execution_result.exception
    badge = exc.is_a?(RSpec::Expectations::ExpectationNotMetError) ? FAIL : ERROR
    print_example(badge, ex)
    @failures << notification
  end

  def example_pending(notification)
    @counts[:pending] += 1
    ex = notification.example
    output.puts "    #{'  ' * [0, @depth - 1].max}#{SKIP}  #{ex.description}"
  end

  def dump_summary(notification)
    output.puts
    output.puts DIVIDER_FAT

    unless @failures.empty?
      output.puts "\n  \e[1;31mFailures:\e[0m\n"
      @failures.each_with_index do |n, i|
        ex  = n.example
        exc = ex.execution_result.exception
        output.puts "  \e[1m#{i + 1}) #{ex.full_description}\e[0m"
        exc.message.lines.first(6).each do |line|
          output.puts "     \e[31m#{line.rstrip}\e[0m"
        end
        output.puts "     \e[90m# #{ex.location}\e[0m"
        output.puts
      end
      output.puts DIVIDER
    end

    t   = notification.examples.size
    p   = @counts[:passed]
    f   = @counts[:failed]
    s   = @counts[:pending]
    sec = format('%.3fs', notification.duration)

    parts = ["\e[32m#{p} passed\e[0m"]
    parts << "\e[31m#{f} failed\e[0m"  if f > 0
    parts << "\e[33m#{s} pending\e[0m" if s > 0

    overall = f.zero? ? "\e[32;1m✔  All #{t} tests passed\e[0m" : "\e[31;1m✖  #{f} of #{t} tests failed\e[0m"
    output.puts "\n  #{overall}"
    output.puts "  #{parts.join('  |  ')}  \e[90m(#{sec})\e[0m"
    output.puts DIVIDER_FAT
  end

  private

  def print_example(badge, example)
    indent = '  ' * [0, @depth - 1].max
    time   = format('%.3fs', example.execution_result.run_time)
    output.puts "    #{indent}#{badge}  #{example.description}  \e[90m(#{time})\e[0m"
  end
end

# ─── Helpers ──────────────────────────────────────────────────────────────────

# Create stub `swiftlint`, `git`, `brew` and `which` executables so the
# subprocess script never touches the real toolchain or the network.
# Every stub appends "<name> <args> [cwd=<dir>]" to $STUB_LOG.
#   swiftlint  prints "LINT-RESULT <args>"; exits STUB_SWIFTLINT_EXIT (default 2)
#              when its arguments contain STUB_SWIFTLINT_FAIL_ON
#   git        prints STUB_GIT_CHANGED (newline separated file list);
#              exits STUB_GIT_EXIT when set
#   brew       exits STUB_BREW_EXIT when set
#   which      finds swiftlint unless STUB_NO_SWIFTLINT is set
# Returns the directory to prepend to PATH.
def build_stub_bin(root)
  bin = File.join(root, 'stubbin')
  FileUtils.mkdir_p(bin)
  File.write(File.join(bin, 'swiftlint'), <<~'SH')
    #!/bin/sh
    echo "swiftlint $* [cwd=$(pwd -P)]" >> "$STUB_LOG"
    if [ -n "$STUB_SWIFTLINT_FAIL_ON" ]; then
      case "$*" in
        *"$STUB_SWIFTLINT_FAIL_ON"*) echo "VIOLATION $*"; exit "${STUB_SWIFTLINT_EXIT:-2}" ;;
      esac
    fi
    echo "LINT-RESULT $*"
    exit 0
  SH
  File.write(File.join(bin, 'git'), <<~'SH')
    #!/bin/sh
    echo "git $* [cwd=$(pwd -P)]" >> "$STUB_LOG"
    if [ -n "$STUB_GIT_EXIT" ]; then
      echo "fatal: ambiguous argument 'HEAD^'" >&2
      exit "$STUB_GIT_EXIT"
    fi
    if [ -n "$STUB_GIT_CHANGED" ]; then
      printf '%s\n' "$STUB_GIT_CHANGED"
    fi
    exit 0
  SH
  File.write(File.join(bin, 'brew'), <<~'SH')
    #!/bin/sh
    echo "brew $* [cwd=$(pwd -P)]" >> "$STUB_LOG"
    if [ -n "$STUB_BREW_EXIT" ]; then
      echo "Error: brew failed"
      exit "$STUB_BREW_EXIT"
    fi
    exit 0
  SH
  File.write(File.join(bin, 'which'), <<~'SH')
    #!/bin/sh
    if [ "$1" = "swiftlint" ] && [ -z "$STUB_NO_SWIFTLINT" ]; then
      echo "$(dirname "$0")/swiftlint"
      exit 0
    fi
    exit 1
  SH
  Dir.glob(File.join(bin, '*')).each { |f| FileUtils.chmod(0o755, f) }
  bin
end

# Directory where child processes drop their coverage snapshots, so the report
# reflects the guarded top-level block as well as the in-process functions.
COVERAGE_DIR = Dir.mktmpdir('swiftlint_cov')

# Preloaded into every child with `ruby -r<helper> main.rb`, which keeps
# main.rb as $PROGRAM_NAME so its top-level guard still fires.
COVERAGE_HELPER = File.join(COVERAGE_DIR, 'cov_helper.rb')
File.write(COVERAGE_HELPER, <<~RUBY)
  require 'coverage'
  Coverage.start
  at_exit do
    dir = ENV['AC_TEST_COVERAGE_DIR']
    next if dir.nil? || dir.empty?

    result = begin
      Coverage.result(stop: false, clear: false)
    rescue ArgumentError
      Coverage.result
    end
    target = result.keys.find { |p| p.to_s.end_with?('main.rb') }
    next if target.nil?

    counts = result[target].map { |c| c.nil? ? '-' : c }.join(',')
    File.write(File.join(dir, "cov-\#{Process.pid}.txt"), counts)
  end
RUBY

# Merge every child snapshot into a single line-count array.
def subprocess_coverage
  Dir.glob(File.join(COVERAGE_DIR, 'cov-*.txt')).each_with_object([]) do |file, acc|
    File.read(file).split(',').each_with_index do |cell, i|
      next if cell == '-'

      acc[i] = (acc[i] || 0) + cell.to_i
    end
  end
end

STEP_ENV_KEYS = %w[
  AC_REPOSITORY_DIR AC_LINT_PATH AC_LINT_RANGE AC_LINT_CONFIG AC_LINT_REPORTER
  AC_LINT_STRICT AC_LINT_QUIET AC_OUTPUT_DIR AC_ENV_FILE_PATH
  STUB_SWIFTLINT_FAIL_ON STUB_SWIFTLINT_EXIT STUB_GIT_CHANGED STUB_GIT_EXIT
  STUB_BREW_EXIT STUB_NO_SWIFTLINT
].freeze

# Sandbox for one subprocess run: repo dir, output dir, env file and stubs,
# all inside a fresh tmpdir.
class StepSandbox
  attr_reader :root, :repo, :output_dir, :env_file, :stub_bin, :stub_log

  def initialize
    @root       = Dir.mktmpdir('swiftlint_step_test')
    @repo       = File.join(@root, 'repo')
    @output_dir = File.join(@root, 'output')
    @env_file   = File.join(@root, 'ac_env_file')
    @stub_log   = File.join(@root, 'stub.log')
    FileUtils.mkdir_p([@repo, @output_dir])
    File.write(@env_file, '')
    @stub_bin = build_stub_bin(@root)
  end

  # Inputs Appcircle always provides; individual tests override or unset them.
  def base_env
    {
      'AC_REPOSITORY_DIR' => repo,
      'AC_OUTPUT_DIR' => output_dir,
      'AC_ENV_FILE_PATH' => env_file,
      'AC_LINT_REPORTER' => 'xcode'
    }
  end

  # Run main.rb in a subprocess. Every step / stub key not given is explicitly
  # UNSET in the child, so the parent's environment never leaks in.
  def run(env = base_env, path: nil)
    child_env = STEP_ENV_KEYS.to_h { |k| [k, nil] }.merge(env)
    child_env['PATH'] = path || "#{stub_bin}#{File::PATH_SEPARATOR}#{ENV.fetch('PATH', '')}"
    child_env['STUB_LOG'] = stub_log
    child_env['AC_TEST_COVERAGE_DIR'] = COVERAGE_DIR
    Open3.capture3(child_env, RbConfig.ruby, "-r#{COVERAGE_HELPER}", MAIN_RB, chdir: root)
  end

  def stub_calls(name = nil)
    return [] unless File.exist?(stub_log)

    lines = File.readlines(stub_log, chomp: true)
    name ? lines.select { |l| l.start_with?("#{name} ") } : lines
  end

  def report(file = 'swiftlint_result.txt')
    path = File.join(output_dir, file)
    File.exist?(path) ? File.read(path) : nil
  end

  def env_file_content
    File.read(env_file)
  end

  def cleanup
    FileUtils.rm_rf(root)
  end
end

# Commands main.rb handed to run_command, in order (from its @@[command] log).
def logged_commands(out)
  out.lines.grep(/\A@@\[command\] /).map { |l| l.sub('@@[command] ', '').chomp }
end

# The exact command main.rb composes for "lint all files".
def lint_all_cmd(reporter, path, flags = '')
  "swiftlint lint --reporter=#{reporter} #{flags} '#{path}'"
end

# The exact command main.rb composes for one changed file.
def lint_file_cmd(reporter, file, flags = '')
  "swiftlint lint --reporter=#{reporter} #{flags} '#{file}' "
end

def git_diff_cmd(repo)
  "git -C #{repo} diff HEAD^ --name-only --diff-filter=d -- '*.swift'"
end

# ─── Tests ────────────────────────────────────────────────────────────────────

RSpec.describe 'main.rb loading contract' do
  it 'defines get_env_variable and run_command when required' do
    expect(respond_to?(:get_env_variable, true)).to be(true)
    expect(respond_to?(:run_command, true)).to be(true)
  end

  it 'does not run the step when required (no abort without AC_REPOSITORY_DIR)' do
    out, err, status = Open3.capture3(
      { 'AC_REPOSITORY_DIR' => nil },
      RbConfig.ruby, '-e', "require #{MAIN_RB.dump}; puts 'loaded'"
    )
    expect(status.exitstatus).to eq(0), err
    expect(out).to eq("loaded\n")
    expect(err).not_to include('Missing repo path.')
  end
end

# ─────────────────────────────────────────────────────────────────────────────

RSpec.describe '#get_env_variable' do
  around do |example|
    saved = ENV.to_h.slice('AC_TEST_KEY')
    example.run
  ensure
    ENV.delete('AC_TEST_KEY')
    ENV.update(saved)
  end

  context 'happy path' do
    it 'returns the value when the key is set' do
      ENV['AC_TEST_KEY'] = 'checkstyle'
      expect(get_env_variable('AC_TEST_KEY')).to eq('checkstyle')
    end

    it 'returns the value unchanged (no strip or expansion)' do
      ENV['AC_TEST_KEY'] = ' ./Sources/$HOME '
      expect(get_env_variable('AC_TEST_KEY')).to eq(' ./Sources/$HOME ')
    end
  end

  context 'empty / nil input' do
    it 'returns nil when the value is an empty string' do
      ENV['AC_TEST_KEY'] = ''
      expect(get_env_variable('AC_TEST_KEY')).to be_nil
    end

    it 'returns nil when the key does not exist' do
      ENV.delete('AC_TEST_KEY')
      expect(get_env_variable('AC_TEST_KEY')).to be_nil
    end

    it 'returns whitespace as-is (it is not treated as empty)' do
      ENV['AC_TEST_KEY'] = '   '
      expect(get_env_variable('AC_TEST_KEY')).to eq('   ')
    end
  end

  context 'error branch' do
    it 'raises TypeError for a nil key' do
      expect { get_env_variable(nil) }.to raise_error(TypeError)
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────

RSpec.describe '#run_command' do
  context 'happy path' do
    before { allow($stdout).to receive(:puts) }

    it 'returns the captured stdout of the command' do
      expect(run_command('echo linted')).to eq("linted\n")
    end

    it 'returns an empty string for a silent successful command' do
      expect(run_command('true')).to eq('')
    end

    it 'echoes the command with the @@[command] prefix' do
      allow($stdout).to receive(:puts).and_call_original
      expect { run_command('true') }.to output("@@[command] true\n").to_stdout
    end

    it 'captures the output instead of streaming it' do
      allow($stdout).to receive(:puts).and_call_original
      expect { run_command('echo hidden') }.to output("@@[command] echo hidden\n").to_stdout_from_any_process
    end

    it 'passes the composed command string to the shell verbatim' do
      cmd = "swiftlint lint --reporter=json  --strict '/repo/Sources'"
      expect(self).to receive(:`).with(cmd) do
        system('true')
        "[]\n"
      end
      expect(run_command(cmd)).to eq("[]\n")
    end
  end

  context 'error branch' do
    before { allow($stdout).to receive(:puts) }

    it 'raises when the command exits non-zero' do
      expect { run_command('false') }.to raise_error(RuntimeError, /Linting failed\. Check logs for details/)
    end

    it 'includes the command output in the error message' do
      expect { run_command("sh -c 'echo 3 violations; exit 2'") }
        .to raise_error(RuntimeError, /3 violations/)
    end

    it 'raises for a non-zero swiftlint run without executing swiftlint' do
      cmd = "swiftlint lint --reporter=xcode  --strict '/repo'"
      expect(self).to receive(:`).with(cmd) do
        system('false')
        "warning: Line Length Violation\n"
      end
      expect { run_command(cmd) }.to raise_error(RuntimeError, /Line Length Violation/)
    end

    it 'still logs the command before raising' do
      allow($stdout).to receive(:puts).and_call_original
      expect do
        run_command('false')
      rescue RuntimeError
        nil
      end.to output("@@[command] false\n").to_stdout
    end

    it 'raises Errno::ENOENT when the command cannot be found' do
      expect { run_command('ac_no_such_command_xyz') }.to raise_error(Errno::ENOENT)
    end
  end

  context 'empty / nil input' do
    before { allow($stdout).to receive(:puts) }

    it 'raises Errno::ENOENT for an empty command string' do
      expect { run_command('') }.to raise_error(Errno::ENOENT)
    end

    it 'treats a nil command as empty (string interpolation) and raises Errno::ENOENT' do
      expect { run_command(nil) }.to raise_error(Errno::ENOENT)
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────

RSpec.describe 'ENV validation' do
  let(:sb) { StepSandbox.new }

  after { sb.cleanup }

  describe 'AC_REPOSITORY_DIR' do
    it 'missing: aborts with "Missing repo path." and runs nothing' do
      _out, err, status = sb.run(sb.base_env.merge('AC_REPOSITORY_DIR' => nil))
      expect(status.exitstatus).to eq(1)
      expect(err).to include('Missing repo path.')
      expect(sb.stub_calls).to be_empty
      expect(sb.env_file_content).to eq('')
    end

    it 'empty: aborts with "Missing repo path." and runs nothing' do
      _out, err, status = sb.run(sb.base_env.merge('AC_REPOSITORY_DIR' => ''))
      expect(status.exitstatus).to eq(1)
      expect(err).to include('Missing repo path.')
      expect(sb.stub_calls).to be_empty
    end

    it 'set: lints the repository directory' do
      out, err, status = sb.run
      expect(status.exitstatus).to eq(0), err
      expect(logged_commands(out)).to eq([lint_all_cmd('xcode', sb.repo, '')])
    end
  end

  describe 'AC_ENV_FILE_PATH' do
    it 'missing: fails non-zero with a TypeError after writing the report' do
      _out, err, status = sb.run(sb.base_env.merge('AC_ENV_FILE_PATH' => nil))
      expect(status.success?).to be(false)
      expect(err).to include('no implicit conversion of nil into String')
      expect(sb.report).to start_with('LINT-RESULT')
    end

    it 'empty: fails non-zero with Errno::ENOENT' do
      _out, err, status = sb.run(sb.base_env.merge('AC_ENV_FILE_PATH' => ''))
      expect(status.success?).to be(false)
      expect(err).to include('No such file or directory')
    end

    it 'non-existent directory: fails non-zero with Errno::ENOENT' do
      bad = File.join(sb.root, 'missing', 'env')
      _out, err, status = sb.run(sb.base_env.merge('AC_ENV_FILE_PATH' => bad))
      expect(status.success?).to be(false)
      expect(err).to include('No such file or directory')
      expect(File.exist?(bad)).to be(false)
    end

    it 'set: exports AC_LINT_OUTPUT_PATH pointing at the report' do
      _out, err, status = sb.run
      expect(status.exitstatus).to eq(0), err
      expected = File.join(sb.output_dir, 'swiftlint_result.txt')
      expect(sb.env_file_content).to eq("AC_LINT_OUTPUT_PATH=#{expected}\n")
    end

    it 'set: appends to the file instead of truncating it' do
      File.write(sb.env_file, "EXISTING=1\n")
      _out, err, status = sb.run
      expect(status.exitstatus).to eq(0), err
      expect(sb.env_file_content.lines.first).to eq("EXISTING=1\n")
      expect(sb.env_file_content.lines.last).to start_with('AC_LINT_OUTPUT_PATH=')
    end

    it 'set to a path that does not exist yet: creates the file' do
      fresh = File.join(sb.root, 'fresh_env')
      _out, err, status = sb.run(sb.base_env.merge('AC_ENV_FILE_PATH' => fresh))
      expect(status.exitstatus).to eq(0), err
      expect(File.read(fresh)).to start_with('AC_LINT_OUTPUT_PATH=')
    end
  end

  describe 'AC_OUTPUT_DIR' do
    it 'missing: fails non-zero with a TypeError and exports nothing' do
      _out, err, status = sb.run(sb.base_env.merge('AC_OUTPUT_DIR' => nil))
      expect(status.success?).to be(false)
      expect(err).to include('no implicit conversion of nil into String')
      expect(sb.env_file_content).to eq('')
    end

    it 'non-existent directory: fails non-zero with Errno::ENOENT and exports nothing' do
      _out, err, status = sb.run(sb.base_env.merge('AC_OUTPUT_DIR' => File.join(sb.root, 'nope')))
      expect(status.success?).to be(false)
      expect(err).to include('No such file or directory')
      expect(sb.env_file_content).to eq('')
    end

    it 'set: writes the swiftlint output to the report file' do
      _out, err, status = sb.run
      expect(status.exitstatus).to eq(0), err
      expect(sb.report).to eq("LINT-RESULT lint --reporter=xcode #{sb.repo}\n")
    end
  end

  describe 'AC_LINT_REPORTER' do
    {
      'xcode' => 'swiftlint_result.txt',
      'emoji' => 'swiftlint_result.txt',
      'github-actions-logging' => 'swiftlint_result.txt',
      'markdown' => 'swiftlint_result.md',
      'csv' => 'swiftlint_result.csv',
      'html' => 'swiftlint_result.html',
      'checkstyle' => 'swiftlint_result.xml',
      'junit' => 'swiftlint_result.xml',
      'json' => 'swiftlint_result.json',
      'sonarqube' => 'swiftlint_result.json'
    }.each do |reporter, file|
      it "#{reporter}: passes --reporter=#{reporter} and writes #{file}" do
        out, err, status = sb.run(sb.base_env.merge('AC_LINT_REPORTER' => reporter))
        expect(status.exitstatus).to eq(0), err
        expect(out).not_to include('Unknown reporter')
        expect(logged_commands(out)).to eq([lint_all_cmd(reporter, sb.repo)])
        expect(sb.report(file)).to include("--reporter=#{reporter}")
        expect(sb.env_file_content).to eq("AC_LINT_OUTPUT_PATH=#{File.join(sb.output_dir, file)}\n")
      end
    end

    it 'missing: prints "Unknown reporter", passes an empty --reporter= and writes a file without extension' do
      out, err, status = sb.run(sb.base_env.merge('AC_LINT_REPORTER' => nil))
      expect(status.exitstatus).to eq(0), err
      expect(out).to include('Unknown reporter')
      expect(logged_commands(out)).to eq([lint_all_cmd('', sb.repo)])
      expect(sb.report('swiftlint_result')).not_to be_nil
    end

    it 'empty: behaves like missing' do
      out, err, status = sb.run(sb.base_env.merge('AC_LINT_REPORTER' => ''))
      expect(status.exitstatus).to eq(0), err
      expect(out).to include('Unknown reporter')
      expect(sb.report('swiftlint_result')).not_to be_nil
    end

    it 'unknown value: is still passed to swiftlint, report has no extension' do
      out, err, status = sb.run(sb.base_env.merge('AC_LINT_REPORTER' => 'yaml'))
      expect(status.exitstatus).to eq(0), err
      expect(out).to include('Unknown reporter')
      expect(logged_commands(out)).to eq([lint_all_cmd('yaml', sb.repo)])
      expect(sb.report('swiftlint_result')).to include('--reporter=yaml')
    end
  end

  describe 'AC_LINT_STRICT / AC_LINT_QUIET' do
    it 'missing: adds neither flag' do
      out, _err, status = sb.run
      expect(status.exitstatus).to eq(0)
      expect(logged_commands(out).first).not_to match(/--strict|--quiet/)
    end

    it 'AC_LINT_STRICT=yes: adds --strict' do
      out, _err, status = sb.run(sb.base_env.merge('AC_LINT_STRICT' => 'yes'))
      expect(status.exitstatus).to eq(0)
      expect(logged_commands(out)).to eq([lint_all_cmd('xcode', sb.repo, ' --strict')])
    end

    it 'AC_LINT_QUIET=yes: adds --quiet' do
      out, _err, status = sb.run(sb.base_env.merge('AC_LINT_QUIET' => 'yes'))
      expect(status.exitstatus).to eq(0)
      expect(logged_commands(out)).to eq([lint_all_cmd('xcode', sb.repo, ' --quiet')])
    end

    it 'both yes: adds --strict before --quiet' do
      out, _err, status = sb.run(sb.base_env.merge('AC_LINT_STRICT' => 'yes', 'AC_LINT_QUIET' => 'yes'))
      expect(status.exitstatus).to eq(0)
      expect(logged_commands(out)).to eq([lint_all_cmd('xcode', sb.repo, ' --strict --quiet')])
    end

    %w[no YES true 1].each do |value|
      it "value #{value.inspect}: is not treated as yes" do
        out, _err, status = sb.run(sb.base_env.merge('AC_LINT_STRICT' => value, 'AC_LINT_QUIET' => value))
        expect(status.exitstatus).to eq(0)
        expect(logged_commands(out).first).not_to match(/--strict|--quiet/)
      end
    end

    it 'empty: adds neither flag' do
      out, _err, status = sb.run(sb.base_env.merge('AC_LINT_STRICT' => '', 'AC_LINT_QUIET' => ''))
      expect(status.exitstatus).to eq(0)
      expect(logged_commands(out).first).not_to match(/--strict|--quiet/)
    end
  end

  describe 'AC_LINT_CONFIG' do
    it 'missing: adds no --config' do
      out, _err, status = sb.run
      expect(status.exitstatus).to eq(0)
      expect(logged_commands(out).first).not_to include('--config')
    end

    it 'empty: adds no --config' do
      out, _err, status = sb.run(sb.base_env.merge('AC_LINT_CONFIG' => ''))
      expect(status.exitstatus).to eq(0)
      expect(logged_commands(out).first).not_to include('--config')
    end

    it 'relative: is resolved against the repository directory' do
      out, _err, status = sb.run(sb.base_env.merge('AC_LINT_CONFIG' => '.swiftlint.yml'))
      expect(status.exitstatus).to eq(0)
      cfg = File.join(sb.repo, '.swiftlint.yml')
      expect(logged_commands(out)).to eq([lint_all_cmd('xcode', sb.repo, " --config #{cfg}")])
    end

    it 'relative with ../: is normalised' do
      out, _err, status = sb.run(sb.base_env.merge('AC_LINT_CONFIG' => 'config/../lint/.swiftlint.yml'))
      expect(status.exitstatus).to eq(0)
      expect(logged_commands(out).first).to include("--config #{File.join(sb.repo, 'lint', '.swiftlint.yml')}")
    end

    it 'absolute: is used as-is' do
      cfg = File.join(sb.root, 'shared', '.swiftlint.yml')
      out, _err, status = sb.run(sb.base_env.merge('AC_LINT_CONFIG' => cfg))
      expect(status.exitstatus).to eq(0)
      expect(logged_commands(out)).to eq([lint_all_cmd('xcode', sb.repo, " --config #{cfg}")])
    end

    it 'combined with strict and quiet: flags come first, then --config' do
      out, _err, status = sb.run(sb.base_env.merge(
        'AC_LINT_CONFIG' => '.swiftlint.yml', 'AC_LINT_STRICT' => 'yes', 'AC_LINT_QUIET' => 'yes'
      ))
      expect(status.exitstatus).to eq(0)
      cfg = File.join(sb.repo, '.swiftlint.yml')
      expect(logged_commands(out)).to eq([lint_all_cmd('xcode', sb.repo, " --strict --quiet --config #{cfg}")])
    end
  end

  describe 'AC_LINT_PATH' do
    it 'missing: lints the repository root' do
      out, _err, status = sb.run
      expect(status.exitstatus).to eq(0)
      expect(out).to include('Linting all files')
      expect(logged_commands(out)).to eq([lint_all_cmd('xcode', sb.repo)])
    end

    it 'empty: lints the repository root' do
      out, _err, status = sb.run(sb.base_env.merge('AC_LINT_PATH' => ''))
      expect(status.exitstatus).to eq(0)
      expect(logged_commands(out)).to eq([lint_all_cmd('xcode', sb.repo)])
    end

    it 'relative: is resolved against the repository directory' do
      out, _err, status = sb.run(sb.base_env.merge('AC_LINT_PATH' => 'App/Sources'))
      expect(status.exitstatus).to eq(0)
      expect(logged_commands(out)).to eq([lint_all_cmd('xcode', File.join(sb.repo, 'App', 'Sources'))])
    end

    it 'absolute: is used as-is' do
      abs = File.join(sb.root, 'elsewhere')
      out, _err, status = sb.run(sb.base_env.merge('AC_LINT_PATH' => abs))
      expect(status.exitstatus).to eq(0)
      expect(logged_commands(out)).to eq([lint_all_cmd('xcode', abs)])
    end
  end

  describe 'AC_LINT_RANGE' do
    it 'missing: lints all files' do
      out, _err, status = sb.run
      expect(status.exitstatus).to eq(0)
      expect(out).to include('Linting all files')
      expect(sb.stub_calls('git')).to be_empty
    end

    it 'empty: lints all files' do
      out, _err, status = sb.run(sb.base_env.merge('AC_LINT_RANGE' => ''))
      expect(status.exitstatus).to eq(0)
      expect(out).to include('Linting all files')
      expect(sb.stub_calls('git')).to be_empty
    end

    it 'all: lints all files' do
      out, _err, status = sb.run(sb.base_env.merge('AC_LINT_RANGE' => 'all'))
      expect(status.exitstatus).to eq(0)
      expect(out).to include('Linting all files')
      expect(sb.stub_calls('git')).to be_empty
    end

    context 'changed' do
      let(:env) { sb.base_env.merge('AC_LINT_RANGE' => 'changed') }

      it 'diffs against HEAD^ and lints each changed file separately' do
        out, err, status = sb.run(env.merge('STUB_GIT_CHANGED' => "App/A.swift\nApp/Sub/B.swift"))
        expect(status.exitstatus).to eq(0), err
        expect(out).to include('Linting changed files')
        expect(logged_commands(out)).to eq([
          git_diff_cmd(sb.repo),
          lint_file_cmd('xcode', File.join(sb.repo, 'App/A.swift')),
          lint_file_cmd('xcode', File.join(sb.repo, 'App/Sub/B.swift'))
        ])
      end

      it 'concatenates every per-file result into the report' do
        _out, err, status = sb.run(env.merge('STUB_GIT_CHANGED' => "A.swift\nB.swift"))
        expect(status.exitstatus).to eq(0), err
        expect(sb.report).to eq(
          "LINT-RESULT lint --reporter=xcode #{File.join(sb.repo, 'A.swift')}\n" \
          "LINT-RESULT lint --reporter=xcode #{File.join(sb.repo, 'B.swift')}\n"
        )
      end

      it 'applies strict, quiet and config to every per-file command' do
        out, _err, status = sb.run(env.merge(
          'STUB_GIT_CHANGED' => 'A.swift', 'AC_LINT_STRICT' => 'yes', 'AC_LINT_QUIET' => 'yes',
          'AC_LINT_CONFIG' => '.swiftlint.yml', 'AC_LINT_REPORTER' => 'json'
        ))
        expect(status.exitstatus).to eq(0)
        cfg = File.join(sb.repo, '.swiftlint.yml')
        expect(logged_commands(out).last)
          .to eq(lint_file_cmd('json', File.join(sb.repo, 'A.swift'), " --strict --quiet --config #{cfg}"))
      end

      it 'ignores AC_LINT_PATH' do
        out, _err, status = sb.run(env.merge('STUB_GIT_CHANGED' => 'A.swift', 'AC_LINT_PATH' => 'Other'))
        expect(status.exitstatus).to eq(0)
        expect(logged_commands(out).last).to eq(lint_file_cmd('xcode', File.join(sb.repo, 'A.swift')))
      end

      it 'no changed swift files: runs no swiftlint and writes an empty report' do
        out, err, status = sb.run(env)
        expect(status.exitstatus).to eq(0), err
        expect(logged_commands(out)).to eq([git_diff_cmd(sb.repo)])
        expect(sb.stub_calls('swiftlint')).to be_empty
        expect(sb.report).to eq('')
        expect(sb.env_file_content).to start_with('AC_LINT_OUTPUT_PATH=')
      end
    end

    it 'other value (e.g. CHANGED): falls back to linting all files' do
      out, _err, status = sb.run(sb.base_env.merge('AC_LINT_RANGE' => 'CHANGED'))
      expect(status.exitstatus).to eq(0)
      expect(out).to include('Linting all files')
      expect(sb.stub_calls('git')).to be_empty
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────

RSpec.describe 'SwiftLint installation' do
  let(:sb) { StepSandbox.new }

  after { sb.cleanup }

  it 'skips brew when swiftlint is already on PATH' do
    out, _err, status = sb.run
    expect(status.exitstatus).to eq(0)
    expect(logged_commands(out)).not_to include('brew install swiftlint')
    expect(sb.stub_calls('brew')).to be_empty
  end

  it 'installs swiftlint with brew when it is missing, then lints' do
    out, err, status = sb.run(sb.base_env.merge('STUB_NO_SWIFTLINT' => '1'))
    expect(status.exitstatus).to eq(0), err
    expect(logged_commands(out)).to eq(['brew install swiftlint', lint_all_cmd('xcode', sb.repo)])
    expect(sb.stub_calls('brew').size).to eq(1)
  end
end

# ─────────────────────────────────────────────────────────────────────────────

RSpec.describe 'Command failures' do
  let(:sb) { StepSandbox.new }

  after { sb.cleanup }

  it 'swiftlint violations (non-zero): exits 1 with "Linting failed" and the swiftlint output' do
    _out, err, status = sb.run(sb.base_env.merge('AC_LINT_STRICT' => 'yes', 'STUB_SWIFTLINT_FAIL_ON' => 'lint'))
    expect(status.exitstatus).to eq(1)
    expect(err).to include('Linting failed. Check logs for details')
    expect(err).to include('VIOLATION lint --reporter=xcode --strict')
  end

  it 'swiftlint failure: writes neither the report nor AC_LINT_OUTPUT_PATH' do
    _out, _err, status = sb.run(sb.base_env.merge('STUB_SWIFTLINT_FAIL_ON' => 'lint'))
    expect(status.success?).to be(false)
    expect(sb.report).to be_nil
    expect(sb.env_file_content).to eq('')
  end

  it 'brew install failure: exits 1 and never runs swiftlint' do
    _out, err, status = sb.run(sb.base_env.merge('STUB_NO_SWIFTLINT' => '1', 'STUB_BREW_EXIT' => '1'))
    expect(status.exitstatus).to eq(1)
    expect(err).to include('Error: brew failed')
    expect(sb.stub_calls('swiftlint')).to be_empty
  end

  it 'git diff failure (changed range): exits 1 and never runs swiftlint' do
    _out, err, status = sb.run(sb.base_env.merge('AC_LINT_RANGE' => 'changed', 'STUB_GIT_EXIT' => '128'))
    expect(status.exitstatus).to eq(1)
    expect(err).to include('Linting failed')
    expect(sb.stub_calls('swiftlint')).to be_empty
    expect(sb.report).to be_nil
  end

  it 'changed range: stops at the first failing file' do
    _out, _err, status = sb.run(sb.base_env.merge(
      'AC_LINT_RANGE' => 'changed', 'STUB_GIT_CHANGED' => "A.swift\nBad.swift\nC.swift",
      'STUB_SWIFTLINT_FAIL_ON' => 'Bad.swift'
    ))
    expect(status.exitstatus).to eq(1)
    expect(sb.stub_calls('swiftlint').size).to eq(2)
    expect(sb.stub_calls('swiftlint').join).not_to include('C.swift')
    expect(sb.report).to be_nil
  end

  it 'swiftlint not installed and brew missing: fails non-zero' do
    File.delete(File.join(sb.stub_bin, 'swiftlint'))
    File.delete(File.join(sb.stub_bin, 'brew'))
    # Only the stub dir and system dirs on PATH, so a real swiftlint/brew cannot be found.
    path = [sb.stub_bin, '/usr/bin', '/bin'].join(File::PATH_SEPARATOR)
    _out, err, status = sb.run(sb.base_env.merge('STUB_NO_SWIFTLINT' => '1'), path: path)
    expect(status.success?).to be(false)
    expect(err).to include('No such file or directory')
  end
end

# ─── Coverage Report ──────────────────────────────────────────────────────────
def print_coverage_report
  return unless defined?(Coverage) && Coverage.running?

  result = begin
    Coverage.result(stop: false, clear: false)
  rescue ArgumentError
    Coverage.result
  end

  main_path = result.keys.find { |p| p&.end_with?('main.rb') }
  return puts("\nCoverage: main.rb not found in results") unless main_path

  # Fold in the counts collected from the `ruby main.rb` subprocesses so the
  # guarded top-level block is not reported as dead code.
  child     = subprocess_coverage
  data      = result[main_path].each_with_index.map do |count, idx|
    count.nil? ? nil : count + (child[idx] || 0)
  end
  lines     = data.each_with_index.reject { |c, _| c.nil? }
  total     = lines.size
  covered   = lines.count { |c, _| c.to_i > 0 }
  pct       = total.positive? ? (covered * 100.0 / total).round(1) : 100.0
  uncovered = lines.select { |c, _| c.to_i == 0 }.map { |_, i| i + 1 }

  color = pct == 100 ? "\e[32;1m" : pct >= 80 ? "\e[33m" : "\e[31m"
  bar_filled = (pct / 5).round
  bar = "\e[32m" + '█' * bar_filled + "\e[90m" + '░' * (20 - bar_filled) + "\e[0m"

  puts "\n\e[90m#{'═' * 72}\e[0m"
  puts '  Coverage Report'
  puts "\e[90m#{'─' * 72}\e[0m"
  puts "  main.rb  #{bar}  #{color}#{pct}%\e[0m  (#{covered}/#{total} lines)"
  if uncovered.any? && uncovered.size <= 20
    puts "  Uncovered lines: \e[90m#{uncovered.join(', ')}\e[0m"
  elsif uncovered.any?
    puts "  Uncovered lines: \e[90m#{uncovered.first(15).join(', ')} … (+#{uncovered.size - 15} more)\e[0m"
  end
  puts "  \e[90mMerged from the in-process function tests and the `ruby main.rb`"
  puts "  ENV validation / failure subprocesses.\e[0m"
  puts "\e[90m#{'═' * 72}\e[0m"
end

# ─── Runner ───────────────────────────────────────────────────────────────────
if __FILE__ == $PROGRAM_NAME
  RSpec.configure do |config|
    config.add_formatter ReadableFormatter
    config.color        = true
    config.order        = :defined
  end

  exit_code = RSpec::Core::Runner.run(['--order', 'defined'])
  print_coverage_report
  FileUtils.rm_rf(COVERAGE_DIR)
  exit exit_code
end
