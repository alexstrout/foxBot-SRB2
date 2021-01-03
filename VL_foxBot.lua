--[[
	foxBot v1.0 by fox: https://taraxis.com/foxBot-SRB2
	Based heavily on VL_ExAI-v2.lua by CoboltBW: https://mb.srb2.org/showthread.php?t=46020
	Initially an experiment to run bots off of PreThinkFrame instead of BotTiccmd
	This allowed AI to control a real player for use in netgames etc.
	Since they're no longer "bots" to the game, it integrates a few concepts from ClassicCoop-v1.3.lua by FuriousFox: https://mb.srb2.org/showthread.php?t=41377
	Such as ring-sharing, nullifying damage, etc. to behave more like a true SP bot, as player.bot is read-only

	Future TODO?
	* Integrate botcskin on ronin bots?
	* Target springs if leader in spring-rise state and we're grounded?
	* Maybe note that under default settings, SRB2 doesn't appear to draw or make noise in the background

	--------------------------------------------------------------------------------
	Copyright (c) 2020 Alex Strout and CobaltBW

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



--[[
	--------------------------------------------------------------------------------
	GLOBAL CONVARS
	(see "bothelp" at bottom for a description of each)
	--------------------------------------------------------------------------------
]]
local CV_ExAI = CV_RegisterVar({
	name = "ai_sys",
	defaultvalue = "On",
	flags = CV_NETVAR|CV_SHOWMODIF,
	PossibleValue = CV_OnOff
})
local CV_AIDebug = CV_RegisterVar({
	name = "ai_debug",
	defaultvalue = "-1",
	flags = 0,
	PossibleValue = {MIN = -1, MAX = 31}
})
local CV_AISeekDist = CV_RegisterVar({
	name = "ai_seekdist",
	defaultvalue = "512",
	flags = CV_NETVAR|CV_SHOWMODIF,
	PossibleValue = {MIN = 32, MAX = 1536}
})
local CV_AIIgnore = CV_RegisterVar({
	name = "ai_ignore",
	defaultvalue = "Off",
	flags = CV_NETVAR|CV_SHOWMODIF,
	PossibleValue = {
		Off = 0,
		Enemies = 1,
		RingsMonitors = 2,
		All = 3
	}
})
local CV_AICatchup = CV_RegisterVar({
	name = "ai_catchup",
	defaultvalue = "Off",
	flags = CV_NETVAR|CV_SHOWMODIF,
	PossibleValue = CV_OnOff
})
local CV_AIKeepDisconnected = CV_RegisterVar({
	name = "ai_keepdisconnected",
	defaultvalue = "On",
	flags = CV_NETVAR|CV_SHOWMODIF,
	PossibleValue = CV_OnOff
})
local CV_AIDefaultLeader = CV_RegisterVar({
	name = "ai_defaultleader",
	defaultvalue = "0",
	flags = CV_NETVAR|CV_SHOWMODIF,
	PossibleValue = {MIN = -1, MAX = 32}
})
local CV_AIHurtMode = CV_RegisterVar({
	name = "ai_hurtmode",
	defaultvalue = "Off",
	flags = CV_NETVAR|CV_SHOWMODIF,
	PossibleValue = {
		Off = 0,
		ShieldLoss = 1,
		RingLoss = 2
	}
})
local CV_AIStatMode = CV_RegisterVar({
	name = "ai_statmode",
	defaultvalue = "Off",
	flags = CV_NETVAR|CV_SHOWMODIF,
	PossibleValue = {
		Off = 0,
		Rings = 1,
		Lives = 2,
		Both = 3
	}
})
local CV_AITeleMode = CV_RegisterVar({
	name = "ai_telemode",
	defaultvalue = "0",
	flags = CV_NETVAR|CV_SHOWMODIF,
	PossibleValue = {MIN = 0, MAX = UINT16_MAX}
})
local CV_AIShowHud = CV_RegisterVar({
	name = "ai_showhud",
	defaultvalue = "On",
	flags = 0,
	PossibleValue = CV_OnOff
})



--[[
	--------------------------------------------------------------------------------
	GLOBAL TYPE DEFINITIONS
	Defines any mobj types etc. needed by foxBot
	--------------------------------------------------------------------------------
]]
freeslot(
	"MT_FOXAI_POINT"
)
mobjinfo[MT_FOXAI_POINT] = {
	spawnstate = S_INVISIBLE,
	radius = FRACUNIT,
	height = FRACUNIT,
	--Sector clipping allowed to properly account for radius in floorz / ceilingz checks
	flags = MF_NOGRAVITY|MF_NOTHINK|MF_NOCLIPTHING
}



--[[
	--------------------------------------------------------------------------------
	GLOBAL HELPER VALUES / FUNCTIONS
	Used in various points throughout code
	--------------------------------------------------------------------------------
]]
--Global MT_FOXAI_POINTs used in various functions (typically by CheckPos)
--Not thread-safe (no need); could be placed in AI tables (as before), at the cost of more things to sync
local PosCheckerObj = nil

--Text table used for HUD hook
local hudtext = {}

--Resolve player by number (string or int)
local function ResolvePlayerByNum(num)
	if type(num) != "number"
		num = tonumber(num)
	end
	if num != nil and num >= 0 and num < 32
		return players[num]
	end
	return nil
end

--Returns absolute angle (0 to 180)
--Useful for comparing angles
local function AbsAngle(ang)
	if ang < 0 and ang > ANGLE_180
		return InvAngle(ang)
	end
	return ang
end

--Destroys mobj and returns nil for assignment shorthand
local function DestroyObj(mobj)
	if mobj and mobj.valid
		P_RemoveMobj(mobj)
	end
	return nil
end

--Moves specified poschecker to x, y, z coordinates, optionally with radius and height
--Useful for checking floorz/ceilingz or other properties at some arbitrary point in space
local function CheckPos(poschecker, x, y, z, radius, height)
	if poschecker and poschecker.valid
		P_TeleportMove(poschecker, x, y, z)
	else
		poschecker = P_SpawnMobj(x, y, z, MT_FOXAI_POINT)
	end

	--Optionally set radius and height, resetting to type default if not specified
	if not radius then radius = poschecker.info.radius end
	poschecker.radius = radius
	if not height then height = poschecker.info.height end
	poschecker.height = height

	return poschecker
end

--Fix bizarre bug where floorz / ceilingz of certain objects is sometimes inaccurate
--(e.g. rings or blue spheres on FOFs - not needed for players or other recently moved objects)
local function FixBadFloorOrCeilingZ(pmo)
	--Briefly set MF_NOCLIP so we don't accidentally destroy the object, oops (e.g. ERZ snails in walls)
	local oflags = pmo.flags
	pmo.flags = $ | MF_NOCLIP
	P_TeleportMove(pmo, pmo.x, pmo.y, pmo.z)
	pmo.flags = oflags
end

--Returns height-adjusted Z for accurate comparison to FloorOrCeilingZ
local function AdjustedZ(bmo, pmo)
	if bmo.eflags & MFE_VERTICALFLIP
		return pmo.z + pmo.height
	end
	return pmo.z
end

--Returns floorz or ceilingz for pmo based on bmo's flip status
local function FloorOrCeilingZ(bmo, pmo)
	if bmo.eflags & MFE_VERTICALFLIP
		return pmo.ceilingz
	end
	return pmo.floorz
end

--Returns water top or bottom for pmo based on bmo's flip status
local function WaterTopOrBottom(bmo, pmo)
	if bmo.eflags & MFE_VERTICALFLIP
		return pmo.waterbottom
	end
	return pmo.watertop
end

--Same as above, but for an arbitrary position in space
--Note this may be inaccurate for player-specific things like standing on goop or on other objects
--(e.g. players above solid objects will report that object's height as their floorz - whereas this will not)
local function FloorOrCeilingZAtPos(bmo, x, y, z, radius, height)
	--Work around lack of a P_CeilingzAtPos function
	PosCheckerObj = CheckPos(PosCheckerObj, x, y, z, radius, height)
	--PosCheckerObj.state = S_LOCKON2
	return FloorOrCeilingZ(bmo, PosCheckerObj)
end

--More accurately predict an object's FloorOrCeilingZ by physically shifting it forward and then back
--This terrifies me
local function PredictFloorOrCeilingZ(bmo, pfac)
	--Amazingly, this somehow does not trigger sector tags etc.
	--Could alternatively use an MF_SOLID PosChecker, ignoring players with a MobjCollide hook
	--However, I prefer this for now as it's using the original object's legitimate floor checks
	local ox, oy, oz = bmo.x, bmo.y, bmo.z
	local oflags = bmo.flags
	bmo.flags = $ | MF_NOCLIPTHING
	P_TeleportMove(bmo,
		bmo.x + bmo.momx * pfac,
		bmo.y + bmo.momy * pfac,
		bmo.z + bmo.momz * pfac)
	local predictfloor = FloorOrCeilingZ(bmo, bmo)
	bmo.flags = oflags
	P_TeleportMove(bmo, ox, oy, oz)
	return predictfloor
end

--P_CheckSight wrapper to approximate sight checks for objects above/below FOFs
--Eliminates being able to "see" targets through FOFs at extreme angles
local function CheckSight(bmo, pmo)
	return bmo.floorz < pmo.ceilingz
		and bmo.ceilingz > pmo.floorz
		and P_CheckSight(bmo, pmo)
end

--P_SuperReady but without the shield and PF_JUMPED checks
local function SuperReady(player)
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

--Silently toggle a convar w/o printing to console
local function ToggleSilent(player, convar)
	local cval = CV_FindVar(convar).value --No error checking - use with caution!
	COM_BufInsertText(player, convar .. " " .. 1 - cval .. "; " .. convar .. " " .. cval)
end



--[[
	--------------------------------------------------------------------------------
	AI SETUP FUNCTIONS / CONSOLE COMMANDS
	Any AI "setup" logic, including console commands
	--------------------------------------------------------------------------------
]]
--Reset (or define) all AI vars to their initial values
local function ResetAI(ai)
	ai.think_last = 0 --Last think time
	ai.jump_last = 0 --Jump history
	ai.spin_last = 0 --Spin history
	ai.move_last = 0 --Directional input history
	ai.anxiety = 0 --Catch-up counter
	ai.panic = 0 --Catch-up mode
	ai.panicjumps = 0 --If too many, just teleport
	ai.flymode = 0 --0 = No interaction. 1 = Grab Sonic. 2 = Sonic is latched.
	ai.spinmode = 0 --If 1, Tails is spinning or preparing to charge spindash
	ai.thinkfly = 0 --If 1, Tails will attempt to fly when Sonic jumps
	ai.idlecount = 0 --Checks the amount of time without any player inputs
	ai.bored = 0 --AI will act independently if "bored".
	ai.drowning = 0 --AI drowning panic. 2 = Tails flies for air.
	ai.target = nil --Enemy to target
	ai.targetcount = 0 --Number of targets in range (used for armageddon shield)
	ai.targetnosight = 0 --How long the target has been out of view
	ai.playernosight = 0 --How long the player has been out of view
	ai.stalltics = 0 --Time that AI has struggled to move
	ai.attackwait = 0 --Tics to wait before attacking again
	ai.attackoverheat = 0 --Used by Fang to determine whether to wait
	ai.cmd_time = 0 --If > 0, suppress bot ai in favor of player controls
	ai.pushtics = 0 --Time leader has pushed against something (used to maybe attack it)
	ai.longjump = false --AI is making a decently sized leap for an enemy
	ai.doteleport = false --AI is attempting to teleport
	ai.predictgap = 0 --AI is jumping a gap
end

--Register follower with leader for lookup later
local function RegisterFollower(leader, bot)
	if not leader.ai_followers
		leader.ai_followers = {}
	end
	leader.ai_followers[#bot + 1] = bot
end

--Unregister follower with leader
local function UnregisterFollower(leader, bot)
	if not (leader and leader.valid and leader.ai_followers)
		return
	end
	leader.ai_followers[#bot + 1] = nil
	if table.maxn(leader.ai_followers) < 1
		leader.ai_followers = nil
	end
end

--Create AI table for a given player, if needed
local function SetupAI(player)
	if player.ai
		return
	end

	--Create table, defining any vars that shouldn't be reset via ResetAI
	player.ai = {
		leader = nil, --Bot's leader
		realleader = nil, --Bot's "real" leader (if temporarily following someone else)
		lastrings = player.rings, --Last ring count of bot (used to sync w/ leader)
		lastlives = player.lives, --Last life count of bot (used to sync w/ leader)
		overlay = nil, --Speech bubble overlay - only (re)create this if needed in think logic
		waypoint = nil, --Transient waypoint used for navigating around corners
		ronin = false, --Headless bot from disconnected client?
		timeseed = (P_RandomByte() + #player) * TICRATE --Used for time-based pseudo-random behaviors (e.g. via BotTime)
	}
	ResetAI(player.ai) --Define the rest w/ their respective values
end

--"Repossess" a bot for player control
local function Repossess(player)
	--Reset our original analog etc. prefs
	--SendWeaponPref isn't exposed to Lua, so just cycle convars to trigger it
	ToggleSilent(player, "flipcam")
	if not netgame and #player > 0
		ToggleSilent(server, "flipcam2")
	end

	--Destroy our thinkfly overlay if it's around
	player.ai.overlay = DestroyObj(player.ai.overlay)

	--Destroy our waypoint if it's around
	player.ai.waypoint = DestroyObj(player.ai.waypoint)

	--Reset anything else
	ResetAI(player.ai)
end

--Destroy AI table (and any child tables / objects) for a given player, if needed
local function DestroyAI(player)
	if not player.ai
		return
	end

	--Reset pflags etc. for player
	Repossess(player)

	--Unregister ourself from our (real) leader if still valid
	UnregisterFollower(player.ai.realleader, player)

	--Kick headless bots w/ no client
	--Otherwise they sit and do nothing
	if player.ai.ronin
		player.quittime = 1
	end

	--My work here is done
	player.ai = nil
	collectgarbage()
end

--Get our "top" leader in a leader chain (if applicable)
--e.g. for A <- B <- D <- C, D's "top" leader is A
--Optionally return searchleader instead of "top" leader (e.g. for ListBots)
local function GetTopLeader(bot, basebot, searchleader)
	if bot != basebot and bot.ai
	and bot.ai.realleader and bot.ai.realleader.valid
	and (not searchleader or bot != searchleader)
		return GetTopLeader(bot.ai.realleader, basebot, searchleader)
	end
	return bot
end

--Get our "bottom" follower in a leader chain (if applicable)
--e.g. for A <- B <- D <- C, A's "bottom" follower is C
local function GetBottomFollower(bot, basebot)
	if bot != basebot and bot.ai_followers
		for k, b in pairs(bot.ai_followers)
			--Pick a random node if the tree splits
			if P_RandomByte() < 128
			or table.maxn(bot.ai_followers) == k
				return GetBottomFollower(b, basebot)
			end
		end
	end
	return bot
end

--List all bots, optionally excluding bots led by leader
local function ListBots(player, leader)
	if leader != nil
		leader = ResolvePlayerByNum(leader)
		if leader and leader.valid
			CONS_Printf(player, "\x84 Excluding players/bots led by " .. leader.name)
		end
	end
	local msg, topleader
	local count = 0
	for bot in players.iterate
		msg = " " .. #bot .. " - " .. bot.name
		if bot.ai
		and bot.ai.leader and bot.ai.leader.valid
		and bot.ai.realleader and bot.ai.realleader.valid
			msg = $ .. "\x83 following " .. bot.ai.leader.name
			if bot.ai.leader != bot.ai.realleader
				msg = $ .. " \x87(" .. bot.ai.realleader.name .. " KO'd)"
			end
			topleader = GetTopLeader(bot.ai.realleader, bot, leader) --infers topleader.valid if not nil
			if topleader and topleader != bot.ai.realleader
				msg = $ .. "\x84 led by " .. topleader.name
			end
		end
		if not leader or (topleader != leader and bot != leader)
			CONS_Printf(player, msg)
			count = $ + 1
		end
	end
	CONS_Printf(player, "Returned " .. count .. " nodes")
end
COM_AddCommand("LISTBOTS", ListBots, 0)

--Set player as a bot following a particular leader
--Internal/Admin-only: Optionally specify some other player/bot to follow leader
local function SetBot(player, leader, bot)
	local pbot = player
	if bot != nil --Must check nil as 0 is valid
		pbot = ResolvePlayerByNum(bot)
	end
	if not (pbot and pbot.valid)
		CONS_Printf(player, "Invalid bot! Please specify a bot by number:")
		ListBots(player)
		return
	end

	--Make sure we won't end up following ourself
	local pleader = ResolvePlayerByNum(leader)
	if pleader and pleader.valid
	and GetTopLeader(pleader, pbot) == pbot
		CONS_Printf(player, pbot.name + " would end up following itself! Please try a different leader:")
		ListBots(player, #pbot)
		return
	end

	--Set up our AI (if needed) and figure out leader
	SetupAI(pbot)
	if pleader and pleader.valid
		CONS_Printf(player, "Set bot " + pbot.name + " following " + pleader.name + " with timeseed " + pbot.ai.timeseed)
		if player != pbot
			CONS_Printf(pbot, player.name + " set bot " + pbot.name + " following " + pleader.name + " with timeseed " + pbot.ai.timeseed)
		end
	elseif pbot.ai.realleader
		CONS_Printf(player, "Stopping bot " + pbot.name)
		if player != pbot
			CONS_Printf(pbot, player.name + " stopping bot " + pbot.name)
		end
	else
		CONS_Printf(player, "Invalid leader! Please specify a leader by number:")
		ListBots(player, #pbot)
	end

	--Valid leader?
	if pleader and pleader.valid
		--Unregister ourself from our old (real) leader (if applicable)
		UnregisterFollower(pbot.ai.realleader, pbot)

		--Set the new leader
		pbot.ai.leader = pleader
		pbot.ai.realleader = pleader

		--Register ourself as a follower
		RegisterFollower(pleader, pbot)
	else
		--Destroy AI if no leader set
		DestroyAI(pbot)
	end
end
COM_AddCommand("SETBOTA", SetBot, COM_ADMIN)
COM_AddCommand("SETBOT", function(player, leader)
	SetBot(player, leader)
end, 0)

--Admin-only: Debug command for testing out shield AI
--Left in for convenience, use with caution - certain shield values may crash game
COM_AddCommand("DEBUG_BOTSHIELD", function(player, bot, shield, inv, spd, super, rings, ems)
	bot = ResolvePlayerByNum(bot)
	shield = tonumber(shield)
	if not (bot and bot.valid) or bot.spectator
		return
	elseif shield == nil
		CONS_Printf(player, bot.name + " has shield " + bot.powers[pw_shield])
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
	print(msg)
end, COM_ADMIN)



--[[
	--------------------------------------------------------------------------------
	AI LOGIC
	Actual AI behavior etc.
	--------------------------------------------------------------------------------
]]
--Returns true for a specified minimum time within a maximum time period
--Used for pseudo-random behaviors like strafing or attack mixups
--e.g. BotTime(bai, 2, 8) will return true for 2s out of every 8s
local function BotTime(bai, mintime, maxtime)
	return (leveltime + bai.timeseed) % (maxtime * TICRATE) < mintime * TICRATE
end

--Teleport a bot to leader, optionally fading out
local function Teleport(bot, fadeout)
	if not (bot.valid and bot.ai)
	or bot.exiting or (bot.pflags & PF_FULLSTASIS) --Whoops
		--Consider teleport "successful" on fatal errors for cleanup
		return true
	end

	--Make sure everything's valid (as this is also called on respawn)
	--Check leveltime to only teleport after we've initially spawned in
	local leader = bot.ai.leader
	if not (leveltime and leader and leader.valid)
	or leader.spectator --Don't teleport to spectators
		return true
	end
	local bmo = bot.realmo
	local pmo = leader.realmo
	if not (bmo and bmo.valid and pmo and pmo.valid)
	or pmo.health <= 0 --Don't teleport to dead leader!
		return true
	end

	--Leader in a zoom tube or other scripted vehicle?
	if leader.powers[pw_carry] == CR_NIGHTSMODE
	or leader.powers[pw_carry] == CR_ZOOMTUBE
	or leader.powers[pw_carry] == CR_MINECART
	or bot.powers[pw_carry] == CR_MINECART
		return true
	end

	--Teleport override?
	if CV_AITeleMode.value
		return not bot.ai.panic --Probably successful if we're not in a panic
	end

	--Fade out (if needed), teleporting after
	if not fadeout
		bot.powers[pw_flashing] = TICRATE / 2 --Skip the fadeout time
	elseif not bot.powers[pw_flashing]
	or bot.powers[pw_flashing] > TICRATE
		bot.powers[pw_flashing] = TICRATE
	end
	if bot.powers[pw_flashing] > TICRATE / 2
		return false
	end

	--Adapted from 2.2 b_bot.c
	local z = pmo.z
	local zoff = pmo.height + 128 * pmo.scale
	if pmo.eflags & MFE_VERTICALFLIP
		z = max(z - zoff, pmo.floorz + pmo.height)
	else
		z = min(z + zoff, pmo.ceilingz - pmo.height)
	end
	bmo.flags2 = $
		& ~MF2_OBJECTFLIP | (pmo.flags2 & MF2_OBJECTFLIP)
		& ~MF2_TWOD | (pmo.flags2 & MF2_TWOD)
	bmo.eflags = $
		& ~MFE_VERTICALFLIP | (pmo.eflags & MFE_VERTICALFLIP)
		& ~MFE_UNDERWATER | (pmo.eflags & MFE_UNDERWATER)
	--bot.powers[pw_underwater] = leader.powers[pw_underwater] --Don't sync water/space time
	--bot.powers[pw_spacetime] = leader.powers[pw_spacetime]
	bot.powers[pw_gravityboots] = leader.powers[pw_gravityboots]
	bot.powers[pw_nocontrol] = leader.powers[pw_nocontrol]

	P_ResetPlayer(bot)
	bmo.state = S_PLAY_JUMP --Looks/feels nicer
	bot.pflags = $ | P_GetJumpFlags(bot)

	--Average our momentum w/ leader's
	bmo.momx = ($ - pmo.momx) / 2 + pmo.momx
	bmo.momy = ($ - pmo.momy) / 2 + pmo.momy
	bmo.momz = ($ - pmo.momz) / 2 + pmo.momz

	--Zero momy in 2D mode (oops)
	if bmo.flags2 & MF2_TWOD
		bmo.momy = 0
	end

	P_TeleportMove(bmo, pmo.x, pmo.y, z)
	P_SetScale(bmo, pmo.scale)
	bmo.destscale = pmo.destscale

	--Fade in (if needed)
	if bot.powers[pw_flashing] < TICRATE / 2
		bot.powers[pw_flashing] = TICRATE / 2
	end
	return true
end

--Calculate a "desired move" vector to a target, taking into account momentum and angle
local function DesiredMove(bmo, pmo, dist, mindist, leaddist, minmag, bmom, grounded, spinning, _2d)
	--Figure out time to target
	local timetotarget = 0
	if bmom and not bmo.player.climbing
		--Calculate prediction factor based on control state (air, spin)
		local pfac = 1 --General prediction mult
		if spinning
			pfac = $ * 16 --Taken from 2.2 p_user.c (pushfoward >> 4)
		elseif not grounded
			if spinning
				pfac = $ * 8 --Taken from 2.2 p_user.c (pushfoward >> 3)
			else
				pfac = $ * 4 --Taken from 2.2 p_user.c (pushfoward >> 2)
			end
		end

		--Extrapolate dist and bmom out to include Z as well
		dist = FixedHypot($, abs(pmo.z - bmo.z))
		bmom = FixedHypot($, abs(bmo.momz))

		--Calculate time, capped to sane values (influenced by pfac)
		--Note this is independent of TICRATE
		timetotarget = FixedDiv(
			min(dist, 256 * FRACUNIT) * pfac,
			max(bmom, 32 * FRACUNIT)
		) / bmo.scale
		--print(timetotarget)
	end

	--Figure out movement and prediction angles
	local mang = R_PointToAngle2(
		0,
		0,
		bmo.momx,
		bmo.momy
	)
	local px = pmo.x + (pmo.momx - bmo.momx) * timetotarget
	local py = pmo.y + (pmo.momy - bmo.momy) * timetotarget
	if leaddist
		local lang = R_PointToAngle2(
			0,
			0,
			pmo.momx,
			pmo.momy
		)
		px = $ + FixedMul(cos(lang), leaddist)
		py = $ + FixedMul(sin(lang), leaddist)
	end
	local pang = R_PointToAngle2(
		bmo.x,
		bmo.y,
		px,
		py
	)

	--Uncomment this for a handy prediction indicator
	--PosCheckerObj = CheckPos(PosCheckerObj, px, py, pmo.z)
	--PosCheckerObj.state = S_LOCKON1

	--Stop skidding everywhere!
	if grounded
	and AbsAngle(mang - bmo.angle) < ANGLE_157h
	and AbsAngle(mang - pang) > ANGLE_157h
	and bmo.player.speed >= FixedMul(bmo.player.runspeed / 2, bmo.scale)
		return 0, 0
	end

	--2D Mode!
	if _2d
		local pdist = abs(px - bmo.x) - mindist
		if pdist < 0
			return 0, 0
		end
		local mag = min(max(pdist, minmag), 50 * FRACUNIT)
		if px < bmo.x
			mag = -$
		end
		return 0, --forwardmove
			mag / FRACUNIT --sidemove
	end

	--Resolve movement vector
	pang = $ - bmo.angle
	local pdist = R_PointToDist2(
		bmo.x,
		bmo.y,
		px,
		py
	) - mindist
	if pdist < 0
		return 0, 0
	end
	local mag = min(max(pdist, minmag), 50 * FRACUNIT)
	return FixedMul(cos(pang), mag) / FRACUNIT, --forwardmove
		FixedMul(sin(pang), -mag) / FRACUNIT --sidemove
end

--Determine if a given target is valid, based on a variety of factors
local function ValidTarget(bot, leader, bpx, bpy, target, maxtargetdist, maxtargetz, flip, ignoretargets, isspecialstage)
	if not (target and target.valid and target.health > 0)
		return 0
	end

	--Target type, in preferred order
	--	-1 = passive - vehicles, rings etc. in special stages
	--	1 = active - enemy etc. (more aggressive engagement rules)
	--	2 = passive - rings etc.
	local ttype = 0

	--We want an enemy
	if (ignoretargets & 1 == 0)
	and (target.flags & (MF_BOSS | MF_ENEMY))
	and target.type != MT_ROSY --Oops
	and not (target.flags2 & MF2_FRET) --Flashing
	and not (target.flags2 & MF2_BOSSFLEE)
	and not (target.flags2 & MF2_BOSSDEAD)
		ttype = 1
	--Or, if melee, a shieldless friendly to buff
	elseif bot.charability2 == CA2_MELEE
	and target.player and target.player.valid
	and target == target.player.realmo --No spectators!
	and not (
		(target.player.powers[pw_shield] & SH_NOSTACK)
		or target.player.revitem == MT_LHRT
		or target.player.spinitem == MT_LHRT
		or target.player.thokitem == MT_LHRT
		or SuperReady(target.player)
	)
	and not bot.ai.attackwait
	and P_IsObjectOnGround(target)
		ttype = 1
	--Air bubbles!
	elseif target.type == MT_EXTRALARGEBUBBLE
	and (
		bot.ai.drowning
		or (
			bot.powers[pw_underwater] > 0
			and (
				leader.powers[pw_underwater] <= 0
				or bot.powers[pw_underwater] < leader.powers[pw_underwater]
			)
		)
	)
		ttype = 2
	--Rings!
	elseif (ignoretargets & 2 == 0)
	and (
		(target.type >= MT_RING and target.type <= MT_FLINGBLUESPHERE)
		or target.type == MT_COIN or target.type == MT_FLINGCOIN
		or (
			not bot.bot --SP bots can't grab flowers
			and (leader.powers[pw_shield] & SH_FIREFLOWER) > (bot.powers[pw_shield] & SH_FIREFLOWER)
			and target.type == MT_FIREFLOWER
		)
	)
		if isspecialstage
			ttype = -1
		else
			ttype = 2
			maxtargetdist = $ / 2 --Rings half-distance
		end
	--Monitors!
	elseif (ignoretargets & 2 == 0)
	and not bot.bot --SP bots can't pop monitors
	and (
		target.type == MT_RING_BOX or target.type == MT_1UP_BOX
		or target.type == MT_SCORE1K_BOX or target.type == MT_SCORE10K_BOX
		or (
			leader.powers[pw_sneakers] > bot.powers[pw_sneakers]
			and (
				target.type == MT_SNEAKERS_BOX
				or target.type == MT_SNEAKERS_GOLDBOX
			)
		)
		or (
			leader.powers[pw_invulnerability] > bot.powers[pw_invulnerability]
			and (
				target.type == MT_INVULN_BOX
				or target.type == MT_INVULN_GOLDBOX
			)
		)
		or (
			leader.powers[pw_shield] and not bot.powers[pw_shield]
			and (
				(target.type >= MT_PITY_BOX and target.type <= MT_ELEMENTAL_BOX)
				or (target.type >= MT_FLAMEAURA_BOX and target.type <= MT_ELEMENTAL_GOLDBOX)
				or (target.type >= MT_FLAMEAURA_GOLDBOX and target.type <= MT_THUNDERCOIN_GOLDBOX)
			)
		)
		or (
			(leader.powers[pw_shield] & SH_FORCE) and (bot.powers[pw_shield] & SH_FORCE)
			and (leader.powers[pw_shield] & SH_FORCEHP) > (bot.powers[pw_shield] & SH_FORCEHP)
			and (
				target.type == MT_FORCE_BOX
				or target.type == MT_FORCE_GOLDBOX
			)
		)
	)
		ttype = 1 --Can pull sick jumps for these
	--Vehicles
	elseif (
		target.type == MT_MINECARTSPAWNER
		or (
			target.type == MT_ROLLOUTROCK
			and leader.powers[pw_carry] == CR_ROLLOUT
			and not target.tracer --No driver
		)
	)
	and not bot.powers[pw_carry]
		ttype = -1
		maxtargetdist = $ * 2 --Vehicles double-distance! (within searchBlockmap coverage)
	else
		return 0
	end

	--Fix occasionally bad floorz / ceilingz values for things
	if not target.ai_validfocz
		FixBadFloorOrCeilingZ(target)
		target.ai_validfocz = true
	end

	--Consider our height against airborne targets
	local bmo = bot.realmo
	local maxtargetz_height = maxtargetz
	if not P_IsObjectOnGround(target)
		maxtargetz_height = $ + bmo.height
	end

	--Decide whether to engage target or not
	if ttype == 1 --Active target, take more risks
		if bot.charability2 == CA2_GUNSLINGER
		and not (bot.pflags & (PF_JUMPED | PF_BOUNCING))
			--Gunslingers don't care about targetfloor (unless jump-attacking)
			if abs(target.z - bmo.z) > 200 * FRACUNIT
				return 0
			end
		elseif bot.charability == CA_FLY
		and (bot.pflags & PF_THOKKED)
		and ((bmo.eflags & MFE_UNDERWATER) or (target.z - bmo.z + bmo.height) * flip < 0)
			return 0 --Flying characters should ignore enemies below them
		elseif bot.powers[pw_carry]
		and abs(target.z - bmo.z) > maxtargetz
			return 0 --Don't divebomb every target when being carried
		elseif (target.z - bmo.z) * flip > maxtargetz_height
		and bot.charability != CA_FLY
			return 0
		elseif abs(target.z - bmo.z) > maxtargetdist
			return 0
		elseif bot.powers[pw_carry] == CR_MINECART
			return 0 --Don't attack from minecarts
		elseif bmo.tracer
		and bot.powers[pw_carry] == CR_ROLLOUT
			--Limit range when rolling around
			maxtargetdist = $ / 16 + bmo.tracer.radius
			bpx = bmo.x
			bpy = bmo.y
		elseif bot.charability == CA_FLY
		and (target.z - bmo.z) * flip > maxtargetz_height
		and (
			not (bot.pflags & PF_THOKKED)
			or bmo.momz * flip < 0
		)
			--Limit range when fly-attacking, unless already flying and rising
			maxtargetdist = $ / 4
			bpx = bmo.x
			bpy = bmo.y
		end
	else --Passive target, play it safe
		if bot.powers[pw_carry]
			return 0
		elseif abs(target.z - bmo.z) > maxtargetz_height
		and not (bot.ai.drowning and target.type == MT_EXTRALARGEBUBBLE)
			return 0
		end
	end

	local dist = R_PointToDist2(
		--Add momentum to "prefer" targets in current direction
		bpx + bmo.momx * 3,
		bpy + bmo.momy * 3,
		target.x,
		target.y
	)
	if dist > maxtargetdist + bmo.radius + target.radius
		return 0
	end

	return ttype, dist
end

--Drive bot based on whatever unholy mess is in this function
--This is the "WhatToDoNext" entry point for all AI actions
local function PreThinkFrameFor(bot)
	if not bot.valid
		return
	end

	--Find a new leader if ours quit
	local bai = bot.ai
	if not (bai and bai.leader and bai.leader.valid)
		--Reset to realleader if we have one
		if bai and bai.leader != bai.realleader
		and bai.realleader and bai.realleader.valid
			bai.leader = bai.realleader
			return
		end
		--Otherwise find a new leader
		--Pick a random leader if default is invalid
		local bestleader = CV_AIDefaultLeader.value
		if bestleader < 0 or bestleader > 31
		or not (players[bestleader] and players[bestleader].valid)
		or players[bestleader] == bot
			bestleader = -1
			for player in players.iterate
				if GetTopLeader(player, bot) != bot --Also infers player != bot as base case
				--Prefer higher-numbered players to spread out bots more
				and (bestleader < 0 or P_RandomByte() < 128)
					bestleader = #player
				end
			end
		end
		--Follow the bottom feeder of the leader chain
		if bestleader > -1
			bestleader = #GetBottomFollower(players[bestleader], bot)
		end
		SetBot(bot, bestleader)
		return
	end

	--Already think this frame?
	if bai.think_last >= leveltime
		return
	end
	bai.think_last = leveltime

	--Make sure AI leader thinks first
	local leader = bai.leader
	if leader.ai
	and leader.ai.think_last < leveltime --Shortcut
		PreThinkFrameFor(leader)
	end

	--Reset leader to realleader if it's no longer valid or spectating
	--(we'll naturally find a better leader above if it's no longer valid)
	if leader != bai.realleader
	and (
		not (bai.realleader and bai.realleader.valid)
		or not bai.realleader.spectator
	)
		bai.leader = bai.realleader
		return
	end

	--Is leader spectating? Temporarily follow leader's leader
	if leader.spectator
	and leader.ai
	and leader.ai.leader
	and leader.ai.leader.valid
	and GetTopLeader(leader.ai.leader, leader) != leader
		bai.leader = leader.ai.leader
		return
	end

	--Handle rings here
	local isspecialstage = G_IsSpecialStage()
	if not isspecialstage
		if CV_AIStatMode.value & 1 == 0
			--Keep rings if leader spectating (still reset on respawn)
			if leader.spectator
			and leader.rings != bai.lastrings
				leader.rings = bai.lastrings
			end
			if bot.rings != bai.lastrings
				P_GivePlayerRings(leader, bot.rings - bai.lastrings)
			end
			bot.rings = leader.rings
			bai.lastrings = leader.rings

			--Oops! Fix awarding extra extra lives
			bot.xtralife = leader.xtralife
		end
		if CV_AIStatMode.value & 2 == 0
			if bot.lives > bai.lastlives
			and bot.lives > leader.lives
				P_GivePlayerLives(leader, bot.lives - bai.lastlives)
				if leveltime
					P_PlayLivesJingle(leader)
				end
			end
			bot.lives = leader.lives
			bai.lastlives = leader.lives
		end
	end

	--****
	--VARS (Player or AI)
	local bmo = bot.realmo
	local pmo = leader.realmo
	local cmd = bot.cmd
	if not (bmo and bmo.valid and pmo and pmo.valid)
		return
	end

	--Check line of sight to player
	if CheckSight(bmo, pmo)
		bai.playernosight = 0
	else
		bai.playernosight = $ + 1
	end

	--Check leader's teleport status
	if leader.ai
		bai.playernosight = max($, leader.ai.playernosight - TICRATE / 2)
		bai.panicjumps = max($, leader.ai.panicjumps - 1)
	end

	--And teleport if necessary
	bai.doteleport = bai.playernosight > 3 * TICRATE
		or bai.panicjumps > 3
	if bai.doteleport and Teleport(bot, true)
		--Post-teleport cleanup
		bai.doteleport = false
		bai.panicjumps = 0
	end

	--Check for player input!
	--If we have any, override ai for a few seconds
	--Check leveltime as cmd always has input at level start
	if leveltime and (
		cmd.forwardmove
		or cmd.sidemove
		or cmd.buttons
	)
		if not bai.cmd_time
			Repossess(bot)

			--Terminate AI to avoid interfering with normal SP bot stuff
			--Otherwise AI may take control again too early and confuse things
			--(We won't get another AI until a valid BotTiccmd is generated)
			if bot.bot
				DestroyAI(bot)
			end
		end
		bai.cmd_time = 8 * TICRATE
	end
	if bai.cmd_time > 0
		bai.cmd_time = $ - 1

		--Teleport override?
		if bai.doteleport and CV_AITeleMode.value > 0
			cmd.buttons = $ | CV_AITeleMode.value
		end
		return
	end

	--Bail here if AI is off (allows logic above to flow normally)
	if CV_ExAI.value == 0
		return
	end

	--****
	--VARS (AI-specific)
	local pcmd = leader.cmd

	--Elements
	local flip = 1
	if bmo.eflags & MFE_VERTICALFLIP
		flip = -1
	end
	local _2d = twodlevel or (bmo.flags2 & MF2_TWOD)
	local scale = bmo.scale
	local touchdist = bmo.radius + pmo.radius
	if bmo.tracer
		touchdist = $ + bmo.tracer.radius
	end
	if pmo.tracer
		touchdist = $ + pmo.tracer.radius
	end

	--Measurements
	local ignoretargets = CV_AIIgnore.value
	local pmom = FixedHypot(pmo.momx, pmo.momy)
	local bmom = FixedHypot(bmo.momx, bmo.momy)
	local pmomang = R_PointToAngle2(0, 0, pmo.momx, pmo.momy)
	local bmomang = R_PointToAngle2(0, 0, bmo.momx, bmo.momy)
	local pspd = leader.speed
	local bspd = bot.speed
	local dist = R_PointToDist2(bmo.x, bmo.y, pmo.x, pmo.y)
	local zdist = FixedMul(pmo.z - bmo.z, scale * flip)
	local predictfloor = PredictFloorOrCeilingZ(bmo, 1) * flip
	local ang = bmo.angle --Used for climbing etc.
	local followmax = touchdist + 1024 * scale --Max follow distance before AI begins to enter "panic" state
	local followthres = touchdist + 92 * scale --Distance that AI will try to reach
	local followmin = touchdist + 32 * scale
	local bmofloor = FloorOrCeilingZ(bmo, bmo) * flip
	local pmofloor = FloorOrCeilingZ(bmo, pmo) * flip
	local jumpheight = FixedMul(bot.jumpfactor, 96 * scale)
	local ability = bot.charability
	local ability2 = bot.charability2
	local falling = bmo.momz * flip < 0
	local isjump = bot.pflags & PF_JUMPED --Currently jumping
	local isabil = bot.pflags & (PF_THOKKED | PF_GLIDING | PF_BOUNCING) --Currently using ability
	local isspin = bot.pflags & PF_SPINNING --Currently spinning
	local isdash = bot.pflags & PF_STARTDASH --Currently charging spindash
	local bmogrounded = P_IsObjectOnGround(bmo) and not (bot.pflags & PF_BOUNCING) --Bot ground state
	local pmogrounded = P_IsObjectOnGround(pmo) --Player ground state
	local dojump = 0 --Signals whether to input for jump
	local doabil = 0 --Signals whether to input for jump ability. Set -1 to cancel.
	local dospin = 0 --Signals whether to input for spinning
	local dodash = 0 --Signals whether to input for spindashing
	local stalled = bspd < scale and bai.move_last --AI is having trouble catching up
		and (isspin or bot.panim != PA_ABILITY2) --But don't worry about it if in attack anim
	local targetdist = CV_AISeekDist.value * scale --Distance to seek enemy targets
	local minspeed = 8 * scale --Minimum speed to spin or adjust combat jump range
	local pmag = FixedHypot(pcmd.forwardmove * FRACUNIT, pcmd.sidemove * FRACUNIT)
	local bmosloped = bmo.standingslope and AbsAngle(bmo.standingslope.zangle) > ANGLE_11hh

	--Are we spectating?
	if bot.spectator
		cmd.forwardmove,
		cmd.sidemove = DesiredMove(bmo, pmo, dist, followthres * 2, FixedSqrt(dist) * 2, 0, 0, bmogrounded, isspin, _2d)
		if abs(zdist) > followthres * 2
		or (bai.jump_last and abs(zdist) > followthres)
			if zdist < 0
				cmd.buttons = $ | BT_USE
				bai.jump_last = 1
			else
				cmd.buttons = $ | BT_JUMP
				bai.jump_last = 1
			end
		else
			bai.jump_last = 0
		end
		bmo.angle = R_PointToAngle2(bmo.x, bmo.y, pmo.x, pmo.y)
		bot.aiming = R_PointToAngle2(0, bmo.z + bmo.height / 2,
			dist + 32 * FRACUNIT, pmo.z + pmo.height / 2)

		--Debug
		if CV_AIDebug.value > -1
		and CV_AIDebug.value == #bot
			hudtext[1] = "dist " + dist / scale
			hudtext[2] = "zdist " + zdist / scale
			hudtext[3] = "FM " + cmd.forwardmove + " SM " + cmd.sidemove
			hudtext[4] = "Jmp " + (cmd.buttons & BT_JUMP) / BT_JUMP + " Spn " + (cmd.buttons & BT_USE) / BT_USE
			hudtext[5] = "leader " + #bai.leader + " - " + bai.leader.name
			if bai.leader != bai.realleader and bai.realleader and bai.realleader.valid
				hudtext[5] = $ + " (realleader " + #bai.realleader + " - " + bai.realleader.name + ")"
			end
			hudtext[6] = nil
		end
		return
	end

	--followmin shrinks when airborne to help land
	if not bmogrounded
	and not bot.powers[pw_carry] --But not on vehicles
		followmin = touchdist / 2
	end

	--If we're a valid ai, optionally keep us around on diconnect
	--Note that this requires rejointimeout to be nonzero
	--They will stay until kicked or no leader available
	--(or until player rejoins, disables ai, and leaves again)
	if bot.quittime and CV_AIKeepDisconnected.value
		bot.quittime = 0 --We're still here!
		bot.ai.ronin = true --But we have no master
	end

	--Set a few flags AI expects - no analog or autobrake, but do use dchar
	bot.pflags = $
		& ~PF_ANALOGMODE
		| PF_DIRECTIONCHAR
		& ~PF_AUTOBRAKE

	--Predict platforming
	--	1 = predicted gap
	--	2 = predicted low floor relative to leader
	--	3 = both
	--	4 = jumping out of special stage badness
	if not isjump
		bai.predictgap = 0
	end
	if bmom > scale and abs(predictfloor - bmofloor) > 24 * scale
		bai.predictgap = $ | 1
	end
	if zdist > -32 * scale and predictfloor - pmofloor < -jumpheight
		bai.predictgap = $ | 2
	else
		bai.predictgap = $ & ~2
	end
	if isspecialstage
	and (bmo.eflags & (MFE_TOUCHWATER | MFE_UNDERWATER))
		bai.predictgap = $ | 4
	end

	if stalled
		bai.stalltics = $ + 1
	else
		bai.stalltics = 0
	end

	--Target ranging - average of bot and leader position
	--This technically allows up to 1.5x max target range
	local bpx = (bmo.x - pmo.x) / 2 + pmo.x --Can't avg via addition as it may overflow
	local bpy = (bmo.y - pmo.y) / 2 + pmo.y

	--Minecart!
	if bot.powers[pw_carry] == CR_MINECART
	or leader.powers[pw_carry] == CR_MINECART
		--Remain calm, possibly finding another minecart
		if bot.powers[pw_carry] == CR_MINECART
			bai.playernosight = 0
			bai.stalltics = 0
		end
		bai.anxiety = 0
		bai.panic = 0
		bpx = bmo.x --Search nearby
		bpy = bmo.y
	end

	--Determine whether to fight
	if bai.thinkfly
		targetdist = $ / 8
	end
	if bai.panic or bai.spinmode or bai.flymode
	or bai.targetnosight > 2 * TICRATE --Implies valid target (or waypoint)
		bai.target = nil
		bai.targetcount = 0
	elseif not ValidTarget(bot, leader, bpx, bpy, bai.target, targetdist, jumpheight, flip, ignoretargets, isspecialstage)
		bai.targetcount = 0

		--If we had a previous target, just reacquire a new one immediately
		--Otherwise, spread search calls out a bit across bots, based on playernum
		if bai.target
		or (
			(leveltime + #bot) % TICRATE == TICRATE / 2
			and pspd < leader.runspeed
		)
			--For chains, prefer targets closest to us instead of avg point
			--But only if we're within max target range
			if bai.target
			and dist < targetdist * 3/2 --Avg pos allows up to 1.5x range
				bpx = bmo.x
				bpy = bmo.y
			end

			--Begin the search!
			bai.target = nil
			if ignoretargets < 3 or bai.bored
				local besttype = 255
				local bestdist = targetdist
				searchBlockmap(
					"objects",
					function(bmo, mo)
						local ttype, tdist = ValidTarget(bot, leader, bpx, bpy, mo, targetdist, jumpheight, flip, ignoretargets, isspecialstage)
						if ttype and CheckSight(bmo, mo)
							if ttype < besttype
							or (ttype == besttype and tdist < bestdist)
								besttype = ttype
								bestdist = tdist
								bai.target = mo
							end
							if mo.flags & (MF_BOSS | MF_ENEMY)
								bai.targetcount = $ + 1
							end
						end
					end, bmo,
					bpx - targetdist, bpx + targetdist,
					bpy - targetdist, bpy + targetdist
				)
			--Always bop leader if they need it
			elseif ValidTarget(bot, leader, bpx, bpy, pmo, targetdist, jumpheight, flip, ignoretargets, isspecialstage)
			and CheckSight(bmo, pmo)
				bai.target = pmo
			end
		end
	end

	--Waypoint! Attempt to negotiate corners
	if bai.playernosight
		if not (bai.waypoint and bai.waypoint.valid)
			bai.waypoint = P_SpawnMobj(pmo.x - pmo.momx, pmo.y - pmo.momy, pmo.z - pmo.momz, MT_FOXAI_POINT)
			--bai.waypoint.state = S_LOCKON3
			bai.waypoint.ai_type = 1
		elseif R_PointToDist2(bmo.x, bmo.y, bai.waypoint.x, bai.waypoint.y) < touchdist
			bai.waypoint = DestroyObj(bai.waypoint)
		end
	elseif bai.waypoint
		bai.waypoint = DestroyObj(bai.waypoint)
	end

	--Determine movement
	if bai.target --Above checks infer bai.target.valid
		--Check target sight
		if CheckSight(bmo, bai.target)
			bai.targetnosight = 0
		else
			bai.targetnosight = $ + 1
		end

		--Used in fight logic later
		targetdist = R_PointToDist2(bmo.x, bmo.y, bai.target.x, bai.target.y)

		--Override our movement and heading to intercept
		cmd.forwardmove, cmd.sidemove =
			DesiredMove(bmo, bai.target, targetdist, 0, 0, 0, bmom, bmogrounded, isspin, _2d)
		bmo.angle = R_PointToAngle2(bmo.x - bmo.momx, bmo.y - bmo.momy, bai.target.x, bai.target.y)
		bot.aiming = R_PointToAngle2(0, bmo.z - bmo.momz + bmo.height / 2,
			targetdist + 32 * FRACUNIT, bai.target.z + bai.target.height / 2)
	--Waypoint!
	elseif bai.waypoint
		--Check waypoint sight
		if CheckSight(bmo, bai.waypoint)
			bai.targetnosight = 0
		else
			bai.targetnosight = $ + 1
		end

		--dist eventually recalculates as a total path length (left partial here for aiming vector)
		--zdist just gets overwritten so we ascend/descend appropriately
		dist = R_PointToDist2(bmo.x, bmo.y, bai.waypoint.x, bai.waypoint.y)
		zdist = FixedMul(bai.waypoint.z - bmo.z, scale * flip)

		--Divert through the waypoint
		cmd.forwardmove, cmd.sidemove =
			DesiredMove(bmo, bai.waypoint, dist, 0, 0, 0, bmom, bmogrounded, isspin, _2d)
		bmo.angle = R_PointToAngle2(bmo.x - bmo.momx, bmo.y - bmo.momy, bai.waypoint.x, bai.waypoint.y)
		bot.aiming = R_PointToAngle2(0, bmo.z - bmo.momz + bmo.height / 2,
			dist + 32 * FRACUNIT, bai.waypoint.z + bai.waypoint.height / 2)

		--Finish the dist calc
		dist = $ + R_PointToDist2(bai.waypoint.x, bai.waypoint.y, pmo.x, pmo.y)
	else
		--Clear target / waypoint sight
		bai.targetnosight = 0

		--Lead target if going super fast (and we're close or target behind us)
		local leaddist = 0
		if bspd > leader.normalspeed and pspd > pmo.scale
		and (dist < followthres or AbsAngle(bmomang - bmo.angle) > ANGLE_90)
			leaddist = followmin + dist + pmom + bmom
		--Reduce minimum distance if moving away (so we don't fall behind moving too late)
		elseif dist < followmin and pspd > bspd
		and AbsAngle(pmomang - bmo.angle) < ANGLE_112h
		and not bot.powers[pw_carry] --But not on vehicles
			followmin = 0 --Distance remains natural due to pspd > bspd check
		end

		--Normal follow movement and heading
		cmd.forwardmove, cmd.sidemove =
			DesiredMove(bmo, pmo, dist, followmin, leaddist, pmag, bmom, bmogrounded, isspin, _2d)
		bmo.angle = R_PointToAngle2(bmo.x - bmo.momx, bmo.y - bmo.momy, pmo.x, pmo.y)
		bot.aiming = R_PointToAngle2(0, bmo.z - bmo.momz + bmo.height / 2,
			dist + 32 * FRACUNIT, pmo.z + pmo.height / 2)
	end

	--Check water
	bai.drowning = 0
	if bmo.eflags & MFE_UNDERWATER
		followmax = $ / 2
		if bot.powers[pw_underwater] > 0
		and bot.powers[pw_underwater] < 16 * TICRATE
			bai.drowning = 1
			if bot.powers[pw_underwater] < 8 * TICRATE
			or (WaterTopOrBottom(bmo, bmo) - bmo.z) * flip < jumpheight + bmo.height / 2
				bai.drowning = 2
			end
		end
	end

	--Check anxiety
	if bai.bored
		bai.anxiety = 0
		bai.panic = 0
	elseif dist > followmax --Too far away
	or (zdist > jumpheight --Too low w/o enemy
		and (not bai.target or bai.target.player))
	or bai.stalltics > TICRATE / 2 --Something in my way!
		bai.anxiety = min($ + 2, 2 * TICRATE)
		if bai.anxiety >= 2 * TICRATE
			bai.panic = 1
		end
	elseif not isjump
		bai.anxiety = max($ - 1, 0)
		bai.panic = 0
	end

	--Over a pit / in danger w/o enemy
	if falling and zdist > 0
	and bmofloor < AdjustedZ(bmo, bmo) * flip - jumpheight * 2
	and (not bai.target or bai.target.player)
	and dist + abs(zdist) > followthres * 2
	and not bot.powers[pw_carry]
		bai.panic = 1
		bai.anxiety = 2 * TICRATE
	end

	--Carry pre-orientation (to avoid snapping leader's camera around)
	if (bot.pflags & PF_CANCARRY) and dist < touchdist * 2
		cmd.angleturn = pcmd.angleturn
	end

	--Being carried?
	if bot.powers[pw_carry]
		bot.pflags = $ | PF_DIRECTIONCHAR --This just looks nicer

		--Override orientation on minecart
		if bot.powers[pw_carry] == CR_MINECART and bmo.tracer
			bmo.angle = bmo.tracer.angle
		end

		--Override vertical aim if we're being carried by leader
		--(so we're not just staring at the sky looking up - in fact, angle down a bit)
		if bmo.tracer == pmo and not bai.target
			bot.aiming = R_PointToAngle2(0, 16 * FRACUNIT, 32 * FRACUNIT, bmo.momz)
		end

		--Jump for targets!
		if bai.target and bai.target.valid and not bai.target.player
			dojump = 1
		--Maybe ask AI carrier to descend
		--Or simply let go of a pulley
		elseif zdist < -jumpheight
			doabil = -1
		--Maybe carry leader again if they're tired?
		elseif ability == CA_FLY
		and bmo.tracer == pmo and bmom < minspeed * 2
		and leader.powers[pw_tailsfly] < TICRATE / 2
		and falling
			dojump = 1
			bai.flymode = 1
		end
	end

	--Check boredom
	if pcmd.buttons == 0 and pmag == 0
	and bmogrounded and (bai.bored or bspd < scale)
	and not (bai.drowning or bai.panic)
		bai.idlecount = $ + 2

		--Aggressive bots get bored slightly faster
		if ignoretargets < 3
			bai.idlecount = $ + 1
		end
	else
		bai.idlecount = 0
	end
	if bai.idlecount > 16 * TICRATE
		bai.bored = 1
	else
		bai.bored = 0
	end

	--********
	--FLY MODE (or super forms)
	if dist < touchdist
		--Carrying leader?
		if pmo.tracer == bmo and leader.powers[pw_carry]
			bai.flymode = 2
		--Activate co-op flight
		elseif bai.thinkfly == 1
		and (leader.pflags & PF_JUMPED)
		and (
			pspd
			or zdist > bmo.height / 2
			or pmo.momz * flip < 0
		)
			dojump = 1
			bai.flymode = 1
		end
		--Check positioning
		--Thinker for co-op fly
		if not (bai.bored or bai.drowning)
		and dist < touchdist / 2
		and abs(zdist) < (pmo.height + bmo.height) / 2
		and bmogrounded and (pmogrounded or bai.thinkfly)
		and not (leader.pflags & (PF_STASIS | PF_SPINNING))
		and not (pspd or bspd)
		and (ability == CA_FLY or SuperReady(bot))
			bai.thinkfly = 1
		else
			bai.thinkfly = 0
		end
		--Ready for takeoff
		if bai.flymode == 1
			bai.thinkfly = 0
			dojump = 1
			--Super!
			if SuperReady(bot)
				if bot.powers[pw_shield] & SH_NOSTACK
					S_StartSound(target, sfx_shldls)
					P_RemoveShield(bot)
					bot.powers[pw_flashing] = max($, TICRATE)
				end
				if falling
					dodash = 1
					bai.flymode = 0
				end
			--Make sure we're not too high up
			elseif zdist < -pmo.height
				doabil = -1
			elseif falling
			or pmo.momz * flip < 0
				doabil = 1
			end
			--Abort if player moves away or spins
			if --[[dist > touchdist or]] leader.dashspeed > 0
				bai.flymode = 0
			end
		--Carrying; Read player inputs
		elseif bai.flymode == 2
			bai.thinkfly = 0
			bot.pflags = $ | (leader.pflags & PF_AUTOBRAKE) --Use leader's autobrake settings
			cmd.forwardmove = pcmd.forwardmove
			cmd.sidemove = pcmd.sidemove
			if pcmd.buttons & BT_USE
				doabil = -1
			else
				doabil = 1
			end
			bmo.angle = pmo.angle
			bot.aiming = R_PointToAngle2(0, 16 * FRACUNIT, 32 * FRACUNIT, bmo.momz)

			--End flymode
			if not leader.powers[pw_carry]
				bai.flymode = 0
			end
		end
	else
		bai.flymode = 0
		bai.thinkfly = 0
	end

	--********
	--SPINNING
	if ability2 == CA2_SPINDASH
	and not (bai.panic or bai.flymode or bai.target)
	and (leader.pflags & PF_SPINNING)
	and (isdash or not (leader.pflags & PF_JUMPED))
		--Spindash
		if leader.dashspeed > leader.maxdash / 4
			if dist > touchdist --Do positioning
				--Same as our normal follow DesiredMove but w/ no mindist / leaddist / minmag
				cmd.forwardmove, cmd.sidemove =
					DesiredMove(bmo, pmo, dist, 0, 0, 0, bmom, bmogrounded, isspin, _2d)
				bai.spinmode = 0
			else
				bot.pflags = $ | PF_AUTOBRAKE
				bmo.angle = pmo.angle
				dodash = 1
				bai.spinmode = 1
			end
		--Spin
		else
			--Keep angle from dash on initial spin frame
			--(So we don't rocket off in some random direction)
			if isdash
				bmo.angle = pmo.angle

				--Jump-cancel this frame?
				if leader.pflags & PF_JUMPED
					dojump = 1
				end
			end
			dospin = 1
			bai.spinmode = 1
		end
	else
		bai.spinmode = 0
	end

	--Leader pushing against something? Attack it!
	--Here so we can override spinmode
	--Also carry this down the leader chain if one exists
	--Or a spectating leader holding spin against the ground
	if (leader.ai and leader.ai.pushtics > TICRATE / 8)
	or (leader.spectator and (pcmd.buttons & BT_USE))
		pmag = 50 * FRACUNIT
	end
	if pmag > 45 * FRACUNIT and pspd < pmo.scale / 2
	and not bai.flymode
		if bai.pushtics > TICRATE / 2
			if dist > touchdist --Do positioning
				--Same as spinmode above
				cmd.forwardmove, cmd.sidemove =
					DesiredMove(bmo, pmo, dist, 0, 0, 0, bmom, bmogrounded, isspin, _2d)
				bai.panic = 1 --Recall bot while still allowing jumping etc.
			else
				--Helpmode!
				bai.target = pmo
				targetdist = dist

				--Stop and aim at what we're aiming at
				bot.pflags = $ | PF_AUTOBRAKE
				bmo.angle = pmo.angle
				bot.pflags = $ & ~PF_DIRECTIONCHAR --Ensure accurate melee

				--Spin! Or melee etc.
				if pmogrounded
				and ability2 != CA2_GUNSLINGER
					dodash = 1

					--Tap key for non-spin characters
					if ability2 != CA2_SPINDASH
					and bai.spin_last
						dodash = 0
					end
				--Do ability
				else
					dojump = 1
					doabil = 1
					cmd.forwardmove = 50
					cmd.sidemove = 0
				end
				bai.spinmode = 1 --Lock behavior
			end
		else
			bai.pushtics = $ + 1
		end
	elseif bai.pushtics > 0
		if isspin
			if isdash
				bmo.angle = pmo.angle
			elseif bmom
				bmo.angle = bmomang
			end
			dospin = 1
			bai.spinmode = 1 --Lock behavior
		end
		if isabil
			if bmom
				bmo.angle = bmomang
			end
			doabil = 1
			cmd.forwardmove = 50
			cmd.sidemove = 0
			bai.spinmode = 1 --Lock behavior
		end
		bai.pushtics = $ - 1
	end

	--Are we pushing against something?
	if bmogrounded
	and bai.stalltics > TICRATE / 2
	and bai.stalltics < TICRATE
	and ability2 != CA2_GUNSLINGER
		dodash = 1
	end

	--******
	--FOLLOW
	if not (bai.flymode or bai.spinmode or bai.target or bot.climbing)
		--Bored
		if bai.bored
			local idle = (bai.idlecount + bai.timeseed) * 17 / TICRATE
			local b1 = 256|128|64
			local b2 = 128|64
			local b3 = 64
			local imirror = 1
			if bai.timeseed & 1 --Odd timeseeds idle in reverse direction
				imirror = -1
			end
			cmd.forwardmove = 0
			cmd.sidemove = 0
			if idle & b1 == b1
				cmd.forwardmove = 35
				bmo.angle = $ + ANGLE_270 * imirror
			elseif idle & b2 == b2
				cmd.forwardmove = 25
				bmo.angle = $ + ANGLE_67h * imirror
			elseif idle & b3 == b3
				cmd.forwardmove = 15
				bmo.angle = $ + ANGLE_337h * imirror
			else
				bmo.angle = idle * (ANG1 * imirror / 2)
			end
		--Too far
		elseif bai.panic or dist > followthres
			if CV_AICatchup.value and dist > followthres * 2
			and not bot.powers[pw_sneakers]
				bot.powers[pw_sneakers] = 2
			end
		--Within threshold
		elseif dist > followmin
			--Do nothing
		--Below min
		else
			if not bai.drowning
				bot.pflags = $ | PF_AUTOBRAKE --Hit the brakes!
			else --Water panic?
				bmo.angle = $ + ANGLE_45
				cmd.forwardmove = 50
			end
		end
	end

	--*********
	--JUMP
	if not (bai.flymode or bai.spinmode or bai.target)
		--Start jump
		if (zdist > 32 * scale and (leader.pflags & PF_JUMPED)) --Following
		or (zdist > 64 * scale and bai.panic) --Vertical catch-up
		or (stalled and not bmosloped
			and pmofloor - bmofloor > 24 * scale)
		or bai.stalltics > TICRATE
		or (isspin and not isdash and bmom
			and AbsAngle(bmomang - bmo.angle) > ANGLE_157h) --Spinning
		or (bai.predictgap & 3 == 3 --Jumping a gap w/ low floor rel. to leader
			and not bot.powers[pw_carry]) --Not in carry state
		or (bai.predictgap & 4) --Jumping out of special stage water
		or bai.drowning == 2
			dojump = 1

			--Count panicjumps
			if bmogrounded and not (isjump or isabil)
				if bai.panic
					bai.panicjumps = $ + 1
				else
					bai.panicjumps = 0
				end
			end
		--Hold jump
		elseif isjump and (zdist > 0 or bai.panic or bai.predictgap or stalled)
		and not bot.powers[pw_carry] --Don't freak out on maces
			dojump = 1
		end

		--********
		--ABILITIES
		if not bai.target
			--Thok
			if ability == CA_THOK
			and (bai.panic or dist > followmax / 2)
				dojump = 1
				if falling or dist > followmax
					--Mix in fire shield half the time
					if bot.powers[pw_shield] == SH_FLAMEAURA
					and BotTime(bai, 1, 2)
						dodash = 1
					else
						doabil = 1
					end
				end

				--Super? Use the special float ability in midair too
				if bot.powers[pw_super] and isjump
				and (
					zdist > jumpheight
					or (zdist > 0 and (falling or bai.spin_last))
					or (bai.predictgap & 2)
					or (
						dist > followmax
						and bai.playernosight > TICRATE / 2
					)
				)
					if falling or bai.spin_last
						dodash = 1
					end
				end
			--Fly
			elseif ability == CA_FLY
			and (isabil or bai.panic or bai.drowning == 2)
				if zdist > jumpheight
				or (zdist > 0 and (falling or isabil))
				or bai.drowning == 2
				or (bai.predictgap & 2) --Flying over low floor rel. to leader
					dojump = 1
					if falling or isabil
						doabil = 1
					end
				elseif zdist < -512 * scale
				or (pmogrounded and dist < followthres and zdist < -jumpheight)
					doabil = -1
				end
			--Glide and climb / Float / Pogo Bounce
			elseif (ability == CA_GLIDEANDCLIMB or ability == CA_FLOAT or ability == CA_BOUNCE)
			and (isabil or bai.panic)
				if zdist > jumpheight
				or (zdist > 0 and (falling or isabil))
				or (bai.predictgap & 2)
				or (
					dist > followmax
					and (
						ability == CA_BOUNCE
						or bai.playernosight > TICRATE / 2
					)
				)
					dojump = 1
					if falling or isabil
						doabil = 1
					end
				end
				if ability == CA_GLIDEANDCLIMB
				and isabil and not bot.climbing
				and (dist < followthres or zdist > followmax / 2)
					bmo.angle = pmo.angle --Match up angles for better wall linking
				end
			--Why not fire shield?
			elseif not (doabil or isabil)
			and bot.powers[pw_shield] == SH_FLAMEAURA
			and (bai.panic or dist > followmax / 2)
				dojump = 1
				if falling or dist > followmax
					dodash = 1 --Use shield ability
				end
			end
		end
	end

	--Climb controls
	if bot.climbing
		local dmf = zdist
		local dms = dist
		if bai.target
			dmf = FixedMul(bai.target.z - bmo.z, scale * flip)
			dms = targetdist
		end
		--Don't wiggle around if target's off the wall
		if AbsAngle(bmo.angle - ang) < ANGLE_67h
		or AbsAngle(bmo.angle - ang) > ANGLE_112h
			dms = 0
		--Shorthand for relative angles >= 180 - meaning, move left
		elseif ang - bmo.angle < 0
			dms = -$
		end
		if FixedHypot(abs(dmf), abs(dms)) > touchdist
			cmd.forwardmove = min(max(dmf / scale, -50), 50)
			cmd.sidemove = min(max(dms / scale, -50), 50)
		else
			cmd.forwardmove = 0
			cmd.sidemove = 0
		end
		if AbsAngle(ang - bmo.angle) > ANGLE_112h
		and (dist > followthres * 2 or zdist < -jumpheight)
			doabil = -1
		end

		--Hold our previous angle when climbing
		bmo.angle = ang
	end

	--Emergency obstacle evasion!
	if bai.waypoint and bai.targetnosight > TICRATE
		if BotTime(bai, 2, 4)
			cmd.sidemove = 50
		else
			cmd.sidemove = -50
		end
	end

	--Gun cooldown for Fang
	if bot.panim == PA_ABILITY2
	and (ability2 == CA2_GUNSLINGER or ability2 == CA2_MELEE)
		bai.attackoverheat = $ + 1
		if bai.attackoverheat > 2 * TICRATE
			bai.attackwait = 1

			--Wait a longer cooldown
			if ability2 == CA2_MELEE
				bai.attackoverheat = 6 * TICRATE
			else
				bai.attackoverheat = 3 * TICRATE
			end
		end
	elseif bai.attackoverheat > 0
		bai.attackoverheat = $ - 1
	else
		bai.attackwait = 0
	end

	--*******
	--FIGHT
	if bai.target and bai.target.valid
	and not bai.pushtics --Don't do combat stuff for pushtics helpmode
		local hintdist = 32 * scale --Magic value - absolute minimum attack range hint, zdists larger than this are also no longer considered for spin/melee
		local maxdist = 256 * scale --Distance to catch up to.
		local mindist = bai.target.radius + bmo.radius + hintdist --Distance to attack from. Gunslingers avoid getting this close
		local targetfloor = FloorOrCeilingZ(bmo, bai.target) * flip
		local attkey = BT_JUMP
		local attack = 0
		local attshield = (bai.target.flags & (MF_BOSS | MF_ENEMY))
			and (bot.powers[pw_shield] == SH_ATTRACT
				or (bot.powers[pw_shield] == SH_ARMAGEDDON and bai.targetcount > 5))
		--Helpmode!
		if bai.target.player
			attkey = BT_USE
		--Rings!
		elseif (bai.target.type >= MT_RING and bai.target.type <= MT_FLINGBLUESPHERE)
		or bai.target.type == MT_COIN or bai.target.type == MT_FLINGCOIN
		or bai.target.type == MT_FIREFLOWER
			--Run into them if within targetfloor height
			if abs(AdjustedZ(bmo, bai.target) * flip - targetfloor) < bmo.height
				attkey = -1
			end
		--Jump for air bubbles! Or vehicles etc.
		elseif bai.target.type == MT_EXTRALARGEBUBBLE
		or bai.target.type == MT_MINECARTSPAWNER
			--Run into them if within height
			if abs(bai.target.z - bmo.z) < bmo.height / 2
				attkey = -1
			end
		--Override if we have an offensive shield
		elseif attshield
		or bai.target.type == MT_ROLLOUTROCK
			--Do nothing, default to jump
		--If we're invulnerable just run into stuff!
		elseif (bot.powers[pw_invulnerability]
			or bot.powers[pw_super]
			or (bot.dashmode > 3 * TICRATE and (bot.charflags & SF_MACHINE)))
		and (bai.target.flags & (MF_BOSS | MF_ENEMY))
		and abs(bai.target.z - bmo.z) < bmo.height / 2
			attkey = -1
		--Fire flower hack
		elseif (bot.powers[pw_shield] & SH_FIREFLOWER)
		and (bai.target.flags & (MF_BOSS | MF_ENEMY))
		and targetdist > hintdist
		and abs(bai.target.z - bmo.z) < bmo.height / 2
			--Run into / shoot them if within height
			attkey = -1
			if (leveltime + bai.timeseed) % TICRATE / 4 == 0
				cmd.buttons = $ | BT_ATTACK
			end
		--Gunslingers shoot from a distance
		elseif ability2 == CA2_GUNSLINGER
			if BotTime(bai, 31, 32) --Randomly (rarely) jump too
			and (bmogrounded or bai.attackwait)
				mindist = abs(bai.target.z - bmo.z) * 3/2
				maxdist = max($ + mindist, 512 * scale)
				attkey = BT_USE
			end
		--Melee only attacks on ground if it makes sense
		elseif ability2 == CA2_MELEE
			if BotTime(bai, 7, 8) --Randomly jump too
			and bmogrounded and abs(bai.target.z - bmo.z) < hintdist
				attkey = BT_USE --Otherwise default to jump below
				mindist = $ + bmom * 2 --Account for <3 range
			end
		--But other no-jump characters always ground-attack
		elseif bot.charflags & SF_NOJUMPDAMAGE
			attkey = BT_USE
		--Finally jump characters randomly spin
		elseif ability2 == CA2_SPINDASH
		and (isspin or BotTime(bai, 1, 8))
		and bmogrounded and abs(bai.target.z - bmo.z) < hintdist
			attkey = BT_USE
			mindist = $ + bmom * 16

			--Min dash speed hack
			if targetdist < maxdist
			and bspd <= minspeed
				mindist = $ + maxdist

				--Halt!
				bot.pflags = $ | PF_AUTOBRAKE
				cmd.forwardmove = 0
				cmd.sidemove = 0
			end
		end

		--Don't do gunslinger stuff if jump-attacking etc.
		if ability2 == CA2_GUNSLINGER and attkey != BT_USE
			ability2 = nil
		end

		--Make sure we're facing the right way if stand-attacking
		if attkey == BT_USE and bmogrounded
		and (ability2 == CA2_GUNSLINGER or ability2 == CA2_MELEE)
		and AbsAngle(bot.drawangle - bmo.angle) > ANGLE_22h
			--Should correct us
			mindist = 0
			maxdist = 0
		end

		--Stay engaged if already jumped or spinning
		if ability2 != CA2_GUNSLINGER
		and (isjump or isabil or isspin) --isspin infers isdash
			mindist = $ + targetdist
		else
			--Determine if we should commit to a longer jump
			bai.longjump = targetdist > maxdist / 2
				or abs(bai.target.z - bmo.z) > jumpheight
				or bmom <= minspeed / 2
		end

		--Range modification if momentum in right direction
		if bmom and AbsAngle(bmomang - bmo.angle) < ANGLE_22h
			mindist = $ + bmom * 8

			--Jump attack should be further timed relative to movespeed
			--Make sure we have a minimum speed for this as well
			if attkey == BT_JUMP
			and (isjump or bmom > minspeed / 2)
				mindist = $ + bmom * 12
			end
		--Cancel spin if off course
		elseif isspin and not isdash
			dojump = 1
		end

		if targetdist < mindist --We're close now
			if ability2 == CA2_GUNSLINGER --Can't shoot too close
				if _2d
					if bai.target.x < bmo.x
						cmd.sidemove = 50
					else
						cmd.sidemove = -50
					end
				else
					cmd.forwardmove = -50
				end
			else
				attack = 1

				if targetdist < bai.target.radius + bmo.radius
					bot.pflags = $ | PF_AUTOBRAKE
				end
			end
		elseif targetdist > maxdist --Too far
			--Do nothing
		else --Midrange
			if ability2 == CA2_GUNSLINGER
				if not bai.attackwait
				and (dist > followthres --Make sure leader's not blocking shot
					or targetdist < R_PointToDist2(pmo.x, pmo.y, bai.target.x, bai.target.y))
					attack = 1

					--Halt!
					bot.pflags = $ | PF_AUTOBRAKE
					cmd.forwardmove = 0
					cmd.sidemove = 0
				else
					--Make Fang find another angle after shots
					dojump = bai.attackwait
					doabil = dojump
					if predictfloor - bmofloor > -32 * scale
						cmd.forwardmove = 15
						if BotTime(bai, 4, 8)
							cmd.sidemove = 30 + 20 * doabil
						else
							cmd.sidemove = -30 - 20 * doabil
						end
					end
				end
			end
		end

		--Attack
		if attack
			if attkey == BT_JUMP
				if bmogrounded or bai.longjump
				or (bai.target.height * 3/4 + bai.target.z - bmo.z) * flip > 0
					dojump = 1
					if ability == CA_FLY and falling
					and (dist > touchdist or zdist < pmo.height)
					and (bai.target.z - bmo.z) * flip > jumpheight
						doabil = 1
					end
				end

				--Use offensive shields
				if attshield and (falling
					or abs(hintdist * 2 + bai.target.height + bai.target.z - bmo.z) < hintdist)
				and targetdist < mindist
					dodash = 1 --Should fire the shield
				end

				--Hammer double-jump hack
				if ability == CA_TWINSPIN
				and not isabil and not bmogrounded
				and (bai.target.flags & (MF_BOSS | MF_ENEMY | MF_MONITOR))
				and targetdist < bai.target.radius + bmo.radius + hintdist
				and abs(bai.target.z - bmo.z) < (bai.target.height + bmo.height) / 2 + hintdist
					doabil = 1
				end

				--Fang double-jump hack
				if ability == CA_BOUNCE
				and not bmogrounded and (falling or isabil)
				and (bai.target.flags & (MF_BOSS | MF_ENEMY | MF_MONITOR))
				and (
					(isabil and targetdist < maxdist)
					or targetfloor - bmofloor > jumpheight
					or (
						targetdist < bai.target.radius + bmo.radius + hintdist
						and (bai.target.z - bmo.z) * flip < 0
					)
				)
					doabil = 1
				end
			elseif attkey == BT_USE
				dospin = 1
				if ability2 == CA2_SPINDASH
				and bot.dashspeed < bot.maxdash / 3
					dodash = 1
				end
			end

			--Bubble shield check!
			if targetdist < bai.target.radius + bmo.radius
			and (bai.target.z - bmo.z) * flip < 0
			and (
				bot.powers[pw_shield] == SH_ELEMENTAL
				or bot.powers[pw_shield] == SH_BUBBLEWRAP
			)
				dodash = 1 --Bop!
			end
		end

		--Platforming during combat
		if (isjump and not attack)
		or (stalled and not bmosloped
			and targetfloor - bmofloor > 24 * scale)
		or bai.stalltics > TICRATE
		or (bai.predictgap & 5) --Jumping a gap / out of special stage water
			dojump = 1
		end
	end

	--Special action - cull bad momentum w/ force shield
	if isjump and falling
	and not (doabil or isabil)
	and (bot.powers[pw_shield] & SH_FORCE)
	and bmom and AbsAngle(bmomang - bmo.angle) > ANGLE_157h
		dodash = 1
	end

	--Maybe use shield double-jump?
	--Outside of dojump block for whirlwind shield (should be safe)
	if not bmogrounded and falling
	and not (doabil or isabil or bot.climbing)
	and not bot.powers[pw_carry]
	and (
		(
			--In combat - thunder shield only (unless no jump damage)
			bot.powers[pw_shield] == SH_THUNDERCOIN
			and bai.target and not bai.target.player
			and not (bot.charflags & SF_NOJUMPDAMAGE)
			and (
				(bai.target.z - bmo.z) * flip > 32 * scale
				or targetdist > 384 * scale
			)
		)
		or (
			--Out of combat - thunder or whirlwind shield
			(bot.powers[pw_shield] == SH_WHIRLWIND
				or bot.powers[pw_shield] == SH_THUNDERCOIN)
			and (not bai.target or bai.target.player)
			and (
				zdist > 32 * scale
				or dist > 384 * scale
			)
		)
	)
		dodash = 1 --Use shield double-jump
		cmd.buttons = $ | BT_JUMP --Force jump control for whirlwind
	end

	--**********
	--DO INPUTS
	--Jump action
	--Could also check "or doabil > 0" as a shortcut
	--But prefer to keep them separate for now
	if dojump
	and (
		(isjump and bai.jump_last) --Already jumping
		or (bmogrounded and not bai.jump_last) --Not jumping yet
		or bot.powers[pw_carry] --Being carried?
	)
	and not (isjump and doabil) --Not requesting abilities
	and not (isabil or bot.climbing) --Not using abilities
		cmd.buttons = $ | BT_JUMP
	end
	--Ability
	if doabil > 0
	and (
		isabil --Already using ability
		or (isjump and not bai.jump_last) --Jump, released input
	)
	and not bot.climbing --Not climbing
	and not (ability == CA_FLY and bai.jump_last) --Flight input check
		cmd.buttons = $ | BT_JUMP
	--"Force cancel" ability
	elseif doabil < 0
	and (
		(ability == CA_FLY and isabil) --If flying, descend
		or bot.climbing --If climbing, let go
		or bot.powers[pw_carry] --Being carried?
	)
		dodash = 1
		cmd.buttons = $ & ~BT_JUMP
	end

	--Spin while moving
	if dospin
	and bmogrounded --Avoid accidental shield abilities
	and not bai.spin_last
	and (
		ability2 != CA2_SPINDASH
		or (
			bspd > minspeed
			and AbsAngle(bmomang - bmo.angle) < ANGLE_22h
		)
	)
		cmd.buttons = $ | BT_USE
	end

	--Charge spindash
	if dodash
	and (
		not bmogrounded --Flight descend / shield abilities
		or isdash --Already spinning
		or bspd < scale --Spin only from standstill
	)
		cmd.buttons = $ | BT_USE
	end

	--Teleport override?
	if bai.doteleport and CV_AITeleMode.value > 0
		cmd.buttons = $ | CV_AITeleMode.value
	end

	--Nights hack - just copy player input
	--(Nights isn't officially supported in coop anyway)
	if bot.powers[pw_carry] == CR_NIGHTSMODE
		cmd.forwardmove = pcmd.forwardmove
		cmd.sidemove = pcmd.sidemove
		cmd.buttons = pcmd.buttons
	end

	--Dead! (Overrides other jump actions)
	if bot.playerstate == PST_DEAD
		bai.stalltics = $ + 1
		cmd.buttons = $ & ~BT_JUMP
		if leader.playerstate == PST_LIVE
		and (
			AdjustedZ(bmo, bmo) * flip - bmofloor < 0
			or bai.stalltics > 6 * TICRATE
		)
		and not bai.jump_last
			cmd.buttons = $ | BT_JUMP
		end
	end

	--*******
	--History
	if cmd.buttons & BT_JUMP
		bai.jump_last = 1
	else
		bai.jump_last = 0
	end
	if cmd.buttons & BT_USE
		bai.spin_last = 1
	else
		bai.spin_last = 0
	end
	if FixedHypot(cmd.forwardmove, cmd.sidemove) > 30
		bai.move_last = 1
	else
		bai.move_last = 0
	end

	--*******
	--Aesthetic
	--thinkfly overlay
	if not (bai.overlay and bai.overlay.valid)
		bai.overlay = P_SpawnMobj(bmo.x, bmo.y, bmo.z, MT_OVERLAY)
		bai.overlay.target = bmo
	end
	if bai.thinkfly == 1
		if bai.overlay.state == S_NULL
			bai.overlay.state = S_FLIGHTINDICATOR
		end
		if SuperReady(bot)
			bai.overlay.colorized = true
			bai.overlay.color = SKINCOLOR_YELLOW
		elseif bai.overlay.colorized
			bai.overlay.colorized = false
			bai.overlay.color = SKINCOLOR_NONE
		end
	else
		bai.overlay.state = S_NULL
	end

	--Debug
	if CV_AIDebug.value > -1
	and CV_AIDebug.value == #bot
		local p = "follow"
		local fight = 0
		local helpmode = 0
		if bai.target and bai.target.valid
			if bai.target.player
				helpmode = 1
			else
				fight = 1
			end
		end
		if bai.flymode == 1 then p = "flymode (ready)"
		elseif bai.flymode == 2 then p = "flymode (carrying)"
		elseif bai.doteleport then p = "\x84" + "teleport!"
		elseif helpmode then p = "\x81" + "helpmode"
		elseif bai.target and bai.targetnosight then p = "\x84" + "targetnosight " + bai.targetnosight
		elseif fight then p = "\x83" + "fight"
		elseif bai.drowning then p = "\x85" + "drowning"
		elseif bai.panic then p = "\x85" + "panic (anxiety " + bai.anxiety + ")"
		elseif bai.bored then p = "bored"
		elseif bai.thinkfly then p = "thinkfly"
		elseif bai.anxiety then p = "\x82" + "anxiety " + bai.anxiety
		elseif bai.targetnosight then p = "\x87" + "waypointnosight " + bai.targetnosight
		elseif bai.playernosight then p = "\x87" + "playernosight " + bai.playernosight
		elseif bai.spinmode then p = "spinmode (dashspeed " + bot.dashspeed / FRACUNIT + ")"
		elseif dist > followthres then p = "follow (far)"
		elseif dist < followmin then p = "follow (close)"
		end
		local dcol = ""
		if dist > followmax then dcol = "\x85" end
		local zcol = ""
		if zdist > jumpheight then zcol = "\x85" end
		--AI States
		hudtext[1] = "AI [" + bai.bored..helpmode..fight..bai.attackwait..bai.thinkfly..bai.flymode..bai.spinmode..bai.drowning..bai.anxiety..bai.panic + "]"
		hudtext[2] = p
		--Distance
		hudtext[3] = dcol + "dist " + dist / scale + "/" + followmax / scale
		hudtext[4] = zcol + "zdist " + zdist / scale + "/" + jumpheight / scale
		--Physics and Action states
		hudtext[5] = "perf " + min(isjump,1)..min(isabil,1)..min(isspin,1)..min(isdash,1) + "|" + dojump..doabil..dospin..dodash
		hudtext[6] = "gap " + bai.predictgap + " stall " + bai.stalltics
		--Inputs
		hudtext[7] = "FM " + cmd.forwardmove + " SM " + cmd.sidemove
		hudtext[8] = "Jmp " + (cmd.buttons & BT_JUMP) / BT_JUMP + " Spn " + (cmd.buttons & BT_USE) / BT_USE + " Th " + (bot.pflags & PF_THOKKED) / PF_THOKKED
		--Target
		if fight
			hudtext[9] = "\x83" + "target " + #bai.target.info + " - " + string.gsub(tostring(bai.target), "userdata: ", "")
				+ " " + bai.targetcount + " " + targetdist / scale
		elseif helpmode
			hudtext[9] = "\x81" + "target " + #bai.target.player + " - " + bai.target.player.name
		else
			hudtext[9] = "leader " + #bai.leader + " - " + bai.leader.name
			if bai.leader != bai.realleader and bai.realleader and bai.realleader.valid
				hudtext[9] = $ + " (realleader " + #bai.realleader + " - " + bai.realleader.name + ")"
			end
		end
		--Waypoint?
		if bai.waypoint
			hudtext[10] = ""
			hudtext[11] = "\x87" + "waypoint " + string.gsub(tostring(bai.waypoint), "userdata: ", "")
				+ " " + R_PointToDist2(bmo.x, bmo.y, bai.waypoint.x, bai.waypoint.y) / scale
		end
	end
end



--[[
	--------------------------------------------------------------------------------
	LUA HOOKS
	Define all hooks used to actually interact w/ the game
	--------------------------------------------------------------------------------
]]
--Tic? Tock! Call PreThinkFrameFor bot
addHook("PreThinkFrame", function()
	for player in players.iterate
		if player.ai
			PreThinkFrameFor(player)
		--Cancel quittime if we've rejoined a previously headless bot
		--(unfortunately PlayerJoin does not fire for rejoins)
		elseif player.quittime and (
			player.cmd.forwardmove
			or player.cmd.sidemove
			or player.cmd.buttons
		)
			player.quittime = 0
		end
	end
end)

--Handle MapChange for bots (e.g. call ResetAI)
addHook("MapChange", function(mapnum)
	for player in players.iterate
		if player.ai
			ResetAI(player.ai)
		end
	end
end)

--Handle damage for bots (simple "ouch" instead of losing rings etc.)
addHook("MobjDamage", function(target, inflictor, source, damage, damagetype)
	if damagetype < DMG_DEATHMASK
	and target.player
	and target.player.valid
	and target.player.ai
	and target.player.rings > 0
	and (
		CV_AIHurtMode.value == 0
		or (
			CV_AIHurtMode.value == 1
			and not target.player.powers[pw_shield]
		)
	)
		S_StartSound(target, sfx_shldls)
		P_DoPlayerPain(target.player, source, inflictor)
		return true
	end
end, MT_PLAYER)

--Handle pickup rules for bots
local function CanPickup(special, toucher)
	--Only pick up flung rings/coins leader could've also picked up
	--However, let anyone pick up rings when ai_hurtmode == 2
	--That is difficult to otherwise account for and is pretty brutal anyway
	if toucher.player
	and toucher.player.valid
	and toucher.player.ai
	and toucher.player.ai.leader
	and toucher.player.ai.leader.valid
	and CV_AIHurtMode.value < 2
	and not P_CanPickupItem(GetTopLeader(toucher.player.ai.leader, toucher.player))
		return true
	end
end
addHook("TouchSpecial", CanPickup, MT_FLINGRING)
addHook("TouchSpecial", CanPickup, MT_FLINGCOIN)

--Handle (re)spawning for bots
addHook("PlayerSpawn", function(player)
	if player.ai
		--Fix bug where respawning in boss grants leader our startrings
		player.ai.lastrings = player.rings

		--Engage!
		Teleport(player)
	elseif not player.jointime
	and CV_AIDefaultLeader.value >= 0
	and CV_AIDefaultLeader.value != #player
		--Defaults to no ai/leader, but bot will sort itself out
		PreThinkFrameFor(player)
	end
end)

--Handle sudden quitting for bots
addHook("PlayerQuit", function(player, reason)
	if player.ai
		DestroyAI(player)
	end
end)

--SP Only: Handle (re)spawning for bots
addHook("BotRespawn", function(pmo, bmo)
	--Allow game to reset SP bot as normal if player-controlled or dead
	if CV_ExAI.value == 0
	or not bmo.player.ai
	or bmo.player.playerstate == PST_DEAD
		return
	end
	return false
end)

--SP Only: Delegate SP AI to foxBot
addHook("BotTiccmd", function(bot, cmd)
	if CV_ExAI.value == 0
		return
	end

	--SP bots need carry state manually set
	if bot.charability == CA_FLY
	and (bot.pflags & PF_THOKKED)
		bot.pflags = $ | PF_CANCARRY
	end

	--Hook no longer needed once ai set up (PreThinkFrame handles instead)
	if bot.ai
		return true
	end

	--Defaults to no ai/leader, but bot will sort itself out
	PreThinkFrameFor(bot)
	return true
end)

--HUD hook!
hud.add(function(v, stplyr, cam)
	--If not previous text in buffer... (e.g. debug)
	if hudtext[1] == nil
		--And we're not a bot...
		if stplyr.ai == nil
		or stplyr.ai.leader == nil
		or not stplyr.ai.leader.valid
		or CV_AIShowHud.value == 0
			return
		end

		--Otherwise generate a simple bot hud
		local bmo = stplyr.realmo
		local pmo = stplyr.ai.leader.realmo
		if bmo and bmo.valid
		and pmo and pmo.valid
			hudtext[1] = "Following " + stplyr.ai.leader.name
			if stplyr.ai.leader != stplyr.ai.realleader
			and stplyr.ai.realleader and stplyr.ai.realleader.valid
				hudtext[1] = $ + " \x83(" + stplyr.ai.realleader.name + " KO'd)"
			end
			hudtext[2] = ""
			if stplyr.ai.doteleport
				hudtext[3] = "\x84Teleporting..."
			elseif pmo.health <= 0
				hudtext[3] = "Waiting for respawn..."
			else
				hudtext[3] = "Dist " + FixedHypot(
					R_PointToDist2(
						bmo.x, bmo.y,
						pmo.x, pmo.y
					),
					abs(pmo.z - bmo.z)
				) / bmo.scale
				if stplyr.ai.playernosight
					hudtext[3] = "\x87" + $
				end
			end
			hudtext[4] = nil

			if stplyr.ai.cmd_time > 0
			and stplyr.ai.cmd_time < 3 * TICRATE
				hudtext[4] = ""
				hudtext[5] = "\x81" + "AI control in " .. stplyr.ai.cmd_time / TICRATE + 1 .. "..."
				hudtext[6] = nil
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
	for k, s in ipairs(hudtext)
		if k & 1
			v.drawString(x, y, s, V_SNAPTOTOP | V_SNAPTOLEFT | v.localTransFlag(), size)
		else
			v.drawString(x + 64 * scale, y, s, V_SNAPTOTOP | V_SNAPTOLEFT | v.localTransFlag(), size)
			y = $ + 4 * scale
		end
		hudtext[k] = nil
	end
end, "game")



--[[
	--------------------------------------------------------------------------------
	HELP STUFF
	Things that may or may not be helpful
	--------------------------------------------------------------------------------
]]
local function BotHelp(player)
	print(
		"\x87 foxBot! - v1.0 - 2020/11/25",
		"\x81  Based on ExAI - v2.0 - 2019/12/31",
		"",
		"\x87 SP / MP Server Admin Convars:",
		"\x80  ai_sys - Enable/Disable AI",
		"\x80  ai_ignore - Ignore targets? \x86(1 = enemies, 2 = rings / monitors, 3 = all)",
		"\x80  ai_seekdist - Distance to seek enemies, rings, etc.",
		"",
		"\x87 MP Server Admin Convars:",
		"\x80  ai_catchup - Allow AI catchup boost? \x86(MP only, sorry!)",
		"\x80  ai_keepdisconnected - Allow AI to remain after client disconnect?",
		"\x83   Note: rejointimeout must also be > 0 for this to work!",
		"\x80  ai_defaultleader - Default leader for new clients \x86(-1 = off, 32 = random)",
		"\x80  ai_hurtmode - Allow AI to get hurt? \x86(1 = shield loss, 2 = ring loss)",
		"",
		"\x87 MP Server Admin Convars - Compatibility:",
		"\x80  ai_statmode - Allow AI individual stats? \x86(1 = rings, 2 = lives, 3 = both)",
		"\x80  ai_telemode - Override AI teleport behavior w/ button press?",
		"\x86   (0 = disable, 64 = fire, 1024 = toss flag, 4096 = alt fire, etc.)",
		"",
		"\x87 MP Server Admin Commands:",
		"\x80  setbota <leader> <bot> - Have <bot> follow <leader> by number \x86(-1 = stop)",
		"",
		"\x87 SP / MP Client Convars:",
		"\x80  ai_debug - Draw detailed debug info to HUD \x86(-1 = off)",
		"\x80  ai_showhud - Draw basic bot info to HUD",
		"",
		"\x87 MP Client Commands:",
		"\x80  setbot <leader> - Follow <leader> by number \x86(-1 = stop)",
		"\x80  listbots - List active bots and players"
	)
	if not player
		print(
			"",
			"\x87 Use \"bothelp\" to show this again!"
		)
	end
end
COM_AddCommand("BOTHELP", BotHelp, COM_LOCAL)



--[[
	--------------------------------------------------------------------------------
	INIT ACTIONS
	Actions to take once we've successfully initialized
	--------------------------------------------------------------------------------
]]
BotHelp() --Display help
