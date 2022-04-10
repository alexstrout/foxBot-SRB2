foxBot! v1.6 ([Changelog](changelog.md))
============
Turn spare SRB2 clients into cooperative AI bots.

![foxBot Being Rad](Media/srb20065.gif)

Features
--------
* Revised AI based on CobaltBW's [ExAI mod](https://mb.srb2.org/showthread.php?t=46020), with additional features and fixes
* Support for any combination of players and bots in multiplayer
* Predictive movement logic for more efficient following and enemy bopping
* Improved understanding of (vanilla) character abilities, shield abilities, and super forms
* Independent behavior for grabbing rings, monitors, etc. as appropriate
* Support for attacking objects or destructible walls their leader pushes against
* Spectator support for non-respawning game modes (can guide bots to next starpost when dead, etc.)
* Integration with [rejointimeout](https://git.do.srb2.org/STJr/SRB2/merge_requests/722) to remain in the game as a bot after client disconnect
* Automatic control handoff between player and AI based on input (like Tails w/ Player 2 input)
* Option to disable AI entirely for an experience similar to FuriousFox's [ClassicCoop mod](https://mb.srb2.org/showthread.php?t=41377)
* ... and more! Give them a shot, they may surprise you :)

Usage
-----
Use `addbot <skin> <color>` to add bots into the game, and `removebot` to remove them.

Alternatively, use `setbot` to turn yourself into a bot, which will allow an AI to take over while AFK.

Most commands are available in splitscreen by appending "2" - `addbot2`, `setbot2`, etc.

Advanced Usage
--------------
It's also possible to use extra SRB2 client instances as bots. For example:

> srb2win.exe -config config-bot.cfg -connect localhost

This method provides some advantages, such as the ability to take direct control of the bot if needed, use
the in-game menus to configure its name / skin / etc., or send chat messages from it to feign sentience.

To configure multiple bots in this way, simply specify a unique .cfg file for each bot.

Compatibility
-------------
foxBot should be compatible with most coop mods, but currently only understands vanilla characters and shields.

It's recommended to set `ai_statmode 3` when using any mod that also syncs rings and lives.
For example, the following settings are recommended for [Combi](https://mb.srb2.org/showthread.php?t=46562): `ai_statmode 3; ai_telemode 64`

It's also recommended to load foxBot first, in case other mods are also using the `PreThinkFrame` hook to read or modify player input.
This will allow them to accurately read or modify AI input as well.

Console Commands / Variables
----------------------------
Use `bothelp` to display this section in-game at any time.

**SP / MP Server Admin:**
* `ai_sys` - Enable/Disable AI
* `ai_ignore` - Ignore targets? *(1 = enemies, 2 = rings / monitors, 3 = all)*
* `ai_seekdist` - Distance to seek enemies, rings, etc.
* `ai_catchup` - Allow AI catchup boost?

**MP Server Admin:**
* `ai_keepdisconnected` - Allow AI to remain after client disconnect?
  * Note: `rejointimeout` must also be > 0 for this to work!
* `ai_defaultleader` - Default leader for new clients *(-1 = off, 32 = random)*
* `ai_maxbots` - Maximum number of added bots per player
* `ai_reserveslot` - Reserve a player slot for joining players?
* `ai_hurtmode` - Allow AI to get hurt? *(1 = shield loss, 2 = ring loss)*
* `ai_statmode` - Allow AI individual stats? *(1 = rings, 2 = lives, 3 = both)*
* `ai_telemode` - Override AI teleport behavior w/ button press? *([64 = fire, 1024 = toss flag, 4096 = alt fire, etc.](https://wiki.srb2.org/wiki/Constants#Button_flags))*

**SP / MP Client:**
* `ai_debug` - Draw detailed debug info to HUD? *(-1 = off)*
* `ai_showhud` - Draw basic bot info to HUD?
* `listbots` - List active bots and players
* `setbot <leader>` - Follow `leader` as bot *(-1 = stop)*
  * `<bot>` - Optionally specify `bot` to set
* `addbot <skin> <color> <name>` - Add bot by `skin` etc.
  * `<type>` - Optionally specify bot `type` *(0 = player, 1 = sp, 3 = mp)*
* `alterbot <bot> <skin> <color>` - Alter `bot`'s `skin` etc.
* `removebot <bot>` - Remove `bot`
* `overrideaiability <jump> <spin>` - Override ability AI *(-1 = reset / [print ability list](https://wiki.srb2.org/wiki/S_SKIN#ability))*
  * `<bot>` - Optionally specify `bot` to override
