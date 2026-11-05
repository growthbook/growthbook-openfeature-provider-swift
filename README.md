# GrowthBook OpenFeature Provider for Swift

An [OpenFeature](https://openfeature.dev) provider for the [OpenFeature Swift SDK](https://github.com/open-feature/swift-sdk), backed by the [GrowthBook Swift SDK](https://github.com/growthbook/growthbook-swift).

## Requirements

- Xcode 16.3 or later
- iOS 15, macOS 12, tvOS 15, watchOS 8 or visionOS 1

## Installation

Add the package with Swift Package Manager:

```swift
.package(url: "https://github.com/growthbook/growthbook-openfeature-provider-swift.git", from: "0.1.0")
```

Then add the product to your target:

```swift
.product(name: "GrowthBookOpenFeature", package: "growthbook-openfeature-provider-swift")
```

## Usage

The provider creates and owns its GrowthBook SDK instance from a `GrowthBookModel`:

```swift
import GrowthBook
import GrowthBookOpenFeature
import OpenFeature

let provider = try GrowthBookOpenFeatureProvider(
    configuration: GrowthBookModel(
        apiHost: "https://cdn.growthbook.io",
        clientKey: "sdk-abc123",
        trackingClosure: { experiment, result in
            // Send the experiment exposure to your analytics tool
        }
    )
)

await OpenFeatureAPI.shared.setProviderAndWait(
    provider: provider,
    initialContext: ImmutableContext(targetingKey: "user-123")
)

let client = OpenFeatureAPI.shared.getClient()
let enabled = client.getBooleanValue(key: "new-checkout", defaultValue: false)
```

- **Context:** OpenFeature context attributes become GrowthBook attributes, and `targetingKey` becomes the `id` attribute. When the context has both, `identityPrecedence` decides which wins (`.targetingKey` by default, or `.idAttribute`). Each context change replaces all attributes. A non-empty initial context replaces the attributes in the `GrowthBookModel`; an empty one keeps them.
- **Readiness:** the provider is ready immediately when features are supplied or cached. Otherwise it waits for the first fetch, up to `initializationTimeout` (10 seconds by default), and reports an error if no features loaded. Evaluations return the caller's default until features are available.
- **Updates:** feature refreshes and streaming updates emit a configuration-changed event when flags change. A failed refresh keeps serving the last features and reports the provider as stale.
- **Values:** values are never converted between types. Integer flags must hold whole numbers, and a `null` flag value returns the caller's default.
- **Tracking:** experiment exposures are reported through `trackingClosure` and plugins, as with the GrowthBook SDK.
- **Not supported yet:** remote evaluation and sticky bucketing. The provider throws `GrowthBookOpenFeatureProviderError` if either is configured.
- **Shutdown:** OpenFeature Swift does not shut providers down. Call `provider.close()` before clearing or replacing the provider.

## Example

[`Examples/CommandLine`](Examples/CommandLine) is a small macOS program that evaluates flags through the provider. It runs offline with bundled features, or against GrowthBook with a client key.

## License

MIT. See [LICENSE](LICENSE).
