---
name: renoise-viewbuilder-layout
description: Rules for building or repairing Renoise ViewBuilder dialogs in Oversample.lua — fixed-width aligned columns, width-property constraints, footer/status sizing, and hiding unused secondary controls. Load when editing UI layout or fixing dialog/column/footer/justify issues.
license: MIT
compatibility: opencode
---

# Renoise ViewBuilder layout rules (learned the hard way)

Apply these whenever you touch `Oversample/Oversample.lua` dialog construction
or `vb:` control sizing.

## Aligned columns = fixed widths
Give every control in a column the same `width` (estimate from widest known
label; factor `~CONTENT_HEIGHT*0.3 + padding`, no text metrics exist).
`CONTENT_HEIGHT = renoise.ViewBuilder.DEFAULT_CONTROL_HEIGHT`.

## `width` property constraints
- `width = "*"` is **REJECTED** for rows/spaces/popups/buttons (runtime error:
  *"expecting a percentage string or number argument for property 'width'"*).
  Valid values are **numbers** or **percentage strings** (e.g. `"100%"`).
- `vb:space` accepts only number/percentage width, not `"*"`; a percentage
  there is unreliable.
- `width = "100%"` on a row inside an auto-sized column collapses the row to
  zero width (percentage is relative to the auto-sized parent → 0). Never use
  percentage width to "fill".

## `horizontal_aligner` justify
`vb:horizontal_aligner` `mode="justify"` spreads space between ALL its direct
children. With exactly two children it pushes the 2nd to the right edge — this
works for the bottom status bar, but it **jumbled the fixed columns in settings
rows**. Avoid for aligned column layouts. Give the footer an explicit width
matching the populated settings row; do not rely on automatic filling or
shrinking.

## Pinning a control to the right edge (e.g. the `+` button)
To pin a control to the right edge of every row while keeping columns aligned:
*always reserve* each column's space. Put optional secondary controls inside a
**fixed-width, fixed-height `vb:row`**, then hide the controls when unused. The
container preserves alignment without drawing empty disabled dropdowns. Only
the newest settings row retains the `+` button.

## Swapping controls
Hide the old control **before** showing its replacement (popup/slider or
popup/label). Showing both even briefly can expand the dialog, leaving unused
space after the old control disappears.

## Status / footer text
`vb:text` expands for longer messages but does not automatically shrink for
shorter ones. A final `"Done."` does not prove the status control is small.
The deployed footer uses a one-control-height `vb:multiline_text`,
`style="body"`, with a fixed width that leaves room for all three buttons.
`SETTINGS_WIDTH` includes the visible columns, `+`, and spacing; the footer
must not exceed it.

## User's UI preferences (enforced)
- Columns must stay aligned (fixed widths).
- No excessive trailing space after the `+` button; `+` should be flush right.
- Status text must not force the dialog wider; preserve the bounded footer
  layout described above.
- Unused secondary Value fields must be visually empty, not empty disabled
  controls.
- Secondary labels are right-aligned and colon-suffixed (e.g. `"Linear
  Phase:"`).
- The user reverts fast when layout looks jumbled — prefer minimal,
  alignment-preserving changes; verify in Renoise.

## Verification
Stub tests do **not** verify native rendering, font metrics, clipping, or
notifier timing. Check in Renoise after reload, including long status messages,
Minimize/Maximize, switching devices, and adding rows. See the
`oversample-tests` skill for the test commands.
