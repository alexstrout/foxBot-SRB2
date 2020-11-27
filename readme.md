foxBot! v1.0
============
Turn spare SRB2 clients into cooperative AI bots: [forum thread here]

Features
--------
* Based on CobaltBW's [ExAI mod](https://mb.srb2.org/showthread.php?t=46020)
* Major rewrite to support multiplayer / multiple bots and fix some issues
* Supports any combination of players and bots
* Prediction-based movement AI for more efficient following and enemy bopping
* Better understanding of abilities, including shield abilities
* Able to attack targets in different ways (air-hammer, spindash, etc.)
* Can grab rings, monitors, etc. as appropriate
* Can attack objects or destructible walls their leader pushes against
* Bots can piggyback [rejointimeout](https://git.do.srb2.org/STJr/SRB2/merge_requests/722) to remain in the game after their client disconnects
* Players can override their bot's input at any time
* AI can be disabled entirely for an experience similar to FuriousFox's [ClassicCoop mod](https://mb.srb2.org/showthread.php?t=41377)
* Highly configurable, with the option to toggle most features (see below)

Preamble
--------
SRB2 features a "Sonic & Tails" mode that enables an AI Tails to follow the player, similarly to classic titles.
This works by spawning another player and [building a "ticcmd" input](https://github.com/STJr/SRB2/blob/master/src/b_bot.c#L46) every frame in order to drive the bot.
[ExAI](https://mb.srb2.org/showthread.php?t=46020) utilizes the [Botticcmd hook](https://wiki.srb2.org/wiki/Lua/Hooks#BotTiccmd) to extend this behavior in various ways.

In order to support multiple bots (and multiplayer), foxBot instead utilizes the [PreThinkFrame hook](https://wiki.srb2.org/wiki/Lua/Hooks#PreThinkFrame) to drive an actual player's input,
allowing bots to simply exist in a way that's transparent to the game's networking and player logic.

Usage
-----
foxBot can be used in singleplayer with the "Sonic & Tails" option, but for best results, multiplayer is recommended.

Simply start a multiplayer coop game, and then alt-tab to launch another instance of the game - for example:

> srb2win.exe -config config-bot.cfg -connect localhost

Once the spare instance is connected, open the console and type `setbot 0` to follow the first player.

This instance can either run in the background, or can simply quit as long as the server has `rejointimeout` set above 0.

Advanced Usage
--------------
The `setbot` command may be used to follow any player or bot; for a list of player numbers, try `nodes`.

Instead of running `setbot` on the client, the server may define a default leader for connecting clients via `ai_defaultleader`.

Disabling `ai_keepdisconnected` is recommended for public games with `rejointimeout` set, to ensure room for new clients.

Disabling `ai_sys` disables AI entirely, limiting foxBot to [ClassicCoop](https://mb.srb2.org/showthread.php?t=41377)-ish functionality. Players will continue to share rings/lives with their leader, and teleport when too far.

Compatibility
-------------
foxBot should be compatible with most coop mods, but only understands vanilla character abilities.

It's recommended to set `ai_statmode 3` for any mod that syncs rings and lives.

e.g. for [Combi](https://mb.srb2.org/showthread.php?t=46562), the following settings are recommended: `ai_statmode 3; ai_telemode 64`

Console Commands / Variables
----------------------------
Use `bothelp` to display this section in-game at any time.

**SP / MP Server Admin Convars:**
* `ai_sys` - Enable/Disable AI
* `ai_ignore` - Ignore targets? (1 = enemies, 2 = rings / monitors, 3 = all)
* `ai_seekdist` - Distance to seek enemies, rings, etc.

**MP Server Admin Convars:**
* `ai_catchup` - Allow AI catchup boost? (MP only, sorry!)
* `ai_keepdisconnected` - Allow AI to remain after client disconnect?
  * Note: `rejointimeout` must also be > 0 for this to work!
* `ai_defaultleader` - Default players to AI following this leader?
* `ai_hurtmode` - Allow AI to get hurt? (1 = shield loss, 2 = ring loss)

**MP Server Admin Convars - Compatibility:**
* `ai_statmode` - Allow AI individual stats? (1 = rings, 2 = lives, 3 = both)
* `ai_telemode` - Override AI teleport behavior w/ button press?
  * (0 = disable, 64 = fire, 1024 = toss flag, 4096 = alt fire, etc.)

**SP / MP Client Convars:**
* `ai_debug` - stream local variables and cmd inputs to console?

**MP Client Commands:**
* `setbot <playernum>` - follow target player by number (e.g. from "nodes" command)

Changes
-------
v1.0 (???):
* Initial release.
