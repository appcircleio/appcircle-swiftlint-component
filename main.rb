
require 'pathname'
require 'fileutils'

def get_env_variable(key)
  ENV[key].nil? || ENV[key] == '' ? nil : ENV[key]
end

def run_command(cmd)
  puts "@@[command] #{cmd}"
  output = `#{cmd}`
  raise "Linting failed. Check logs for details \n\n #{output}" unless $CHILD_STATUS.success?

  output
end

repository_path = get_env_variable('AC_REPOSITORY_DIR') || abort('Missing repo path.')
lint_path = get_env_variable('AC_LINT_PATH') || '.'
lint_range = get_env_variable('AC_LINT_RANGE')
lint_config = get_env_variable('AC_LINT_CONFIG')
lint_reporter = get_env_variable('AC_LINT_REPORTER')
lint_strict = get_env_variable('AC_LINT_STRICT')
lint_quiet = get_env_variable('AC_LINT_QUIET')
output_path = get_env_variable('AC_OUTPUT_DIR')

report_file = 'swiftlint_result'
case lint_reporter
when 'xcode', 'emoji', 'github-actions-logging'
  report_file += '.txt'
when 'markdown'
  report_file += '.md'
when 'csv', 'html'
  report_file += ".#{lint_reporter}"
when 'checkstyle', 'junit'
  report_file += '.xml'
when 'json', 'sonarqube'
  report_file += '.json'
else
  puts 'Unknown reporter'
end

cmd_line = ''
cmd_line += ' --strict' if lint_strict == 'yes'
cmd_line += ' --quiet' if lint_quiet == 'yes'

unless lint_config.nil?
  config_file = if Pathname.new(lint_config.to_s).absolute?
                  lint_config
                else
                  File.expand_path(File.join(repository_path, lint_config))
                end
  cmd_line += " --config #{config_file}"
end

swift_lint_result = ''

if lint_range == 'changed'
  puts 'Linting changed files'
  git_command = "git -C #{repository_path} diff HEAD^ --name-only --diff-filter=d -- '*.swift'"
  changed_files = run_command(git_command)
  changed_files.each_line do |file|
    swift_file = File.join(repository_path, file.strip)
    swift_lint_result += run_command("swiftlint lint --reporter=#{lint_reporter} #{cmd_line} '#{swift_file}' ")
  end
else
  puts 'Linting all files'
  swift_files_path = if Pathname.new(lint_path.to_s).absolute?
                       lint_path
                     else
                       File.expand_path(File.join(repository_path, lint_path))
                     end
  swift_lint_result = run_command("swiftlint lint --reporter=#{lint_reporter} #{cmd_line} '#{swift_files_path}'")
end

report_path = File.join(output_path, report_file)

File.open(report_path, 'w') do |f|
  f.write(swift_lint_result)
end

# #Write Environment Variable
File.open(ENV['AC_ENV_FILE_PATH'], 'a') do |f|
  f.puts "AC_LINT_OUTPUT_PATH=#{report_path}"
end

exit 0
