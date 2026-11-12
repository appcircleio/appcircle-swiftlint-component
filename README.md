# Appcircle SwiftLint Component

Installs [SwiftLint](https://github.com/realm/SwiftLint) and runs it according to given options. 

Required Input Variables
- `$AC_LINT_PATH`: Specifies the path to lint
- `$AC_LINT_RANGE` You can lint all files or take the git diff and only lint those files
- `$AC_LINT_CONFIG` Specifies linting configuration file. For example : /.swiftlint.yml
- `$AC_LINT_REPORTER` The custom reporter to use
- `$AC_LINT_STRICT` Use strict mode for linting. This will fail the build if linting fails.
- `$AC_LINT_QUIET` Don't print status logs like 'Linting ' & 'Done linting'.

Output Variable
- `$AC_LINT_OUTPUT_PATH`: The path of the output file.

## Running tests

Requires the [RSpec](https://rspec.info) gem and the Ruby standard library (Coverage). No Gemfile or Bundler needed.

```bash
ruby test/test_main.rb
```

A coverage report is printed at the end of each run. The tests never run the real `swiftlint`, `brew` or `git`: stub executables are put first on `PATH` inside a temporary directory.
