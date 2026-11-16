import Foundation
import Observation

/// The status of a ``MutationObserver``'s latest mutation.
public enum MutationStatus: Sendable {
    /// No mutation has run since the observer was created or reset.
    case idle
    /// The latest mutation is queued, running, or waiting for its keys to refetch. In a scope,
    /// only the scope's last mutation waits for the refetch; earlier ones leave `.pending` when
    /// their remote call returns.
    case pending
    /// The latest mutation succeeded.
    case success
    /// The latest mutation failed.
    case error
}

/// Runs mutations and tracks the latest one's status.
///
/// In a view, get one with ``MutationClient``. Elsewhere, such as in a view model, create one
/// with the provider:
///
/// ```swift
/// @Observable @MainActor
/// final class ProfileModel {
///     let follow: MutationObserver<Void, Void>
///     init(provider: QueryProvider) {
///         follow = MutationObserver(provider: provider)
///     }
/// }
/// ```
///
/// `mutate` has two forms. Called from synchronous code, such as a button's action, it returns
/// right away and reports failures through ``error``. Called with `await`, it returns the result
/// and throws. In an async context Swift always picks the second form; to start a mutation
/// without waiting there, call it from a synchronous closure: `_ = { follow.mutate { ... } }()`.
///
/// ``status``, ``error``, ``variables`` and ``data`` describe the latest call. Starting a
/// mutation clears ``error`` and ``data``. ``isMutating`` covers every call.
@Observable
@MainActor
public final class MutationObserver<Input: Sendable, Result> {
    /// The latest mutation's status.
    public private(set) var status: MutationStatus = .idle
    /// The latest mutation's error, if it failed.
    public private(set) var error: (any Error)?
    /// The latest mutation's input.
    public private(set) var variables: Input?
    /// The latest mutation's result, once it succeeds.
    public private(set) var data: Result?

    public var isIdle: Bool { status == .idle }
    public var isPending: Bool { status == .pending }
    public var isSuccess: Bool { status == .success }
    public var isError: Bool { status == .error }

    /// Whether any mutation started from this observer is queued, running, or waiting for its
    /// keys to refetch. Unlike ``isPending``, which follows only the latest call, it stays `true`
    /// until every call has finished.
    public var isMutating: Bool { mutationCount > 0 }
    private var mutationCount = 0

    @ObservationIgnored private var provider: QueryProvider?
    @ObservationIgnored private var defaultScope: (any Hashable & Sendable)?
    @ObservationIgnored private var defaultInvalidates: [QueryFilter] = []
    @ObservationIgnored private var latestCall: UInt64 = 0

    nonisolated init() {}

    /// Creates an observer outside a view, such as in a view model. `scope` and `invalidates`
    /// are defaults for its mutations, as with ``MutationClient``.
    public init(provider: QueryProvider, scope: (any Hashable & Sendable)? = nil, invalidates: [QueryFilter] = []) {
        configure(provider: provider, scope: scope, invalidates: invalidates)
    }

    func configure(provider: QueryProvider, scope: (any Hashable & Sendable)?, invalidates: [QueryFilter]) {
        self.provider = provider
        defaultScope = scope
        defaultInvalidates = invalidates
    }

    /// Returns the observer to `.idle` and clears the latest mutation's error, input and result.
    /// Mutations still running finish without updating it.
    public func reset() {
        latestCall &+= 1
        status = .idle
        error = nil
        variables = nil
        data = nil
    }

    // MARK: Mutations with input

    /// Starts a mutation with `input` and returns right away. Failures are reported through
    /// ``error``.
    public func mutate(
        _ input: Input,
        scope: (any Hashable & Sendable)? = nil,
        invalidates: [QueryFilter] = [],
        _ mutation: @escaping @Sendable (Input) async throws -> sending Result,
        optimistic: (@MainActor (OptimisticContext, Input) throws -> Void)? = nil
    ) {
        fire(
            input, scope: scope, invalidates: invalidates,
            Self.bind(mutation, input),
            optimistic: Self.bind(optimistic, input)
        )
    }

    /// Runs a mutation with `input` and returns its result, throwing its error.
    @discardableResult
    public func mutate(
        _ input: Input,
        scope: (any Hashable & Sendable)? = nil,
        invalidates: [QueryFilter] = [],
        _ mutation: @escaping @Sendable (Input) async throws -> sending Result,
        optimistic: (@MainActor (OptimisticContext, Input) throws -> Void)? = nil
    ) async throws -> Result {
        try await run(
            input, scope: scope, invalidates: invalidates,
            Self.bind(mutation, input),
            optimistic: Self.bind(optimistic, input)
        )
    }

    // MARK: Internal

    private static func bind(
        _ mutation: @escaping @Sendable (Input) async throws -> sending Result,
        _ input: Input
    ) -> @Sendable () async throws -> sending Result {
        { try await mutation(input) }
    }

    private static func bind(
        _ optimistic: (@MainActor (OptimisticContext, Input) throws -> Void)?,
        _ input: Input
    ) -> OptimisticUpdate? {
        guard let optimistic else { return nil }
        return { tx in try optimistic(tx, input) }
    }

    /// Starts a mutation without waiting for it. The optimistic update applies before returning.
    func fire(
        _ input: Input,
        scope: (any Hashable & Sendable)?,
        invalidates: [QueryFilter],
        _ mutation: @escaping @Sendable () async throws -> sending Result,
        optimistic: OptimisticUpdate?
    ) {
        let call = start(input)
        let provider = installedProvider
        let run: MutationRun
        do {
            run = try begin(provider, scope: scope, invalidates: invalidates, optimistic: optimistic)
        } catch {
            fail(call, error)
            return
        }
        Task {
            do {
                let result = try await provider.finishMutation(run, mutation)
                succeed(call, result)
            } catch {
                fail(call, error)
            }
        }
    }

    /// Runs a mutation and returns its result.
    func run(
        _ input: Input,
        scope: (any Hashable & Sendable)?,
        invalidates: [QueryFilter],
        _ mutation: @escaping @Sendable () async throws -> sending Result,
        optimistic: OptimisticUpdate?
    ) async throws -> Result {
        let call = start(input)
        let provider = installedProvider
        do {
            let run = try begin(provider, scope: scope, invalidates: invalidates, optimistic: optimistic)
            let result = try await provider.finishMutation(run, mutation)
            succeed(call, result)
            return result
        } catch {
            fail(call, error)
            throw error
        }
    }

    private var installedProvider: QueryProvider {
        guard let provider else {
            preconditionFailure("MutationClient used before it was installed in a view with a QueryProvider in its environment")
        }
        return provider
    }

    private func start(_ input: Input) -> UInt64 {
        mutationCount += 1
        latestCall &+= 1
        status = .pending
        error = nil
        variables = input
        data = nil
        return latestCall
    }

    private func succeed(_ call: UInt64, _ result: Result) {
        mutationCount -= 1
        guard call == latestCall else { return }
        data = result
        status = .success
    }

    private func fail(_ call: UInt64, _ error: any Error) {
        mutationCount -= 1
        guard call == latestCall else { return }
        self.error = error
        status = .error
    }

    private func begin(
        _ provider: QueryProvider,
        scope: (any Hashable & Sendable)?,
        invalidates: [QueryFilter],
        optimistic: OptimisticUpdate?
    ) throws -> MutationRun {
        try provider.beginMutation(
            scope: scope ?? defaultScope,
            invalidates: defaultInvalidates + invalidates,
            optimistic: optimistic
        )
    }
}

extension MutationObserver where Input == Void, Result == Void {
    /// Creates an observer whose mutations take no input and return nothing. See
    /// ``init(provider:scope:invalidates:)``.
    public convenience init(provider: QueryProvider, scope: (any Hashable & Sendable)? = nil, invalidates: [QueryFilter] = []) {
        self.init()
        configure(provider: provider, scope: scope, invalidates: invalidates)
    }
}

extension MutationObserver where Input == Void {
    /// Starts a mutation and returns right away. Failures are reported through ``error``.
    public func mutate(
        scope: (any Hashable & Sendable)? = nil,
        invalidates: [QueryFilter] = [],
        _ mutation: @escaping @Sendable () async throws -> sending Result,
        optimistic: OptimisticUpdate? = nil
    ) {
        fire((), scope: scope, invalidates: invalidates, mutation, optimistic: optimistic)
    }

    /// Runs a mutation and returns its result, throwing its error.
    @discardableResult
    public func mutate(
        scope: (any Hashable & Sendable)? = nil,
        invalidates: [QueryFilter] = [],
        _ mutation: @escaping @Sendable () async throws -> sending Result,
        optimistic: OptimisticUpdate? = nil
    ) async throws -> Result {
        try await run((), scope: scope, invalidates: invalidates, mutation, optimistic: optimistic)
    }
}
