public enum EngineContract {
    /// Current host-pack binary contract; bump when any boundary type changes shape.
    public static let current = 7
    /// Oldest accepted contract. Contract 7 appends analyzer storage and preserves existing layouts.
    public static let minimumCompatible = 2
}
