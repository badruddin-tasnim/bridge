# Bridge UI/UX Design System Specification (v1.1)

> **Document Version:** 1.1.0  
> **Status:** Canonical Design Reference  
> **Target Platforms:** macOS Menu Bar App (SwiftUI / AppKit) & Android Mobile App (Kotlin / Material Design)  
> **Scope:** Brand Guidelines, Color Tokens, Typography Scale, Spacing Grid, Component Anatomy, Motion, and UX Rules.

---

## 1. Design Philosophy & Visual Identity

**Bridge** connects an Android phone and a Mac over local Wi-Fi with instant, peer-to-peer simplicity. The design language reflects this relationship:

- **Minimalist Cyber-Industrial Elegance:** Clean geometric layouts, dark obsidian surfaces, tactile outlines, and hyper-legible monospace data points.
- **High Intentionality:** Every line, dot, and card exists for a functional reason. No decorative clutter.
- **Electric Lime Accent (`#C8F135`):** The signature vibrant brand color representing an active, live, data-syncing link.
- **Deep Obsidian Hierarchy:** Instead of flat `#000000`, Bridge utilizes a multi-layered obsidian scale (`#0E0F12` $\to$ `#121418` $\to$ `#181B20` $\to$ `#1C1F25`) that gives visual depth without eye strain.

---

## 2. Color System & Design Tokens

### 2.1 Complete Cross-Platform Color Token Matrix

| Token Name | Hex Code | SwiftUI Token (`BridgeColors`) | Android Resource (`@color`) | Semantic Purpose |
| :--- | :--- | :--- | :--- | :--- |
| **Ink** | `#0E0F12` | `BridgeColors.ink` | `@color/bridge_ink` | Deepest canvas background on Android; high-contrast text on Lime buttons. |
| **Background (Mac)** | `#121418` | `BridgeColors.bg` | — | Mac menu bar popover base container surface. |
| **Panel** | `#181B20` (Android)<br>`#1C1F25` (Mac) | `BridgeColors.panel` | `@color/bridge_panel` | Elevated card surfaces, device containers, grouping tiles. |
| **Pill / Surface Light**| `#1C1F25` | `BridgeColors.panel` | `@color/bridge_pill` | Status pills, chips, secondary rounded badges. |
| **Node Background** | `#262A31` | — | `@color/bridge_node_bg` | Inactive/idle node circles in link diagrams. |
| **Line (Subtle)** | `#2B2F36` | `BridgeColors.line` | `@color/bridge_line` | 1dp/pt hairline dividers, subtle card separator rules. |
| **Line 2 / Outline** | `#3A3F47` | `BridgeColors.line2` | `@color/bridge_outline` | Interactive button borders, unselected input borders, card outlines. |
| **Primary Text** | `#F4F5F2` | `BridgeColors.text` | `@color/bridge_text` | High-contrast off-white for primary headlines, active device names, inputs. |
| **Soft Text** | `#C9CED4` | `BridgeColors.soft` | `@color/bridge_soft` | Subheadings, card secondary descriptions, button text. |
| **Muted Text** | `#9BA3AD` | `BridgeColors.muted` | `@color/bridge_muted` | Metadata, overlines, port/IP numbers, inactive status labels. |
| **Electric Lime** | `#C8F135` | `BridgeColors.lime` | `@color/bridge_lime` | **Primary brand accent.** Live connection, primary CTAs, active OTP boxes, online dot. |
| **Soft Coral** | `#FF9A8A` | `BridgeColors.coral` | `@color/bridge_coral` | **Destructive / Error accent.** Unpair buttons, disconnect warnings, error notes. |

### 2.2 Contextual / Status Container Tokens (Android)

| Semantic State | Background Hex | Border Hex (1dp) | Text / Dot Color |
| :--- | :--- | :--- | :--- |
| **Error / Failed** | `#1D1514` (`@color/bridge_error_bg`) | `#5A3A36` (`@color/bridge_error_border`) | `#FF9A8A` (Coral) |
| **Connected Note** | `#171D0C` (`@color/bridge_connected_bg`) | `#4B5A1D` (`@color/bridge_connected_border`) | `#C8F135` (Lime) |
| **Connecting / Searching** | `#15171B` (`@color/bridge_connecting_bg`) | `#2B2F36` (`@color/bridge_line`) | `#9BA3AD` (Muted) |

### 2.3 Opacity Overlays
- **Mac Unpair Action Tile:** Background `rgba(255, 154, 138, 0.08)` (`#FF9A8A` at 8%), stroke `rgba(255, 154, 138, 0.38)` (`#FF9A8A` at 38%).
- **Mac Update Banner Border:** Stroke `rgba(200, 241, 53, 0.35)` (`#C8F135` at 35%).
- **Disabled State Alpha:** Primary actions become `alpha = 0.45` when disabled or awaiting input.

---

## 3. Typography System

Bridge utilizes **two bespoke font families** to separate human-readable content from technical data:

1. **Plus Jakarta Sans** (Geometric Humanist Sans):
   - Files: `plus_jakarta_sans_regular.ttf`, `plus_jakarta_sans_medium.ttf`, `plus_jakarta_sans_semibold.ttf`, `plus_jakarta_sans_bold.ttf`.
   - Used for: Brand mark, headlines, body text, button labels, and general UI.
2. **DM Mono** (Technical Monospace):
   - Files: `dm_mono_regular.ttf`, `dm_mono_medium.ttf`.
   - Used for: 6-digit OTP codes, IP addresses, ports, protocol overlines, status badges, and device role tags.

### 3.1 Type Scale Specification

| Usage | Font Family | Weight | Size (macOS) | Size (Android) | Kerning / Tracking | Color Token | Case |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **Wordmark** | Plus Jakarta Sans | Medium | 21pt | 22sp | `-0.4pt` / `-0.02` | `text` (`#F4F5F2`) | lowercase ("bridge") |
| **Hero Title** | Plus Jakarta Sans | Bold | — | 22sp (autosize 17–22) | `-0.02` | `ink` (on Lime) / `text` | Sentence case |
| **Card / Section Title** | Plus Jakarta Sans | Medium | 15.5pt | 17sp | `-0.15pt` / `-0.01` | `text` (`#F4F5F2`) | Title case |
| **Body / Explanations** | Plus Jakarta Sans | Regular | 13.5pt | 15sp | `0` | `soft` / `muted` | Sentence case |
| **Small Descriptions** | Plus Jakarta Sans | Regular | 12.5pt | 12.5sp | `0` | `muted` (`#9BA3AD`) | Sentence case |
| **Micro Footers / Hints**| Plus Jakarta Sans | Regular | 12pt | 11.5sp | `0` | `muted` (`#9BA3AD`) | Sentence case |
| **OTP / Code Display** | DM Mono | Medium | 30pt | 26sp | `1.8pt` / `0` | `lime` (`#C8F135`) | Numbers |
| **Section Overlines** | DM Mono | Regular | 11pt | 11sp | `1.54pt` / `0.12–0.14` | `muted` (`#9BA3AD`) | ALL CAPS |
| **Live / Status Tag** | DM Mono | Medium / Reg | 11pt | 12sp | `0.88pt` / `0` | `lime` (`#C8F135`) | Mixed / Title case |
| **Primary Button** | Plus Jakarta Sans | SemiBold | 14pt | 16sp | `0` | `ink` (`#0E0F12`) | Title / Sentence case |
| **Secondary Button** | Plus Jakarta Sans | Medium | 13pt | 14–16sp | `0` | `soft` / `coral` | Title / Sentence case |

---

## 4. Spacing, Elevation & Corner Radii

### 4.1 Corner Radii Hierarchy

| Radius | Usage on macOS | Usage on Android |
| :--- | :--- | :--- |
| **32dp** | — | Hero Card (`bg_card_lime`), Panel Card (`bg_card_panel`) |
| **27–28dp** | — | Pill Buttons (Primary Lime, Outlined Buttons) |
| **26dp** | — | Devices Group Card (`bg_card_devices`) |
| **20–22pt/dp**| Pairing Card Container (22pt) | Placeholder Tiles (Files / Notifications, dashed 20dp) |
| **16–18pt/dp**| Connected Device Card (18pt), QR Tile (18pt) | Status Pill (16dp), Error/Connecting Note Banners (16dp) |
| **12–14pt/dp**| Toggle Button (12pt), Copy Button (12pt), Update Banner (14pt) | OTP Code Input Boxes (14dp), Modal Sheets |
| **10pt** | Unpair Square Button (10pt), Logo Mark (10pt) | — |

### 4.2 Spacing & Padding Scale

- **macOS Popover:**
  - Fixed Width: `360pt`
  - Window Edge Padding: `20pt` all around
  - Vertical Inter-Component Gap: `12pt`
  - Card Inner Padding: `14pt` horizontal, `13pt` vertical (Device Card); `18pt` (Pairing Card)
- **Android Screen:**
  - Page Padding: Start `20dp`, End `20dp`, Top `36dp`, Bottom `28dp`
  - Hero Card Padding: `24dp` all around
  - Standard Element Margin Top: `12dp`, `16dp`, `22dp`, or `24dp`
  - OTP Box Gap: `8dp` between boxes; `10dp` width x `2dp` height dash separator in the center (3 + 3 split)

---

## 5. Component Anatomy & Specifications

### 5.1 The Header Bar
- **Logo Mark:** 32×32pt (Mac) or 34×34dp (Android). Crisp lime square with rounded corners (10pt) and negative-space bridge symbol.
- **Wordmark:** Strictly lowercase `"bridge"`.
- **Status Indicator Pill:**
  - Mac: Right-aligned inline cluster with a 7×7pt circle dot + `ONLINE` / `WAITING` in DM Mono (11pt, kerning 0.88).
  - Android: 28dp height pill (`bg_pill`, corner radius 16dp), containing a 6×6dp dot + `Linked` / `Linking…` / `Not linked` in Plus Jakarta Sans Regular (11.5sp).

### 5.2 Device Connection Card
- **Device Icon:** 40×40pt container with 12pt corner radius filled with Lime (`#C8F135`) and an obsidian phone glyph (`#0E0F12`).
- **Device Details:** Primary device name (e.g. "Galaxy A52s", "MacBook Pro") with secondary status subtitle ("Linked to this Mac, same Wi-Fi").
- **Unpair Button:**
  - Mac: 34×34pt rounded square (10pt radius) with a coral outline and crisp vector `UnlinkIconShape`.
  - Android: 54dp height pill button with 1dp `#3A3F47` outline and Coral (`#FF9A8A`) text.

### 5.3 6-Digit Pairing OTP Input
- **Layout:** 6 visual square boxes split into two groups of 3 by an 8dp horizontal spacer with a central dash (width 10dp, height 2dp, color `#3A3F47`).
- **Box Dimensions:** Width `46dp`, Height `60dp`, Corner Radius `14dp`.
- **Default State:** Background `#181B20`, Border 1dp `#2B2F36` (`bg_code_box`).
- **Active / Focused State:** Background `#181B20`, Border 1dp Electric Lime `#C8F135` (`bg_code_box_active`).
- **Text:** 26sp DM Mono Medium centered, color `#C8F135`.
- **Underlying Input:** Hidden `EditText` with `inputType="number"`, `maxLength="6"`, receiving auto-focus when any box is tapped.

### 5.4 QR Code Display Tile (macOS)
- **Container:** 176×176pt off-white tile (`#F4F5F2`) with 18pt corner radius.
- **QR Padding:** 12pt inner margin. Image rendered with `.interpolation(.none)` for pin-sharp pixels.

### 5.5 Action Buttons
1. **Primary Button (e.g., "Scan QR code", "Connect to Mac", "Update"):**
   - Height: 54–56dp (Android), 28–38pt (Mac).
   - Background: Solid Electric Lime (`#C8F135`).
   - Corners: Full capsule (27–28dp) or rounded (12–14pt).
   - Text Color: Deep Obsidian `#0E0F12`.
   - Font: Plus Jakarta Sans SemiBold.
2. **Secondary / Outlined Button (e.g., "Pair another phone", "Connect"):**
   - Background: Transparent.
   - Border: 1dp solid `#3A3F47`.
   - Text Color: `#F4F5F2` (Normal) or `#FF9A8A` (Unpair/Destructive).
   - Font: Plus Jakarta Sans Medium.

### 5.6 Update Banner
- Appears seamlessly below the header when a newer version is published on GitHub.
- Dismissible for 24 hours (records timestamp in preferences).
- Has an action button ("Update") that directs to release assets, plus a subtle cross button (`ic_close_small` / SF Symbol `xmark`).

---

## 6. BridgeLinkView (Interactive Canvas Element)

`BridgeLinkView` is the dynamic visual centerpiece rendered on Android across connection states.

```
+-----------------------------------------------------------+
|   (Phone Node)                               (Mac Node)   |
|      ( )============== Bézier Wire =============( )       |
|    Left(48,48)         Quadratic curve        Right(272,48)|
|                         Control(160,98)                   |
+-----------------------------------------------------------+
```

### 6.1 Geometry Spec (Virtual Canvas: 320 × 104)
- **Left Node (Phone):** Center `(48f, 48f)`, Radius `28f`.
- **Right Node (Mac):** Center `(272f, 48f)`, Radius `28f`.
- **Quadratic Bézier Curve:** Starts at `(76f, 52f)`, controls at `(160f, 98f)`, ends at `(244f, 52f)`.
- **Wire Stroke Width:** `2.4f`, round caps and joins.

### 6.2 State Visuals
- **HERO_CONNECTED:**
  - Wire: Solid `#0E0F12` with animated Lime/Obsidian data packets traveling along the path.
  - Nodes: Filled with Obsidian `#0E0F12`. Device outlines rendered in Lime `#C8F135`.
  - Ripple Rings: Subtle expanding pulse around connected nodes.
- **PAIRING_IDLE / HERO_IDLE:**
  - Wire: Dashed line (`DashPathEffect(floatArrayOf(6f, 6f), 0f)`), color `#3A3F47`.
  - Nodes: Filled with `#1C1F25` (Pairing) or `#262A31` (Hero), stroke `#3A3F47`.
  - Central Dot: 4dp static node at wire midpoint `(160, 75)` in `#9BA3AD`.
- **CONNECTING / LINKING:**
  - Flowing dash phase animation at 30fps along the wire curve.
  - Alternating packet pulses moving between phone and Mac.

---

## 7. Motion & Interaction Specifications

- **Status Dot Breathing:**
  - macOS: `Animation.easeInOut(duration: 1.2).repeatForever()` scaling `1.0 $\to$ 0.8` and opacity `1.0 $\to$ 0.35`.
  - Android: `ObjectAnimator` with `AccelerateDecelerateInterpolator` over `700ms` bouncing alpha between `1.0f` and `0.2f`.
- **Popover Transitions (macOS):**
  - Smooth height resizing via `NSPopover.animates = true`.
  - Collapsed Connected: `230pt` height (+66pt if update banner active).
  - Expanded Pairing / Code view: `580pt` height.
  - Idle / Unpaired: `490pt` height.
- **Copy Feedback:**
  - Tapping "Copy" on Mac changes button background to solid Lime `#C8F135`, text to "Copied", reverting after `2000ms`.

---

## 8. Invariable UX Rules for Next Versions

When designing or implementing new features (e.g. notifications, file transfers, clipboard sync previews):

1. **Never use pure `#000000` for cards or surfaces.** Always use the obsidian tier (`#0E0F12`, `#181B20`, `#1C1F25`).
2. **Never capitalize the wordmark.** It is always lowercase `"bridge"` in Medium weight with negative kerning.
3. **Reserve Electric Lime (`#C8F135`) for active states.** Do not use Lime for neutral metadata, passive backgrounds, or inactive icons.
4. **Reserve Soft Coral (`#FF9A8A`) for destructives and errors.** Never use bright generic red (`#FF0000`).
5. **Monospace Typography Rule:** Any IP, port, timestamp, byte count, token, or OTP code MUST use `DM Mono`. All conversational or descriptive UI uses `Plus Jakarta Sans`.
6. **No Clutter:** Actions must be minimal. Never create multi-step wizards when a single-glance card can accomplish the goal.
7. **Consistent Corner Softness:** Large containers use `18–32dp` radius. Micro controls use `10–14dp`. Interactive buttons are rounded pills (`27–28dp`).
