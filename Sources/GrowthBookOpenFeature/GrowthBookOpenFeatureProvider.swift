import Combine
import Foundation
import GrowthBook
import OpenFeature

/// Which identity becomes the GrowthBook `id` attribute when an OpenFeature context has both a
/// `targetingKey` and an explicit `id` attribute.
public enum IdentityPrecedence {
    /// The OpenFeature `targetingKey` wins.
    case targetingKey
    /// The explicit `id` attribute wins.
    case idAttribute
}

/// Errors thrown when a ``GrowthBookOpenFeatureProvider`` is created with an unsupported configuration.
public enum GrowthBookOpenFeatureProviderError: Error, Equatable {
    /// Remote evaluation is not supported by this provider yet.
    case remoteEvalUnsupported
    /// Sticky bucketing is not supported by this provider yet.
    case stickyBucketingUnsupported
}

/// OpenFeature provider backed by a GrowthBook SDK instance that the provider creates and owns.
///
/// Supports local evaluation with fetched, cached or supplied feature payloads. Experiment exposures
/// are reported through the configuration's `trackingClosure`, as with the GrowthBook SDK.
///
/// OpenFeature Swift has no shutdown hook, so call ``close()`` before clearing or replacing the provider.
public final class GrowthBookOpenFeatureProvider: FeatureProvider, @unchecked Sendable {
    public let hooks: [any Hook] = []
    public let metadata: ProviderMetadata = GrowthBookProviderMetadata()

    public var status: ProviderStatus { statusTracker.status }

    private let configuration: GrowthBookModel
    private let identityPrecedence: IdentityPrecedence
    private let initializationTimeout: TimeInterval
    private let networkDispatcher: NetworkProtocol?
    private let cachingManager: CachingLayer?
    private let ttlSeconds: Int

    private let statusTracker = ProviderStatusTracker()
    /// Serializes refresh results so they are handled outside the SDK's lock.
    private let queue = DispatchQueue(label: "io.growthbook.openfeature.provider")
    /// Guards the state below. Recursive so a tracking callback that evaluates another flag can't deadlock.
    private let lock = NSRecursiveLock()
    private(set) var sdk: GrowthBookSDK?
    private var appliedContext = ContextSnapshot(nil)
    private var hasUsablePayload = false
    private var featureSnapshot: [String: Data] = [:]
    private var pendingInitialization: (() -> Void)?
    private var isClosed = false

    /// Creates a provider. The GrowthBook SDK is created when OpenFeature initializes the provider.
    ///
    /// - Parameters:
    ///   - configuration: GrowthBook settings. `remoteEval` and `stickyBucketService` are not supported.
    ///   - identityPrecedence: Which identity wins when the context has both a `targetingKey` and an `id` attribute.
    ///   - initializationTimeout: Seconds to wait for the first feature fetch before reporting an error.
    ///   - networkDispatcher: Network client to use instead of the SDK's default.
    ///   - cachingManager: Cache to use instead of the SDK's default.
    ///   - ttlSeconds: How long fetched features are considered fresh.
    /// - Throws: ``GrowthBookOpenFeatureProviderError`` for unsupported configurations.
    public init(
        configuration: GrowthBookModel,
        identityPrecedence: IdentityPrecedence = .targetingKey,
        initializationTimeout: TimeInterval = 10,
        networkDispatcher: NetworkProtocol? = nil,
        cachingManager: CachingLayer? = nil,
        ttlSeconds: Int = 60
    ) throws {
        if configuration.remoteEval {
            throw GrowthBookOpenFeatureProviderError.remoteEvalUnsupported
        }
        if configuration.stickyBucketService != nil {
            throw GrowthBookOpenFeatureProviderError.stickyBucketingUnsupported
        }
        self.configuration = configuration
        self.identityPrecedence = identityPrecedence
        self.initializationTimeout = initializationTimeout
        self.networkDispatcher = networkDispatcher
        self.cachingManager = cachingManager
        self.ttlSeconds = ttlSeconds
    }

    deinit {
        close()
    }

    public func observe() -> AnyPublisher<ProviderEvent, Never> {
        statusTracker.observe()
    }

    // MARK: - Lifecycle

    public func initialize(initialContext: EvaluationContext?) -> Future<Void, Never> {
        Future { promise in
            self.lock.lock()
            guard !self.isClosed, self.sdk == nil else {
                self.lock.unlock()
                promise(.success(()))
                return
            }

            // A non-empty initial context replaces the configured attributes; an empty one keeps them.
            var model = self.configuration
            let snapshot = ContextSnapshot(initialContext)
            if !snapshot.isEmpty {
                model.attributes = JSON(self.attributes(from: initialContext))
            }
            self.appliedContext = snapshot

            let sdk = self.makeSDK(model: model)
            self.sdk = sdk
            self.featureSnapshot = Self.snapshot(of: sdk.getFeatures())

            // Supplied or cached features make the provider usable straight away.
            if !self.featureSnapshot.isEmpty {
                self.hasUsablePayload = true
                self.lock.unlock()
                self.statusTracker.send(.ready(nil))
                promise(.success(()))
                return
            }

            self.pendingInitialization = { promise(.success(())) }
            self.lock.unlock()

            self.queue.asyncAfter(deadline: .now() + self.initializationTimeout) { [weak self] in
                self?.finishInitialization(
                    with: .error(ProviderEventDetails(message: "Timed out waiting for GrowthBook features", errorCode: .general))
                )
            }
        }
    }

    public func onContextSet(oldContext: EvaluationContext?, newContext: EvaluationContext) -> Future<Void, Never> {
        Future { promise in
            self.lock.lock()
            self.apply(context: newContext)
            self.lock.unlock()
            promise(.success(()))
        }
    }

    /// Stops the provider and releases its GrowthBook SDK. Evaluations afterwards return the caller's default.
    ///
    /// OpenFeature Swift doesn't shut providers down, so call this before clearing or replacing the
    /// provider. Calling it more than once is harmless.
    public func close() {
        lock.lock()
        guard !isClosed else {
            lock.unlock()
            return
        }
        isClosed = true
        let sdk = self.sdk
        self.sdk = nil
        let pending = pendingInitialization
        pendingInitialization = nil
        lock.unlock()

        sdk?.close()
        if let pending {
            statusTracker.send(.error(ProviderEventDetails(message: "Provider closed", errorCode: .providerFatal)))
            pending()
        }
    }

    // MARK: - Evaluation

    public func getBooleanEvaluation(key: String, defaultValue: Bool, context: EvaluationContext?) throws
        -> ProviderEvaluation<Bool>
    {
        try evaluate(key: key, defaultValue: defaultValue, context: context, convert: ValueConversion.bool)
    }

    public func getStringEvaluation(key: String, defaultValue: String, context: EvaluationContext?) throws
        -> ProviderEvaluation<String>
    {
        try evaluate(key: key, defaultValue: defaultValue, context: context, convert: ValueConversion.string)
    }

    public func getIntegerEvaluation(key: String, defaultValue: Int64, context: EvaluationContext?) throws
        -> ProviderEvaluation<Int64>
    {
        try evaluate(key: key, defaultValue: defaultValue, context: context, convert: ValueConversion.int64)
    }

    public func getDoubleEvaluation(key: String, defaultValue: Double, context: EvaluationContext?) throws
        -> ProviderEvaluation<Double>
    {
        try evaluate(key: key, defaultValue: defaultValue, context: context, convert: ValueConversion.double)
    }

    public func getObjectEvaluation(key: String, defaultValue: Value, context: EvaluationContext?) throws
        -> ProviderEvaluation<Value>
    {
        try evaluate(key: key, defaultValue: defaultValue, context: context, convert: ValueConversion.value)
    }

    private func evaluate<T>(
        key: String,
        defaultValue: T,
        context: EvaluationContext?,
        convert: (JSON) -> T?
    ) throws -> ProviderEvaluation<T> {
        lock.lock()
        defer { lock.unlock() }

        if isClosed {
            throw OpenFeatureError.providerFatalError(message: "Provider closed")
        }
        guard let sdk, hasUsablePayload else {
            throw OpenFeatureError.providerNotReadyError
        }

        // OpenFeature installs a new context before calling onContextSet, and may hand the provider a
        // context it never announced. Applying it here keeps results from belonging to another user.
        apply(context: context)

        let result = sdk.evalFeature(id: key)
        switch result.source {
        case "unknownFeature":
            throw OpenFeatureError.flagNotFoundError(key: key)
        case "cyclicPrerequisite":
            throw OpenFeatureError.parseError(message: "Cyclic prerequisite for flag \(key)")
        default:
            break
        }

        let variant = result.experimentResult?.key
        guard let json = result.value, json.type != .null else {
            return ProviderEvaluation(value: defaultValue, variant: variant, reason: Reason.defaultReason.rawValue)
        }
        guard let value = convert(json) else {
            throw OpenFeatureError.typeMismatchError
        }
        return ProviderEvaluation(value: value, variant: variant, reason: Self.reason(for: result.source))
    }

    // MARK: - Internals

    private func makeSDK(model: GrowthBookModel) -> GrowthBookSDK {
        let refreshHandler: CacheRefreshHandler = { [weak self] error in
            // Called with the SDK's lock held, so handle the result on the provider's queue instead.
            self?.queue.async { [weak self] in
                self?.handleRefresh(error: error)
            }
        }
        let builder = GrowthBookBuilder(
            growthBookBuilderModel: model,
            apiRequestHeaders: model.apiRequestHeaders ?? [:],
            streamingHostRequestHeaders: model.streamingHostRequestHeaders ?? [:],
            ttlSeconds: ttlSeconds,
            refreshHandler: refreshHandler,
            cachingManager: cachingManager ?? CachingManager(apiKey: model.clientKey)
        )
        if let networkDispatcher {
            _ = builder.setNetworkDispatcher(networkDispatcher: networkDispatcher)
        }
        return builder.initializer()
    }

    /// Replaces the SDK's attributes when the context differs from the last one applied. Caller holds `lock`.
    private func apply(context: EvaluationContext?) {
        guard let sdk, !isClosed else { return }
        let snapshot = ContextSnapshot(context)
        guard snapshot != appliedContext else { return }
        sdk.setAttributes(attributes: attributes(from: context))
        appliedContext = snapshot
    }

    private func handleRefresh(error: SDKError?) {
        lock.lock()
        guard !isClosed, let sdk else {
            lock.unlock()
            return
        }
        let newSnapshot = Self.snapshot(of: sdk.getFeatures())
        let changedKeys = Self.changedKeys(from: featureSnapshot, to: newSnapshot)
        featureSnapshot = newSnapshot
        let wasUsable = hasUsablePayload
        if error == nil || !newSnapshot.isEmpty {
            hasUsablePayload = true
        }
        let isUsable = hasUsablePayload
        let isInitializing = pendingInitialization != nil
        lock.unlock()

        if isInitializing {
            finishInitialization(
                with: isUsable
                    ? .ready(nil)
                    : .error(ProviderEventDetails(message: "Failed to load GrowthBook features: \(String(describing: error))", errorCode: .general))
            )
            return
        }

        if error != nil {
            if isUsable, statusTracker.status == .ready {
                statusTracker.send(.stale(ProviderEventDetails(message: "Failed to refresh GrowthBook features")))
            }
            return
        }
        if !wasUsable || statusTracker.status == .stale || statusTracker.status == .error {
            statusTracker.send(.ready(nil))
        }
        if wasUsable, !changedKeys.isEmpty {
            statusTracker.send(.configurationChanged(ProviderEventDetails(flagsChanged: changedKeys.sorted())))
        }
    }

    private func finishInitialization(with event: ProviderEvent) {
        lock.lock()
        let pending = pendingInitialization
        pendingInitialization = nil
        lock.unlock()

        guard let pending else { return }
        statusTracker.send(event)
        pending()
    }

    /// Converts an OpenFeature context to GrowthBook attributes, mapping `targetingKey` to `id`.
    private func attributes(from context: EvaluationContext?) -> [String: Any] {
        guard let context else { return [:] }
        var attributes = context.asMap().compactMapValues { value -> Any? in
            value.isNull() ? nil : ValueConversion.attribute(from: value)
        }
        let targetingKey = context.getTargetingKey()
        if !targetingKey.isEmpty, identityPrecedence == .targetingKey || attributes["id"] == nil {
            attributes["id"] = targetingKey
        }
        return attributes
    }

    private static func reason(for source: String) -> String {
        switch source {
        case "experiment":
            return Reason.split.rawValue
        case "force":
            return Reason.targetingMatch.rawValue
        case "override":
            return Reason.staticReason.rawValue
        case "defaultValue":
            return Reason.defaultReason.rawValue
        default:
            return Reason.unknown.rawValue
        }
    }

    /// Encodes each feature so refreshes can be compared without evaluating (evaluation fires tracking).
    private static func snapshot(of features: [String: Feature]) -> [String: Data] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return features.compactMapValues { try? encoder.encode($0) }
    }

    private static func changedKeys(from old: [String: Data], to new: [String: Data]) -> Set<String> {
        Set(old.keys).union(new.keys).filter { old[$0] != new[$0] }
    }
}

/// Provider metadata reported to OpenFeature.
public struct GrowthBookProviderMetadata: ProviderMetadata {
    public let name: String? = "GrowthBook"
}

/// The parts of an OpenFeature context that affect evaluation, used to detect context changes.
private struct ContextSnapshot: Equatable {
    let targetingKey: String
    let attributes: [String: Value]

    init(_ context: EvaluationContext?) {
        targetingKey = context?.getTargetingKey() ?? ""
        attributes = context?.asMap() ?? [:]
    }

    var isEmpty: Bool { targetingKey.isEmpty && attributes.isEmpty }
}
