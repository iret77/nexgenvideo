public enum EngineContract {
    /// Current host-pack binary contract; bump when any boundary type changes shape.
    public static let current = 4
    /// Oldest contract accepted after additive ABI changes.
    public static let minimumCompatible = 2
}
