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