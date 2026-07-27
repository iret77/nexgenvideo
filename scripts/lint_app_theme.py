#!/usr/bin/env python3

from pathlib import Path
import re
import sys


ROOT = Path(__file__).resolve().parents[1]
SOURCE_ROOT = ROOT / "Sources" / "NexGenVideo"
THEME_FILE = SOURCE_ROOT / "UI" / "AppTheme.swift"

NUMBER = r"-?(?:\d+(?:\.\d+)?|\.\d+)"
WEIGHT = r"(?:light|regular|medium|semibold|bold)"
SEMANTIC_FONT = (
    r"(?:body|callout|caption|caption2|footnote|headline|largeTitle|"
    r"subheadline|title|title2|title3)"
)
NESTED_ARGUMENTS = r"(?:[^()]|\([^()]*\))*?"

RULES = [
    (
        "numeric frame metric",
        rf"\.frame\s*\([^)]*\b(?:width|height|minWidth|maxWidth|minHeight|maxHeight|"
        rf"idealWidth|idealHeight)\s*:\s*{NUMBER}",
    ),
    (
        "numeric padding",
        rf"\.padding\s*\(\s*(?:(?:\.[A-Za-z]+|\[[^\]]+\])\s*,\s*)?{NUMBER}",
    ),
    (
        "numeric stack/grid spacing",
        rf"\b(?:HStack|VStack|ZStack|LazyHStack|LazyVStack|LazyVGrid|LazyHGrid|GridItem)"
        rf"\s*\({NESTED_ARGUMENTS}\bspacing\s*:\s*{NUMBER}",
    ),
    (
        "numeric font size",
        rf"(?:\.font\s*\(\s*\.system|NSFont\.(?:systemFont|monospacedDigitSystemFont)|"
        rf"NSImage\.SymbolConfiguration)\s*\([^)]*(?:size|ofSize|pointSize)\s*:\s*{NUMBER}",
    ),
    (
        "semantic font outside AppTheme",
        rf"\.font\s*\(\s*\.{SEMANTIC_FONT}\s*\)",
    ),
    (
        "direct SwiftUI font weight",
        rf"(?:\bweight\s*:\s*|\.fontWeight\s*\()\s*\.{WEIGHT}\b",
    ),
    (
        "numeric corner radius",
        rf"\b(?:cornerRadius|cornerWidth|cornerHeight)\s*:\s*{NUMBER}",
    ),
    (
        "numeric border width",
        rf"(?:\blineWidth\s*:\s*|\.setLineWidth\s*\(\s*|\.lineWidth\s*=\s*){NUMBER}",
    ),
    (
        "numeric tracking",
        rf"\.tracking\s*\(\s*{NUMBER}",
    ),
    (
        "numeric animation timing",
        rf"(?:\.animation|withAnimation|\.spring|\.linear|\.easeIn|\.easeOut|\.easeInOut)"
        rf"[\s\S]{{0,300}}?(?:duration|response|dampingFraction)\s*:\s*{NUMBER}",
    ),
    (
        "numeric opacity",
        rf"(?:\.opacity|\.withAlphaComponent|\.setAlpha)\s*\(\s*(?:CGFloat\s*\(\s*)?{NUMBER}",
    ),
    (
        "numeric layer opacity",
        rf"\b(?:alphaValue|shadowOpacity)\s*=\s*{NUMBER}",
    ),
    (
        "direct palette color",
        r"\b(?:Color|NSColor)\.(?:black|white|red|orange|yellow|gray|clear|"
        r"systemRed|systemOrange|systemYellow)\b|"
        r"\.(?:foregroundStyle|foregroundColor)\s*\(\s*\.(?:black|white|red|orange|yellow|gray)\b",
    ),
    (
        "unstyled Divider",
        r"(?<!App)\bDivider\s*\(\s*\)",
    ),
    (
        "shadow outside AppTheme",
        r"\.shadow\s*\((?![^)]*AppTheme\.Shadow\b)",
    ),
]

RULE_EXEMPTIONS = {
    # These values render the user's authored text shadow into video content; they are not app chrome.
    "numeric layer opacity": {
        SOURCE_ROOT / "Preview" / "TextLayerController.swift",
    },
}

INLINE_RULE_EXEMPTIONS = {
    "unstyled Divider": "app-theme: native-menu-divider",
}


def without_comments_and_strings(source: str) -> str:
    output = list(source)
    index = 0

    def blank(start: int, end: int) -> None:
        for offset in range(start, end):
            if output[offset] != "\n":
                output[offset] = " "

    while index < len(source):
        if source.startswith("//", index):
            end = source.find("\n", index)
            if end == -1:
                end = len(source)
            blank(index, end)
            index = end
            continue

        if source.startswith("/*", index):
            start = index
            index += 2
            depth = 1
            while index < len(source) and depth:
                if source.startswith("/*", index):
                    depth += 1
                    index += 2
                elif source.startswith("*/", index):
                    depth -= 1
                    index += 2
                else:
                    index += 1
            blank(start, index)
            continue

        hashes = 0
        quote_index = index
        if source[index] == "#":
            while quote_index < len(source) and source[quote_index] == "#":
                hashes += 1
                quote_index += 1
        if quote_index < len(source) and source[quote_index] == '"':
            triple = source.startswith('"""', quote_index)
            quote = '"""' if triple else '"'
            delimiter = quote + ("#" * hashes)
            start = index
            index = quote_index + len(quote)
            while index < len(source):
                if source.startswith(delimiter, index):
                    index += len(delimiter)
                    break
                if hashes == 0 and source[index] == "\\":
                    index = min(len(source), index + 2)
                else:
                    index += 1
            blank(start, index)
            continue

        index += 1

    return "".join(output)


def line_number(source: str, offset: int) -> int:
    return source.count("\n", 0, offset) + 1


def main() -> int:
    failures: list[tuple[Path, int, str, str]] = []
    for path in sorted(SOURCE_ROOT.rglob("*.swift")):
        if path == THEME_FILE:
            continue
        original_source = path.read_text(encoding="utf-8")
        original_lines = original_source.splitlines()
        source = without_comments_and_strings(original_source)
        for rule_name, pattern in RULES:
            if path in RULE_EXEMPTIONS.get(rule_name, set()):
                continue
            for match in re.finditer(pattern, source):
                line = line_number(source, match.start())
                marker = INLINE_RULE_EXEMPTIONS.get(rule_name)
                if marker and marker in original_lines[line - 1]:
                    continue
                snippet = source.splitlines()[line - 1].strip()
                failures.append((path.relative_to(ROOT), line, rule_name, snippet))

    if not failures:
        print("AppTheme lint passed")
        return 0

    print("AppTheme lint failed: UI styling must use AppTheme tokens", file=sys.stderr)
    for path, line, rule, snippet in failures:
        print(f"{path}:{line}: {rule}: {snippet}", file=sys.stderr)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
