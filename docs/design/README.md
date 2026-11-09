# Design: Ink and Signal

## Overview

This is the visual specification for the SpeakUp iPhone app in home mode.
It says how screens look, where things live and how each part maps to SwiftUI.
What the app does, how feedback is graded and what the metrics mean stay in [product.md](../product.md); this file never overrides it.

Status: direction v1, proposed on 2026-11-09 and waiting for Ryan's review.
The questions still open are in [Decisions for Ryan](#decisions-for-ryan).

**Direction, "Ink and Signal".**
Black and white carry the whole interface, set in SF Pro on plain system backgrounds, so the app reads like a native Apple tool and Ryan's own words stay the loudest thing on screen.
One red-orange signal color means "act here": the record button, the "needs work" level and every problem marked in the transcript.
Feedback is typographic rather than chart-heavy: a verdict in large type, quotes from the take with play buttons, and a transcript marked up like an editor's proof, with a different mark for each kind of problem.
There is no score anywhere; every dimension shows a level as a word plus a three-segment meter.

## Files

- `prototype/index.html` is a static, clickable prototype of every home-mode screen at 390 by 844 pt, in light and dark side by side.
  Open it from disk in Safari or Chrome.
  Buttons inside a phone jump to the next screen; the legend chips in the report toggle each kind of mark; tapping a mark or a timestamp moves the player.
  A switch at the top shows both themes, light only or dark only.
- `screenshots/` holds a 2x PNG of every frame, named `<screen>-<light|dark>.png`.
  Long screens (report, comparison, history) also have `<screen>-full-<theme>.png`, the whole scroll in one image.
- `prototype/capture.py` regenerates the screenshots: `uv run --with playwright python docs/design/prototype/capture.py` from the repository root.
  It uses the installed Google Chrome.

The prototype is a design reference, not code to port.
Where it approximates the platform, the app uses the real thing:

- Icons are Material Symbols Rounded as a stand-in; the app uses the SF Symbols in [Icons](#icons).
- Toolbar buttons, the tab bar and the player use a CSS imitation of Liquid Glass; the app uses the system glass material.
- The status bar, Dynamic Island and home indicator are drawn only for context.
- All content is sample data written for the prototype.

## Principles

1. **Ryan's words are the material.**
   Quotes, the transcript and the reference version are set as readable text at body size or larger, never shrunk into a chart.
   Every quote carries a timestamp chip that plays that moment.
2. **One signal color, and it means act.**
   Red-orange marks recording, "needs work" and problems in the transcript.
   It is never decoration.
   Green appears only for "what worked" and "improved".
   Everything else is black, white and grays.
3. **Levels, not scores.**
   A dimension shows a word and a three-segment meter, both always together, so color is never the only cue.
4. **The report reads in the order Ryan acts.**
   Verdict, what worked, what to fix with the Retry button, then the evidence: dimensions, structure, transcript, reference version, metrics.
5. **Calm while speaking.**
   The recording screen shows time, the target window and a level meter, and nothing that grades him mid-take.
6. **Native first.**
   System navigation, sheets, full-screen cover, tab bar, Liquid Glass toolbars, Dynamic Type, light and dark mode.
   Custom drawing is limited to the record control, level meters, transcript marks, the take timeline and the two history charts.

## Design tokens

### Color roles

Each role is a color set in `Assets.xcassets` with light and dark appearances, exposed as a static on a `Theme` namespace (for example `Theme.signal`).
Where a system color matches exactly, use the system color instead of a custom asset.

| Role | Use | Light | Dark | SwiftUI |
| --- | --- | --- | --- | --- |
| `background` | Every screen, sheets | `#FFFFFF` | `#000000` | `Color(.systemBackground)` |
| `surface` | Cards, tiles, inputs, chips, timestamp chips on `background` | `#F2F2F7` | `#1C1C1E` | `Color(.secondarySystemBackground)` |
| `fill` | Empty meter segments, ruler track, timestamp chips on `surface` (dark) | `#E5E5EA` | `#2C2C2E` | `Color(.systemGray5)` |
| `ink` | Primary text, icons, filled primary buttons, strong and okay meter segments | `#000000` | `#FFFFFF` | `.primary` |
| `ink2` | Secondary text: meta, evidence, captions, quotes, timestamps | `#6C6C70` | `#98989F` | custom asset |
| `ink3` | Chevrons and pending step rings only, never text that must be read | `#AEAEB2` | `#545458` | custom asset |
| `separator` | Hairlines between rows | `rgba(60,60,67,.16)` | `rgba(84,84,88,.55)` | `Color(.separator)` |
| `signal` | Record control, "needs work", focus card heading, blocks, off-topic bar, current-value flags | `#C8341A` | `#FF6A4D` | custom asset |
| `signalTint` | Filler highlight, "new this take" pill, off-topic range on the timeline | `signal` at 11% | `signal` at 22% | custom asset |
| `onSignal` | Text on a `signal` fill (block chip) | `#FFFFFF` | `#000000` | custom asset |
| `good` | "What worked" heading, "improved" pill and metric arrows | `#1E7A4C` | `#3DCB82` | custom asset |
| `goodTint` | "Improved" pill background | `good` at 10% | `good` at 14% | custom asset |
| `onInk` | Text and icons on an `ink` fill (primary buttons, selected chips, play button) | `#FFFFFF` | `#000000` | `Color(.systemBackground)` |
| `levelOkay` | "Okay" cells in the dimension grid, target zone on the recording ruler | black at 28% | white at 34% | custom asset |
| `meterEmpty` | Unfilled segments in level-history columns | `#E5E5EA` | `#3A3A3C` | custom asset |
| `ring` | Outer ring of the record control | `#C7C7CC` | `#545458` | custom asset |

- **Tint.** The app's tint is `ink` (`.tint(.primary)`), so links, toggles and toolbar buttons are black or white.
  System blue never appears.
- **Why a custom `ink2`.** The system `secondaryLabel` is 60% gray and measures about 3.4:1 on white, below AA for the 13 to 15 pt text it would set.
  `ink2` measures 5.2:1 on `background` and 4.7:1 on `surface` in light, 7.3:1 and 5.9:1 in dark.
- **Contrast of the accents.** `signal` text measures 5.3:1 on `background` and 4.75:1 on `surface` in light, 7.4:1 and 6.0:1 in dark.
  `good` measures 5.3:1 and 4.8:1 in light, 8.2:1 on `surface` in dark.
  White on light `signal` is 5.6:1; black on dark `signal` is 7.4:1.
- **Color is never alone.** Every signal or good color travels with a word, an icon or a shape: "Needs work", the meter, the mark style, an arrow.

### Typography

SF Pro only, through `Font.system`, so Dynamic Type, optical sizes and the Display cut come for free.
Sizes below are the defaults at the Large content size; every style scales with `relativeTo:` the text style named.
All figures use `.monospacedDigit()`.

| Token | Size, weight | Line height | Relative to | Use |
| --- | --- | --- | --- | --- |
| `screenTitle` | 34 bold | 41 | `.largeTitle` | Practice, History (the system large navigation title) |
| `question` | 32 semibold, tracking -3% | 38 | `.largeTitle` | The impromptu question |
| `promptTitle` | 22 semibold, tracking -2% | 28 | `.title2` | Prompt at the top of recording, processing, report, comparison |
| `verdict` | 21 medium, tracking -2% | 29 | `.title3` | Verdict paragraph |
| `section` | 20 semibold, tracking -2% | 25 | `.title3` | Section titles: Fix next, Dimensions, Structure, Transcript |
| `cardTitle` | 22 semibold | 28 | `.title2` | Focus name on Home and History, start tiles use 20 |
| `instruction` | 19 semibold, tracking -2% | 25 | `.headline` | The "do this" line in a focus card |
| `body` | 17 regular | 22 to 24 | `.body` | Rows, strength text, reference version |
| `transcript` | 17 regular | 29 | `.body` | Annotated transcript; the extra leading leaves room for marks |
| `quote` | 16 regular, `ink2` | 23 | `.callout` | Quotes from the take, in typographic quotes |
| `meta` | 15 regular, `ink2` | 20 | `.subheadline` | Evidence lines, row subtitles, helper text |
| `label` | 15 semibold | 20 | `.subheadline` | Level words, field labels, focus card headings |
| `caption` | 13 medium or semibold, `ink2` | 18 | `.footnote` | "Verdict", gutter timestamps, chip text, tile labels |
| `micro` | 11 to 12 semibold | 14 | `.caption2` | Block chip text, chart axis labels |
| `timer` | 92 thin | 92 | `.largeTitle` | Recording timer, `.monospacedDigit()` |

No uppercase tracked labels.
Hierarchy comes from size and weight, not from small caps.

### Spacing, shape, depth

- 4 pt grid.
  Screen side margin **20**.
  Section spacing **36** (from the end of one section to the next section title).
  Row vertical padding **12 to 13**; card padding **16**; tile padding **14**.
- Shapes follow one rule: content containers are rounded rectangles with `.continuous` corners, every interactive control is a capsule or a circle.
  Cards **22**, metric tiles **20**, the nervousness card **20**, inputs **14**, the text editor **16**, meter segments **2 to 3**.
  Buttons, chips, the timestamp chip, the player and the tab bar are capsules; toolbar buttons and the play button are circles.
- No shadows on content.
  Depth comes only from the system glass on toolbars, the tab bar and the docked player, and from the sheet presentation.
- Lists are hairline rows on `background`, not inset grouped cards.
  Cards (`surface`) are used only where a block is a unit Ryan acts on: the focus strip, start tiles, focus cards, comparison cards, metric tiles, the reference version.

### Icons

SF Symbols, weight matched to the adjacent text, `.imageScale(.medium)` unless noted.

| Use | SF Symbol |
| --- | --- |
| Practice tab | `mic` (selected: `mic.fill`) |
| History tab | `clock.arrow.circlepath` |
| Settings | `gearshape` |
| Back, close, more | system back button, `xmark`, `ellipsis` |
| Impromptu tile | `bubble.left.and.bubble.right` |
| Prepared tile | `list.bullet.rectangle` |
| Dictate | `mic` |
| Suggested length | `timer` |
| Another question | `arrow.triangle.2.circlepath` |
| Focus card heading | `scope` |
| What worked | `checkmark.circle.fill` |
| Done step | `checkmark` in a filled `ink` circle |
| Retry | `arrow.counterclockwise` |
| Play, pause | `play.fill`, `pause.fill` |
| Improved, metric down | `arrow.up`, `arrow.down` |
| Level change | `arrow.right` |
| Session at home, in the car | `house`, `car` |
| Row disclosure | `chevron.right` in `ink3` |

## Navigation

- `TabView` with two tabs, **Practice** and **History**, each with its own `NavigationStack`.
  The tab bar is the system iOS 26 tab bar; the prototype only imitates it.
- Practice:
  - Home pushes **Impromptu**.
  - Home presents **Prepared** as a sheet at the `.large` detent.
  - Record on either presents a `fullScreenCover` that holds **Recording** and then **Processing**.
  - When feedback is ready the cover dismisses and **Report** is pushed onto the Practice stack.
    If Ryan left Processing, the report appears in Recent and History, and a local notification links to it.
  - **Retry this prompt** presents the recording cover again for the next take; when its feedback is ready, **Comparison** is pushed on top of the report.
  - Comparison's **Next prompt** returns to Impromptu with a new question; **Retry** records another take.
- History pushes a session, then a prompt's comparison or a take's report.
- Driving-mode sessions open in the same report and comparison screens.

## Components

Each component lists its anatomy, states and the SwiftUI shape it takes.
Measurements are in points.

### Prompt header

- Used at the top of Report, Comparison, Processing and Recording.
- Anatomy: mode caption ("Impromptu", `caption`), the prompt (`promptTitle`, up to three lines, never truncated), a meta line (`meta`): "Take 1 of 1, 1:24".
- On Recording the caption and meta are dropped; the prompt alone sits under the toolbar.
- SwiftUI: a `VStack(alignment: .leading, spacing: 4)`; the meta line uses `Text(duration, format: .time(pattern: .minuteSecond))`.

### Impromptu question

- Category chips in a horizontal `ScrollView`: capsule, height 36, `surface` fill, `body` 15 medium; the selected chip is an `ink` fill with `onInk` text.
  Categories: Explain a decision, Status update, Teach a concept, Push back.
- The question in `question` style, 30 pt below the chips; a context line in `body` `ink2`; a meta line with `timer` and the suggested length.
- **Another question** is a capsule button, height 40, `surface` fill, `label` text.
- The record control is docked at the bottom center, 34 above the bottom edge, with the word "Record" under it.

### Prepared input

- A sheet with a close button and the title "Prepared".
- Fields, each with its label above (`label`): **Title** (single-line field), **Your points** (multi-line editor; each line renders as a bullet; helper text under the label in `caption`), **Target length** (segmented `Picker`: 30 s, 1 min, 2 min, 3 min).
- **Dictate** is a glass capsule inside the editor's bottom-right corner and starts on-device dictation into the editor.
- The record control is docked as on Impromptu.

### Nervousness scale

- Shown only before the first take of a session, on the prompt screen, and again as a short sheet when the session ends.
- A `surface` card: the question (`label`), five equal buttons 1 to 5 (height 40, radius 12, `background` fill in light and `fill` in dark, selected `ink` fill), end labels "Calm" and "Very" in `caption`.
- Optional: skipping it never blocks recording.

### Record control

- 84 diameter.
  A 4-point ring in `ring`, a 66 inner circle in `signal`.
- Recording state: the inner shape morphs to a 32 by 32 rounded square (radius 8), still `signal`.
- Label under it (`label`): "Record" when idle; on Recording the hint "Tap stop or say “done”" sits above it in `meta` instead.
- SwiftUI: a `Button` with a custom `ButtonStyle`; the inner shape is a `RoundedRectangle` whose size and corner radius animate with `.spring(duration: 0.35, bounce: 0.2)`.
  `.sensoryFeedback(.impact(weight: .medium), trigger: isRecording)`.
  Accessibility label "Record" or "Stop recording".

### Recording readout

- **Timer**: `timer` style, centered, 84 below the prompt.
  It keeps counting past the target; nothing turns red when time runs over, because the product never cuts a take off.
- **Target ruler**: 300 wide, centered, 26 below the timer.
  A 2-point `fill` track from 0 to the target maximum, a 6-point `levelOkay` bar over the target window (1:00 to 2:00 here), the elapsed part of the track in `ink`, and a 12-point `signal` dot at the current time with a 3-point `background` halo.
  Tick labels in `caption` at 0:00, the window start and the window end.
  Past the end, the track rescales so the dot stays visible.
- **Level meter**: a row of 3-point capsules across the full content width, 96 tall, newest on the right, opacity rising from 25% at the left to 100% at the right.
  Bars come from `AVAudioRecorder.averagePower` (or the audio engine tap) at about 30 updates a second; silences show as 4-point dots, so Ryan can see his own pauses.
  Draw it with `Canvas` inside a `TimelineView(.animation)`.
- The toolbar shows a close button (discard, with a confirmation dialog) and "Take N".

### Processing steps

- Five rows: Sent to your Mac mini, Transcribed word for word, Marking fillers, blocks, restarts, Reading structure and focus, Writing feedback.
- Each row: a 26 status circle and the step name in `body`.
  Done: an `ink` filled circle with a `checkmark` and the elapsed time on the right in `meta`.
  Active: a rotating 2-point arc (`ProgressView` with a custom style).
  Pending: a 1.5-point `ink3` ring and the name in `ink2`.
- Under a hairline, **Your words**: the plain transcript as soon as transcription finishes, fading out at the bottom.
- The steps come from server progress events; they never fake progress.

### Verdict and strength

- "Verdict" in `caption`, then the verdict in `verdict` style, at most about 40 words.
- **What worked**: a `checkmark.circle.fill` and "What worked" in `good`, one sentence in `body`, then a quote row.
- **Quote row**: the quote in `quote` style inside typographic quotes, with a timestamp chip aligned to its first line on the right.

### Timestamp chip

- Capsule, height 26, `surface` fill (on a `surface` card: `background` in light, `fill` in dark), `play.fill` at 17 and the time in `caption` semibold.
- Tapping it seeks the docked player to that time and starts playback.
  Accessibility label "Play from 0:58".

### Focus card

- One per focus item, at most two, in a `surface` card, radius 22, padding 16, 10 apart.
- Heading: `scope` and the dimension name in `signal`, `label` style.
- Instruction in `instruction` style: what to do next take, concrete, may quote the target sentence.
- Evidence in `meta`: what happened and when.
- A quote row with a timestamp chip.
- After the cards: **Retry this prompt**, a full-width capsule button, height 52, `ink` fill, `onInk` text, with `arrow.counterclockwise`.
  This is the only primary button on the report.

### Level chip

- The level word (`label`) followed by a three-segment meter: three 14 by 6 capsules, 3 apart.
- Strong: three segments in `ink`.
  Okay: two in `ink`, one in `fill`.
  Needs work: one in `signal`, two in `fill`, and the word in `signal`.
- Right-aligned in its row so the meters line up in a column.
- Accessibility: one element, label "Answer first, needs work".

### Dimension row

- The dimension name in `body` medium on the left, the level chip on the right, the evidence under it in `meta` (one line, a timestamp or a quote fragment where it helps).
- Rows are separated by hairlines; six rows in the order of the product's rubric.

### Structure outline

- "What you said, in order." in `meta`, followed by the finding in `signal` semibold when the main point was not first ("The main point came last.").
- A two-column grid: a 40-wide gutter with the start time in `caption`, then the point in `body` and its role under it in `caption` (Reason, Supporting reason, Off-topic, Decision).
- Off-topic points are set in `ink2` with the role in `signal`.
  A late decision has the role "Decision, too late" in `signal`.
- When the main point did not come first, a dashed `signal` slot at the top says "The decision belongs here".
  It is the one dashed element in the app.

### Annotated transcript

- A legend row of filter chips, one per mark type with its count; tapping a chip hides or shows that mark (capsule, height 30, `surface` fill; off: transparent with a hairline border and `ink2` text).
- Segments: the transcript split at sentence groups, each with its start time in a 40-wide gutter.
- Marks, one style per type, all readable without color:

| Mark | Style | Example |
| --- | --- | --- |
| Filler | `signalTint` highlight behind the word, radius 4, 2 horizontal padding | "um," |
| Block | Inline capsule, height 20, `signal` fill, `onSignal` text: the pause length | "1.4 s" |
| Repetition | 2-point dotted `signal` underline, offset 5, under the repeated words | "I think," |
| Restart | The abandoned start struck through with a 1.5-point `ink2` line, text in `ink2` | "We need -" |
| Off-topic | The whole segment in `ink2`, a 3-point `signal` bar in the gutter, and "Off-topic, 20 s" in `signal` `caption` above it | the Aurora story |

- Only filler words used as fillers are marked; "like two weeks" stays plain because it means "about".
- Tapping a mark selects it (a 2-point `ink` outline, offset 2) and seeks the player to it; the player caption names it ("Block, 1.4 s").
- SwiftUI: build each segment as an `AttributedString` with custom attributes per mark and render it with `Text`; draw block chips and filler highlights with a `TextRenderer` (iOS 18 and later) that reads those attributes, so wrapping and Dynamic Type stay native.
  Hit-testing: map the tap location to a character offset with the same text layout, or fall back to a `Menu` per segment listing its marks.
  Add a custom VoiceOver rotor "Marks" that walks the marks in order; each mark reads as "Filler, um, 0:01".

### Take timeline player

- Docked at the bottom of the report, 12 from the sides, 26 above the bottom edge: a glass capsule, height 64.
- Left: a 44 play button (`ink` fill, `onInk` glyph).
- Right: a caption line (the selected mark or "Playing", and "0:14 / 1:24" in `ink2`) above a 14-tall timeline.
- The timeline: a 2-point `levelOkay` track; filler ticks (2 by 6, `ink2`); block ticks (4 by 14, `signal`); the off-topic range as an 8-tall `signalTint` capsule with a `signal` hairline; a 2 by 18 `ink` playhead.
  Dragging scrubs; tapping a tick jumps to that mark.
- SwiftUI: `safeAreaInset(edge: .bottom)` with `.glassEffect()` on the capsule; the timeline is a `Canvas`.

### Reference version

- Intro in `meta`: "Your content, rebuilt answer first. A model of the structure, not a script to memorize."
- A `surface` card of rows, each a 70-wide role column (`caption` semibold, `ink2`: Answer, Reason 1, Reason 2, Close) and the text in `body`; the Answer row is semibold.
- Rows separated by hairlines.
  Uses only Ryan's own content; it never adds facts he did not say.

### Metric tiles

- A two-column grid, 10 apart, of `surface` tiles (radius 20, padding 14, min height 118).
- Each tile: the metric name (`caption` semibold, `ink2`), the value (30 semibold, `.monospacedDigit()`, unit in `meta` after it), and a reference line at the bottom in `caption`.
- A value outside its normal range is set in `signal` (fillers 6.9 against a typical 2 to 6).
- Pace and pitch say "Not graded".
- At accessibility text sizes the grid becomes one column.

### Comparison

- **Focus comparison card** (`surface`, radius 22): the dimension name in `body` semibold, a status pill on the right, then the evidence.
  When a quote shows the change, a three-column grid: "Take 1" or "Take 2" in `caption`, the quote (take 1 in `ink2`, take 2 in `ink`), a timestamp chip.
- **Status pill**: capsule, height 26, `caption` bold.
  Improved: `arrow.up` and "Improved" in `good` on `goodTint`.
  Still slipping: "Same" in `ink2` on `fill`.
  New this take: "New this take" in `signal` on `signalTint`.
- **Dimension change row**: the name, under it the previous level in `meta` with `arrow.right`, and the new level chip on the right.
  Unchanged dimensions collapse into one `meta` line.
- **Metric table**: columns Metric, Take 1 (`ink2`), Take 2.
  A take 2 value that moved the right way gets an arrow and `good`; one that moved the wrong way gets an arrow and `signal`; length and pace stay `ink` without arrows.
- **Listen**: two `surface` tiles side by side, each with a 38 play button, "Take 1" and its length.
- **Bottom actions**: two capsules docked at the bottom: **Retry** (glass) and **Next prompt** (`ink` fill), heights 52.

### History

- **Focus card**: the current focus with its level history: one column per take, oldest first, last ten takes.
  A column is three stacked 18 by 7 segments, 2 apart; filled bottom up by level (strong three in `ink`, okay two in `ink`, needs work one in `signal`), empty segments in `meterEmpty`.
  "Last 10 takes" in `caption` at the right; a one-sentence trend in `meta` under it.
  The same component sits on Home, where the card links to History.
- **Dimensions by session**: a grid with dimension names (`caption` medium) and one 20-tall cell per session, radius 5, 5 apart.
  Cell colors: strong `ink`, okay `levelOkay`, needs work `signal`; a legend with all three sits under the dates.
  A session's cell shows the level of its last take.
  Tapping a cell opens that session.
- **Fillers per 100 words**: one bar per session, 18 wide, 4-radius tops, past sessions at 42% `ink`, the latest in `ink` with its value labeled.
  A band at 5% `ink` marks the typical range 2 to 6, labeled "Typical 2 to 6".
  Axis labels 0, 5, 10 in `micro`; date labels under the bars.
  Swift Charts: `BarMark` plus a `RectangleMark` for the band.
- **Sessions**: grouped by day ("Today", "Saturday", `caption` semibold).
  A row has a 40 `surface` circle with `house` or `car`, the counts ("2 prompts, 3 takes") in `body`, the prompts in `meta`, and "Nervous 3 to 2" on the right in `caption`.

## Screens

The frames in `screenshots/` are the reference; these notes cover what a frame cannot show.

- **Home** (`home-*.png`): large title "Practice", a settings button in the toolbar, the focus card, two start tiles (Impromptu filled with `ink` because it is the main drill, Prepared on `surface`), then Recent as hairline rows.
  Tiles are 156 tall, radius 22, title 20 semibold, description `meta`.
- **Prepared** (`prepared-*.png`): see [Prepared input](#prepared-input).
- **Impromptu** (`impromptu-*.png`): see [Impromptu question](#impromptu-question).
  The nervousness card shows because this is the first take of the session.
- **Recording** (`recording-*.png`): full-screen cover; the system orange microphone dot is visible in the status bar.
- **Processing** (`processing-*.png`): same cover; the close button leaves while processing continues.
- **Report** (`report-*.png`, `report-full-*.png`): prompt header, verdict, what worked, Fix next with Retry, Dimensions, Structure, Transcript, Reference version, Metrics, with the player docked.
  In the frame, the 1.4 s block is selected.
- **Comparison** (`compare-*.png`, `compare-full-*.png`): prompt header, verdict, focus items, dimensions that changed, metrics, listen, bottom actions.
- **History** (`history-*.png`, `history-full-*.png`): large title, focus card, dimension grid, filler chart, sessions.

## Motion

Motion only confirms an action or a change of state.

- Record control: the circle-to-square morph on start and back on stop, `.spring(duration: 0.35, bounce: 0.2)`, with an impact haptic.
- Level meter: live, about 30 updates a second, no easing between samples.
- Processing: each step's ring turns into a check with a 0.2 s cross-fade; the transcript fades in when ready.
- Report: appears with the standard push; no staggered entrance.
- Selecting a mark: the selection outline appears instantly and the playhead slides to the mark in 0.25 s; `.sensoryFeedback(.selection, trigger:)`.
- Legend filters: marks fade in or out over 0.15 s.
- Comparison status pills and level changes appear without animation; the content is the news.
- Reduce Motion: the level meter updates at 10 a second, and the playhead jumps instead of sliding.

## Accessibility

- Dynamic Type through AX5: rows and cards grow; metric tiles and the listen tiles become one column; the level chip moves under the dimension name at accessibility sizes.
- Every mark, level and status carries a non-color cue (shape, word or icon).
- VoiceOver: the transcript has a "Marks" rotor; each timestamp chip reads "Play from 0:58"; the record control announces its state.
- Increase Contrast: `ink2` darkens to `#4A4A4F` in light and lightens to `#C0C0C6` in dark; `signalTint` rises to 20% in light.
- Minimum hit target 44 by 44 for every control, including marks (extend the tappable area beyond the glyphs).

## Copy

- Direct, both good and bad, no softening and no nitpicking, per [product.md#feedback](../product.md#feedback).
- Second person, plain verbs: "Open with the decision", "Cut the Aurora Serverless story".
- No exclamation marks, no emoji, no praise words without evidence.
- Times as m:ss ("1:24"); durations under a minute as seconds with a space ("20 s", "1.4 s").
- Typographic quotes around anything Ryan said.
- No score, rank, streak or percentage of "good".

## Alternatives considered

- **Proof sheet (editorial).**
  New York serif for the transcript and reference version on a warm paper background, with feedback as margin notes like an editor's proof.
  Not chosen: it is the closest cousin of Penny Diary's "Ledger" look, so two of Ryan's apps would look alike; serif body text with inline marks reads slower on a phone; and a paper background fights the system materials iOS 26 puts on toolbars and sheets.
- **Studio meter (dark instrument).**
  Always dark, the waveform as the hero, a ring per dimension and metric tiles at the top of the report.
  Not chosen: it leads with delivery metrics, the opposite of the product's structure-first position; rings read as scores, which v1 rules out; and a dark-only app breaks the light and dark requirement.
- **Coach chat.**
  Feedback as a conversation, one message per point, with follow-up questions.
  Not chosen: it hides the structure of the answer, makes take-to-take comparison hard, and invites reading more instead of recording again.

Ink and Signal keeps the app native and quiet, gives the one color a single job, and makes Ryan's own words the center of the report.
Any of the alternatives can be mocked up for comparison.

## Decisions for Ryan

1. **One signal color for both recording and problems?**
   Recommendation: yes; red-orange always means "act here", and the app stays monochrome otherwise.
   The alternative is a red record button with amber problem marks, which adds a second accent.
2. **Report order: verdict, what worked, Fix next and Retry, then evidence?**
   Recommendation: yes; the Retry button sits right after the two things to fix, and the transcript is below for when he wants proof.
3. **Any live feedback while recording (a filler counter, a pace warning)?**
   Recommendation: none in v1; it pulls attention from speaking, and the retry loop already gives fast feedback.
4. **Should "done" by voice also end a take at home?**
   Recommendation: yes, the same on-device keyword as driving mode, so the habit is the same in both places.
5. **Nervousness check: before the first take of a session and after "End session" only?**
   Recommendation: yes, optional and skippable, never before every take.
6. **Transcript marks: all five on by default, with filter chips?**
   Recommendation: yes; marks are evidence, while the two focus cards keep the next take's target narrow.
7. **Reference version always visible, or hidden behind a "Show" button until after the retry?**
   Recommendation: visible, below the transcript; hiding it costs a tap on every report.
   If Ryan finds himself reciting it, switch to hidden until take 2.
8. **History grid: a session shows its last take's levels?**
   Recommendation: yes, because the last take shows where he ended up; the comparison screen already shows the first take.
9. **Two tabs, Practice and History?**
   Recommendation: yes; Settings stays a toolbar button on Practice, and driving mode will start from Practice.
