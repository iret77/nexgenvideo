public enum EngineContract {
    /// Current host-pack binary contract; bump when any boundary type changes shape.
    public static let current = 11
    /// Contracts 7–9 add new capabilities and append class storage without changing old layouts.
    /// Contract 10 appends FrameImageModel cases; the host never writes them for older packs.
    // Contract 11 appends candidate validation without changing installed-pack offsets.
    public static let minimumCompatible = 2
}
