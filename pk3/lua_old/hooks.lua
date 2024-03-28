--[[
	--------------------------------------------------------------------------------
	LUA HOOKS
	Define all hooks used to actually interact w/ the game
	--------------------------------------------------------------------------------
]]
local fb = __foxBot

--Tic? Tock! Call fb.PreThinkFrameFor bot
addHook("PreThinkFrame", function()
	for player in players.iterate
		--Handle bots
		if player.ai
			fb.PreThinkFrameFor(player)
		--Cancel quittime if we've rejoined a previously headless bot
		--(unfortunately PlayerJoin does not fire for rejoins)
		elseif player.quittime and (
			player.cmd.forwardmove
			or player.cmd.sidemove
			or player.cmd.buttons
		)
			player.quittime = 0
		end

		--Handle follower cycling?
		--(may also apply to player-controlled bots)
		if player.ai_followers or player.ai_picktarget
			fb.LeaderPreThinkFrameFor(player)
		end
	end
end)

--Handle MapChange for bots (e.g. call ResetAI)
addHook("MapChange", function(mapnum)
	for player in players.iterate
		if player.ai
			fb.ResetAI(player.ai)
		end
	end
end)

--Handle MapLoad for bots
addHook("MapLoad", function(mapnum)
	for player in players.iterate
		if player.ai
			--Fix bug where "real" ring counts aren't reset on map change
			player.ai.syncrings = false
		end
	end

	--Set stage vars
	fb.isspecialstage = G_IsSpecialStage(mapnum)
end)

--Handle damage for bots (simple "ouch" instead of losing rings etc.)
function fb.NotifyLoseShield(bot, basebot)
	--basebot nil on initial call, but automatically set after
	if bot != basebot
		if bot.ai_followers
			for _, b in ipairs(bot.ai_followers)
				if b and b.valid
					fb.NotifyLoseShield(b, basebot or bot)
				end
			end
		end
		if bot.ai
			bot.ai.loseshield = true
		end
	end
end
addHook("MobjDamage", function(target, inflictor, source, damage, damagetype)
	if target.player and target.player.valid
		--Handle bot invulnerability
		if not (damagetype & DMG_DEATHMASK)
		and target.player.ai
		and target.player.rings > 0
		--Always allow heart shield loss so bots don't just have it all the time
		--Otherwise do loss rules according to ai_hurtmode
		and (target.player.powers[pw_shield] & SH_NOSTACK) != SH_PINK
		and (
			fb.CV_AIHurtMode.value == 0
			or (
				fb.CV_AIHurtMode.value == 1
				and not target.player.powers[pw_shield]
			)
		)
			S_StartSound(target, sfx_shldls)
			P_DoPlayerPain(target.player, source, inflictor)
			return true
		--Handle shield loss if ai_hurtmode off
		elseif fb.CV_AIHurtMode.value == 0
		and not target.player.ai
		and not target.player.powers[pw_shield]
			fb.NotifyLoseShield(target.player)
		end
	end
end, MT_PLAYER)

--Handle special stage damage for bots
addHook("ShouldDamage", function(target, inflictor, source, damage, damagetype)
	if fb.isspecialstage
	and (damagetype & DMG_DEATHMASK)
	and target.player
	and target.player.valid
	and target.player.ai
	and target.player.ai.leader
	and target.player.ai.leader.valid
	and target.player.ai.leader.mo --Not spectator etc.
	and target.player.ai.leader.mo.valid
	and target.player.ai.leader.mo.health > 0
		S_StartSound(target, sfx_shldls)
		fb.Teleport(target.player, false)
		return false
	end
end, MT_PLAYER)

--Handle death for bots
addHook("MobjDeath", function(target, inflictor, source, damagetype)
	--Handle shield loss if ai_hurtmode off
	if fb.CV_AIHurtMode.value == 0
	and target.player and target.player.valid
	and not target.player.ai
		fb.NotifyLoseShield(target.player)
	end
end, MT_PLAYER)

--Handle pickup rules for bots
function fb.CanPickupItem(leader)
	--Allow pickups if leader is dead, oops
	return not (leader.mo and leader.mo.valid and leader.mo.health > 0)
		or P_CanPickupItem(leader)
end
function fb.CanPickup(special, toucher)
	--Only pick up flung rings/coins leader could've also picked up
	--However, let anyone pick up rings when ai_hurtmode == 2
	--That is difficult to otherwise account for and is pretty brutal anyway
	if toucher.player
	and toucher.player.valid
	and toucher.player.ai
	and toucher.player.ai.leader
	and toucher.player.ai.leader.valid
	and fb.CV_AIHurtMode.value < 2
	and not fb.CanPickupItem(fb.GetTopLeader(toucher.player.ai.leader, toucher.player))
		return true
	end
end
addHook("TouchSpecial", fb.CanPickup, MT_FLINGRING)
addHook("TouchSpecial", fb.CanPickup, MT_FLINGCOIN)

--Handle (re)spawning for bots
addHook("PlayerSpawn", function(player)
	if player.ai
		--Fix resetting leader's rings to our startrings
		player.ai.lastrings = player.rings

		--Fix spectators not resetting some vars due to reduced AI
		if player.spectator
			fb.ResetAI(player.ai)
		end

		--Queue teleport to player, unless we're still in sight
		--Check leveltime to only teleport after we've initially spawned in
		if leveltime
			player.ai.playernosight = 3 * TICRATE

			--Do an immediate teleport if necessary
			if player.ai.doteleport and player.ai.stalltics > 6 * TICRATE
				player.ai.stalltics = 0
				fb.Teleport(player, false)
			end
		end
	elseif not player.jointime
	and fb.CV_AIDefaultLeader.value >= 0
	and fb.CV_AIDefaultLeader.value != #player
		--Defaults to no ai/leader, but bot will sort itself out
		fb.PreThinkFrameFor(player)
	end
end)

--Handle joining players
addHook("PlayerJoin", function(playernum)
	--Kick most recent headless bot if too many and we're trying to reserve a slot
	if netgame and fb.CV_AIReserveSlot.value
	and fb.PlayerCount() >= fb.CV_MaxPlayers.value - 1
		--First find our highest per-player bot count
		local bestbotcount = 0
		for player in players.iterate
			if player.ai_ownedbots
				bestbotcount = max($, table.maxn(player.ai_ownedbots))
			end
		end

		--Next find players with that bot count
		local bestplayers = {}
		for player in players.iterate
			if player.ai_ownedbots and table.maxn(player.ai_ownedbots) == bestbotcount
				table.insert(bestplayers, player)
			end
		end

		--Finally find the newest bot among those players
		local bestbot = nil
		for _, player in ipairs(bestplayers)
			for _, bot in ipairs(player.ai_ownedbots)
				if bot.ai
				and (bot.ai.ronin or bot.ai_owner)
				and (
					not (bestbot and bestbot.valid)
					or bot.jointime < bestbot.jointime
				)
					bestbot = bot
				end
			end
		end
		if bestbot and bestbot.valid
			if bestbot.ai_owner and bestbot.ai_owner.valid
				fb.ConsPrint(bestbot.ai_owner, "Server full - removing most recent bot to make room for new players")
			end
			bestbot.ai_forceremove = true
			fb.RemoveBot(server, #bestbot)
		end
	end
end)

--Handle sudden quitting for bots
addHook("PlayerQuit", function(player, reason)
	if player.ai
		fb.DestroyAI(player)
	end

	--Unregister ourself from player owner
	fb.UnregisterOwner(player.ai_owner, player)

	--Kick all owned bots
	while player.ai_ownedbots
	and player.ai_ownedbots[1]
	and player.ai_ownedbots[1].valid
		fb.RemoveBot(player, #player.ai_ownedbots[1])
		fb.UnregisterOwner(player, player.ai_ownedbots[1]) --Just in case
	end
end)

--SP Only: Handle (re)spawning for bots
addHook("BotRespawn", function(pmo, bmo)
	--Allow game to reset SP bot as normal if player-controlled or dead
	if fb.CV_ExAI.value == 0
	or not (server and server.valid) or server.exiting --Derpy hack as only mobjs are passed in
	or not (bmo.player and bmo.player.valid and bmo.player.ai)
		return
	--Treat BOT_MPAI as a normal player
	elseif bmo.player.bot == BOT_MPAI
		return false
	--Just destroy AI if dead, since SP bots don't get a PlayerSpawn event on respawn
	--This resolves ring-sync issues on respawn and probably other things too
	elseif bmo.player.playerstate == PST_DEAD
		fb.DestroyAI(bmo.player)
	end
	return false
end)

--SP Only: Delegate SP AI to foxBot
addHook("BotTiccmd", function(bot, cmd)
	--Fix bug where we don't respawn w/ coopstarposts
	if bot.outofcoop
	and bot.ai
	and bot.ai.leader
	and bot.ai.leader.valid
	and bot.ai.leader.starpostnum != bot.starpostnum
		if fb.SPBot(bot)
			fb.DestroyAI(bot)
		end
		bot.outofcoop = false
		bot.playerstate = PST_REBORN
		return true
	end

	--Treat BOT_MPAI as a normal player
	if bot.bot == BOT_MPAI
		--Except fix weird starpostnum bug w/ coopstarposts
		if fb.CV_CoopStarposts.value
		and bot.ai
		and bot.ai.leader
		and bot.ai.leader.valid
			bot.starpostnum = max($, bot.ai.leader.starpostnum)
		end
		return true
	end

	--Fix disconnecting 2p bots
	if bot.quittime
		return true
	end

	--Fix issue where SP bot grants early perfect bonus
	if not (netgame or splitscreen) --D'oh! Only in singleplayer
	and (not (server and server.valid) or server.exiting)
		bot.rings = 0
		if bot.ai
			bot.ai.lastrings = 0
			fb.DestroyAI(bot)
		end
		return
	end

	--Bail if no AI
	--Also fix botleader getting reset on map change etc. due to blocking normal AI
	if fb.CV_ExAI.value == 0
	or not (bot.botleader and bot.botleader.valid)
		return
	end

	--SP bots need carry state manually set
	if bot.mo and bot.mo.valid
	and bot.mo.state >= S_PLAY_FLY
	and bot.mo.state <= S_PLAY_FLY_TIRED
		bot.pflags = $ | PF_CANCARRY
	end

	--Hook no longer needed once ai set up (PreThinkFrame handles instead)
	if bot.ai
		--But first, mirror leader's powerups! Since we can't grab monitors
		--Use top leader to avoid issues when cycling followers
		local leader = fb.GetTopLeader(bot.ai.leader, bot)
		if leader and leader.valid
			local pshield = leader.powers[pw_shield] & SH_NOSTACK
			if leader.powers[pw_shield]
			and pshield != SH_PINK
			and not bot.powers[pw_shield]
			and fb.BotTimeExact(bot.ai, TICRATE)
			--Temporary var for this logic only
			--Note that it does not go in bot.ai, as that is destroyed on p2 input in SP
			and not bot.ai_noshieldregen
				if pshield == SH_ARMAGEDDON
					bot.ai_noshieldregen = pshield
				end
				P_SwitchShield(bot, leader.powers[pw_shield])
				if bot.mo and bot.mo.valid
					S_StartSound(bot.mo, sfx_s3kcas)
				end
			elseif pshield != bot.ai_noshieldregen
				bot.ai_noshieldregen = nil
			end
			bot.powers[pw_invulnerability] = leader.powers[pw_invulnerability]
			bot.powers[pw_sneakers] = leader.powers[pw_sneakers]
			bot.powers[pw_gravityboots] = leader.powers[pw_gravityboots]
		end

		--Keep our botleader up to date
		bot.botleader = bot.ai.realleader
		return true
	end

	--Defaults to no ai/leader, but bot will sort itself out
	fb.PreThinkFrameFor(bot)
	return true
end)

--HUD hook!
hud.add(function(v, stplyr, cam)
	--If not previous text in buffer... (e.g. debug)
	if fb.hudtext[1] == nil
		--And we have HUD enabled...
		if fb.CV_AIShowHud.value == 0
			return
		end

		--Is our picker up?
		local ai = stplyr.ai
		local target = nil
		if stplyr.ai_picktarget
		and stplyr.ai_picktarget.valid
			target = stplyr.ai_picktarget.ai_player
			if target and target.valid
				ai = target.ai --Inspect our target's ai, not our own
				fb.hudtext[1] = "Leading " + fb.ShortName(target)
				if stplyr.ai_picktime
					fb.hudtext[1] = "\x8A" .. $
				end
				if ai and ai.cmd_time
					fb.hudtext[1] = $ .. " \x81(player-controlled)"
				elseif target.realmo and target.realmo.valid and target.realmo.skin
					fb.hudtext[1] = $ .. " \x86(" .. target.realmo.skin .. ")"
				end
				fb.hudtext[2] = nil
			end
		--Or are we a bot?
		elseif ai
			target = ai.leader
			if target and target.valid
				fb.hudtext[1] = "Following " + fb.ShortName(target)
				if target != ai.realleader
				and ai.realleader and ai.realleader.valid
					if ai.realleader.spectator
						fb.hudtext[1] = $ + " \x87(" + fb.ShortName(ai.realleader) + " KO'd)"
					else
						fb.hudtext[1] = $ + " \x83(" + fb.ShortName(ai.realleader) + ")"
					end
				end
				fb.hudtext[2] = nil
			end
		end

		--Bail if no ai or target
		if not (ai and target and target.valid)
			return
		end

		--Generate a simple bot hud!
		local bmo = stplyr.realmo
		local pmo = target.realmo
		if bmo and bmo.valid
		and pmo and pmo.valid
			fb.hudtext[2] = ""
			if ai.doteleport
				fb.hudtext[3] = "\x84Teleporting..."
			elseif pmo.health <= 0
				fb.hudtext[3] = "Waiting for respawn..."
			else
				fb.hudtext[3] = "Dist " + FixedHypot(
					R_PointToDist2(
						bmo.x, bmo.y,
						pmo.x, pmo.y
					),
					abs(pmo.z - bmo.z)
				) / bmo.scale
				if ai.playernosight
					fb.hudtext[3] = "\x87" + $
				end
			end
			fb.hudtext[4] = nil

			if ai.cmd_time > 0
			and ai.cmd_time < 3 * TICRATE
				fb.hudtext[4] = ""
				fb.hudtext[5] = "\x81" + "AI control in " .. ai.cmd_time / TICRATE + 1 .. "..."
				fb.hudtext[6] = nil
			elseif ai != stplyr.ai --Infers ai_picktarget as target
			and fb.CanSwapCharacter(stplyr, target)
				fb.hudtext[4] = ""
				fb.hudtext[5] = "\x81Press \x82[Fire]\x81 to swap characters"
				fb.hudtext[6] = nil
			end
		end
	end

	--Positioning / size
	local x = 16
	local y = 56
	local size = "small"
	local scale = 1

	--Spectating?
	if stplyr.spectator
		y = $ + 44
	elseif stplyr.pflags & PF_FINISHED
		y = $ + 22
	end

	--Account for splitscreen
	--Avoiding V_PERPLAYER as text gets a bit too squashed
	if splitscreen
		y = $ / 2
		if #stplyr > 0
			y = $ + 108 --Magic!
		end
	end

	--Small fonts become illegible at low res
	if v.height() < 400
		size = nil
		scale = 2
	end

	--Draw! Flushing hudtext after
	for k, s in ipairs(fb.hudtext)
		if k & 1
			v.drawString(x, y, s, V_SNAPTOTOP | V_SNAPTOLEFT | v.localTransFlag(), size)
		else
			v.drawString(x + 64 * scale, y, s, V_SNAPTOTOP | V_SNAPTOLEFT | v.localTransFlag(), size)
			y = $ + 4 * scale
		end
		fb.hudtext[k] = nil
	end
end, "game")
