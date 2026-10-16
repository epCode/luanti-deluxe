# Common Mineclonia library functions

## Compatibility functions

### `mcl_util.log_deprecated_call(level, moreinfo)`
  Writes a luanti-style deprecation message to the log.
  When called from a function, it writes to the log the name of the function,
  stating it as a deprecated function, followed by the filename and the line
  number of the function calling the deprecated function.
  If a second argument is given, it is written to next line in the log after
  the deprecation message. This can be used to point to specifics of any
  updated APIs.

#### Arguments:
  level: log level, defaults to "warning".
  moreinfo: optional extra informative message.

## Hands and first-person hand animations

The item in the other hand is the first item of the player's `offhand`
inventory list. Like Minecraft, a right-click uses the main hand first and the
other hand only if the main hand item does nothing.

### `mcl_util.get_hand_item(player, hand)` / `mcl_util.set_hand_item(player, hand, stack, skip_anim)`
  Gets or replaces the item in `hand` (`"main"` or `"offhand"`). With
  `skip_anim` the first-person view replaces the item without lowering it
  (e.g. for the drawing stages of a bow).

### `mcl_util.main_hand_passive(player, pointed_thing)`
  Whether a right-click does nothing with the main hand item, so that the other
  hand is used. Items decide with `_mcl_main_hand_passive` (a boolean or a
  function `(player, itemstack, pointed_thing)`); otherwise the empty hand,
  nodes not pointed at nodes, food the player is too full for and items without
  `on_place`/`on_secondary_use` are passive.

### `mcl_util.get_use_hand(player, predicate, pointed_thing)`
  Returns the hand and item that a held right-click uses for items accepted by
  `predicate(itemstack)`: the main hand, or the other hand if the main hand is
  passive. Returns nil if neither.

### `mcl_util.start_item_use(player, def, restart)` / `mcl_util.stop_item_use(player, animation)`
  Shows an item being used in first person (`ObjectRef:start_item_use`), once
  per use: an active use with the same animation and hand is only restarted
  with `restart`. `stop_item_use` with `animation` only ends a use with that
  animation. `mcl_util.get_item_use(player)` returns `{animation, hand}` or nil.

### `mcl_util.swing_hand(player, def)`
  Swings the hand (`ObjectRef:swing_hand`), e.g. `{hand = "offhand"}`.
