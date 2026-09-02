import AppKit
import SwiftUI

enum AppTheme {

    // MARK: - Backgrounds

    enum Background {
        static let base = NSColor(red: 10/255, green: 10/255, blue: 10/255, alpha: 1)
        static let surface = NSColor(red: 22/255, green: 22/255, blue: 22/255, alpha: 1)
        static let raised = NSColor(red: 30/255, green: 30/255, blue: 30/255, alpha: 1)
        static let prominent = NSColor(red: 44/255, green: 44/255, blue: 44/255, alpha: 1)
        static let overlay = NSColor.black

        /// Alias — empty media slot is a raised plate.
        static let placeholder = raised

        static var baseColor: Color { Color(base) }
        static var surfaceColor: Color { Color(surface) }
        static var raisedColor: Color { Color(raised) }
        static var prominentColor: Color { Color(prominent) }
        static var previewCanvasColor: Color { .black }
        static var placeholderColor: Color { Color(placeholder) }
        static var overlayColor: Color { Color(overlay) }
        static var clearColor: Color { .clear }
        static var clearNSColor: NSColor { .clear }
    }

    // MARK: - Borders

    enum Border {
        static let primary = NSColor.white.withAlphaComponent(0.16)
        static let subtle = NSColor.white.withAlphaComponent(0.12)
        static let divider = NSColor.white.withAlphaComponent(0.44)
        static let shortDash: [CGFloat] = [3, 3]
        static let compactDash: [CGFloat] = [4, 3]
        static let regularDash: [CGFloat] = [4, 4]
        static let longDash: [CGFloat] = [8, 4]

        static var primaryColor: Color { Color(primary) }
        static var subtleColor: Color { Color(subtle) }
    }

    // MARK: - Border widths

    enum BorderWidth {
        static let hairline: CGFloat = 0.5
        static let thin: CGFloat = 1
        static let medium: CGFloat = 1.5
        static let thick: CGFloat = 2
    }

    // MARK: - Accent

    enum Accent {
        static let timecodeNSColor = NSColor(red: 0.95, green: 0.6, blue: 0.2, alpha: 1)
        static let timecodeColor = Color(timecodeNSColor)

        /// Warm off-white
        static let primaryNSColor = NSColor(red: 0.961, green: 0.937, blue: 0.894, alpha: 1)
        static let primary = Color(primaryNSColor)

        /// Pack-scoped accent — marks a cockpit tab a format pack contributed, distinct from the
        /// first-party generic tabs. (#c08bff)
        static let pack = Color(red: 0.753, green: 0.545, blue: 1.0)

        /// Vibrant highlight used by the onboarding tour spotlight.
        static let spotlight = Color(red: 1.0, green: 0.27, blue: 0.27)
        static let transformGuide = Color(red: 1.0, green: 0.2, blue: 0.6)
        static let spotlightGradient = LinearGradient(
            colors: [
                Color(red: 1.0, green: 0.34, blue: 0.30),
                Color(red: 0.95, green: 0.15, blue: 0.28),
                Color(red: 1.0, green: 0.48, blue: 0.22),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    // MARK: - Adjust sliders

    enum Slider {
        static let trackHeight: CGFloat = 4
        static let thumbSize: CGFloat = 10
        static let labelColumn: CGFloat = 106
        /// Temperature track: cool blue (low) → warm amber (high).
        static let tempGradient = [Color(red: 0.32, green: 0.55, blue: 0.92), Color(red: 0.95, green: 0.72, blue: 0.32)]
        /// Tint track: green (low) → magenta (high).
        static let tintGradient = [Color(red: 0.42, green: 0.78, blue: 0.45), Color(red: 0.82, green: 0.38, blue: 0.72)]
        /// Master luma track: near-black → near-white.
        static let lumaGradient = [Color(white: 0.05), Color(white: 0.95)]
    }

    // MARK: - Color wheels

    enum Wheels {
        static let padSize: CGFloat = 96
        static let puckSize: CGFloat = 10
        static let ringWidth: CGFloat = 1
        static let crosshairColor = Color.white.opacity(AppTheme.Opacity.faint)
    }

    enum Curve {
        static let editorHeight: CGFloat = 180
        static let pointDiameter: CGFloat = 9
        /// Invisible grab target around each point — much larger than the dot so it's easy to hit.
        static let pointHitDiameter: CGFloat = 30
        static let lumaColor = Color(red: 1, green: 1, blue: 1)
        static let redColor = Color(red: 1, green: 0.22, blue: 0.18)
        static let greenColor = Color(red: 0.32, green: 0.82, blue: 0.36)
        static let blueColor = Color(red: 0.32, green: 0.56, blue: 1)
    }

    /// Monochrome silver shimmer
    static let aiGradient = LinearGradient(
        stops: [
            .init(color: Color(white: 1.00), location: 0.00),
            .init(color: Color(white: 0.78), location: 0.45),
            .init(color: Color(white: 0.60), location: 0.55),
            .init(color: Color(white: 1.00), location: 1.00),
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let aiGradientDark = LinearGradient(
        stops: [
            .init(color: Color(white: 0.11), location: 0.00),
            .init(color: Color(white: 0.06), location: 1.00),
        ],
        startPoint: .top,
        endPoint: .bottom
    )

    // MARK: - Glass

    enum Glass {
        static let primaryTint = Accent.primary.opacity(0.05)
    }

    // MARK: - Status

    enum Status {
        static let error = NSColor(red: 0xE5/255.0, green: 0x4F/255.0, blue: 0x4F/255.0, alpha: 1)

        static var errorColor: Color { Color(error) }

        static let success = NSColor(red: 0x4F/255.0, green: 0xB8/255.0, blue: 0x5F/255.0, alpha: 1)

        static var successColor: Color { Color(success) }

        static let warning = NSColor(red: 0xE8/255.0, green: 0x9C/255.0, blue: 0x3E/255.0, alpha: 1)

        static var warningColor: Color { Color(warning) }
    }

    // MARK: - Text

    enum Text {
        static let primary = NSColor.white.withAlphaComponent(1.0)
        static let secondary = NSColor.white.withAlphaComponent(0.80)
        static let tertiary = NSColor.white.withAlphaComponent(0.62)
        static let muted = NSColor.white.withAlphaComponent(0.34)
        static let systemSecondary = NSColor.secondaryLabelColor

        static var primaryColor: Color { Color(primary) }
        static var secondaryColor: Color { Color(secondary) }
        static var tertiaryColor: Color { Color(tertiary) }
        static var mutedColor: Color { Color(muted) }
    }

    // MARK: - Opacity

    enum Opacity {
        static let transparent: Double = 0
        static let interactionTarget: Double = 0.001
        static let opaque: Double = 1
        static let subtle: Double = 0.04
        static let glass: Double = 0.05
        static let hint: Double = 0.06
        static let faint: Double = 0.08
        static let soft: Double = 0.10
        static let subdued: Double = 0.12
        static let muted: Double = 0.15
        static let selection: Double = 0.18
        static let dim: Double = 0.20
        static let moderate: Double = 0.25
        static let shadow: Double = 0.30
        static let medium: Double = 0.35
        static let settingsWindow: Double = 0.4
        static let shimmer: Double = 0.42
        static let elevated: Double = 0.45
        static let balanced: Double = 0.50
        static let strong: Double = 0.55
        static let disabled: Double = 0.60
        static let scrim: Double = 0.70
        static let prominent: Double = 0.80
        static let emphasis: Double = 0.85
        static let high: Double = 0.90
        static let nearOpaque: Double = 0.95
    }

    // MARK: - Track type colors

    enum TrackColor {
        static let video = NSColor(red: 0x00/255.0, green: 0x91/255.0, blue: 0xC2/255.0, alpha: 1)
        static let audio = NSColor(red: 0x58/255.0, green: 0xA8/255.0, blue: 0x22/255.0, alpha: 1)
        static let image = NSColor(red: 0xB7/255.0, green: 0x2D/255.0, blue: 0xD2/255.0, alpha: 1)
        static let text = NSColor(red: 0xB7/255.0, green: 0x2D/255.0, blue: 0xD2/255.0, alpha: 1)
        static let lottie = NSColor(red: 0xE0/255.0, green: 0xA8/255.0, blue: 0x00/255.0, alpha: 1)
    }

    // MARK: - Corner radii

    enum Radius {
        static let xs: CGFloat = 3
        static let xsSm: CGFloat = 4
        static let sm: CGFloat = 6
        static let smMd: CGFloat = 7
        static let md: CGFloat = 10
        static let mdLg: CGFloat = 12
        static let lg: CGFloat = 14
        static let xl: CGFloat = 20

        static func concentric(outer: CGFloat, padding: CGFloat) -> CGFloat {
            max(outer - padding, 0)
        }
    }

    // MARK: - Spacing

    enum Spacing {
        static let none: CGFloat = 0
        static let micro: CGFloat = 1
        static let xxs: CGFloat = 2
        static let xs: CGFloat = 4
        static let xsSm: CGFloat = 5
        static let sm: CGFloat = 6
        static let smMd: CGFloat = 8
        static let md: CGFloat = 10
        static let mdLg: CGFloat = 12
        static let lg: CGFloat = 14
        static let lgXl: CGFloat = 16
        static let xl: CGFloat = 20
        static let xlXxl: CGFloat = 24
        static let xxl: CGFloat = 28
    }

    // MARK: - Font sizes

    enum FontSize {
        static let micro: CGFloat = 8
        static let xxs: CGFloat = 9
        static let xs: CGFloat = 10
        static let sm: CGFloat = 11
        static let smMd: CGFloat = 12
        static let md: CGFloat = 13
        static let mdLg: CGFloat = 14
        static let lg: CGFloat = 15
        static let lgXl: CGFloat = 16
        static let xlSm: CGFloat = 17
        static let xl: CGFloat = 18
        static let title1: CGFloat = 22
        static let title2: CGFloat = 28
        static let display: CGFloat = 36
    }

    // MARK: - Font weights

    enum FontWeight {
        static let light: Font.Weight = .light
        static let regular: Font.Weight = .regular
        static let medium: Font.Weight = .medium
        static let semibold: Font.Weight = .semibold
        static let bold: Font.Weight = .bold
    }

    enum AppKitFontWeight {
        static let light: NSFont.Weight = .light
        static let regular: NSFont.Weight = .regular
        static let medium: NSFont.Weight = .medium
        static let semibold: NSFont.Weight = .semibold
        static let bold: NSFont.Weight = .bold
    }

    // MARK: - Tracking (letter-spacing)

    enum Tracking {
        static let tight: CGFloat = -0.5
        static let normal: CGFloat = 0
        static let subtle: CGFloat = 0.3
        static let wide: CGFloat = 1.5
    }

    // MARK: - Icon sizes (square frame dimensions)

    enum IconSize {
        static let xxs: CGFloat = 12
        static let xs: CGFloat = 14
        static let sm: CGFloat = 18
        static let smMd: CGFloat = 20
        static let md: CGFloat = 22
        static let mdLg: CGFloat = 24
        static let lg: CGFloat = 26
        static let lgXl: CGFloat = 28
        static let xl: CGFloat = 30
    }

    enum ComponentSize {
        static let statusDotDiameter: CGFloat = 8
        static let thinkingDotDiameter: CGFloat = 5
        static let segmentedTabMarkerDiameter: CGFloat = 6
        static let packSurfaceStatTileMinWidth: CGFloat = 116
        static let packSurfaceProgressMaxWidth: CGFloat = 360
        static let toolbarZoomWidth: CGFloat = 100
        static let homeSidebarWidth: CGFloat = 220
        static let homeCardOverlayHeight: CGFloat = 60
        static let packInstallProgressWindow = CGSize(width: 320, height: 80)
        static let settingsSidebarWidth: CGFloat = 220
        static let settingsProviderCardMinWidth: CGFloat = 320
        static let settingsProviderHeaderMinHeight: CGFloat = 58
        static let settingsProviderControlMinHeight: CGFloat = 96
        static let settingsClientCardMinWidth: CGFloat = 280
        static let settingsClientCardMinHeight: CGFloat = 104
        static let chatHistoryWidth: CGFloat = 280
        static let chatHistoryMaxHeight: CGFloat = 360
        static let mentionPopoverWidth: CGFloat = 260
        static let mentionPopoverHeight: CGFloat = 280
        static let pluginLauncherWidth: CGFloat = 320
        static let pluginLauncherMaxHeight: CGFloat = 360
        static let captionPreviewMaxHeight: CGFloat = 150
        static let captionPreviewMaxTextWidthRatio: CGFloat = 0.9
        static let toolImagePreviewMaxHeight: CGFloat = 50
        static let agentChoiceChipMaxWidth: CGFloat = 320
        static let projectCardWidth: CGFloat = 150
        static let projectCardHeight: CGFloat = 120
        static let homeNoticeHorizontalMinWidth: CGFloat = 500
        static let homeNoticeMinHeight: CGFloat = 70
        static let updateOverlayWidth: CGFloat = 640
        static let projectActivityWidth: CGFloat = 340
        static let projectActivityMaxHeight: CGFloat = 420
        static let projectActivityCostWidth: CGFloat = 68
        static let tourStageHeight: CGFloat = 300
        static let exportSidebarWidth: CGFloat = 360
        static let exportWindow = CGSize(width: 860, height: 560)
        static let generationMentionMinWidth: CGFloat = 160
        static let generationMentionPopoverMinWidth: CGFloat = 180
        static let generationMenuWidth: CGFloat = 220
        static let generationPromptMinHeight: CGFloat = 60
        static let generationPromptMaxHeight: CGFloat = 120
        static let generationNegativePromptMinHeight: CGFloat = 36
        static let generationNegativePromptMaxHeight: CGFloat = 72
        static let feedbackPreview = CGSize(width: 88, height: 56)
        static let feedbackTextHeight: CGFloat = 160
        static let feedbackWindowMin = CGSize(width: 480, height: 420)
        static let feedbackWindowIdeal = CGSize(width: 480, height: 480)
        static let mcpInstructionsWindow = CGSize(width: 680, height: 560)
        static let shortcutsWindow = CGSize(width: 700, height: 520)
        static let shortcutKeyColumnWidth: CGFloat = 118
        static let cockpitLabelWidth: CGFloat = 76
        static let cockpitMessageMaxWidth: CGFloat = 320
        static let packSurfaceRowHeight: CGFloat = 68
        // Badge masters are 728×193 (~3.77) — a wide header band. 224pt keeps them ≤ native @2x.
        static let pluginBadgeWidth: CGFloat = 224
        static let pluginBadgeAspect: CGFloat = 728.0 / 193.0
        static let pluginPickerWidth: CGFloat = 520
        static let pluginPickerHeight: CGFloat = 460
        /// Min width of a pack card in the responsive picker grid (~2 columns at picker width).
        static let pluginCardMinWidth: CGFloat = 220
        /// Fixed height of the Sanity strip pinned under the Review gallery (predictable galleries above).
        static let reviewSanityStripHeight: CGFloat = 200
        static let reviewThumbnailWidth: CGFloat = 160
        static let reviewRedoPopoverWidth: CGFloat = 300
        static let reviewSourceLabelWidth: CGFloat = 110
        static let reviewRemixPopoverWidth: CGFloat = 340
        static let inspectorPopoverWidth: CGFloat = 340
        static let fontPickerMaxWidth: CGFloat = 160
        static let generationReferenceWidth: CGFloat = 72
        static let generationReferenceHeight: CGFloat = 41
        static let textEditorMinHeight: CGFloat = 80
        static let dragPreviewWidth: CGFloat = 80
        static let dragPreviewHeight: CGFloat = 60
        static let searchThumbnailWidth: CGFloat = 80
        static let searchThumbnailHeight: CGFloat = 45
        static let previewToolbarHeight: CGFloat = 36
        static let previewErrorMaxWidth: CGFloat = 520
        static let previewErrorMaxHeight: CGFloat = 240
        static let previewScrubberHeight: CGFloat = 12
        static let previewControlWidth: CGFloat = 32
        static let previewControlHeight: CGFloat = 28
        static let projectMismatchWidth: CGFloat = 360
        static let alertBodyTextWidth: CGFloat = 240
        static let agentComposerMinHeight: CGFloat = 92
        static let agentComposerMaxHeight: CGFloat = 280
        static let agentComposerGrabHeight: CGFloat = 10
        static let agentDecisionMaxHeight: CGFloat = 318
        static let agentBlockLabelWidth: CGFloat = 96
        static let agentAssetPickerWidth: CGFloat = 280
        static let agentAssetPickerHeight: CGFloat = 260
        static let agentConversationTitleMinWidth: CGFloat = 120
        static let agentScrollAwayThreshold: CGFloat = 80
        static let formatSheetWidth: CGFloat = 500
        static let formatSheetCardListMinHeight: CGFloat = 460
        static let formatSheetCardListMaxHeight: CGFloat = 600
        static let tourCalloutWidth: CGFloat = 320
        static let tourCalloutEstimatedHeight: CGFloat = 220
        static let tourBookendWidth: CGFloat = 600
        static let beatTimelineBandHeight: CGFloat = 20
        /// Label column of the Brief field rows — wide enough for the longest label ("Director pattern").
        static let briefLabelWidth: CGFloat = 104
        /// Theater's floating transport cluster — wide enough for a comfortable scrub without
        /// spanning the whole window.
        static let theaterTransportWidth: CGFloat = 460
    }

    enum Layout {
        static let safeDimensionCeiling: CGFloat = 10_000
        static let mediaPanelDefault: CGFloat = 500
        static let mediaPanelMin: CGFloat = 280
        static let inspectorDefault: CGFloat = 260
        static let inspectorMin: CGFloat = 150
        static let agentPanelMin: CGFloat = 240
        static let agentPanelMax: CGFloat = 640
        static let chatColumnMax: CGFloat = 640
        static let panelHeaderHeight: CGFloat = 28
        static let toolbarHeight: CGFloat = 38
        static let titleBarChromeHeight: CGFloat = 36
        static let trafficLightInset: CGFloat = 70
        static let panelGap: CGFloat = 5
        static let timelineMinHeight: CGFloat = 100
        static let timelineMaxHeight: CGFloat = 700
        static let produceTimelineStripHeight: CGFloat = 180
        static let produceTimelineStripDefault: CGFloat = 280
        static let producePreviewMinHeight: CGFloat = 180
        static let producePreviewDefaultWidth: CGFloat = 360
        static let trackHeight: CGFloat = 50
        static let rulerHeight: CGFloat = 24
        static let trackHeaderWidth: CGFloat = 100
        static let dropZoneHeight: CGFloat = 60
        static let insertThreshold: CGFloat = 10
        static let dragThreshold: CGFloat = 3
        static let previewMinWidth: CGFloat = 400
        static let previewMinHeight: CGFloat = 320
        static let finishPreviewMinHeight: CGFloat = 280
        static let finishReviewMinHeight: CGFloat = 200
        static let finishPreviewFraction: CGFloat = 0.68
    }

    enum Timeline {
        static let snapGuide = NSColor.systemYellow
        static var snapGuideColor: Color { Color(snapGuide) }
        static let razorGuide = NSColor.systemOrange
        static let playhead = NSColor.systemRed
        static let offsetBadge = NSColor(red: 1, green: 0.28, blue: 0.28, alpha: 1)
        static let trackMinHeight: CGFloat = 32
        static let trackMaxHeight: CGFloat = 200
        static let trackResizeHandleZone: CGFloat = 6
        static let trimHandleWidth: CGFloat = 4
        static let clipCornerRadius: CGFloat = Radius.xs
        static let clipTypeStripWidth: CGFloat = Radius.xs
        static let clipLabelBarHeight: CGFloat = 16
        static let clipVolumeKeyframeSize: CGFloat = 7
        static let clipVolumeKeyframeHitSize: CGFloat = 14
        static let clipVolumeFadeHandleEdgeInset: CGFloat = 6
        static let clipFadeKneeTopInset: CGFloat = 4
        static let keyframeRulerHeight: CGFloat = 18
        static let keyframeStripHeight: CGFloat = 14
        static let keyframeHeaderHeight: CGFloat = keyframeRulerHeight + keyframeStripHeight
        static let keyframeRowHeight: CGFloat = 22
        static let keyframeStampButtonWidth: CGFloat = 22
        static let keyframeNavigationButtonWidth: CGFloat = 6
        static let keyframeControlsColumnWidth: CGFloat =
            keyframeNavigationButtonWidth * 2 + keyframeStampButtonWidth
        static let keyframeDiamondSize: CGFloat = 8
        static let keyframeHitTolerance: CGFloat = 7
        static let keyframeSnapThresholdPixels: Double = 4
        static let playheadTriangleSize: CGFloat = 8
        static let rangeEdgeHitSlop: CGFloat = 8
        static let playbackFollowMargin: CGFloat = 60
        static let rippleIndicatorArrowWidth: CGFloat = 7
        static let rippleIndicatorArrowHeight: CGFloat = 10
        static let headerTypeStripWidth: CGFloat = 3
        static let headerIconSize: CGFloat = 14
        static let rulerMajorTickTargetPixels: Double = 80
        static let rulerMinimumMinorTickSpacing: Double = 12
        static let rulerLabelLeadingInset: Double = 3
        static let keyframeMarkerHalfSize: CGFloat = 3
        static let keyframeMarkerBottomInset: CGFloat = 5
        static let clipLabelInset: CGFloat = 6
        static let offsetBadgeHorizontalPadding: CGFloat = 4
        static let offsetBadgeVerticalPadding: CGFloat = 1
        static let waveformBarWidth: CGFloat = 1
    }

    enum BlendFraction {
        static let waveformHighlight: CGFloat = 0.30
    }

    enum Window {
        static let settingsDefault = NSSize(width: 980, height: 640)
        static let settingsMin = NSSize(width: 760, height: 480)
        // Cap for the home/launcher window. Like the editor, the real open size is a fraction of the
        // visible screen (60% × 82%) capped here, so on a tall display the launcher opens tall — enough
        // that the "Choose a format" sheet shows its pack cards without scrolling.
        static let homeDefault = NSSize(width: 1440, height: 1040)
        static let homeMin = NSSize(width: 760, height: 720)
        static let projectWidthFraction: CGFloat = 0.88
        static let projectHeightFraction: CGFloat = 0.96
        // The screen fraction governs Retina-scaled displays; the cap bounds unusually large desktops.
        static let projectDefault = NSSize(width: 2560, height: 1800)
        static let projectMin = NSSize(width: 960, height: 640)
        static let splash = NSSize(width: 600, height: 400)
        static let fallbackVisibleFrame = NSSize(width: 1440, height: 900)
    }

    enum Caption {
        static let defaultFontSize: Double = 48
        static let minFontSize: Double = 12
        static let maxFontSize: Double = 300
        static let minPosition: Double = 0
        static let maxPosition: Double = 1
        static let centerSnapValue: CGFloat = 0.5
        static let centerSnapThreshold: Double = 0.02
        static let defaultCenterY: CGFloat = 0.9
        static let defaultCenter = CGPoint(x: centerSnapValue, y: defaultCenterY)
        static let minDisplayDuration: Double = 0.7
    }

    enum GenerationPanel {
        static let mediaAreaMinHeight: CGFloat = 120
        static let loadingHeight: CGFloat = 180
        static let promptMinHeight: CGFloat = 40
        static let referenceTileWidth: CGFloat = 80
        static let referenceTileHeight: CGFloat = 56
    }

    enum MediaPanel {
        static let contextRowHeight: CGFloat = IconSize.md
    }

    enum Generating {
        static let thumbnailBarWidth: CGFloat = 60
        static let previewBarWidth: CGFloat = 160
        static let thumbnailBarHeight: CGFloat = 3
        static let previewBarHeight: CGFloat = 4
        static let progressDuration: Double = 45
        static let progressTarget: CGFloat = 0.9
        static let shimmerDuration: Double = 1.35
        static let shimmerWidthFraction: CGFloat = 0.45
        static let shimmerRotationDegrees: Double = 18
    }

    // MARK: - Shadows

    struct ShadowStyle {
        let color: Color
        let radius: CGFloat
        let x: CGFloat
        let y: CGFloat
    }

    enum Shadow {
        static let sm = ShadowStyle(color: .black.opacity(AppTheme.Opacity.shadow), radius: 1, x: 0, y: 0.5)
        static let md = ShadowStyle(color: .black.opacity(AppTheme.Opacity.shadow), radius: 4, x: 0, y: 2)
        static let lg = ShadowStyle(color: .black.opacity(AppTheme.Opacity.moderate), radius: 24, x: 0, y: 8)
        static let cardRest = ShadowStyle(color: .black.opacity(AppTheme.Opacity.dim), radius: 4, x: 0, y: 2)
        static let cardHover = ShadowStyle(color: .black.opacity(AppTheme.Opacity.settingsWindow), radius: 12, x: 0, y: 4)
        static let floating = ShadowStyle(color: .black.opacity(Opacity.medium), radius: 4, x: 0, y: 2)
        static let spotlight = ShadowStyle(
            color: Accent.spotlight.opacity(Opacity.strong),
            radius: 10,
            x: 0,
            y: 0
        )
        static let control = ShadowStyle(color: .black.opacity(Opacity.shadow), radius: 2, x: 0, y: 0)
        static let handle = ShadowStyle(color: .black.opacity(Opacity.shadow), radius: 1, x: 0, y: 1)
    }

    // MARK: - Custom cursors

    /// Timeline fade-knee cursor glyph. macOS cursor idiom: black glyph with a white
    /// outline, readable on any clip color — deliberately NOT theme-tinted.
    enum Cursor {
        static let size: CGFloat = 18
        static let strokeWidth: CGFloat = 3
        static let rampInsetX: CGFloat = 2
        static let rampBottomY: CGFloat = 4
        static let rampTopY: CGFloat = 14
        static let glyphColor = NSColor.black
        static let outlineColor = NSColor.white
    }

    // MARK: - Animation durations

    enum Anim {
        static let quick: Double = 0.12
        static let hover: Double = 0.15
        static let selection: Double = 0.18
        static let transition: Double = 0.2
        static let pulse: Double = 0.25
        static let cardSpringResponse: Double = 0.3
        static let cardSpringDamping: Double = 0.7
        static let copyConfirmation: Double = 1.4
        static let splashHold: Double = 2.4
        static let splashFade: Double = 0.35
    }
}

// MARK: - Shadow view modifier

extension View {
    func shadow(_ style: AppTheme.ShadowStyle) -> some View {
        shadow(color: style.color, radius: style.radius, x: style.x, y: style.y)
    }

    func panelHeaderBar() -> some View {
        frame(maxWidth: .infinity)
            .frame(height: AppTheme.Layout.panelHeaderHeight)
            .background(AppTheme.Background.raisedColor)
            .overlay(alignment: .bottom) {
                Rectangle().fill(AppTheme.Border.primaryColor).frame(height: AppTheme.BorderWidth.thin)
            }
    }
}

struct AppDivider: View {
    var body: some View {
        Divider()
            .overlay(AppTheme.Border.subtleColor)
    }
}

// MARK: - ClipType color mapping

extension ClipType {
    var themeColor: NSColor {
        switch self {
        case .video: AppTheme.TrackColor.video
        case .audio: AppTheme.TrackColor.audio
        case .image: AppTheme.TrackColor.image
        case .text: AppTheme.TrackColor.text
        case .lottie: AppTheme.TrackColor.lottie
        case .document: AppTheme.TrackColor.lottie
        }
    }
}
