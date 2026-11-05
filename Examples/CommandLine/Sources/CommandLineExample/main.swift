import Foundation
import GrowthBook
import GrowthBookOpenFeature
import OpenFeature

/// Features used when no client key is given, so the example runs offline.
let bundledFeatures = """
{
    "welcome-message": {
        "defaultValue": "Hello!",
        "rules": [{"condition": {"country": "CA"}, "force": "Bonjour!"}]
    },
    "dark-mode": {"defaultValue": false},
    "max-items": {"defaultValue": 10},
    "checkout-layout": {
        "defaultValue": "classic",
        "rules": [{
            "key": "checkout-layout",
            "variations": ["classic", "compact"],
            "weights": [0.5, 0.5],
            "coverage": 1,
            "hashAttribute": "id"
        }]
    }
}
"""

let environment = ProcessInfo.processInfo.environment
// Set GB_CLIENT_KEY to fetch live features; GB_API_HOST defaults to GrowthBook Cloud.
let clientKey = environment["GB_CLIENT_KEY"]

let configuration = GrowthBookModel(
    apiHost: environment["GB_API_HOST"] ?? "https://cdn.growthbook.io",
    clientKey: clientKey,
    features: clientKey == nil ? Data(bundledFeatures.utf8) : nil,
    trackingClosure: { experiment, result in
        print("  [exposure] \(experiment.key) -> variation \(result.variationId)")
    }
)

let provider = try GrowthBookOpenFeatureProvider(configuration: configuration)
await OpenFeatureAPI.shared.setProviderAndWait(
    provider: provider,
    initialContext: ImmutableContext(
        targetingKey: "user-123",
        structure: ImmutableStructure(attributes: ["country": .string("CA")])
    )
)

let client = OpenFeatureAPI.shared.getClient()
print(clientKey == nil ? "Using bundled features" : "Using features from \(configuration.apiHost ?? "")")

if clientKey == nil {
    print("welcome-message: \(client.getStringValue(key: "welcome-message", defaultValue: "Hi"))")
    print("dark-mode: \(client.getBooleanValue(key: "dark-mode", defaultValue: true))")
    print("max-items: \(client.getIntegerValue(key: "max-items", defaultValue: 0))")

    let layout = client.getStringDetails(key: "checkout-layout", defaultValue: "classic")
    print("checkout-layout: \(layout.value) (reason: \(layout.reason ?? "none"), variant: \(layout.variant ?? "none"))")
} else {
    // With live features, pass flag keys as arguments: swift run CommandLineExample my-flag other-flag
    for key in CommandLine.arguments.dropFirst() {
        let details = client.getObjectDetails(key: key, defaultValue: .null)
        print("\(key): \(details.value) (reason: \(details.reason ?? "none"))")
    }
}

provider.close()
