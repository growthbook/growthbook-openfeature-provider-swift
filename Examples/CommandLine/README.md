# Command-line example

A small macOS program that evaluates GrowthBook flags through the OpenFeature Swift SDK, using the provider from this repo.

Run it offline with bundled features:

```sh
cd Examples/CommandLine
swift run
```

Or fetch live features from GrowthBook and evaluate the flags you name:

```sh
GB_CLIENT_KEY=sdk-abc123 swift run CommandLineExample my-flag other-flag
```

Set `GB_API_HOST` to use a self-hosted GrowthBook instead of `https://cdn.growthbook.io`.

The example depends on the provider by path; apps depend on the released package instead.
