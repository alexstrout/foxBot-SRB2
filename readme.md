foxBot! v1.3.1 ([Changelog](changelog.md))
==============
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

Preamble
--------
Like the classic titles that inspired it, SRB2 features a "Sonic & Tails" mode allowing an AI Tails to accompany you through the game -
often meeting untimely demises from bottomless pits, spikes, enemies, lava, lasers, and whatever else it can manage to run itself into.

Using SRB2's Lua interface, it's possible to extend the behavior of this bot in various ways, such as via the [Botticcmd hook](https://wiki.srb2.org/wiki/Lua/Hooks#BotTiccmd) used by [ExAI](https://mb.srb2.org/showthread.php?t=46020).
However, this mode is limited to singleplayer only, and there is currently no way to spawn additional players/bots via Lua. (though clever workarounds like [BuddyEx](https://mb.srb2.org/showthread.php?t=50847) exist)

In order to support multiplayer (and multiple bots), foxBot instead relies on using a spare client to connect to a cooperative multiplayer session and voluntarily turn into a bot.
The [PreThinkFrame hook](https://wiki.srb2.org/wiki/Lua/Hooks#PreThinkFrame) is then used to drive that player's input, allowing bots to exist in a way that's transparent to the game's networking and player logic.

Usage
-----
foxBot can be used in singleplayer with the "Sonic & Tails" option, but for best results, multiplayer is recommended.

Simply start a multiplayer coop game, and then alt-tab to launch another instance of the game - for example:

> srb2win.exe -config config-bot.cfg -connect localhost

Once connected, the AI should automatically activate and begin following the first player.

Advanced Usage
--------------
For multiple bots, simply repeat the above steps to connect multiple clients (it's recommended to specify a unique .cfg file for each client).
These clients can then either continue to run in the background, or just quit if the server has `rejointimeout` enabled.

The `setbot` command may be used to follow any player or bot; for a list of player numbers, try `listbots`.

For public games, disabling `rejointimeout` or `ai_keepdisconnected` is recommended to ensure room for new clients.
It may also be wise to disable `ai_defaultleader` or set a `motd` explaining the bot to avoid confusion.

Disabling `ai_sys` limits foxBot to [ClassicCoop](https://mb.srb2.org/showthread.php?t=41377)-like functionality;
all AI logic will stop, but players will continue to share rings/lives with their leader, and teleport when too far.
In singleplayer, foxBot will yield AI control back to the game, similarly to ExAI.

Compatibility
-------------
foxBot should be compatible with most coop mods, but currently only understands vanilla characters and shields.

It's recommended to set `ai_statmode 3` when using any mod that also syncs rings and lives.
For example, the following settings are recommended for [Combi](https://mb.srb2.org/showthread.php?t=46562): `ai_statmode 3; ai_telemode 64`

It's also recommended to load foxBot first, in case other mods are also using `PreThinkFrameFor` to read or modify player input.
This will allow them to accurately read or modify AI input as well.

Console Commands / Variables
----------------------------
Use `bothelp` to display this section in-game at any time.

**SP / MP Server Admin:**
* `ai_sys` - Enable/Disable AI
* `ai_ignore` - Ignore targets? *(1 = enemies, 2 = rings / monitors, 3 = all)*
* `ai_seekdist` - Distance to seek enemies, rings, etc.

**MP Server Admin:**
* `ai_catchup` - Allow AI catchup boost? *(MP only, sorry!)*
* `ai_keepdisconnected` - Allow AI to remain after client disconnect?
  * Note: `rejointimeout` must also be > 0 for this to work!
* `ai_defaultleader` - Default leader for new clients *(-1 = off, 32 = random)*
* `ai_hurtmode` - Allow AI to get hurt? *(1 = shield loss, 2 = ring loss)*
* `ai_statmode` - Allow AI individual stats? *(1 = rings, 2 = lives, 3 = both)*
* `ai_telemode` - Override AI teleport behavior w/ button press? *([64 = fire, 1024 = toss flag, 4096 = alt fire, etc.](https://wiki.srb2.org/wiki/Constants#Button_flags))*
* `setbota <leader> <bot>` - Have *bot* follow *leader* by number *(-1 = stop)*

**SP / MP Client:**
* `ai_debug` - Draw detailed debug info to HUD? *(-1 = off)*

**MP Client:**
* `ai_showhud` - Draw basic bot info to HUD?
* `setbot <leader>` - Follow *leader* by number *(-1 = stop)*
* `listbots` - List active bots and players
