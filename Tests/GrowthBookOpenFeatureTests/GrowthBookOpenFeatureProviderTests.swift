import Combine
import GrowthBook
import OpenFeature
import XCTest

@testable import GrowthBookOpenFeature

final class GrowthBookOpenFeatureProviderTests: XCTestCase {
    private var cancellables: Set<AnyCancellable> = []
    private var providers: [GrowthBookOpenFeatureProvider] = []

    override func tearDown() {
        providers.forEach { $0.close() }
        providers = []
        cancellables = []
        super.tearDown()
    }

    // MARK: - Typed evaluation

    func testTypedEvaluations() async throws {
        let client = try await makeClient(features: Payloads.features)

        XCTAssertEqual(client.getDetails(key: "bool-flag", defaultValue: false).value, true)
        XCTAssertEqual(client.getDetails(key: "string-flag", defaultValue: "").value, "hello")
        XCTAssertEqual(client.getDetails(key: "int-flag", defaultValue: Int64(0)).value, 42)
        XCTAssertEqual(client.getDetails(key: "int-flag", defaultValue: 0.0).value, 42.0)
        XCTAssertEqual(client.getDetails(key: "fraction-flag", defaultValue: 0.0).value, 1.5)

        let details = client.getDetails(key: "string-flag", defaultValue: "")
        XCTAssertNil(details.errorCode)
        XCTAssertEqual(details.reason, Reason.defaultReason.rawValue)
    }

    func testObjectEvaluationPreservesNestedValues() async throws {
        let client = try await makeClient(features: Payloads.features)

        let value = client.getDetails(key: "json-flag", defaultValue: Value.null).value
        XCTAssertEqual(
            value,
            .structure([
                "list": .list([.integer(1), .null, .structure(["nested": .string("yes")])]),
                "ratio": .double(0.5),
            ])
        )
    }

    func testIntegerRejectsFractionsAndOutOfRangeValues() async throws {
        let client = try await makeClient(features: Payloads.features)

        let fraction = client.getDetails(key: "fraction-flag", defaultValue: Int64(7))
        XCTAssertEqual(fraction.value, 7)
        XCTAssertEqual(fraction.errorCode, .typeMismatch)

        let tooBig = client.getDetails(key: "big-flag", defaultValue: Int64(7))
        XCTAssertEqual(tooBig.value, 7)
        XCTAssertEqual(tooBig.errorCode, .typeMismatch)
    }

    func testTypeMismatchReturnsDefault() async throws {
        let client = try await makeClient(features: Payloads.features)

        let details = client.getDetails(key: "string-flag", defaultValue: true)
        XCTAssertEqual(details.value, true)
        XCTAssertEqual(details.errorCode, .typeMismatch)

        // No truthiness: a number is not a boolean.
        XCTAssertEqual(client.getDetails(key: "int-flag", defaultValue: false).errorCode, .typeMismatch)
    }

    func testTopLevelNullReturnsDefault() async throws {
        let client = try await makeClient(features: Payloads.features)

        let details = client.getDetails(key: "null-flag", defaultValue: "fallback")
        XCTAssertEqual(details.value, "fallback")
        XCTAssertNil(details.errorCode)
        XCTAssertEqual(details.reason, Reason.defaultReason.rawValue)
    }

    func testMissingFlagReturnsFlagNotFound() async throws {
        let client = try await makeClient(features: Payloads.features)

        let details = client.getDetails(key: "missing", defaultValue: "fallback")
        XCTAssertEqual(details.value, "fallback")
        XCTAssertEqual(details.errorCode, .flagNotFound)
    }

    func testCyclicPrerequisiteReturnsParseError() async throws {
        let client = try await makeClient(features: Payloads.features)

        XCTAssertEqual(client.getDetails(key: "cyclic-flag", defaultValue: false).errorCode, .parseError)
    }

    // MARK: - Targeting and identity

    func testTargetingKeyBecomesId() async throws {
        let client = try await makeClient(
            features: Payloads.features,
            context: ImmutableContext(targetingKey: "user-1")
        )

        let details = client.getDetails(key: "id-flag", defaultValue: "")
        XCTAssertEqual(details.value, "matched")
        XCTAssertEqual(details.reason, Reason.targetingMatch.rawValue)
    }

    func testTargetingKeyWinsByDefault() async throws {
        let client = try await makeClient(
            features: Payloads.features,
            context: ImmutableContext(targetingKey: "user-1").withAttribute(key: "id", value: .string("other"))
        )

        XCTAssertEqual(client.getDetails(key: "id-flag", defaultValue: "").value, "matched")
    }

    func testIdAttributeWinsWhenConfigured() async throws {
        let client = try await makeClient(
            features: Payloads.features,
            identityPrecedence: .idAttribute,
            context: ImmutableContext(targetingKey: "other").withAttribute(key: "id", value: .string("user-1"))
        )

        XCTAssertEqual(client.getDetails(key: "id-flag", defaultValue: "").value, "matched")
    }

    func testTargetingKeyFillsMissingIdWhenIdAttributeWins() async throws {
        let client = try await makeClient(
            features: Payloads.features,
            identityPrecedence: .idAttribute,
            context: ImmutableContext(targetingKey: "user-1").withAttribute(key: "id", value: .null)
        )

        XCTAssertEqual(client.getDetails(key: "id-flag", defaultValue: "").value, "matched")
    }

    func testEmptyContextKeepsConfiguredAttributes() async throws {
        let client = try await makeClient(features: Payloads.features, attributes: ["country": "CA"])

        XCTAssertEqual(client.getDetails(key: "country-flag", defaultValue: "").value, "ca")
    }

    func testInitialContextReplacesConfiguredAttributes() async throws {
        let client = try await makeClient(
            features: Payloads.features,
            attributes: ["country": "CA"],
            context: ImmutableContext(targetingKey: "user-1")
        )

        XCTAssertEqual(client.getDetails(key: "country-flag", defaultValue: "").value, "default")
    }

    func testDateContextValuesBecomeIsoStrings() {
        let date = Date(timeIntervalSince1970: 0)
        XCTAssertEqual(ValueConversion.attribute(from: .date(date)) as? String, "1970-01-01T00:00:00.000Z")
    }

    // MARK: - Context changes

    func testContextChangesReplaceAttributes() async throws {
        let api = OpenFeatureAPI()
        let client = try await makeClient(api: api, features: Payloads.features, context: ImmutableContext(targetingKey: "user-1"))
        XCTAssertEqual(client.getDetails(key: "id-flag", defaultValue: "").value, "matched")

        await api.setEvaluationContextAndWait(evaluationContext: ImmutableContext(targetingKey: "user-2"))
        XCTAssertEqual(client.getDetails(key: "id-flag", defaultValue: "").value, "default")

        await api.setEvaluationContextAndWait(
            evaluationContext: ImmutableContext(attributes: ["country": .string("CA")])
        )
        XCTAssertEqual(client.getDetails(key: "id-flag", defaultValue: "").value, "default")
        XCTAssertEqual(client.getDetails(key: "country-flag", defaultValue: "").value, "ca")

        // Logout drops the previous user's attributes.
        await api.setEvaluationContextAndWait(evaluationContext: ImmutableContext())
        XCTAssertEqual(client.getDetails(key: "country-flag", defaultValue: "").value, "default")
    }

    func testEvaluationAppliesContextBeforeProviderIsNotified() throws {
        let provider = try makeProvider(features: Payloads.features)
        wait(for: provider.initialize(initialContext: ImmutableContext(targetingKey: "user-1")))

        let result = try provider.getStringEvaluation(
            key: "id-flag", defaultValue: "", context: ImmutableContext(targetingKey: "user-2"))
        XCTAssertEqual(result.value, "default")
    }

    func testContextChangeEmitsContextChanged() async throws {
        let api = OpenFeatureAPI()
        let provider = try makeProvider(features: Payloads.features)
        await api.setProviderAndWait(provider: provider, initialContext: ImmutableContext(targetingKey: "user-1"))

        let changed = expectation(description: "context changed")
        provider.observe()
            .sink { if case .contextChanged = $0 { changed.fulfill() } }
            .store(in: &cancellables)

        await api.setEvaluationContextAndWait(evaluationContext: ImmutableContext(targetingKey: "user-2"))
        await fulfillment(of: [changed], timeout: 2)
        XCTAssertEqual(provider.status, .ready)
    }

    func testContextChangeKeepsStaleStatus() async throws {
        let api = OpenFeatureAPI()
        let network = MockNetwork(response: Payloads.featuresResponse)
        let provider = try makeProvider(network: network, ttlSeconds: 0)
        await api.setProviderAndWait(provider: provider)

        let stale = expectation(description: "stale")
        var contextChanges = 0
        provider.observe()
            .sink { event in
                switch event {
                case .stale: stale.fulfill()
                case .contextChanged: contextChanges += 1
                default: break
                }
            }
            .store(in: &cancellables)
        network.response = nil
        try provider.refreshForTesting()
        await fulfillment(of: [stale], timeout: 2)

        await api.setEvaluationContextAndWait(evaluationContext: ImmutableContext(targetingKey: "user-2"))
        XCTAssertEqual(contextChanges, 0)
        XCTAssertEqual(provider.status, .stale)
    }

    // MARK: - Experiments

    func testExperimentReportsVariantAndTracksExposureOnce() async throws {
        var exposures: [String] = []
        let client = try await makeClient(
            features: Payloads.features,
            context: ImmutableContext(targetingKey: "user-1"),
            trackingClosure: { experiment, _ in exposures.append(experiment.key) }
        )

        let details = client.getDetails(key: "experiment-flag", defaultValue: "")
        XCTAssertEqual(details.value, "treatment")
        XCTAssertEqual(details.variant, "1")
        XCTAssertEqual(details.reason, Reason.split.rawValue)
        XCTAssertEqual(exposures, ["experiment-flag"])
    }

    func testTrackingClosureRunsAfterTheProviderLockIsReleased() async throws {
        var otherThreadFinished = false
        var client: Client?
        client = try await makeClient(
            features: Payloads.features,
            // The SDK reports each user's exposure once per process, so use a user no other test tracks.
            context: ImmutableContext(targetingKey: "lock-test-user"),
            trackingClosure: { _, _ in
                // Waiting on another thread that evaluates a flag deadlocks if the closure runs under the lock.
                let done = DispatchSemaphore(value: 0)
                DispatchQueue.global().async {
                    _ = client?.getDetails(key: "string-flag", defaultValue: "")
                    done.signal()
                }
                otherThreadFinished = done.wait(timeout: .now() + 2) == .success
            }
        )

        XCTAssertEqual(client?.getDetails(key: "experiment-flag", defaultValue: "").value, "treatment")
        XCTAssertTrue(otherThreadFinished)
    }

    // MARK: - Initialization

    func testFetchedFeaturesMakeProviderReady() async throws {
        let network = MockNetwork(response: Payloads.featuresResponse)
        let client = try await makeClient(network: network)

        XCTAssertEqual(client.getDetails(key: "string-flag", defaultValue: "").value, "hello")
    }

    func testFetchedEmptyPayloadMakesProviderReady() async throws {
        let api = OpenFeatureAPI()
        let network = MockNetwork(response: #"{"features": {}}"#)
        _ = try await makeClient(api: api, network: network)

        XCTAssertEqual(api.getProviderStatus(), .ready)
    }

    func testCachedFeaturesMakeProviderReadyImmediately() async throws {
        let cache = MemoryCache()
        cache.saveContent(fileName: "FeatureCache", content: Data(Payloads.featuresMap.utf8))
        let network = MockNetwork(response: nil)
        let client = try await makeClient(network: network, cache: cache)

        XCTAssertEqual(client.getDetails(key: "string-flag", defaultValue: "").value, "hello")
    }

    func testFailedFetchWithoutDataReportsError() async throws {
        let api = OpenFeatureAPI()
        let network = MockNetwork(response: nil)
        let client = try await makeClient(api: api, network: network)

        XCTAssertEqual(api.getProviderStatus(), .error)
        let details = client.getDetails(key: "string-flag", defaultValue: "fallback")
        XCTAssertEqual(details.value, "fallback")
        XCTAssertEqual(details.errorCode, .providerNotReady)
    }

    func testInitializationTimesOut() async throws {
        let api = OpenFeatureAPI()
        let network = MockNetwork(response: nil, respond: false)
        _ = try await makeClient(api: api, network: network, initializationTimeout: 0.1)

        XCTAssertEqual(api.getProviderStatus(), .error)
    }

    func testEncryptedPayload() async throws {
        let client = try await makeClient(
            features: Payloads.encryptedFeatures,
            encryptionKey: Payloads.encryptionKey
        )

        XCTAssertEqual(client.getDetails(key: "greeting", defaultValue: "").value, "hello")
    }

    // MARK: - Updates

    func testRefreshEmitsConfigurationChangedOnlyForRealChanges() async throws {
        let api = OpenFeatureAPI()
        let network = MockNetwork(response: Payloads.featuresResponse)
        let provider = try makeProvider(network: network, ttlSeconds: 0)
        await api.setProviderAndWait(provider: provider)

        var changes: [[String]] = []
        let received = expectation(description: "configuration changed")
        provider.observe()
            .sink { event in
                if case .configurationChanged(let details) = event {
                    changes.append(details?.flagsChanged ?? [])
                    received.fulfill()
                }
            }
            .store(in: &cancellables)

        // Same payload: no event.
        try provider.refreshForTesting()
        network.response = #"{"features": {"string-flag": {"defaultValue": "updated"}}}"#
        try provider.refreshForTesting()

        await fulfillment(of: [received], timeout: 2)
        XCTAssertEqual(changes.count, 1)
        XCTAssertTrue(changes[0].contains("string-flag"))
        XCTAssertEqual(api.getClient().getDetails(key: "string-flag", defaultValue: "").value, "updated")
    }

    func testRefreshFailureKeepsServingFlags() async throws {
        let api = OpenFeatureAPI()
        let network = MockNetwork(response: Payloads.featuresResponse)
        let provider = try makeProvider(network: network, ttlSeconds: 0)
        await api.setProviderAndWait(provider: provider)

        let stale = expectation(description: "stale")
        provider.observe()
            .sink { if case .stale = $0 { stale.fulfill() } }
            .store(in: &cancellables)

        network.response = nil
        try provider.refreshForTesting()

        await fulfillment(of: [stale], timeout: 2)
        XCTAssertEqual(api.getClient().getDetails(key: "string-flag", defaultValue: "").value, "hello")
    }

    // MARK: - Configuration and shutdown

    func testRejectsRemoteEval() {
        let model = GrowthBookModel(features: Data(Payloads.features.utf8), remoteEval: true)
        XCTAssertThrowsError(try GrowthBookOpenFeatureProvider(configuration: model)) { error in
            XCTAssertEqual(error as? GrowthBookOpenFeatureProviderError, .remoteEvalUnsupported)
        }
    }

    func testRejectsStickyBucketing() {
        let model = GrowthBookModel(features: Data(Payloads.features.utf8), stickyBucketService: StickyBucketService())
        XCTAssertThrowsError(try GrowthBookOpenFeatureProvider(configuration: model)) { error in
            XCTAssertEqual(error as? GrowthBookOpenFeatureProviderError, .stickyBucketingUnsupported)
        }
    }

    func testCloseStopsEvaluation() async throws {
        let api = OpenFeatureAPI()
        let provider = try makeProvider(features: Payloads.features)
        await api.setProviderAndWait(provider: provider)

        provider.close()
        provider.close()

        let details = api.getClient().getDetails(key: "string-flag", defaultValue: "fallback")
        XCTAssertEqual(details.value, "fallback")
        XCTAssertEqual(details.errorCode, .providerFatal)
        XCTAssertEqual(provider.status, .fatal)
    }

    func testMetadataName() throws {
        XCTAssertEqual(try makeProvider(features: Payloads.features).metadata.name, "GrowthBook")
    }

    // MARK: - Helpers

    private func makeProvider(
        features: String? = nil,
        attributes: [String: Any] = [:],
        encryptionKey: String? = nil,
        identityPrecedence: IdentityPrecedence = .targetingKey,
        network: MockNetwork = MockNetwork(response: nil),
        cache: MemoryCache = MemoryCache(),
        initializationTimeout: TimeInterval = 2,
        ttlSeconds: Int = 60,
        trackingClosure: @escaping TrackingCallback = { _, _ in }
    ) throws -> GrowthBookOpenFeatureProvider {
        let model = GrowthBookModel(
            apiHost: "https://example.test",
            clientKey: "sdk-test",
            encryptionKey: encryptionKey,
            features: features.map { Data($0.utf8) },
            attributes: JSON(attributes),
            trackingClosure: trackingClosure
        )
        let provider = try GrowthBookOpenFeatureProvider(
            configuration: model,
            identityPrecedence: identityPrecedence,
            initializationTimeout: initializationTimeout,
            networkDispatcher: network,
            cachingManager: cache,
            ttlSeconds: ttlSeconds
        )
        providers.append(provider)
        return provider
    }

    private func makeClient(
        api: OpenFeatureAPI = OpenFeatureAPI(),
        features: String? = nil,
        attributes: [String: Any] = [:],
        encryptionKey: String? = nil,
        identityPrecedence: IdentityPrecedence = .targetingKey,
        context: EvaluationContext? = nil,
        network: MockNetwork = MockNetwork(response: nil),
        cache: MemoryCache = MemoryCache(),
        initializationTimeout: TimeInterval = 2,
        trackingClosure: @escaping TrackingCallback = { _, _ in }
    ) async throws -> Client {
        let provider = try makeProvider(
            features: features,
            attributes: attributes,
            encryptionKey: encryptionKey,
            identityPrecedence: identityPrecedence,
            network: network,
            cache: cache,
            initializationTimeout: initializationTimeout,
            trackingClosure: trackingClosure
        )
        await api.setProviderAndWait(provider: provider, initialContext: context)
        return api.getClient()
    }

    private func wait(for future: Future<Void, Never>) {
        let done = expectation(description: "future")
        future.sink { _ in done.fulfill() }.store(in: &cancellables)
        wait(for: [done], timeout: 2)
    }
}

extension GrowthBookOpenFeatureProvider {
    /// Triggers a feature fetch on the owned SDK.
    func refreshForTesting() throws {
        try XCTUnwrap(sdk).refreshCache()
    }
}

/// Network double that serves a fixed response, fails, or never answers.
final class MockNetwork: NetworkProtocol, @unchecked Sendable {
    var response: String?
    private let respond: Bool

    init(response: String?, respond: Bool = true) {
        self.response = response
        self.respond = respond
    }

    func consumeGETRequest(url: String, successResult: @escaping (Data) -> Void, errorResult: @escaping (Error) -> Void) {
        guard respond else { return }
        if let response {
            successResult(Data(response.utf8))
        } else {
            errorResult(URLError(.notConnectedToInternet))
        }
    }

    func consumePOSTRequest(url: String, params: [String: Any], successResult: @escaping (Data) -> Void, errorResult: @escaping (Error) -> Void) {
        consumeGETRequest(url: url, successResult: successResult, errorResult: errorResult)
    }
}

/// In-memory cache so tests don't share files.
final class MemoryCache: NSObject, CachingLayer {
    private var contents: [String: Data] = [:]

    func saveContent(fileName: String, content: Data) { contents[fileName] = content }
    func getContent(fileName: String) -> Data? { contents[fileName] }
    func setCacheKey(_ key: String) {}
    func clearCache() { contents = [:] }
    func setSystemCacheDirectory(_ directory: CacheDirectory) {}
    func setCustomCachePath(_ path: String) {}
}

enum Payloads {
    static let featuresMap = """
    {
        "bool-flag": {"defaultValue": true},
        "string-flag": {"defaultValue": "hello"},
        "int-flag": {"defaultValue": 42},
        "fraction-flag": {"defaultValue": 1.5},
        "big-flag": {"defaultValue": 100000000000000000000},
        "json-flag": {"defaultValue": {"list": [1, null, {"nested": "yes"}], "ratio": 0.5}},
        "null-flag": {"defaultValue": null},
        "id-flag": {
            "defaultValue": "default",
            "rules": [{"condition": {"id": "user-1"}, "force": "matched"}]
        },
        "country-flag": {
            "defaultValue": "default",
            "rules": [{"condition": {"country": "CA"}, "force": "ca"}]
        },
        "experiment-flag": {
            "defaultValue": "control",
            "rules": [{
                "key": "experiment-flag",
                "variations": ["control", "treatment"],
                "weights": [0, 1],
                "coverage": 1,
                "hashAttribute": "id"
            }]
        },
        "cyclic-flag": {
            "defaultValue": true,
            "rules": [{"parentConditions": [{"id": "cyclic-flag", "condition": {"value": true}}]}]
        }
    }
    """

    static let features = #"{"features": \#(featuresMap)}"#
    static let featuresResponse = features

    static let encryptionKey = "Ns04T5n9+59rl2x3SlNHtQ=="
    static let encryptedFeatures = #"{"encryptedFeatures": "RdZCI/ctegPHQ8rPfE/RNA==.9Ry+P4zVJMRnviWuws/0OhorG9mE75CUU2YJRflYeBCA24s41VLG2r9Z7yaAIM86"}"#
}
