public enum EngineContract {
    /// Current host-pack binary contract; bump when any boundary type changes shape.
    public static let current = 8
    /// Contracts 7–8 add new capabilities and append class storage without changing old layouts.
    public static let minimumCompatible = 2
}
