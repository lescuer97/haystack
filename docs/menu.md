# Menu — modal UI and bounded text input

The menu is a small, self-contained demonstration of a modal screen. It has no
wallet, network, or payment integration: the wallet page only edits a local
display-name buffer in memory.

Open it with `Esc` on the keyboard or the Start button on controller 0. Opening
always shows the **Main** page with its first row selected. While the menu is
open, world movement, mouse dragging, and the `G`/`B` debug toggles are ignored.
The frame that opens or closes the menu is modal too, so the click that closes
it cannot move the world.

## Controls

| Input | Effect |
|---|---|
| `Esc` / gamepad Start | toggle the menu; opening returns to Main and selects row 0 |
| `Up` / `Left`, D-pad up/left, left stick up/left | select the previous row (wraps to the last) |
| `Down` / `Right`, D-pad down/right, left stick down/right | select the next row (wraps to the first) |
| `Enter` / keypad Enter / gamepad bottom face (A/Cross) | activate the selected row |
| mouse movement | select the row under the pointer |
| left click on a row | select and activate that row |
| left click outside every row | blur the focused field (the highlight stays) |
| printable text | append to the focused field |
| Backspace | delete the last codepoint in the focused field |

`WASD` is **not** a menu direction: it stays a typing key, so entering a wallet
name never moves the highlight. Held directions step once immediately and then
repeat at the same shared 10 steps/s cadence as the camera. `Space` types a
space; it is not a confirm key. Arrow keys, D-pad, and stick
share the vertical list: up/left mean previous, down/right mean next, and at
most one row moves per frame. Opposing requests on the same frame cancel.

The highlight is persistent UI state (`Menu.selected_index`), not a transient
hover: it moves only when a direction steps or the pointer actually moves onto
another row. A stationary pointer never overrides a keyboard or controller
selection, and a direction wins if both change on the same frame. Moving the
selection away from an editable field blurs it, so typing cannot land in the
field that was previously focused; the caret appears only after activation.

Pages and rows:

- **Main**: `Wallet` (navigation), `Resume` (close).
- **Wallet**: `Wallet name` (editable text), `Clear name` (action), `Back to
  Main` (navigation).

## Module responsibilities

| File | Job |
|---|---|
| `src/input.zig` | polls devices only; produces one `FrameInput` with screen-space pointer, click/escape/confirm/backspace edges, viewport size, bounded typed text, and the shared directional requests used by both camera and menu |
| `src/menu.zig` | page/item data, pure layout maths, `TextField`, and the runtime `Menu` state (page, selected row, focus, text buffers, last pointer) |
| `src/game.zig` | `GameState.update` gives the menu first refusal; a consumed frame never reaches the camera or debug toggles |
| `src/rendering.zig` | reads menu state and draws the modal last, over the world, HUD, and minimap |
| `src/main.zig` | calls `setExitKey(.null)` so `Esc` is a menu key, then passes the viewport size to `rendering.draw` |

`menu.zig` does not import Raylib. `FrameInput` defaults describe a 1000×640
viewport, so tests can drive the whole menu without a window.

## Adding a page, action, or field

Page content is a list of tagged unions. The switches are exhaustive, so the
compiler points at every place that needs a decision.

```zig
pub const MenuItem = union(enum) {
    navigate: MenuPage,      // open another page
    action: Action,          // run a local action
    text_input: InputField,  // focus an editable field
};
```

1. **New page**: add a variant to `MenuPage`, add a `const foo_items` array, add
   it to `pageTitle` and `pageItems`, and keep it within `max_items_per_page`.
   Do not add storage for a page: `currentPage` already selects it.
2. **New action**: add a variant to `Action`, handle it in `Menu.activate`, and
   give it a label in `itemLabel`. Actions should only mutate local `Menu`
   state unless a real system is deliberately added.
3. **New field**: add a variant to `InputField`, add its `TextField` storage to
   `Menu`, add it to `textField`/`textFieldConst`, and place a `.text_input` row
   on a page. The renderer draws any field generically through
   `textFieldConst` and `isFocused`.

`TextField` is fixed at 128 UTF-8 bytes and never allocates. Appends work on
whole Unicode codepoints, reject controls and surrogate halves, and stop at
capacity; backspace removes one whole codepoint. Rendering scrolls the value so
the caret stays visible, and scissors it to the input box.

## Layout and tests

`menu.calculateLayout(page, viewport_w, viewport_h)` is the single source of
rectangles for both hit testing and drawing. It centres the panel, then scales
padding, title height, gaps, and row height down with it, so every title and
item rectangle stays inside the panel even at tiny viewport sizes. There is no
scrolling system.

Headless tests in `menu.zig`, `input.zig`, and `game.zig` cover layout centring
and hit geometry, escape/navigation/action transitions, selection start and
reset, direction wrapping and cancellation, confirm activation, mouse selection versus
a stationary pointer, focus blurring, Unicode editing and capacity,
preservation of UI fields through `Reader.repeat`, the shared direction cadence,
WASD filtering while the menu is open, and modal input blocking the camera and
debug toggles.
