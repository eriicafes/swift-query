import SwiftUI

/// Runs mutations for a view and tracks the latest one's status.
///
/// ```swift
/// @MutationClient private var follow                     // status only
/// @MutationClient<Void, Draft> private var create        // tracks the result
/// @MutationClient<String, Message> private var send      // tracks input and result
/// @MutationClient(scope: "settings", invalidates: [.tag("settings")]) private var save
/// ```
///
/// Each view gets its own client. Mutations run through the environment's ``QueryProvider``
/// (see ``QueryProvider/mutate(scope:invalidates:_:optimistic:)``), so scopes are shared with
/// every other mutation. `scope` and `invalidates` are defaults: a call's `scope` replaces the
/// default, and its `invalidates` are added to the default ones.
///
/// For defaults built from init parameters, assign the wrapper in `init`:
///
/// ```swift
/// @MutationClient private var follow: MutationObserver<Void, Void>
///
/// init(id: String) {
///     _follow = MutationClient(scope: "user-\(id)", invalidates: [.key(UserDetail(id: id))])
/// }
/// ```
@propertyWrapper
public struct MutationClient<Input: Sendable, Result>: DynamicProperty {
    @Environment(QueryProvider.self) private var provider
    @State private var client = MutationObserver<Input, Result>()
    private let scope: (any Hashable & Sendable)?
    private let invalidates: [QueryFilter]

    /// A client whose mutations take an `Input` and return a `Result`.
    public init(scope: (any Hashable & Sendable)? = nil, invalidates: [QueryFilter] = []) {
        self.scope = scope
        self.invalidates = invalidates
    }

    @MainActor
    public var wrappedValue: MutationObserver<Input, Result> {
        client
    }

    public nonisolated func update() {
        let client = client
        let provider = provider
        let scope = scope
        let invalidates = invalidates
        MainActor.assumeIsolated {
            client.configure(provider: provider, scope: scope, invalidates: invalidates)
        }
    }
}

extension MutationClient where Input == Void, Result == Void {
    /// A client whose mutations take no input and return nothing.
    public init(scope: (any Hashable & Sendable)? = nil, invalidates: [QueryFilter] = []) {
        self.scope = scope
        self.invalidates = invalidates
    }
}
