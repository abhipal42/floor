package app.floor.android.design

import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.ReadOnlyComposable
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.graphics.Color
import app.floor.android.model.SocialNetwork
import app.floor.android.model.TopicGroup
import kotlin.math.pow

/**
 * One colour token with a value for each appearance (iOS `Swatch`).
 *
 * The dark values are the v2 design canvas's own hexes and the locked app mocks'. The light values
 * are direction D, "Marble & Patina": a cool marble ground, white panels, and outcome colours
 * darkened until text in them reads at 4.5:1 or better on both.
 */
data class Swatch(
    val light: Long,
    val dark: Long,
    val lightOpacity: Float = 1f,
    val darkOpacity: Float = 1f,
) {
    fun color(dark: Boolean): Color =
        if (dark) hex(this.dark, darkOpacity) else hex(light, lightOpacity)

    companion object {
        /** WCAG 2 relative luminance of an sRGB hex. */
        fun luminance(hex: Long): Double {
            fun channel(value: Long): Double {
                val c = (value and 0xFF).toDouble() / 255
                return if (c <= 0.03928) c / 12.92 else ((c + 0.055) / 1.055).pow(2.4)
            }
            return 0.2126 * channel(hex shr 16) + 0.7152 * channel(hex shr 8) + 0.0722 * channel(hex)
        }

        /** WCAG 2 contrast ratio between two opaque colours, 1..21. */
        fun contrast(a: Long, b: Long): Double {
            val x = luminance(a)
            val y = luminance(b)
            return (maxOf(x, y) + 0.05) / (minOf(x, y) + 0.05)
        }
    }
}

/** `hex(0x34D399)`, so the canvas's values can be pasted in as written. */
fun hex(rgb: Long, opacity: Float = 1f): Color = Color(0xFF000000 or rgb).copy(alpha = opacity)

/** Every adaptive token, as data, so the tests can check contrast without drawing anything. */
object Tones {
    // Ground and surfaces
    val ground = Swatch(0xECEFEE, 0x07080A)
    val card = Swatch(0xFFFFFF, 0x1E2128)
    val cardSunken = Swatch(0xF1F4F3, 0x15171C)
    val chip = Swatch(0xE1E6E4, 0x23262E)
    val track = Swatch(0xD7DDDA, 0x2A2E37)
    val cardBorder = Swatch(0x111816, 0xFFFFFF, lightOpacity = 0.08f, darkOpacity = 0.06f)

    // Text
    val text = Swatch(0x111816, 0xFFFFFF)
    val textSecondary = Swatch(0x38433F, 0xC9CED6)
    val textMuted = Swatch(0x616D68, 0x9BA1AD)
    val trailing = Swatch(0x76817D, 0x7E8592)

    // Vote outcomes
    val yea = Swatch(0x0B7A57, 0x34D399)
    val yeaBright = Swatch(0x086146, 0x6EE7B7)
    val nay = Swatch(0xA8481A, 0xFB923C)
    val nayBright = Swatch(0x8C3B14, 0xFDBA74)

    // State
    val live = Swatch(0xC8281C, 0xFF453A)
    val liveText = Swatch(0xB42318, 0xFF6B61)
    val scheduled = Swatch(0x7D5800, 0xFDE047)
    val accent = Swatch(0x1C6F5B, 0x34D399)
    val accentSoft = Swatch(0x2E7D68, 0xA7F3D0)

    // From the app-matches-landing round
    val threshold = Swatch(0x8A6500, 0xFACC15)
    val panel = Swatch(0xFFFFFF, 0x14161B)
    val panelBorder = Swatch(0xD5DBD8, 0x2A2E36)
    val raised = Swatch(0xC3CAC7, 0x3A3F49)
    val groundGlow = Swatch(0xD3E3DD, 0x0F2A20)
    val shadow = Swatch(0x111816, 0x000000, lightOpacity = 0.14f, darkOpacity = 0.45f)

    // From the LocApp mock (onboarding with location).
    val warningPanel = Swatch(0xFBF0E6, 0x1E1610)
    val warningBorder = Swatch(0xE2B48E, 0x5A3A1E)
    val textFaint = Swatch(0x636E69, 0x858B95)

    // From the AppRepMoney mock: bar fills, and the AI label colour (text, so contrast-tested).
    val teal = Swatch(0x0B4A45, 0x0F9488)
    val dim = Swatch(0x3F4945, 0x858B95)
    val ai = Swatch(0x5B3FB5, 0xC4B5FD)
    val aiInk = Swatch(0xFFFFFF, 0x1A1033)
    const val AI_CARD_TINT = 0.08f

    /** The Money bar's four fills, left to right. */
    val moneyBar = listOf(yea, teal, threshold, dim)

    // From the members-elect mock (round 12): anything about a member-elect. Text, so contrast-tested.
    val elect = Swatch(0x0369A1, 0x7DD3FC)
    /** Text on an [elect] fill: the ELECT tag. */
    val electInk = Swatch(0xFFFFFF, 0x07263A)
    /** How strongly the takes-office banner is washed with [elect]. */
    const val ELECT_TINT = 0.08f

    // From the round 13 mock (Said): the top of the deck's front card, washed down into the panel.
    val deckTop = Swatch(0xE2E8F2, 0x23304A)

    // The home-screen widget's ground.
    val widget = Swatch(0xFFFFFF, 0x0B0C0F)

    // From the Finals stories mock (v0.2.57): a story's band, by topic group. The band's text is
    // white in both appearances, so every value reads at 4.5:1 or better under white (PaletteTest).
    // The dark defense, money, courts and other values are the Arena direction's own (`.d1`).
    val topicDefense = Swatch(0x3B6E8F, 0x2D5F86)
    val topicMoney = Swatch(0x7A5A12, 0x8A6512)
    val topicCourts = Swatch(0x6A4C9C, 0x5E3FA0)
    val topicHealth = Swatch(0xB0304A, 0x962840)
    val topicLand = Swatch(0x2F6B3A, 0x285C32)
    val topicRights = Swatch(0x1F6E73, 0x1A5C60)
    val topicGov = Swatch(0x8C3F5D, 0x783550)
    val topicOther = Swatch(0x5E6A66, 0x4A5560)

    // Arena (the locked app-wide direction, 2026-11-17): a story card's gradient hairline, bright at
    // the top left and fading by 40% along 160 degrees, and its soft drop shadow.
    val storyEdge = Swatch(0x111816, 0xFFFFFF, lightOpacity = 0.14f, darkOpacity = 0.18f)
    val storyEdgeFade = Swatch(0x111816, 0xFFFFFF, lightOpacity = 0.06f, darkOpacity = 0.02f)
    val storyShadow = Swatch(0x111816, 0x000000, lightOpacity = 0.22f, darkOpacity = 0.9f)

    // Arena app-wide (phase 2, v0.2.58): every card is glass, a fill with a 1dp top highlight and a
    // soft long drop shadow (`.d1 --shadowS`); a post card's fill runs down from [postTop] to
    // [postBottom]; a promise card's from [promiseTop] to [promiseBottom] (`--promiseBg`).
    val cardShadow = Swatch(0x111816, 0x000000, lightOpacity = 0.14f, darkOpacity = 0.8f)
    val cardHighlight = Swatch(0xFFFFFF, 0xFFFFFF, lightOpacity = 0f, darkOpacity = 0.05f)
    val postTop = Swatch(0xFFFFFF, 0x181B22)
    val postBottom = Swatch(0xF4F7F6, 0x13161B)
    val promiseTop = Swatch(0xE2E8F2, 0x1F2530)
    val promiseBottom = Swatch(0xFFFFFF, 0x14171D)

    /** Text on the call button's [yea] fill (`--callInk`). */
    val callInk = Swatch(0xFFFFFF, 0x06231A)

    /**
     * The member hero, by party (`--heroBg`, `--heroFx`): a deep gradient from [heroTop] at the top
     * left to [heroBottom], with [heroLight] as a radial light at the top right. White text in both
     * appearances, like a story band, so each value reads at 4.5:1 or better under white.
     * The dark Democratic values are Arena's own; Republican and independent follow the same recipe.
     */
    fun heroTop(party: String): Swatch = when (party) {
        "D" -> Swatch(0x2F5FD0, 0x1E3A8A)
        "R" -> Swatch(0xB43636, 0x7F1D1D)
        else -> Swatch(0x5E6A66, 0x3F4652)
    }

    fun heroBottom(party: String): Swatch = when (party) {
        "D" -> Swatch(0x1A2F6E, 0x0B1430)
        "R" -> Swatch(0x5C1616, 0x2A0B0B)
        else -> Swatch(0x2B3230, 0x14171C)
    }

    fun heroLight(party: String): Swatch = when (party) {
        "D" -> Swatch(0x8DB8FF, 0x6EA8FE, lightOpacity = 0.5f, darkOpacity = 0.5f)
        "R" -> Swatch(0xFCA5A5, 0xF87171, lightOpacity = 0.45f, darkOpacity = 0.45f)
        else -> Swatch(0xD1D5DB, 0xC9CED6, lightOpacity = 0.35f, darkOpacity = 0.3f)
    }

    /** The party chip's text on [partyTint] (`--partyInk`): "D-NY" on a post. Contrast-tested. */
    fun partyInk(party: String): Swatch = when (party) {
        "D" -> Swatch(0x1E4AB0, 0xBFD6FF)
        "R" -> Swatch(0x9B2C2C, 0xFECACA)
        else -> Swatch(0x38433F, 0xE4E4E7)
    }

    /** The three networks Floor reads, in their own brand colours (allowed as tokens by the spec). */
    const val BLUESKY = 0x1185FEL
    const val YOUTUBE = 0xFF0033L
    const val MASTODON = 0x6364FFL

    /** The band text on a topic colour, and the verdict chip on the band: the same in both appearances. */
    const val BAND_INK = 0xFFFFFFL
    const val VERDICT_INK = 0x0B0C0FL

    fun topic(group: TopicGroup): Swatch = when (group) {
        TopicGroup.DEFENSE -> topicDefense
        TopicGroup.MONEY -> topicMoney
        TopicGroup.COURTS -> topicCourts
        TopicGroup.HEALTH -> topicHealth
        TopicGroup.LAND -> topicLand
        TopicGroup.RIGHTS -> topicRights
        TopicGroup.GOV -> topicGov
        TopicGroup.OTHER -> topicOther
    }

    /**
     * A topic's colour as text on the ground or a card (v0.2.59: a Bills section's header, a
     * fast-track tile's count). Light uses the band colour itself; dark, the mock's lighter tint of
     * it, since the bands are too deep to read on Arena's near-black. Contrast-tested.
     */
    fun topicText(group: TopicGroup): Swatch = when (group) {
        TopicGroup.DEFENSE -> Swatch(topicDefense.light, 0x8FB8DB)
        TopicGroup.MONEY -> Swatch(topicMoney.light, 0xE0B85A)
        TopicGroup.COURTS -> Swatch(topicCourts.light, 0xB9A3F0)
        TopicGroup.HEALTH -> Swatch(topicHealth.light, 0xF0879E)
        TopicGroup.LAND -> Swatch(topicLand.light, 0x7FBF6A)
        TopicGroup.RIGHTS -> Swatch(topicRights.light, 0x6CC4C9)
        TopicGroup.GOV -> Swatch(topicGov.light, 0xE39BBA)
        TopicGroup.OTHER -> Swatch(topicOther.light, 0xA9B4B0)
    }

    /** A chamber's label on a Week headliner (v0.2.59 mock): the Senate blue, the House gold. */
    val senate = Swatch(0x2F5FD0, 0x6EA8FE)
    val house = threshold

    fun party(party: String): Swatch = when (party) {
        "D" -> Swatch(0x2F5FD0, 0x6EA8FE)
        "R" -> Swatch(0xB43636, 0xF87171)
        else -> Swatch(0x616D68, 0x9BA1AD)
    }

    fun partyTint(party: String): Swatch = when (party) {
        "D" -> Swatch(0xDCE6FB, 0x1E3A8A)
        "R" -> Swatch(0xFBE1DE, 0x7F1D1D)
        else -> Swatch(0xE1E6E4, 0x3F3F46)
    }

    /** Text tokens that must read at 4.5:1 on the ground and on a panel, in both appearances. */
    val textTokens: List<Pair<String, Swatch>> = listOf(
        "text" to text, "textSecondary" to textSecondary, "textMuted" to textMuted, "textFaint" to textFaint,
        "yea" to yea, "nay" to nay, "liveText" to liveText, "scheduled" to scheduled,
        "accent" to accent, "threshold" to threshold, "ai" to ai, "elect" to elect,
        "party D" to party("D"), "party R" to party("R"), "party I" to party("I"),
        "senate" to senate, "house" to house,
    ) + TopicGroup.entries.map { "topic ${it.name}" to topicText(it) }
}

/**
 * The app's colours for one appearance. Screens read them through [Palette]; nothing in a screen
 * names a hex.
 */
class FloorColors(val isDark: Boolean) {
    private fun of(swatch: Swatch) = swatch.color(isDark)

    val ground = of(Tones.ground)
    val card = of(Tones.card)
    val cardSunken = of(Tones.cardSunken)
    val chip = of(Tones.chip)
    val track = of(Tones.track)
    val cardBorder = of(Tones.cardBorder)
    val text = of(Tones.text)
    val textSecondary = of(Tones.textSecondary)
    val textMuted = of(Tones.textMuted)
    val trailing = of(Tones.trailing)
    val yea = of(Tones.yea)
    val yeaBright = of(Tones.yeaBright)
    val nay = of(Tones.nay)
    val nayBright = of(Tones.nayBright)
    val live = of(Tones.live)
    val liveText = of(Tones.liveText)
    val scheduled = of(Tones.scheduled)
    val accent = of(Tones.accent)
    val accentSoft = of(Tones.accentSoft)
    val threshold = of(Tones.threshold)
    val panel = of(Tones.panel)
    val panelBorder = of(Tones.panelBorder)
    val raised = of(Tones.raised)
    val groundGlow = of(Tones.groundGlow)
    val shadow = of(Tones.shadow)
    val warningPanel = of(Tones.warningPanel)
    val warningBorder = of(Tones.warningBorder)
    val textFaint = of(Tones.textFaint)
    val teal = of(Tones.teal)
    val dim = of(Tones.dim)
    val ai = of(Tones.ai)
    val aiInk = of(Tones.aiInk)
    val widget = of(Tones.widget)
    val elect = of(Tones.elect)
    val electInk = of(Tones.electInk)
    val deckTop = of(Tones.deckTop)

    fun party(party: String) = of(Tones.party(party))
    fun partyTint(party: String) = of(Tones.partyTint(party))
    fun topic(group: TopicGroup) = of(Tones.topic(group))
    fun topicText(group: TopicGroup) = of(Tones.topicText(group))
    fun chamberText(chamber: app.floor.android.model.Chamber) =
        of(if (chamber == app.floor.android.model.Chamber.SENATE) Tones.senate else Tones.house)

    /** A story band's text and the verdict chip on it (iOS `bandInk`, `verdictInk`). */
    val bandInk = hex(Tones.BAND_INK)
    val verdictInk = hex(Tones.VERDICT_INK)

    /** The band's sheen at its top right and its shade at the bottom (Arena's `--bandFx`). */
    val bandSheen = hex(0xFFFFFF, 0.25f)
    val bandShade = hex(0x000000, 0.3f)

    /** The verdict chip's fill: near-white in both appearances. */
    val verdictChip = hex(0xFFFFFF, 0.95f)

    val storyEdge = of(Tones.storyEdge)
    val storyEdgeFade = of(Tones.storyEdgeFade)
    val storyShadow = of(Tones.storyShadow)

    /** The 1dp inner highlight along a story card's top edge (Arena's `inset 0 1px 0`). */
    val storyHighlight = hex(0xFFFFFF, 0.06f)

    val cardShadow = of(Tones.cardShadow)
    val cardHighlight = of(Tones.cardHighlight)
    val postTop = of(Tones.postTop)
    val postBottom = of(Tones.postBottom)
    val promiseTop = of(Tones.promiseTop)
    val promiseBottom = of(Tones.promiseBottom)
    val callInk = of(Tones.callInk)
    fun heroTop(party: String) = of(Tones.heroTop(party))
    fun heroBottom(party: String) = of(Tones.heroBottom(party))
    fun heroLight(party: String) = of(Tones.heroLight(party))
    fun partyInk(party: String) = of(Tones.partyInk(party))

    /** A network's brand colour: its badge on a post's portrait. */
    fun network(network: SocialNetwork): Color = when (network) {
        SocialNetwork.BLUESKY -> hex(Tones.BLUESKY)
        SocialNetwork.YOUTUBE -> hex(Tones.YOUTUBE)
        SocialNetwork.MASTODON -> hex(Tones.MASTODON)
        else -> text
    }

    // The member hero is a lit surface, the same in both appearances: white text, glass tiles, the
    // streak in Arena's own yea and nay, a missed call as translucent white.
    val heroInk = hex(0xFFFFFF)
    val heroTile = hex(0xFFFFFF, 0.12f)
    val heroTileBorder = hex(0xFFFFFF, 0.16f)
    val heroRing = hex(0xFFFFFF, 0.2f)
    val heroButtonDim = hex(0xFFFFFF, 0.16f)
    val heroShadow = hex(0x000000, 0.6f)
    val heroGreen = hex(0x34D399, 0.18f)
    val streakYea = hex(0x34D399)
    val streakNay = hex(0xFB923C)
    val streakOther = hex(0xFFFFFF, 0.25f)

    /** A video thumbnail's centred play button (`.post .play i`). */
    val playScrim = hex(0x000000, 0.55f)
    val playRing = hex(0xFFFFFF, 0.7f)
    val playInk = hex(0xFFFFFF)

    // Lit displays: the same in both appearances.
    /** The split-flap board: its frame, and the top and bottom halves of each cell. */
    val flapBoard = hex(0x0B0C0F)
    val flapTop = hex(0x1C1F25)
    val flapBottom = hex(0x121418)

    /** The broadcast scoreboard on the vote screen: turf stripes and its border. */
    val turf = hex(0x0E1A14)
    val turfAlt = hex(0x0B1611)
    val turfBorder = hex(0x1E2A23)

    /**
     * The no-platform card's browser frame (round 13): an archived web page, drawn as paper in both
     * appearances as a page is, with the Wayback stamp's red.
     */
    val browserBar = hex(0x22252C)
    val browserUrl = hex(0x14161B)
    val browserChrome = hex(0xC4C9D2)
    val browserDot = hex(0x3A3F49)
    val paper = hex(0xF4F2EC)
    val paperInk = hex(0x14161B)
    val paperRule = hex(0xD9D5CB)
    val wayback = hex(0xB4232A)

    /** The silver frame around a player card, light in both appearances, and the text on it. */
    val silver = listOf(hex(0xE5E7EB), hex(0x6B7280), hex(0xC4C9D2))
    val silverInk = hex(0x07080A)

    companion object {
        val Light = FloorColors(isDark = false)
        val Dark = FloorColors(isDark = true)
    }
}

val LocalFloorColors = staticCompositionLocalOf { FloorColors.Light }

/** The current appearance's colours: `Palette.yea`, `Palette.panel`. */
val Palette: FloorColors
    @Composable @ReadOnlyComposable get() = LocalFloorColors.current

/**
 * Draws [content] in the dark palette whatever the appearance: for the split-flap board and the
 * turf scoreboard, which are lit displays rather than surfaces.
 */
@Composable
fun LitObject(content: @Composable () -> Unit) {
    CompositionLocalProvider(LocalFloorColors provides FloorColors.Dark, content = content)
}
