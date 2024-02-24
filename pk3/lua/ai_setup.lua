--[[
	--------------------------------------------------------------------------------
	AI SETUP FUNCTIONS / CONSOLE COMMANDS
	Any AI "setup" logic, including console commands
	--------------------------------------------------------------------------------
]]
local fb = __foxBot

--Set a new target for AI
function fb.SetTarget(ai, target)
	--Clean up previous target, if any
	if ai.target and ai.target.valid
	and ai.target.ai_attacker == ai
		ai.target.ai_attacker = nil
	end

	--Set target and reset (or define) target-specific vars
	ai.target = target
	ai.targetjumps = 0 --If too many, abort target
	if target and target.valid
	and not target.ai_attacker
		target.ai_attacker = ai
	end
end

--Reset (or define) all AI vars to their initial values
function fb.ResetAI(ai)
	ai.think_last = 0 --Last think time
	ai.jump_last = 0 --Jump history
	ai.spin_last = 0 --Spin history
	ai.move_last = 0 --Directional input history
	ai.zoom_last = false --Zoom tube history
	ai.anxiety = 0 --Catch-up counter
	ai.panic = 0 --Catch-up mode
	ai.panicjumps = 0 --If too many, just teleport
	ai.flymode = 0 --0 = No interaction. 1 = Grab Sonic. 2 = Sonic is latched.
	ai.spinmode = 0 --If 1, Tails is spinning or preparing to charge spindash
	ai.thinkfly = 0 --If 1, Tails will attempt to fly when Sonic jumps
	ai.idlecount = 0 --Checks the amount of time without any player inputs
	ai.bored = 0 --AI will act independently if "bored".
	ai.drowning = 0 --AI drowning panic. 2 = Tails flies for air.
	fb.SetTarget(ai, nil) --Enemy to target
	ai.targetcount = 0 --Number of targets in range (used for armageddon shield)
	ai.targetnosight = 0 --How long the target has been out of view
	ai.playernosight = 0 --How long the player has been out of view
	ai.stalltics = 0 --Time that AI has struggled to move
	ai.attackwait = 0 --Tics to wait before attacking again
	ai.attackoverheat = 0 --Used by Fang to determine whether to wait
	ai.cmd_time = 0 --If > 0, suppress bot ai in favor of player controls
	ai.pushtics = 0 --Time leader has pushed against something (used to maybe attack it)
	ai.longjump = 0 --AI is making a decently sized leap for an enemy
	ai.doteleport = false --AI is attempting to teleport
	ai.teleporttime = 0 --Time since AI has first attempted to teleport
	ai.predictgap = 0 --AI is jumping a gap
	ai.loseshield = false --If true, lose our shield (e.g. due to leader getting hit)
	ai.busy = false --AI is "busy" (spectating, in combat, etc.)
	ai.busyleader = nil --Temporary leader when busy

	--Destroy any child objects if they're around
	ai.overlay = fb.DestroyObj($) --Speech bubble overlay - only (re)create this if needed in think logic
	ai.overlaytime = 0 --Time overlay has been active
	ai.waypoint = fb.DestroyObj($) --Transient waypoint used for navigating around corners
end

--Update all followers' followerindex
function fb.UpdateFollowerIndices(leader)
	if not (leader and leader.valid and leader.ai_followers)
		return
	end
	for k, b in ipairs(leader.ai_followers)
		if b and b.valid and b.ai
			b.ai.followerindex = k
		end
	end

	--Maintain a recursive "tail" reference to our last follower
	local tail = fb.TableLast(leader.ai_followers)
	if tail and tail.valid and tail.ai_followers
		tail = $.ai_followers.tail
	end
	leader.ai_followers.tail = tail

	--Bubble this change up through realleader (if applicable)
	local baseleader = leader
	while leader.ai
	and leader.ai.realleader
	and leader.ai.realleader.valid
	and leader.ai.realleader.ai_followers
	and fb.TableLast(leader.ai.realleader.ai_followers) == leader
	and leader.ai.realleader != baseleader
		leader.ai.realleader.ai_followers.tail = tail
		leader = leader.ai.realleader
	end
end

--Register follower with leader for lookup later
function fb.RegisterFollower(leader, bot)
	if not (leader and leader.valid)
		return
	end
	if not leader.ai_followers
		leader.ai_followers = {}
	end
	table.insert(leader.ai_followers, bot)
	fb.UpdateFollowerIndices(leader)
end

--Unregister follower with leader
function fb.UnregisterFollower(leader, bot)
	if not (leader and leader.valid and leader.ai_followers)
		return
	end
	for k, b in ipairs(leader.ai_followers)
		if b == bot
			table.remove(leader.ai_followers, k)
			break
		end
	end
	if leader.ai_followers[1]
		fb.UpdateFollowerIndices(leader)
	else
		leader.ai_followers = nil
	end
end

--Register bot with player owner for lookup later
function fb.RegisterOwner(player, bot)
	if not (player and player.valid)
		return
	end
	if not player.ai_ownedbots
		player.ai_ownedbots = {}
	end
	table.insert(player.ai_ownedbots, bot)
	if bot and bot.valid
		bot.ai_owner = player
	end
end

--Unregister bot with player owner
function fb.UnregisterOwner(player, bot)
	if bot and bot.valid
		bot.ai_owner = nil
	end
	if not (player and player.valid and player.ai_ownedbots)
		return
	end
	for k, b in ipairs(player.ai_ownedbots)
		if b == bot
			table.remove(player.ai_ownedbots, k)
			break
		end
	end
	if not player.ai_ownedbots[1]
		player.ai_ownedbots = nil
	end
end

--Create AI table for a given player, if needed
function fb.SetupAI(player)
	if player.ai
		return
	end

	--Create table, defining any vars that shouldn't be reset via ResetAI
	player.ai = {
		leader = nil, --Bot's leader
		realleader = nil, --Bot's "real" leader (if temporarily following someone else)
		followerindex = 0, --Our index in realleader's ai_followers array
		lastrings = player.rings, --Last ring count of bot (used to sync w/ leader)
		lastlives = player.lives, --Last life count of bot (used to sync w/ leader)
		realrings = player.rings, --"Real" ring count of bot (outside of sync)
		realxtralife = player.xtralife, --"Real" xtralife count of bot (outside of sync)
		reallives = player.lives, --"Real" life count of bot (outside of sync)
		ronin = false, --Headless bot from disconnected client?
		timeseed = P_RandomByte() + #player, --Used for time-based pseudo-random behaviors (e.g. via BotTime)
		syncrings = false, --Current sync setting for rings
		synclives = false, --Current sync setting for lives
		lastseenpos = { x = 0, y = 0, z = 0 } --Last seen position tracking
	}
	fb.ResetAI(player.ai) --Define the rest w/ their respective values
	player.ai.playernosight = 3 * TICRATE --For setup only, queue an instant teleport
end

--Restore "real" ring / life counts for a given player
function fb.RestoreRealRings(player)
	player.rings = player.ai.realrings
	player.xtralife = player.ai.realxtralife
end
function fb.RestoreRealLives(player)
	player.lives = player.ai.reallives

	--Transition to spectating if we had no lives left
	if player.lives < 1 and not player.spectator
		player.playerstate = PST_REBORN
	end
end

--"Repossess" a bot for player control
function fb.Repossess(player)
	--Reset our original analog etc. prefs
	--SendWeaponPref isn't exposed to Lua, so just cycle convars to trigger it
	--However, 2.2.11 now prevents this as none of the convars are marked CV_ALLOWLUA
	--So we must manually restore some pflags with ugly convar lookups :P
	if not netgame or player == consoleplayer
		local CV_Analog = CV_FindVar("configanalog")
		local CV_Directionchar = CV_FindVar("directionchar")
		local CV_Autobrake = CV_FindVar("autobrake")
		if not netgame and #player > 0
			CV_Analog = CV_FindVar("configanalog2")
			CV_Directionchar = CV_FindVar("directionchar2")
			CV_Autobrake = CV_FindVar("autobrake2")
		end
		COM_BufInsertText(player, "__SendPlayerPrefs " .. CV_Analog.value .. " " .. CV_Directionchar.value .. " " .. CV_Autobrake.value)
	end

	--Reset our vertical aiming (in case we have vert look disabled)
	player.aiming = 0

	--Reset anything else
	fb.ResetAI(player.ai)
end

--Destroy AI table (and any child tables / objects) for a given player, if needed
function fb.DestroyAI(player)
	if not player.ai
		return
	end

	--Reset pflags etc. for player
	--Also resets all vars, clears target, etc.
	fb.Repossess(player)

	--Unregister ourself from our (real) leader if still valid
	fb.UnregisterFollower(player.ai.realleader, player)

	--Kick headless bots w/ no client
	--Otherwise they sit and do nothing
	if player.ai.ronin
		player.quittime = 1
	end

	--Restore our "real" ring / life counts if synced
	if player.ai.syncrings
		fb.RestoreRealRings(player)
	end
	if player.ai.synclives
		fb.RestoreRealLives(player)
	end

	--SP bots record our last good realleader to reset to later
	if fb.SPBot(player)
		player.ai_lastrealleader = player.ai.realleader
	end

	--My work here is done
	player.ai = nil
	collectgarbage()
end

--Get our "top" leader in a leader chain (if applicable)
--e.g. for A <- B <- D <- C, D's "top" leader is A
function fb.GetTopLeader(bot, basebot)
	--basebot automatically set to bot if nil
	if bot != basebot and bot.valid and bot.ai
	and bot.ai.realleader and bot.ai.realleader.valid
		return fb.GetTopLeader(bot.ai.realleader, basebot or bot)
	end
	return bot
end

--Get our "bottom" follower in a leader chain (if applicable)
--e.g. for A <- B <- D <- C, A's "bottom" follower is C
function fb.GetBottomFollower(bot, basebot)
	--basebot automatically set to bot if nil
	if bot != basebot and bot.valid and bot.ai_followers
		for k, b in ipairs(bot.ai_followers)
			--Pick a random node if the tree splits
			if P_RandomByte() < 128
			or table.maxn(bot.ai_followers) == k
				return fb.GetBottomFollower(b, basebot or bot)
			end
		end
	end
	return bot
end

--List all bots, optionally excluding bots led by leader
function fb.SubListBots(player, leader, owner, bot, level)
	if bot == leader
		return 0
	end
	local msg = #bot .. " - " .. bot.name
	for i = 0, level
		msg = " " .. $
	end
	if bot.realmo and bot.realmo.valid and bot.realmo.skin
		msg = $ .. " \x86(" .. bot.realmo.skin .. ")"
	end
	if bot.spectator
		msg = $ .. " \x87(KO'd)"
	end
	if bot.quittime
		msg = $ .. " \x85(disconnecting)"
	elseif bot.ai_owner and bot.ai_owner.valid
		msg = $ .. " \x8A(" .. fb.BotType(bot) .. ": " .. #bot.ai_owner .. " - " .. bot.ai_owner.name .. ")"
	elseif bot.ai and bot.ai.cmd_time
		msg = $ .. " \x81(player-controlled)"
	elseif bot.ai and bot.ai.ronin
		msg = $ .. " \x83(disconnected)"
	elseif not bot.bot
		msg = $ .. " \x84(player)"
	end
	local count = 0
	if owner == nil or fb.IsAuthority(owner, bot, true)
		fb.ConsPrint(player, msg)
		count = 1
	end
	if bot.ai_followers
		for _, b in ipairs(bot.ai_followers)
			if b and b.valid
				count = $ + fb.SubListBots(player, leader, owner, b, level + 1)
			end
		end
	end
	return count
end
function fb.ListBots(player, leader, owner)
	if leader != nil
		leader = fb.ResolvePlayerByNum($)
		if leader and leader.valid
			fb.ConsPrint(player, "\x84 Excluding players/bots led by " .. leader.name)
		end
	end
	if owner != nil
		owner = fb.ResolvePlayerByNum($)
		if owner and owner.valid
			fb.ConsPrint(player, "\x81 Showing only players/bots owned by " .. owner.name)
		end
	end
	local count = 0
	for p in players.iterate
		if not p.ai
			count = $ + fb.SubListBots(player, leader, owner, p, 0)
		end
	end
	fb.ConsPrint(player, "Returned " .. count .. " nodes")
end
COM_AddCommand("LISTBOTS", fb.ListBots, COM_LOCAL)

--Set player as a bot following a particular leader
--Internal/Admin-only: Optionally specify some other player/bot to follow leader
function fb.SetBot(player, leader, bot)
	local pbot = player
	if bot != nil --Must check nil as 0 is valid
		pbot = fb.ResolveMultiplePlayersByNum(player, bot)
		if type(pbot) == "table"
			for _, bot in ipairs(pbot)
				fb.SetBot(player, leader, bot)
			end
			return
		end
		if not fb.IsAuthority(player, pbot)
			pbot = nil
		end
	end
	if not (pbot and pbot.valid)
		fb.ConsPrint(player, "Invalid bot! Please specify a bot by number:")
		fb.ListBots(player, nil, #player)
		return
	end

	--Make sure we won't end up following ourself
	local pleader = fb.ResolvePlayerByNum(leader)
	if pleader and pleader.valid
	and fb.GetTopLeader(pleader, pbot) == pbot
		if pbot == player
			fb.ConsPrint(pleader, pbot.name + " tried to follow you, but you're already following them!")
			if pleader == pbot.ai_owner
				fb.ConsPrint(pleader, pbot.name + "\x8A has no leader and will be removed shortly...")
			end
		end
		fb.ConsPrint(player, pbot.name + " would end up following itself! Please try a different leader:")
		fb.ListBots(player, #pbot)
		return
	end

	--Set up our AI (if needed) and figure out leader
	fb.SetupAI(pbot)
	if pleader and pleader.valid
		fb.ConsPrint(player, "Set bot " + pbot.name + " following " + pleader.name)
		if player != pbot
			fb.ConsPrint(pbot, player.name + " set bot " + pbot.name + " following " + pleader.name)
		end
	elseif pbot.ai.realleader
		fb.ConsPrint(player, "Stopping bot " + pbot.name)
		if player != pbot
			fb.ConsPrint(pbot, player.name + " stopping bot " + pbot.name)
		end
	else
		fb.ConsPrint(player, "Invalid leader! Please specify a leader by number:")
		fb.ListBots(player, #pbot)
	end

	--Valid leader?
	if pleader and pleader.valid
		--Unregister ourself from our old (real) leader (if applicable)
		fb.UnregisterFollower(pbot.ai.realleader, pbot)

		--Set the new leader
		pbot.ai.leader = pleader
		pbot.ai.realleader = pleader

		--Register ourself as a follower
		fb.RegisterFollower(pleader, pbot)
	else
		--Destroy AI if no leader set
		fb.DestroyAI(pbot)

		--Allow bot to return itself to owner if able (owner not following it)
		if pbot.ai_owner and pbot.ai_owner.valid and pbot.ai_owner != player
			fb.SetBot(pbot, #pbot.ai_owner)
		end
	end
end
COM_AddCommand("SETBOT2", fb.SetBot, COM_SPLITSCREEN)
COM_AddCommand("SETBOT", fb.SetBot, 0)

--Add player as a bot following us
function fb.AddBot(player, skin, color, name, type)
	if not (player.realmo and player.realmo.valid)
		fb.ConsPrint(player, "Can't do this outside a level!")
		return
	end
	if netgame
		if not fb.IsAdmin(player)
		and player.ai_ownedbots
		and table.maxn(player.ai_ownedbots) >= fb.CV_AIMaxBots.value
			fb.ConsPrint(player, "Too many bots! Maximum allowed per player: " .. fb.CV_AIMaxBots.value)
			return
		end
		if fb.CV_AIReserveSlot.value
		and fb.PlayerCount() >= fb.CV_MaxPlayers.value - 1
			fb.ConsPrint(player, "Too many bots for current maxplayers count: " .. fb.CV_MaxPlayers.value)
			if fb.IsAdmin(player)
				fb.ConsPrint(player, "\x82" .. "Admin Only:\x80 Try increasing maxplayers or disabling ai_reserveslot")
			end
			return
		end
	end

	--Use logical defaults in singleplayer
	if color
		color = R_GetColorByName($)
	end
	if not (netgame or splitscreen)
		--Figure out skins in use
		local skinsinuse = {}
		for p in players.iterate
			if p.realmo and p.realmo.valid
				skinsinuse[p.realmo.skin] = true
			end
		end

		--Default to next available unlocked skin
		if not (skin and skins[skin])
			for s in skins.iterate
				if not skinsinuse[s.name]
				and R_SkinUsable(player, s.name)
					skin = s.name
					break
				end
			end
		end

		--Default to skin's prefcolor / realname
		if skin and skins[skin]
		and not skinsinuse[skin]
			if not color
				color = skins[skin].prefcolor
			end
			if not name or name == ""
				name = skins[skin].realname
			end
		end
	end

	--Validate skin
	if not (skin and skins[skin])
		local rs = {}
		for s in skins.iterate
			if R_SkinUsable(player, s.name)
				table.insert(rs, s.name)
			end
		end
		local i = P_RandomKey(table.maxn(rs)) + 1
		skin = rs[i]
	end

	--Validate color
	if not color
		color = P_RandomRange(1, 68)
	end

	--Validate name
	if not name or name == ""
		name = fb.BotlessName(player) .. "Bot"
	end
	local i = 0
	local n = name
	for p in players.iterate
		if fb.BotlessName(p) == n
			i = $ + 1
			n = name .. i
		end
	end
	name = n

	--Validate type
	type = tonumber($)
	if type != nil
		type = min(max($, BOT_NONE), BOT_MPAI)
	elseif netgame or splitscreen
		type = BOT_MPAI
	else
		type = BOT_2PAI
	end

	--Dedicated servers will crash adding a BOT_NONE bot to slot 0
	--Instead, work around this by adding a proxy BOT_MPAI bot there for a second
	local sbot = nil
	if type == BOT_NONE and not (players[0] and players[0].valid)
		sbot = G_AddPlayer("tails", 8, "Server Proxy Bot", BOT_MPAI)
	end

	--Add that bot!
	--Manually set our skin later, since G_AddPlayer throws error for hidden skins on BOT_NONE bot
	local pbot = G_AddPlayer("sonic", color, name, type)
	if pbot and pbot.valid
		fb.ConsPrint(player, "Adding " .. fb.BotType(pbot) .. " " .. pbot.name .. " / " .. skins[skin].name .. " / " .. R_GetNameByColor(color))

		--Set our skin if usable
		if R_SkinUsable(pbot, skin)
			R_SetPlayerSkin(pbot, skin)
		end

		--Force color in singleplayer
		pbot.skincolor = color

		--Set that bot! And figure out authority owner
		fb.SetBot(pbot, #player)
		fb.RegisterOwner(player, pbot)

		--All summoned bots should disconnect when stopped, except SP bots
		if pbot.ai and not fb.SPBot(pbot)
			pbot.ai.ronin = true
		end
	else
		fb.ConsPrint(player, "Unable to add bot!")
	end

	--Remove server proxy bot (if applicable)
	if sbot and sbot.valid
		G_RemovePlayer(#sbot)
	end
end
COM_AddCommand("ADDBOT2", fb.AddBot, COM_SPLITSCREEN)
COM_AddCommand("ADDBOT", fb.AddBot, 0)

--Alter player bot's skin, etc.
function fb.AlterBot(player, bot, skin, color)
	local pbot = fb.ResolveMultiplePlayersByNum(player, bot)
	if type(pbot) == "table"
		for _, bot in ipairs(pbot)
			fb.AlterBot(player, bot, skin, color)
		end
		return
	end
	if not fb.IsAuthority(player, pbot)
		pbot = nil
	end
	if not (pbot and pbot.valid)
		fb.ConsPrint(player, "Invalid bot! Please specify a bot by number:")
		fb.ListBots(player, nil, #player)
		return
	end

	--Set skin and color
	if skin and skins[skin]
	and R_SkinUsable(pbot, skin)
	and pbot.realmo and pbot.realmo.valid --Must be used in-level
	and pbot.realmo.skin != skins[skin].name
		fb.ConsPrint(player, "Set bot " .. pbot.name .. " skin to " .. skins[skin].name)
		if player != pbot
			fb.ConsPrint(pbot, player.name + " set bot " .. pbot.name .. " skin to " .. skins[skin].name)
		end
		R_SetPlayerSkin(pbot, skin)
	elseif not color
		color = skin --Try skin arg as color
	end
	if color
		color = R_GetColorByName($)
		if color --Not nil or 0, since we shouldn't set SKINCOLOR_NONE
		and color != pbot.skincolor
			fb.ConsPrint(player, "Set bot " .. pbot.name .. " color to " .. R_GetNameByColor(color))
			if player != pbot
				fb.ConsPrint(pbot, player.name + " set bot " .. pbot.name .. " color to " .. R_GetNameByColor(color))
			end
			if pbot.realmo and pbot.realmo.valid
			and pbot.realmo.color == pbot.skincolor
				pbot.realmo.color = color
			end
			pbot.skincolor = color
		end
	end
end
COM_AddCommand("ALTERBOT2", fb.AlterBot, COM_SPLITSCREEN)
COM_AddCommand("ALTERBOT", fb.AlterBot, 0)

--Remove player bot
function fb.RemoveBot(player, bot)
	local pbot = nil
	if bot != nil --Must check nil as 0 is valid
		pbot = fb.ResolveMultiplePlayersByNum(player, bot)
		if type(pbot) == "table"
			for _, bot in ipairs(pbot)
				fb.RemoveBot(player, bot)
			end
			return
		end
	elseif player.ai_ownedbots
		--Loop in descending order, instead of just using ipairs
		local b = nil
		for i = table.maxn(player.ai_ownedbots), 1, -1
			b = player.ai_ownedbots[i]
			if not b.quittime
				pbot = b
				break
			end
		end
	elseif player.ai_followers
		--Loop in descending order, instead of just using ipairs
		local b = nil
		for i = table.maxn(player.ai_followers), 1, -1
			b = player.ai_followers[i]
			if fb.IsAuthority(player, b, true)
				pbot = b
				break
			end
		end
	end
	if not fb.IsAuthority(player, pbot)
		pbot = nil
	end
	if not (pbot and pbot.valid and (pbot.ai or pbot.ai_owner)) --Avoid misleading errors on non-ai
		fb.ConsPrint(player, "Invalid bot! Please specify a bot by number:")
		fb.ListBots(player, nil, #player)
		return
	end

	--Remove owned bot (or bot flagged for forced removal)
	if pbot.ai_forceremove or (pbot.ai_owner and pbot.ai_owner.valid and pbot.ai_owner == player)
		fb.ConsPrint(player, "Removing " .. fb.BotType(pbot) .. " " .. pbot.name)
		if player != pbot.ai_owner
			fb.ConsPrint(pbot.ai_owner, player.name .. " removing " .. fb.BotType(pbot) .. " " .. pbot.name)
		end

		--Remove that bot!
		fb.DestroyAI(pbot) --Silently stop bot, should transition to disconnected
		if pbot.bot or pbot.ai_forceremove
			pbot.ai_forceremove = nil --Just in case
			if #pbot > 0 --Don't remove dedicated server! Fall back to G_RemovePlayer
				pbot.quittime = INT32_MAX --Skip disconnect time
			else
				G_RemovePlayer(#pbot)
			end
			if netgame
				chatprint("\x82*" .. pbot.name .. "\x82 has left the game")
			end
		end
	--Stop bot if no owner (real player)
	--Alternatively, transfer bot if owned by someone else
	else
		fb.SetBot(player, -1, #pbot)
	end
end
COM_AddCommand("REMOVEBOT2", fb.RemoveBot, COM_SPLITSCREEN)
COM_AddCommand("REMOVEBOT", fb.RemoveBot, 0)

--Override character jump / spin ability AI
--Internal/Admin-only: Optionally specify some other player/bot to override
function fb.SetAIAbility(player, pbot, abil, type, min, max)
	abil = tonumber($)
	if abil != nil and abil >= min and abil <= max
		local msg = pbot.name .. " " .. type .. " AI override " .. abil
		fb.ConsPrint(player, "Set " .. msg)
		if player != pbot
			fb.ConsPrint(pbot, player.name .. " set " .. msg)
		end
		pbot.ai_override_abil = $ or {}
		pbot.ai_override_abil[type] = abil
	elseif pbot.ai_override_abil and pbot.ai_override_abil[type] != nil
		local msg = pbot.name .. " " .. type .. " AI override " .. pbot.ai_override_abil[type]
		fb.ConsPrint(player, "Cleared " .. msg)
		if player != pbot
			fb.ConsPrint(pbot, player.name .. " cleared " .. msg)
		end
		pbot.ai_override_abil[type] = nil
		if next(pbot.ai_override_abil) == nil
			pbot.ai_override_abil = nil
		end
	else
		local msg = "Invalid " .. type .. " AI override, " .. pbot.name .. " has " .. type .. " AI "
		if type == "spin"
			if pbot.ai
				fb.ConsPrint(player, msg .. pbot.charability2)
			end
			fb.ConsPrint(player,
				"Valid spin abilities:",
				"\x86 -1 = Reset",
				"\x80 0 = None",
				"\x83 1 = Spindash",
				"\x89 2 = Gunslinger",
				"\x8E 3 = Melee"
			)
		else
			if pbot.ai
				fb.ConsPrint(player, msg .. pbot.charability)
			end
			fb.ConsPrint(player,
				"Valid jump abilities:",
				"\x86 -1 = Reset",
				"\x80 0 = None           \x80 8 = Slow Hover",
				"\x84 1 = Thok           \x80 9 = Telekinesis",
				"\x87 2 = Fly            \x80 10 = Fall Switch",
				"\x85 3 = Glide          \x80 11 = Jump Boost",
				"\x80 4 = Homing Attack  \x80 12 = Air Drill",
				"\x80 5 = Swim           \x80 13 = Jump Thok",
				"\x80 6 = Double Jump    \x89 14 = Tail Bounce",
				"\x8C 7 = Hover          \x8E 15 = Melee (Twin-Spin)"
			)
		end
	end
end
function fb.OverrideAIAbility(player, abil, abil2, bot)
	local pbot = player
	if bot != nil --Must check nil as 0 is valid
		pbot = fb.ResolveMultiplePlayersByNum(player, bot)
		if type(pbot) == "table"
			for _, bot in ipairs(pbot)
				fb.OverrideAIAbility(player, abil, abil2, bot)
			end
			return
		end
		if not fb.IsAuthority(player, pbot)
			pbot = nil
		end
	end
	if not (pbot and pbot.valid)
		fb.ConsPrint(player, "Invalid bot! Please specify a bot by number:")
		fb.ListBots(player, nil, #player)
		return
	end

	--Set that ability!
	fb.SetAIAbility(player, pbot, abil, "jump", CA_NONE, CA_TWINSPIN)
	fb.SetAIAbility(player, pbot, abil2, "spin", CA2_NONE, CA2_MELEE)
end
COM_AddCommand("OVERRIDEAIABILITY2", fb.OverrideAIAbility, COM_SPLITSCREEN)
COM_AddCommand("OVERRIDEAIABILITY", fb.OverrideAIAbility, 0)

--Admin-only: Debug command for testing out shield AI
--Left in for convenience, use with caution - certain shield values may crash game
COM_AddCommand("DEBUG_BOTSHIELD", function(player, bot, shield, inv, spd, super, rings, ems, scale, abil, abil2)
	bot = fb.ResolvePlayerByNum(bot)
	shield = tonumber(shield)
	if not (bot and bot.valid)
		return
	elseif shield == nil
		fb.ConsPrint(player,
			"Valid shields:",
			" " .. SH_NONE .. "\t\tNone",
			" " .. SH_PITY .. "\t\tPity",
			" " .. SH_WHIRLWIND .. "\t\tWhirlwind",
			" " .. SH_ARMAGEDDON .. "\t\tArmageddon",
			" " .. SH_PINK .. "\t\tPink",
			" " .. SH_ELEMENTAL .. "\tElemental",
			" " .. SH_ATTRACT .. "\tAttraction",
			" " .. SH_FLAMEAURA .. "\tFlame",
			" " .. SH_BUBBLEWRAP .. "\tBubble",
			" " .. SH_THUNDERCOIN .. "\tLightning",
			" " .. SH_FORCE .. "\tForce",
			"Valid shield flags:",
			" " .. SH_FIREFLOWER .. "\tFireflower",
			" " .. SH_PROTECTFIRE .. "\tFire Protection",
			" " .. SH_PROTECTWATER .. "\tWater Protection",
			" " .. SH_PROTECTELECTRIC .. "\tElectric Protection",
			" " .. SH_PROTECTSPIKE .. "\tSpike Protection"
		)
		fb.ConsPrint(player, bot.name + " has shield " + bot.powers[pw_shield])
		return
	end
	P_SwitchShield(bot, shield)
	local msg = player.name + " granted " + bot.name + " shield " + shield
	inv = tonumber(inv)
	if inv
		bot.powers[pw_invulnerability] = inv
		msg = $ + " invulnerability " + inv
	end
	spd = tonumber(spd)
	if spd
		bot.powers[pw_sneakers] = spd
		msg = $ + " sneakers " + spd
	end
	super = tonumber(super)
	if super and not (bot.charflags & SF_SUPER)
		bot.charflags = $ | SF_SUPER
		msg = $ + " super ability"
	end
	rings = tonumber(rings)
	if rings
		P_GivePlayerRings(bot, rings)
		msg = $ + " rings " + rings
	end
	ems = tonumber(ems)
	if ems and not All7Emeralds(emeralds)
		local bmo = bot.realmo
		if bmo and bmo.valid
			local ofs = 32 * bmo.scale + bmo.radius
			P_SpawnMobj(bmo.x - ofs, bmo.y - ofs, bmo.z, MT_EMERALD1)
			P_SpawnMobj(bmo.x - ofs, bmo.y, bmo.z, MT_EMERALD2)
			P_SpawnMobj(bmo.x - ofs, bmo.y + ofs, bmo.z, MT_EMERALD3)
			P_SpawnMobj(bmo.x + ofs, bmo.y - ofs, bmo.z, MT_EMERALD4)
			P_SpawnMobj(bmo.x + ofs, bmo.y, bmo.z, MT_EMERALD5)
			P_SpawnMobj(bmo.x + ofs, bmo.y + ofs, bmo.z, MT_EMERALD6)
			P_SpawnMobj(bmo.x, bmo.y - ofs, bmo.z, MT_EMERALD7)
			msg = $ + " emeralds"
		end
	end
	scale = tonumber(scale)
	if scale
		local bmo = bot.realmo
		if bmo and bmo.valid
			if scale > 0
				bmo.destscale = scale * FRACUNIT
				msg = $ + " scale " + scale
			elseif scale < 0
				bmo.destscale = FRACUNIT / abs(scale)
				msg = $ + " scale 1/" + abs(scale)
			end
		end
	end
	abil = tonumber(abil)
	if abil != nil and abil >= CA_NONE and abil <= CA_TWINSPIN
		bot.charability = abil
		msg = $ + " abil " + abil
	end
	abil2 = tonumber(abil2)
	if abil2 != nil and abil2 >= CA2_NONE and abil <= CA2_MELEE
		bot.charability2 = abil2
		msg = $ + " abil2 " + abil2
	end
	print(msg)
end, COM_ADMIN)

--Debug command for printing out AI objects
function fb.DumpNestedTable(player, t, level, pt)
	pt[t] = true
	for k, v in pairs(t)
		local msg = k .. " = " .. tostring(v)
		for i = 0, level
			msg = " " .. $
		end
		fb.ConsPrint(player, msg)
		if type(v) == "table" and not pt[v]
			fb.DumpNestedTable(player, v, level + 1, pt)
		end
	end
end
COM_AddCommand("DEBUG_BOTAIDUMP", function(player, bot)
	bot = fb.ResolvePlayerByNum(bot)
	if not (bot and bot.valid)
		return
	end
	if bot.ai
		fb.ConsPrint(player, "-- botai " .. bot.name .. " --")
		fb.DumpNestedTable(player, bot.ai, 0, {})
	end
	if bot.ai_followers
		fb.ConsPrint(player, "-- ai_followers " .. bot.name .. " --")
		fb.DumpNestedTable(player, bot.ai_followers, 0, {})
	end
	if bot.ai_ownedbots
		fb.ConsPrint(player, "-- ai_ownedbots " .. bot.name .. " --")
		fb.DumpNestedTable(player, bot.ai_ownedbots, 0, {})
	end
	if bot.ai_override_abil
		fb.ConsPrint(player, "-- ai_override_abil " .. bot.name .. " --")
		fb.DumpNestedTable(player, bot.ai_override_abil, 0, {})
	end
end, COM_LOCAL)
