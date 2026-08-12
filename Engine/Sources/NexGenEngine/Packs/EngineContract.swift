public enum EngineContract {
    /// Current host-pack binary contract; bump when any boundary type changes shape.
    public static let current = 6
    /// Oldest contract accepted by this host. Contract 6 only appends class storage and preserves value layouts.
    public static let minimumCompatible = 2
}
