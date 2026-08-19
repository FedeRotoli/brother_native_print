# Contributing to brother_native_print

Thanks for taking the time to contribute! 🎉

## Code of conduct

Be respectful and constructive. Harassment or offensive behavior will not be
tolerated.

## How to contribute

- **Report a bug** – open an
  [issue](https://github.com/FedeRotoli/brother_native_print/issues) with a
  clear description, the affected platform (Android/iOS), the printer model
  and the steps to reproduce.
- **Request a feature** – open an issue describing the use case and the
  desired behavior.
- **Submit code** – fork the repository, create a feature branch and open a
  [pull request](https://github.com/FedeRotoli/brother_native_print/pulls).

## Development setup

```sh
flutter pub get
cd example && flutter pub get && cd ..
```

Run the analysis and the tests before opening a pull request:

```sh
flutter analyze
flutter test
```

For the example app you can also run the integration test on a real device:

```sh
cd example
flutter test integration_test
```

## Project layout

```
lib/                      Dart API (public surface + method channel)
android/                  Android implementation (Kotlin)
ios/brother_native_print  iOS implementation (Swift, SPM package)
example/                  Demo app
custom_paper/             Custom paper .bin definitions for supported printers
```

## Pull request checklist

- [ ] `flutter analyze` passes with no issues.
- [ ] `flutter test` passes.
- [ ] New public API is documented with `///` doc comments.
- [ ] User-facing strings are in English.
- [ ] CHANGELOG.md is updated under "Unreleased" or a new version heading.

## Publishing

Maintainers: bump the version in `pubspec.yaml`, update `CHANGELOG.md`, then:

```sh
flutter pub publish --dry-run
flutter pub publish
```

## License

By contributing you agree that your contributions will be licensed under the
[MIT License](LICENSE).
