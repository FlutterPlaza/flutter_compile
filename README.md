## flutter_compile

![coverage][coverage_badge]
[![style: very good analysis][very_good_analysis_badge]][very_good_analysis_link]
[![License: BSD-3][license_badge]][license_link]

A Dart CLI to simplify compiling and setting up the Flutter framework development environment. This tool automates the steps required and make it easy to switch between default flutter installation and the Compiled flutter installation.

---

## Getting Started 🚀

If the CLI application is available on [pub](https://pub.dev), activate globally via:

```sh
dart pub global activate flutter_compile
```

Or locally via:

```sh
dart pub global activate --source=path <path to this package>
```

## Usage

```sh
# Set up the Flutter development environment
$ flutter_compile install

# Switch between normal Flutter installation and compiled Flutter installation
$ flutter_compile switch

# Show CLI version
$ flutter_compile --version

# Show usage help
$ flutter_compile --help
```

## Running Tests with coverage 🧪

To run all unit tests use the following command:

```sh
dart pub global activate coverage 1.2.0
dart test --coverage=coverage
dart pub global run coverage:format_coverage --lcov --in=coverage --out=coverage/lcov.info
```

To view the generated coverage report you can use [coverage](https://github.com/linux-test-project/lcov).

```sh
# Generate Coverage Report
$ genhtml coverage/lcov.info -o coverage/

# Open Coverage Report
$ open coverage/index.html
```

---

[coverage_badge]: https://github.com/FlutterPlaza/flutter_compile/actions/workflows/main.yaml/badge.svg
[license_badge]: https://img.shields.io/badge/license-BSD--3-blue.svg
[license_link]: https://opensource.org/licenses/BSD-3
[very_good_analysis_badge]: https://img.shields.io/badge/style-very_good_analysis-B22C89.svg
[very_good_analysis_link]: https://pub.dev/packages/very_good_analysis
[very_good_cli_link]: https://github.com/VeryGoodOpenSource/very_good_cli
