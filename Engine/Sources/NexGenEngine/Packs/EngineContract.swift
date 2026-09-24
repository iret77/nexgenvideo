public enum EngineContract {
    /// Current host-pack binary contract; bump when any boundary type changes shape.
    public static let current = 10
    /// Contracts 7–10 add capabilities without changing existing value layouts.
    public static let minimumCompatible = 2
}
