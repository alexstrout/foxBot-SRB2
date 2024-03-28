--[[
	--------------------------------------------------------------------------------
	GLOBAL HELPER VALUES / FUNCTIONS
	Used in various points throughout code
	--------------------------------------------------------------------------------
]]
local fb = __foxBot

--Global MT_FOXAI_POINTs used in various functions
fb.PosCheckerObj = nil

--Global vars
fb.isspecialstage = leveltime and G_IsSpecialStage() --Also set on MapLoad

--NetVars!
addHook("NetVars", function(network)
	fb.PosCheckerObj = network($)
	fb.isspecialstage = network($)
end)

--Text table used for HUD hook
fb.hudtext = {}

--Return whether player has elevated privileges
function fb.IsAdmin(player)
	return player == server
		or (player and player.valid
			and IsPlayerAdmin(player))
end

--Return whether player has authority over bot
function fb.IsAuthority(player, bot, strict)
	return bot == player
		or (fb.IsAdmin(player) and not strict)
		or (bot and bot.valid
			and (bot.ai_owner == player
				or (bot.ai and bot.ai.ronin
					and bot.ai.realleader == player)))
end

--Return shortened player name
function fb.ShortName(player)
	if string.len(player.name) > 10
		return string.sub(player.name, 1, 10) .. ".."
	end
	return player.name
end

--Return player name without 2.2.11's colored [BOT] suffix
function fb.BotlessName(player)
	local len = string.len(player.name) - 7
	if string.sub(player.name, len + 1) == "\x84[BOT]\x80"
		return string.sub(player.name, 1, len)
	end
	return player.name
end

--Return descriptive bot type
function fb.BotType(bot)
	if bot.bot == BOT_MPAI
		return "mp bot"
	elseif bot.bot != BOT_NONE
		return "2p bot"
	end
	return "bot"
end

--Return if bot is considered an "sp bot" (2p bot)
function fb.SPBot(bot)
	return bot.bot and bot.bot != BOT_MPAI
end

--Resolve player by number (string or int)
function fb.ResolvePlayerByNum(num)
	num = tonumber($)
	if num != nil and num >= 0 and num < 32
		return players[num]
	end
	return nil
end

--Resolve multiple players by string (or player by number)
function fb.ResolveMultiplePlayersByNum(player, num)
	--Support "all" and "disconnect[ed/ing]" arguments
	if type(num) == "string" --Double-check before using string lib
		local b = string.lower(string.sub(num, 1, 10))
		if b == "all" or b == "disconnect"
			local ret = {}
			for pbot in players.iterate
				if fb.IsAuthority(player, pbot)
				and (
					b == "all" or pbot.quittime
					--Avoid dropping summoned bots w/ "disconnected"
					or (pbot.ai and pbot.ai.ronin and not pbot.ai_owner)
				)
					table.insert(ret, #pbot)
				end
			end
			return ret
		end
	end

	--Plain old boring num
	return fb.ResolvePlayerByNum(num)
end

--Return number of connected players/bots
function fb.PlayerCount()
	local pcount = 0
	for _ in players.iterate
		pcount = $ + 1
	end
	return pcount
end

--Returns absolute angle (0 to 180)
--Useful for comparing angles
function fb.AbsAngle(ang)
	if ang < 0 and ang > ANGLE_180
		return InvAngle(ang)
	end
	return ang
end

--Returns last (maxn) array element
function fb.TableLast(t)
	return t[table.maxn(t)]
end

--Destroys mobj and returns nil for assignment shorthand
function fb.DestroyObj(mobj)
	if mobj and mobj.valid
		P_RemoveMobj(mobj)
	end
	return nil
end

--Moves specified poschecker to x, y, z coordinates, optionally with radius and height
--Useful for checking floorz/ceilingz or other properties at some arbitrary point in space
function fb.CheckPos(poschecker, x, y, z, radius, height)
	if poschecker and poschecker.valid
		P_SetOrigin(poschecker, x, y, z)
	else
		poschecker = P_SpawnMobj(x, y, z, MT_FOXAI_POINT)
	end

	--Optionally set radius and height, resetting to type default if not specified
	poschecker.radius = radius or poschecker.info.radius
	poschecker.height = height or poschecker.info.height

	return poschecker
end

--Fix bizarre bug where floorz / ceilingz of certain objects is sometimes inaccurate
--(e.g. rings or blue spheres on FOFs - not needed for players or other recently moved objects)
function fb.FixBadFloorOrCeilingZ(pmo)
	--Briefly set MF_NOCLIP so we don't accidentally destroy the object, oops (e.g. ERZ snails in walls)
	local oflags = pmo.flags
	pmo.flags = $ | MF_NOCLIP
	P_SetOrigin(pmo, pmo.x, pmo.y, pmo.z)
	pmo.flags = oflags
end

--Returns height-adjusted Z for accurate comparison to FloorOrCeilingZ
function fb.AdjustedZ(bmo, pmo)
	if bmo.eflags & MFE_VERTICALFLIP
		return pmo.z + pmo.height
	end
	return pmo.z
end

--Returns floorz or ceilingz for pmo based on bmo's flip status
function fb.FloorOrCeilingZ(bmo, pmo)
	if bmo.eflags & MFE_VERTICALFLIP
		return pmo.ceilingz
	end
	return pmo.floorz
end

--Returns water top or bottom for pmo based on bmo's flip status
function fb.WaterTopOrBottom(bmo, pmo)
	if bmo.eflags & MFE_VERTICALFLIP
		return pmo.waterbottom
	end
	return pmo.watertop
end

--Same as above, but for an arbitrary position in space
--Note this may be inaccurate for player-specific things like standing on goop or on other objects
--(e.g. players above solid objects will report that object's height as their floorz - whereas this will not)
function fb.FloorOrCeilingZAtPos(bmo, x, y, z, radius, height)
	--Work around lack of a P_CeilingzAtPos function
	fb.PosCheckerObj = fb.CheckPos(fb.PosCheckerObj, x, y, z, radius, height)
	fb.PosCheckerObj.eflags = $ & ~MFE_VERTICALFLIP | (bmo.eflags & MFE_VERTICALFLIP)
	--fb.PosCheckerObj.state = S_LOCKON2
	return fb.FloorOrCeilingZ(bmo, fb.PosCheckerObj)
end

--More accurately predict an object's FloorOrCeilingZ by physically shifting it forward and then back
--This terrifies me
function fb.PredictFloorOrCeilingZ(bmo, pfac)
	--Amazingly, this somehow does not trigger sector tags etc.
	--Could alternatively use an MF_SOLID PosChecker, ignoring players with a MobjCollide hook
	--However, I prefer this for now as it's using the original object's legitimate floor checks
	local ox, oy, oz = bmo.x, bmo.y, bmo.z
	local oflags = bmo.flags
	bmo.flags = $ | MF_NOCLIPTHING
	P_SetOrigin(bmo,
		bmo.x + bmo.momx * pfac,
		bmo.y + bmo.momy * pfac,
		bmo.z + bmo.momz * pfac)
	local predictfloor = fb.FloorOrCeilingZ(bmo, bmo)
	bmo.flags = oflags
	P_SetOrigin(bmo, ox, oy, oz)
	return predictfloor
end

--P_CheckSight wrapper to approximate sight checks for objects above/below FOFs
--Eliminates being able to "see" targets through FOFs at extreme angles
function fb.CheckSight(bmo, pmo)
	--Allow equal heights so we can see DSZ3 boss
	return bmo.floorz <= pmo.ceilingz
		and bmo.ceilingz >= pmo.floorz
		and P_CheckSight(bmo, pmo)
end

--P_SuperReady but without the shield and PF_JUMPED checks
function fb.SuperReady(player)
	return not player.powers[pw_super]
		and not player.powers[pw_invulnerability]
		and not player.powers[pw_tailsfly]
		and (player.charflags & SF_SUPER)
		--and (player.pflags & PF_JUMPED)
		--and not (player.powers[pw_shield] & SH_NOSTACK)
		and not (maptol & TOL_NIGHTS)
		and All7Emeralds(emeralds)
		and player.rings >= 50
end

--CONS_Printf but substituting consoleplayer for secondarydisplayplayer
function fb.ConsPrint(player, ...)
	if player == secondarydisplayplayer
		player = consoleplayer
	end
	CONS_Printf(player, ...)
end

--Send player prefs to server
COM_AddCommand("__SendPlayerPrefs", function(player, analog, directionchar, autobrake)
	player.pflags = $
		& ~PF_ANALOGMODE
		& ~PF_DIRECTIONCHAR
		& ~PF_AUTOBRAKE
	if not fb.SPBot(player) --Avoid setting these flags on BOT_2PHUMAN
		if tonumber(analog)
			player.pflags = $ | PF_ANALOGMODE
		end
		if tonumber(directionchar)
			player.pflags = $ | PF_DIRECTIONCHAR
		end
	end
	if tonumber(autobrake)
		player.pflags = $ | PF_AUTOBRAKE
	end
end, 0)
