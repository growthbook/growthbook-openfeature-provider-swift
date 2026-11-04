# Contributing Guide

We welcome all contributions!

This repo is the [OpenFeature](https://openfeature.dev) provider for the
[GrowthBook Swift SDK](https://github.com/growthbook/growthbook-swift). Flag
evaluation lives in the GrowthBook SDK; this package maps OpenFeature context,
types, events and errors onto it.

## Requirements

- **Xcode 16.3 or later**, selected as the developer directory. OpenFeature
  Swift 0.7 needs Swift 6.1.
- `xcode-select -p` must print a path inside `Xcode.app`. The standalone
  Command Line Tools ship no XCTest, so `swift test` fails with
  `no such module 'XCTest'`.

## Getting started

```sh
git clone git@github.com:growthbook/growthbook-openfeature-provider-swift.git
cd growthbook-openfeature-provider-swift
swift build
swift test
```

## Writing code

- **Dependencies:** `growthbook-swift` 2.x and OpenFeature Swift 0.7.x. Use only
  the GrowthBook SDK's public API. If the provider needs a change in the SDK,
  make it in `growthbook-swift` first and raise the minimum version here.
- **Platforms:** iOS 15, macOS 12, tvOS 15, watchOS 8 and visionOS 1, which are
  OpenFeature's minimums. `swift test` only covers macOS, so CI also builds for
  the other platforms.
- **Behavior:** match the
  [GrowthBook JS OpenFeature provider](https://github.com/open-feature/js-sdk-contrib/tree/main/libs/providers/growthbook-client)
  unless there is a reason not to, and call out any difference in the PR.
- **Style:** no linter is configured. Match the surrounding code: 4-space
  indentation, `camelCase`, and `///` doc comments on declarations.

## Opening pull requests

1. Branch from `main`.
2. Run `swift build` and `swift test`.
3. Use conventional-commit subjects (`fix:`, `feat:`, `test:`).
4. Open the PR against `main` and describe what changed and how to verify it.

## Releasing

Maintainers release by tagging `main` with a semver version (for example
`0.2.0`) and creating a GitHub release. SwiftPM consumes the tag directly; there
is nothing to publish.

## Getting help

- [Slack community](https://slack.growthbook.io?ref=contributing)
- [Open an issue](https://github.com/growthbook/growthbook-openfeature-provider-swift/issues)

Found a security vulnerability? Email security@growthbook.io — **don't file a
public issue**. See the [security
policy](https://github.com/growthbook/growthbook/blob/main/SECURITY.md).

Contributors are expected to follow the [Code of
Conduct](https://github.com/growthbook/growthbook/blob/main/CODE_OF_CONDUCT.md).
