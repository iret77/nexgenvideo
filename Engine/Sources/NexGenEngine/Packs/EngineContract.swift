public enum EngineContract {
    /// Current host-pack binary contract; bump when any boundary type changes shape.
    public static let current = 5
    /// Oldest contract accepted by this host. Contract 5 changes public value layouts.
    public static let minimumCompatible = 5
}
