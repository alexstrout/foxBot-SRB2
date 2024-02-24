--[[
	--------------------------------------------------------------------------------
	HELP STUFF
	Things that may or may not be helpful
	--------------------------------------------------------------------------------
]]
local fb = __foxBot

function fb.BotHelp(player, advanced)
	print("\x87 foxBot! v1.7: 2023-06-22")
	print("\x81  Based on ExAI v2.0: 2019-12-31")
	if not advanced
		print("")
		print("\x83 Use \"bothelp 1\" to show advanced commands!")
	end
	if advanced
	or not netgame --Show in menus
	or fb.IsAdmin(player)
		print("")
		print("\x87 SP / MP Server Admin:")
		print("\x80  ai_sys - Enable/Disable AI")
		print("\x80  ai_ignore - Ignore targets? \x86(1 = enemies, 2 = rings / monitors, 3 = all)")
		print("\x80  ai_seekdist - Distance to seek enemies, rings, etc.")
		print("\x80  ai_catchup - Allow AI catchup boost?")
	end
	if advanced
	or (fb.IsAdmin(player) and (netgame or splitscreen))
		print("")
		print("\x87 MP Server Admin:")
		print("\x80  ai_keepdisconnected - Allow AI to remain after client disconnect?")
		print("\x83   Note: rejointimeout must also be > 0 for this to work!")
		print("\x80  ai_defaultleader - Default leader for new clients \x86(-1 = off, 32 = random)")
		print("\x80  ai_maxbots - Maximum number of added bots per player")
		print("\x80  ai_reserveslot - Reserve a player slot for joining players?")
		print("\x80  ai_hurtmode - Allow AI to get hurt? \x86(1 = shield loss, 2 = ring loss)")
		print("\x80  ai_statmode - Allow AI individual stats? \x86(1 = rings, 2 = lives, 3 = both)")
		print("\x80  ai_telemode - Override AI teleport behavior w/ button press?")
		print("\x86   (64 = fire, 1024 = toss flag, 4096 = alt fire, etc.)")
	end
	print("")
	print("\x87 SP / MP Client:")
	if advanced
		print("\x80  ai_debug - Draw detailed debug info to HUD? \x86(-1 = off)")
	end
	print("\x80  ai_showhud - Draw basic bot info to HUD?")
	print("\x80  listbots - List active bots and players")
	print("\x80  setbot <leader> - Follow <leader> as bot \x86(-1 = stop)")
	if advanced
		print("\x84   <bot> - Optionally specify <bot> to set")
	end
	print("\x80  addbot <skin> <color> <name> - Add bot by <skin> etc.")
	if advanced
		print("\x84   <type> - Optionally specify bot <type> \x86(0 = player, 1 = sp, 3 = mp)")
	end
	print("\x80  alterbot <bot> <skin> <color> - Alter <bot>'s <skin> etc.")
	print("\x80  removebot <bot> - Remove <bot>")
	if advanced
		print("\x80  overrideaiability <jump> <spin> - Override ability AI \x86(-1 = reset)")
		print("\x84   <bot> - Optionally specify <bot> to override")
		print("")
		print("\x8A In-Game Actions:")
		print("\x82  [Toss Flag]\x80 - Recall following bots / Use abilities")
		print("\x83   Note: Pushing against walls or objects also triggers this")
		print("\x82  [Weapon Next / Prev]\x80 - Cycle following bots")
		print("\x82  [Weapon Select 1-7]\x80, \x82[Alt Fire]\x80 - Inspect following bots")
		print("\x82  [Fire]\x80 - Swap character (while inspecting bot)")
		print("\x83   Note: Bot must be nearby and not player-controlled")
	end
	if not player
		print("")
		print("\x87 Use \"bothelp\" to show this again!")
	end
end
COM_AddCommand("BOTHELP", fb.BotHelp, COM_LOCAL)

fb.BotHelp() --Display help
