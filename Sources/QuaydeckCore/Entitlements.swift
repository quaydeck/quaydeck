import Foundation

/// Capabilities that can be gated.
///
/// Everything Quaydeck 1.0 ships with is free, permanently. This enum exists so that
/// features added *later* have somewhere to be gated without a refactor, and so that
/// the free build and any future paid build differ by an entitlement lookup rather
/// than by a fork of the code.
public enum Feature: String, CaseIterable, Sendable {
    // Shipped in 1.0. Always available, in every build, forever.
    case scanning
    case advice
    case history
    case notifications
    case pinning
    case restartInTerminal

    /// Whether this feature is part of the permanently free set.
    public var isFreeForever: Bool { true }
}

public protocol Entitlements: Sendable {
    func isEnabled(_ feature: Feature) -> Bool
}

/// The 1.0 entitlement set: everything on.
///
/// When a paid tier arrives, a new `Feature` case is added with `isFreeForever`
/// returning false and a different `Entitlements` implementation is injected at the
/// app's composition root. Nothing in `QuaydeckCore` or `QuaydeckUI` changes.
public struct FreeEntitlements: Entitlements {
    public init() {}
    public func isEnabled(_ feature: Feature) -> Bool { feature.isFreeForever }
}
