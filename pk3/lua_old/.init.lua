--[[
	foxBot v1.7 by fox: https://taraxis.com/foxBot-SRB2
	Based heavily on VL_ExAI-v2.lua by CobaltBW: https://mb.srb2.org/showthread.php?t=46020
	Initially an experiment to run bots off of PreThinkFrame instead of BotTiccmd
	This allowed AI to control a real player for use in netgames etc.
	Since they're no longer "bots" to the game, it integrates a few concepts from ClassicCoop-v1.3.lua by FuriousFox: https://mb.srb2.org/showthread.php?t=41377
	Such as ring-sharing, nullifying damage, etc. to behave more like a true SP bot, as player.bot is read-only

	Future TODO?
	* Avoid inturrupting players/bots carrying other players/bots due to flying too close
		(need to figure out a good way to detect if we're carrying someone)
	* Modular rewrite, defining behaviors on hashed functions - this would allow:
		* Mod support - AI hooks / overrides for targeting, ability rules, etc.
		* Gametype support - definable goals based on current game mode
		* Better abstractions - no more monolithic mess / derpy leader system
		* Other things to improve your life immeasurably
	* "Bounce" detection flag based on leader's last momentum?
		* Would increase abil threshold, allowing Tails etc. to bounce with leader better
	* Register fallback convars in case of conflicts? For buddyex compatibility etc.

	--------------------------------------------------------------------------------
	Copyright (c) 2023 Alex Strout and Claire Ellis

	Permission is hereby granted, free of charge, to any person obtaining a copy of
	this software and associated documentation files (the "Software"), to deal in
	the Software without restriction, including without limitation the rights to
	use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies
	of the Software, and to permit persons to whom the Software is furnished to do
	so, subject to the following conditions:

	The above copyright notice and this permission notice shall be included in all
	copies or substantial portions of the Software.

	THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
	IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
	FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
	AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
	LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
	OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
	SOFTWARE.
]]

--Basic init
rawset(_G, "__foxBot", {})
