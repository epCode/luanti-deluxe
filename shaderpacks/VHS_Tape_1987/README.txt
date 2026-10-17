VHS Tape 1987
=============
Wobbly tracking, smeared colour, tape noise and a soft, washed-out picture.

Version 1.0 by Luanti Shader Studio
Made with Luanti Shader Studio 1.0.0 on 2026-10-15.
Built against: Luanti 5.17.0-dev (minetest)

WHAT IS THIS?
-------------
A client-side shader pack for Luanti (formerly Minetest). It only changes how
the game looks on YOUR computer; it works in singleplayer and on any server
and needs no mods.

Effects in this pack:
  Post-processing:
    - Vignette

Files:
  second_stage/opengl_fragment.glsl
  second_stage/opengl_vertex.glsl

INSTALL (automatic)
-------------------
  Linux / macOS:  open a terminal in this folder and run   ./install.sh
                  (or ./install.sh /path/to/luanti  for a portable copy)
  Windows:        double-click install.bat
                  (for a portable Luanti, drag its folder onto install.bat)

Then fully quit and restart Luanti.

INSTALL (manual)
----------------
1. Copy this whole folder somewhere permanent. The recommended place is the
   "shaderpacks" folder inside your Luanti user folder:
     Linux (normal install)  ~/.minetest/shaderpacks/
     Linux (Flatpak)         ~/.var/app/org.luanti.luanti/.minetest/shaderpacks/
                             (Flatpak can ONLY read inside this folder!)
     Linux (Snap)            ~/snap/luanti/common/.minetest/shaderpacks/
     Windows (installer)     %APPDATA%\Minetest\shaderpacks\
     Windows (portable zip)  <your Luanti folder>\shaderpacks\
     macOS                   ~/Library/Application Support/minetest/shaderpacks/
2. Start Luanti, open Settings, search for "shader path" (it is under
   Advanced > Graphics), and set it to the full path of the copied folder.
   Alternatively add this line to minetest.conf while Luanti is closed:
     shader_path = /full/path/to/shaderpacks/VHS_Tape_1987
3. Restart Luanti.

UNINSTALL
---------
Run uninstall.sh / uninstall.bat, or clear the "Shader path" setting
(remove the shader_path line from minetest.conf) and restart Luanti.

RECOMMENDED SETTINGS
--------------------
  enable_post_processing = true

TROUBLESHOOTING
---------------
* "Failed to compile the ... shader": this pack was made for Luanti 5.17.0-dev (minetest); shader
  internals change between Luanti versions. Re-export the project
  (project.lssproj) with Luanti Shader Studio targeting your Luanti version.
  The exact compiler error is written to debug.txt in your Luanti folder.
* Post-processing effects need "enable_post_processing = true" (default on
  desktop, off on Android).
* Changes to files inside the pack are picked up when you leave and re-join
  a world; changing shader_path itself needs a full restart.

LICENSE
-------
The generated files contain Luanti's own shader code (LGPL 2.1 or later,
(C) the Luanti contributors) with the pack's additions appended, so the
pack as a whole is distributed under the LGPL 2.1 or later.
