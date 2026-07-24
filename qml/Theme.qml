pragma Singleton
import QtQuick

// Watchtower design tokens — see designs/design_handoff_watchtower/README.md.
// Warm-shifted graphite surfaces, a single amber accent, restrained status
// colors, two type families, and an intentionally orthogonal (0-radius) geometry.
QtObject {
    id: theme

    // ---------------------------------------------------------------- Color
    readonly property color bg:          "#1a1816"  // window bg, table headers, sub-bars
    readonly property color panel:       "#221f1c"  // cards, drawers, modals, top bar
    readonly property color panel2:      "#2a2722"  // hover / secondary surface
    readonly property color panel3:      "#322e28"  // raised surface (events-v2 cards/segments)
    readonly property color line:        "#34302a"  // subtle hairline dividers
    readonly property color line2:       "#443f37"  // component borders, table cells
    readonly property color ink:         "#f0ece4"  // primary text
    readonly property color ink2:        "#a89f90"  // secondary text
    readonly property color ink3:        "#6e6657"  // tertiary text, labels, placeholder
    readonly property color accent:      "#e8a13a"  // amber — primary, active, focus
    readonly property color accentDim:   "#5a3f15"  // amber chip/badge background
    readonly property color accentSoft:  Qt.rgba(232 / 255, 161 / 255, 58 / 255, 0.08)
    readonly property color warn:        "#e8a13a"  // = accent
    readonly property color warnDim:     "#5a3f15"
    readonly property color bad:         "#d96649"  // offline, REC indicator (burnt orange/red)
    readonly property color badDim:      "#4a2218"
    readonly property color good:        "#8eb96b"  // LIVE (olive)
    readonly property color goodDim:     "#2a4015"
    readonly property color rec:         "#d96649"  // recording (same as bad)
    readonly property color violet:      "#9a7bd0"  // bookmark markers/icons
    readonly property color badSoft:     Qt.rgba(217 / 255, 102 / 255, 73 / 255, 0.10)
    readonly property color goodSoft:    Qt.rgba(142 / 255, 185 / 255, 107 / 255, 0.10)
    readonly property color info:        "#6f9bc4"  // blue — in-progress / vehicle accents
    readonly property color infoDim:     "#2c4055"

    readonly property color windowBackdrop: "#0d0c0b"  // OS-level chrome backdrop
    readonly property color tileBg:         "#0a0908"  // near-black warm camera tile bg
    // Title-bar surface (design: linear-gradient(#252220, #1c1a17) over a black hairline).
    readonly property color titleBarTop:    "#252220"
    readonly property color titleBarBottom: "#1c1a17"

    // ----------------------------------------------------------- Typography
    // Two families only. Mono is used for timestamps, IDs, counts, uppercase
    // labels, and tabular numerics. Never set Space Grotesk in all-caps.
    readonly property string fontSans: "Space Grotesk"
    readonly property string fontMono: "JetBrains Mono"

    readonly property int fsDisplay: 32  // login/health big number (700)
    readonly property int fsH1:      24  // page H1 (600)
    readonly property int fsTitle:   16  // modal/drawer title (600)
    readonly property int fsBody:    13  // body (400)
    readonly property int fsSmall:   12  // small body / table cell
    readonly property int fsMono:    11  // tabular numeric / timestamp / id
    readonly property int fsLabel:   10  // uppercase eyebrow / column header
    readonly property int fsBadge:    9  // status badge text

    // -------------------------------------------------------------- Spacing
    // 4px base. Tokens named by pixel value to map 1:1 onto the design rhythm.
    readonly property int s4:   4
    readonly property int s8:   8
    readonly property int s10:  10
    readonly property int s12:  12
    readonly property int s14:  14
    readonly property int s16:  16
    readonly property int s18:  18
    readonly property int s20:  20
    readonly property int s22:  22
    readonly property int s24:  24
    readonly property int s28:  28
    readonly property int s32:  32
    readonly property int s36:  36
    readonly property int s48:  48
    readonly property int s56:  56

    // ----------------------------------------------------- Geometry / chrome
    readonly property int radius: 0  // orthogonal everywhere; only status dots are round

    readonly property int titleBarHeight:  36
    readonly property int tabStripHeight:  34   // view tabs, only while camera tabs are open
    readonly property int topBarHeight:     64
    readonly property int subBarHeight:     56
    readonly property int railWidth:        72
    readonly property int opsSidebarWidth: 320
    readonly property int navItemHeight:    56

    readonly property int borderThin:   1  // hairline dividers / component borders
    readonly property int edgeAccent:   3  // active nav rail edge, fault tile top edge
    readonly property int edgeToast:    4  // toast left edge

    // Severity → color (events-v2: critical=bad, high=accent, medium=ink-2, low=ink-3).
    function sevColor(p) {
        return p === "critical" ? bad : p === "high" ? accent : p === "medium" ? ink2 : ink3;
    }
}
