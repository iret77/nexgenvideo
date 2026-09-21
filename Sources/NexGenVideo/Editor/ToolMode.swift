/// The active editing tool. Affects timeline click behavior and cursor.
enum ToolMode: CaseIterable {
    case pointer  // V key — default selection/move/trim
    case razor    // C key — click to split clips
    case slip     // T key — drag a clip body to shift its source range
}
