import Foundation

/// Round to `digits` decimal places with round-half-to-even (banker's
/// rounding), matching CPython's built-in `round(float, ndigits)`. Swift's
/// default `.rounded()` is round-half-away-from-zero, which would diverge from
/// the Python oracle on exact `.5` ULP cases; `.toNearestOrEven` matches.
func pyRound(_ value: Double, _ digits: Int) -> Double {
    let factor = pow(10.0, Double(digits))
    return (value * factor).rounded(.toNearestOrEven) / factor
}

/// Python's `str(float)` / f-string default for a float — e.g. `10.0` → "10.0",
/// `5.0` → "5.0". The cost notes only interpolate clean provider limits
/// (`max_duration_s`, `min_duration_s`), which are whole-number floats, so a
/// shortest-round-trip repr with a guaranteed trailing ".0" for integral values
/// reproduces the Python output exactly.
func pyFloat(_ value: Double) -> String {
    if value == value.rounded() && abs(value) < 1e16 {
        // Integral float → Python prints "N.0".
        return String(format: "%.1f", value)
    }
    // Shortest representation that round-trips (Swift's default matches
    // Python's repr for the non-integral limits that could appear here).
    return "\(value)"
}

/// Python's `f"{x:.1f}"` — fixed one decimal place.
func pyFixed1(_ value: Double) -> String {
    String(format: "%.1f", value)
}
