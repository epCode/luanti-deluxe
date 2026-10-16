Main menu customization
=======================

Each game can give the main menu a look and contents of its own, shown while it
is selected in the game bar. The tab row at the top (Start Game, Join Game,
Content, About) and the game bar stay the engine's; what is inside the tabs is
up to the game. Games without a `menu/menu.conf` keep the classic menu.


Fonts
-----

A game can replace the engine's fonts for all UI, in the menu and in game, with
font files it ships. In `game.conf`:

    font_path = fonts/MyFont-Regular.ttf
    # optional: font_path_bold, font_path_italic, font_path_bold_italic
    # (default to font_path), and mono_font_path (+ the same variants) for the
    # chat console
    mono_font_path = fonts/MyFont-Regular.ttf

Only `.ttf` and `.woff` files inside the game folder are used. The server sends
them to clients as font media, so they also apply when playing on a remote server.


Menu files
----------

Everything lives in the game's `menu/` folder:

| File | Use |
|------|-----|
| `header.png`, `footer.png`, `background.png`, `overlay.png` | Classic menu images (see lua_api.md, "Menu images") |
| `icon.png` | Game bar icon |
| `theme.ogg` | Menu music |
| `panorama_0.png` ... `panorama_5.png` | Rotating cube-map background: front, right, back, left, up, down (`.jpg` works too) |
| `panorama_overlay.png` | Drawn over the panorama, e.g. a vignette |
| `button.png`, `button_hovered.png`, `button_pressed.png` | Texture for every button in the menu, drawn 9-sliced |
| `splashes.txt` | Splash texts for the title view, one per line (`#` starts a comment) |
| `menu.conf` | Settings below; its presence also keeps the game's theme on every tab |


menu.conf
---------

    # What the Start Game tab shows:
    #   title   a title screen (logo, splash text, a column of big buttons)
    #           whose Singleplayer button opens the world list
    #   worlds  the world list directly
    #   classic the engine's Start Game tab (default)
    start_tab = title

    # What the Join Game tab shows:
    #   servers a server list with Join, Direct Connection and Add Server
    #   classic the engine's Join Game tab (default)
    join_tab = servers
    # The server list only shows public servers running this game unless
    join_all_games = false

    # Title screen buttons: rows separated by ";", buttons in a row by ",".
    # Available: singleplayer, multiplayer, content, settings, about, quit
    title_buttons = singleplayer; multiplayer; content; settings, quit
    # Rename a button: label_<button>
    label_settings = Options...

    # Splash text over the logo, from splashes.txt
    splash = true
    splash_color = #ffff00

    # Text at the bottom of the title screen
    footer_left = My Game
    footer_right = Built on Luanti
    footer_color = #ffffffcc

    # Text in the top left corner (default: the game's name, empty hides it)
    topleft_text =

    # World list: text next to each world's name; $name is replaced by the
    # value of the world option "name" (default: Creative/Survival Mode)
    world_summary = $mymode, $mydifficulty

    # Panorama
    panorama = true
    panorama_speed = 1.5

    # Button textures: border size in source pixels for 9-slicing, text color
    button_middle = 4
    button_text_color = #e0e0e0

    # Extra formspec added to every menu formspec, for any other styling.
    # $MENU is replaced by the path of the menu folder.
    formspec_prepend = style_type[label;textcolor=#dddddd]


World options
-------------

A game can ask for options when a world is created, instead of asking in game:
it lists them in `world_settingtypes.txt` in the game folder, in the same format
as `settingtypes.txt`. The Create World dialog then gets a "Game" page with them
(next to the "World" page with seed and map generator), and the world list's
Edit dialog shows them too. Their values are written to the world's `world.mt`
when it is created or edited, where the game reads them with
`Settings(core.get_worldpath() .. "/world.mt")`.

* Types: `bool` and `enum` (buttons cycling through the values, like
  Minecraft's), `int`, `float` and `string` (text fields).
* Options before the first `[Category]` are shown directly; each category
  becomes a button opening a page of its own, e.g. `[Game Rules]`.
* The comment above an option is its tooltip. A last comment line
  `Requires: other_bool, !other_bool, mode=hardcore, !mode=creative` shows the
  option only while the other options have those values.

Example:

    # One life only.
    mygame_mode (Game Mode) enum survival survival,hardcore,creative

    #    Requires: !mygame_mode=hardcore
    mygame_difficulty (Difficulty) enum normal peaceful,easy,normal,hard

    [Game Rules]
    mygame_keep_inventory (Keep inventory after death) bool false

Use `disabled_settings` in `game.conf` to hide the engine's Creative Mode and
Enable Damage checkboxes when the game's options replace them.


Making a panorama
-----------------

In game, stand where the panorama should be taken, look towards what should
be in front and press **Sneak + Screenshot** (Shift+F12). The six faces are
saved as `panorama_0.png` ... `panorama_5.png` in a `panorama_<time>` folder in
the screenshot directory, without HUD, hand or selection box; copy them into
the game's `menu/` folder (`.jpg` keeps them small). The faces are as large as
the window is tall, so use a big window.

The faces are square 90° views facing front, right, back, left, up and down,
where "front" is the player's horizontal look direction.
