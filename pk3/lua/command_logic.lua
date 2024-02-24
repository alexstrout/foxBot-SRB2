--[[
	--------------------------------------------------------------------------------
	COMMAND LOGIC
	Handle non-AI behavior such as leader controls etc.
	--------------------------------------------------------------------------------
]]
local fb = __foxBot

--Set a new "pick target" for AI leader
function fb.SetPickTarget(leader, bot)
	if not (bot and bot.valid)
		return
	end
	local bmo = bot.realmo
	if bmo and bmo.valid
		local pt = leader.ai_picktarget
		if not (pt and pt.valid)
			leader.ai_picktarget = P_SpawnMobjFromMobj(bmo, 0, 0,
				bmo.height + 32 * bmo.scale, MT_LOCKON)
			pt = leader.ai_picktarget
		end
		if pt and pt.valid
			pt.ai_player = bot --Quick helper
			if leader == displayplayer
			or leader == secondarydisplayplayer
				pt.state = S_LOCKONINF1
			else --Don't show this to everyone
				pt.state = S_INVISIBLE
			end
			pt.target = bmo
			pt.colorized = true
			pt.color = bmo.color
		end
	end
end

--Cycle followers back and forth
function fb.CycleFollower(leader, dir)
	if not (leader and leader.valid and leader.ai_followers)
		return
	end
	if dir > 0
		table.insert(leader.ai_followers, table.remove(leader.ai_followers, 1))
	elseif dir < 0
		table.insert(leader.ai_followers, 1, table.remove(leader.ai_followers))
	end
	if dir
		S_StartSound(nil, sfx_menu1, leader)
		fb.SetPickTarget(leader, leader.ai_followers[1])
		leader.ai_picktime = TICRATE
	end
	fb.UpdateFollowerIndices(leader)
end

--Swap characters with follower
function fb.SubCanSwapCharacter(player, skin)
	return player and player.valid
		and player.realmo and player.realmo.valid --Only in-game!
		and R_SkinUsable(player, skin)
		and not (player.pflags & (PF_FULLSTASIS | PF_THOKKED | PF_SHIELDABILITY))
end
function fb.CanSwapCharacter(leader, bot)
	return bot and bot.valid --Needed for bot.skin arg
		and fb.SubCanSwapCharacter(leader, bot.skin)
		and fb.SubCanSwapCharacter(bot, leader.skin)
		and bot.ai and not bot.ai.cmd_time
		and (fb.IsAuthority(leader, bot, true)
			or (leader.ai and not leader.ai.cmd_time))
		and FixedHypot( --Above infers valid realmo
			R_PointToDist2(
				bot.realmo.x, bot.realmo.y,
				leader.realmo.x, leader.realmo.y
			),
			bot.realmo.z - leader.realmo.z
		) < 384 * bot.realmo.scale + bot.realmo.radius + leader.realmo.radius
end
function fb.SubSwapCharacter(player, swap)
	--Play effects!
	S_StartSound(player.realmo, sfx_s3k6b)
	P_SpawnGhostMobj(player.realmo)
	P_SpawnMobjFromMobj(player.realmo, 0, 0, 0, MT_SUPERSPARK)

	--Swap skins
	R_SetPlayerSkin(player, swap.skin)

	--Swap colors
	player.realmo.color = swap.realmo.color
	player.skincolor = swap.skincolor

	--Swap shields
	if fb.SPBot(player) --Don't let 2p bots regen this shield
		player.ai_noshieldregen = player.powers[pw_shield]
	end
	P_SwitchShield(player, 0) --Avoid nuke blasting on swap lol
	P_SwitchShield(player, swap.powers[pw_shield])

	--Swap ability AI override (if applicable)
	player.ai_override_abil = swap.ai_override_abil

	--Remember original swap character
	if player != swap.ai_swapchar
		player.ai_swapchar = swap.ai_swapchar
	else
		player.ai_swapchar = nil
	end
end
function fb.SwapCharacter(leader, bot)
	if not fb.CanSwapCharacter(leader, bot)
		return
	end

	--Swap characters
	local temp = {
		skin = leader.skin,
		skincolor = leader.skincolor,
		realmo = { color = leader.realmo.color },
		powers = { [pw_shield] = leader.powers[pw_shield] },
		ai_override_abil = leader.ai_override_abil,
		ai_swapchar = leader.ai_swapchar or leader
	}
	bot.ai_swapchar = $ or bot
	fb.SubSwapCharacter(leader, bot)
	fb.SubSwapCharacter(bot, temp)
end

--Drive leader commands based on key presses etc.
function fb.LeaderPreThinkFrameFor(leader)
	--Cycle followers w/ weapon cycle keys
	local pcmd = leader.cmd
	if pcmd.buttons & BT_WEAPONNEXT
		if not leader.ai_pickbuttons
			fb.CycleFollower(leader, 1)
		end
		leader.ai_pickbuttons = true
	elseif pcmd.buttons & BT_WEAPONPREV
		if not leader.ai_pickbuttons
			fb.CycleFollower(leader, -1)
		end
		leader.ai_pickbuttons = true
	--Hold selection for ai_picktime
	elseif leader.ai_picktime
		leader.ai_pickbuttons = nil
		leader.ai_picktime = $ - 1
		if leader.ai_picktime <= 0
			leader.ai_picktime = nil
		elseif leader.ai_followers
			fb.SetPickTarget(leader, leader.ai_followers[1])
		end
	--Inspect followers w/ weapon select keys
	--(preempted by ai_picktime hold from cycling followers)
	elseif pcmd.buttons & BT_WEAPONMASK
		fb.SetPickTarget(leader, leader.ai_followers[pcmd.buttons & BT_WEAPONMASK])
	elseif pcmd.buttons & BT_FIRENORMAL
		fb.SetPickTarget(leader, leader.ai_followers[1])
	elseif leader.ai_picktarget
		leader.ai_picktarget = fb.DestroyObj($)
	end

	--Swap characters?
	if leader.ai_picktarget
		if pcmd.buttons & BT_ATTACK
			if not leader.ai_swapbutton
			and leader.ai_picktarget.valid
				fb.SwapCharacter(leader, leader.ai_picktarget.ai_player)
			end
			leader.ai_swapbutton = true
		else
			leader.ai_swapbutton = nil
		end
	end
end
