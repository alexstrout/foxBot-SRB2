--[[
	foxBot v1.6 by fox: https://taraxis.com/foxBot-SRB2
	Based heavily on VL_ExAI-v2.lua by CobaltBW: https://mb.srb2.org/showthread.php?t=46020
	Initially an experiment to run bots off of PreThinkFrame instead of BotTiccmd
	This allowed AI to control a real player for use in netgames etc.
	Since they're no longer "bots" to the game, it integrates a few concepts from ClassicCoop-v1.3.lua by FuriousFox: https://mb.srb2.org/showthread.php?t=41377
	Such as ring-sharing, nullifying damage, etc. to behave more like a true SP bot, as player.bot is read-only

	Future TODO?
	* Remove bots for ai_reserveslot based on follower count first
	* Avoid inturrupting players/bots carrying other players/bots due to flying too close
		(need to figure out a good way to detect if we're carrying someone)
	* Modular rewrite, defining behaviors on hashed functions - this would allow:
		* Mod support - AI hooks / overrides for targeting, ability rules, etc.
		* Gametype support - definable goals based on current game mode
		* Better abstractions - no more monolithic mess / derpy leader system
		* Other things to improve your life immeasurably
	* Bots break CoopOrDie teamlives by being dead with one life. Oops!
	* Bots get stuck infinitely teleporting on low FLASHINGTICS? Or at least with PAIN mod
		* Possibly just implement manual fallback timer?
	* Default-leader nodes based on same IP? (Is this possible?)
		* If possible, determine ownership / authority this way?
	* "Bounce" detection flag based on leader's last momentum?
		* Would increase abil threshold, allowing Tails etc. to bounce with leader better

	--------------------------------------------------------------------------------
	Copyright (c) 2022 Alex Strout and Shane Ellis

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
local CV_MaxPlayers = CV_FindVar("maxplayers")
local CV_CoopStarposts = CV_FindVar("coopstarposts")
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
	PossibleValue = {MIN = 64, MAX = 1536}
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
	defaultvalue = "-1",
	flags = CV_NETVAR|CV_SHOWMODIF,
	PossibleValue = {MIN = -1, MAX = 32}
})
local CV_AIMaxBots = CV_RegisterVar({
	name = "ai_maxbots",
	defaultvalue = "2",
	flags = CV_NETVAR|CV_SHOWMODIF,
	PossibleValue = {MIN = 0, MAX = 32}
})
local CV_AIReserveSlot = CV_RegisterVar({
	name = "ai_reserveslot",
	defaultvalue = "On",
	flags = CV_NETVAR|CV_SHOWMODIF,
	PossibleValue = CV_OnOff
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
--Global MT_FOXAI_POINTs used in various functions
local PosCheckerObj = nil

--Global vars
local isspecialstage = leveltime and G_IsSpecialStage() --Also set on MapLoad

--NetVars!
addHook("NetVars", function(network)
	PosCheckerObj = network($)
	isspecialstage = network($)
end)

--Text table used for HUD hook
local hudtext = {}

--Return whether player has elevated privileges
local function IsAdmin(player)
	return player == server
		or (player and player.valid
			and IsPlayerAdmin(player))
end

--Return whether player has authority over bot
local function IsAuthority(player, bot, strict)
	return bot == player
		or (IsAdmin(player) and not strict)
		or (bot and bot.valid
			and (bot.ai_owner == player
				or (bot.ai and bot.ai.ronin
					and bot.ai.realleader == player)))
end

--Return shortened player name
local function ShortName(player)
	if string.len(player.name) > 10
		return string.sub(player.name, 1, 10) .. ".."
	end
	return player.name
end

--Return descriptive bot type
local function BotType(bot)
	if bot.bot == BOT_MPAI
		return "mp bot"
	elseif bot.bot != BOT_NONE
		return "2p bot"
	end
	return "bot"
end

--Return if bot is considered an "sp bot" (2p bot)
local function SPBot(bot)
	return bot.bot and bot.bot != BOT_MPAI
end

--Resolve player by number (string or int)
local function ResolvePlayerByNum(num)
	num = tonumber($)
	if num != nil and num >= 0 and num < 32
		return players[num]
	end
	return nil
end

--Resolve multiple players by string (or player by number)
local function ResolveMultiplePlayersByNum(player, num)
	--Support "all" and "disconnect[ed/ing]" arguments
	if type(num) == "string" --Double-check before using string lib
		local b = string.lower(string.sub(num, 1, 10))
		if b == "all" or b == "disconnect"
			local ret = {}
			for pbot in players.iterate
				if IsAuthority(player, pbot)
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
	return ResolvePlayerByNum(num)
end

--Return number of connected players/bots
local function PlayerCount()
	local pcount = 0
	for _ in players.iterate
		pcount = $ + 1
	end
	return pcount
end

--Returns absolute angle (0 to 180)
--Useful for comparing angles
local function AbsAngle(ang)
	if ang < 0 and ang > ANGLE_180
		return InvAngle(ang)
	end
	return ang
end

--Returns last (maxn) array element
local function TableLast(t)
	return t[table.maxn(t)]
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
local function FixBadFloorOrCeilingZ(pmo)
	--Briefly set MF_NOCLIP so we don't accidentally destroy the object, oops (e.g. ERZ snails in walls)
	local oflags = pmo.flags
	pmo.flags = $ | MF_NOCLIP
	P_SetOrigin(pmo, pmo.x, pmo.y, pmo.z)
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
	PosCheckerObj.eflags = $ & ~MFE_VERTICALFLIP | (bmo.eflags & MFE_VERTICALFLIP)
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
	P_SetOrigin(bmo,
		bmo.x + bmo.momx * pfac,
		bmo.y + bmo.momy * pfac,
		bmo.z + bmo.momz * pfac)
	local predictfloor = FloorOrCeilingZ(bmo, bmo)
	bmo.flags = oflags
	P_SetOrigin(bmo, ox, oy, oz)
	return predictfloor
end

--P_CheckSight wrapper to approximate sight checks for objects above/below FOFs
--Eliminates being able to "see" targets through FOFs at extreme angles
local function CheckSight(bmo, pmo)
	--Allow equal heights so we can see DSZ3 boss
	return bmo.floorz <= pmo.ceilingz
		and bmo.ceilingz >= pmo.floorz
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

--CONS_Printf but substituting consoleplayer for secondarydisplayplayer
local function ConsPrint(player, ...)
	if player == secondarydisplayplayer
		player = consoleplayer
	end
	CONS_Printf(player, ...)
end



--[[
	--------------------------------------------------------------------------------
	AI SETUP FUNCTIONS / CONSOLE COMMANDS
	Any AI "setup" logic, including console commands
	--------------------------------------------------------------------------------
]]
--Set a new target for AI
local function SetTarget(ai, target)
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
local function ResetAI(ai)
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
	SetTarget(ai, nil) --Enemy to target
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
	ai.overlay = DestroyObj($) --Speech bubble overlay - only (re)create this if needed in think logic
	ai.overlaytime = 0 --Time overlay has been active
	ai.waypoint = DestroyObj($) --Transient waypoint used for navigating around corners
end

--Update all followers' followerindex
local function UpdateFollowerIndices(leader)
	if not (leader and leader.valid and leader.ai_followers)
		return
	end
	for k, b in ipairs(leader.ai_followers)
		if b and b.valid and b.ai
			b.ai.followerindex = k
		end
	end

	--Maintain a recursive "tail" reference to our last follower
	local tail = TableLast(leader.ai_followers)
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
	and TableLast(leader.ai.realleader.ai_followers) == leader
	and leader.ai.realleader != baseleader
		leader.ai.realleader.ai_followers.tail = tail
		leader = leader.ai.realleader
	end
end

--Register follower with leader for lookup later
local function RegisterFollower(leader, bot)
	if not (leader and leader.valid)
		return
	end
	if not leader.ai_followers
		leader.ai_followers = {}
	end
	table.insert(leader.ai_followers, bot)
	UpdateFollowerIndices(leader)
end

--Unregister follower with leader
local function UnregisterFollower(leader, bot)
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
		UpdateFollowerIndices(leader)
	else
		leader.ai_followers = nil
	end
end

--Register bot with player owner for lookup later
local function RegisterOwner(player, bot)
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
local function UnregisterOwner(player, bot)
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
local function SetupAI(player)
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
	ResetAI(player.ai) --Define the rest w/ their respective values
	player.ai.playernosight = 3 * TICRATE --For setup only, queue an instant teleport
end

--Restore "real" ring / life counts for a given player
local function RestoreRealRings(player)
	player.rings = player.ai.realrings
	player.xtralife = player.ai.realxtralife
end
local function RestoreRealLives(player)
	player.lives = player.ai.reallives

	--Transition to spectating if we had no lives left
	if player.lives < 1 and not player.spectator
		player.playerstate = PST_REBORN
	end
end

--"Repossess" a bot for player control
local function Repossess(player)
	--Reset our original analog etc. prefs
	--SendWeaponPref isn't exposed to Lua, so just cycle convars to trigger it
	--However, 2.2.11 now prevents this as none of the convars are marked CV_ALLOWLUA
	--So we must manually restore some pflags with ugly convar lookups :P
	local CV_Analog = CV_FindVar("configanalog")
	local CV_Directionchar = CV_FindVar("directionchar")
	local CV_Autobrake = CV_FindVar("autobrake")
	if not netgame and #player > 0
		CV_Analog = CV_FindVar("configanalog2")
		CV_Directionchar = CV_FindVar("directionchar2")
		CV_Autobrake = CV_FindVar("autobrake2")
	end
	player.pflags = $
		& ~PF_ANALOGMODE
		& ~PF_DIRECTIONCHAR
		& ~PF_AUTOBRAKE
	if netgame or splitscreen or #player == 0
		if (CV_Analog.value)
			player.pflags = $ | PF_ANALOGMODE
		end
		if (CV_Directionchar.value)
			player.pflags = $ | PF_DIRECTIONCHAR
		end
	end
	if (CV_Autobrake.value)
		player.pflags = $ | PF_AUTOBRAKE
	end

	--Reset our vertical aiming (in case we have vert look disabled)
	player.aiming = 0

	--Reset anything else
	ResetAI(player.ai)
end

--Destroy AI table (and any child tables / objects) for a given player, if needed
local function DestroyAI(player)
	if not player.ai
		return
	end

	--Reset pflags etc. for player
	--Also resets all vars, clears target, etc.
	Repossess(player)

	--Unregister ourself from our (real) leader if still valid
	UnregisterFollower(player.ai.realleader, player)

	--Kick headless bots w/ no client
	--Otherwise they sit and do nothing
	if player.ai.ronin
		player.quittime = 1
	end

	--Restore our "real" ring / life counts if synced
	if player.ai.syncrings
		RestoreRealRings(player)
	end
	if player.ai.synclives
		RestoreRealLives(player)
	end

	--SP bots record our last good realleader to reset to later
	if SPBot(player)
		player.ai_lastrealleader = player.ai.realleader
	end

	--My work here is done
	player.ai = nil
	collectgarbage()
end

--Get our "top" leader in a leader chain (if applicable)
--e.g. for A <- B <- D <- C, D's "top" leader is A
local function GetTopLeader(bot, basebot)
	--basebot automatically set to bot if nil
	if bot != basebot and bot.valid and bot.ai
	and bot.ai.realleader and bot.ai.realleader.valid
		return GetTopLeader(bot.ai.realleader, basebot or bot)
	end
	return bot
end

--Get our "bottom" follower in a leader chain (if applicable)
--e.g. for A <- B <- D <- C, A's "bottom" follower is C
local function GetBottomFollower(bot, basebot)
	--basebot automatically set to bot if nil
	if bot != basebot and bot.valid and bot.ai_followers
		for k, b in ipairs(bot.ai_followers)
			--Pick a random node if the tree splits
			if P_RandomByte() < 128
			or table.maxn(bot.ai_followers) == k
				return GetBottomFollower(b, basebot or bot)
			end
		end
	end
	return bot
end

--List all bots, optionally excluding bots led by leader
local function SubListBots(player, leader, owner, bot, level)
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
		msg = $ .. " \x8A(" .. BotType(bot) .. ": " .. #bot.ai_owner .. " - " .. bot.ai_owner.name .. ")"
	elseif bot.ai and bot.ai.cmd_time
		msg = $ .. " \x81(player-controlled)"
	elseif bot.ai and bot.ai.ronin
		msg = $ .. " \x83(disconnected)"
	elseif not bot.bot
		msg = $ .. " \x84(player)"
	end
	local count = 0
	if owner == nil or IsAuthority(owner, bot, true)
		ConsPrint(player, msg)
		count = 1
	end
	if bot.ai_followers
		for _, b in ipairs(bot.ai_followers)
			count = $ + SubListBots(player, leader, owner, b, level + 1)
		end
	end
	return count
end
local function ListBots(player, leader, owner)
	if leader != nil
		leader = ResolvePlayerByNum($)
		if leader and leader.valid
			ConsPrint(player, "\x84 Excluding players/bots led by " .. leader.name)
		end
	end
	if owner != nil
		owner = ResolvePlayerByNum($)
		if owner and owner.valid
			ConsPrint(player, "\x81 Showing only players/bots owned by " .. owner.name)
		end
	end
	local count = 0
	for p in players.iterate
		if not p.ai
			count = $ + SubListBots(player, leader, owner, p, 0)
		end
	end
	ConsPrint(player, "Returned " .. count .. " nodes")
end
COM_AddCommand("LISTBOTS", ListBots, COM_LOCAL)

--Set player as a bot following a particular leader
--Internal/Admin-only: Optionally specify some other player/bot to follow leader
local function SetBot(player, leader, bot)
	local pbot = player
	if bot != nil --Must check nil as 0 is valid
		pbot = ResolveMultiplePlayersByNum(player, bot)
		if type(pbot) == "table"
			for _, bot in ipairs(pbot)
				SetBot(player, leader, bot)
			end
			return
		end
		if not IsAuthority(player, pbot)
			pbot = nil
		end
	end
	if not (pbot and pbot.valid)
		ConsPrint(player, "Invalid bot! Please specify a bot by number:")
		ListBots(player, nil, #player)
		return
	end

	--Make sure we won't end up following ourself
	local pleader = ResolvePlayerByNum(leader)
	if pleader and pleader.valid
	and GetTopLeader(pleader, pbot) == pbot
		ConsPrint(player, pbot.name + " would end up following itself! Please try a different leader:")
		ListBots(player, #pbot)
		return
	end

	--Set up our AI (if needed) and figure out leader
	SetupAI(pbot)
	if pleader and pleader.valid
		ConsPrint(player, "Set bot " + pbot.name + " following " + pleader.name)
		if player != pbot
			ConsPrint(pbot, player.name + " set bot " + pbot.name + " following " + pleader.name)
		end
	elseif pbot.ai.realleader
		ConsPrint(player, "Stopping bot " + pbot.name)
		if player != pbot
			ConsPrint(pbot, player.name + " stopping bot " + pbot.name)
		end
	else
		ConsPrint(player, "Invalid leader! Please specify a leader by number:")
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
COM_AddCommand("SETBOT2", SetBot, COM_SPLITSCREEN)
COM_AddCommand("SETBOT", SetBot, 0)

--Add player as a bot following us
local function AddBot(player, skin, color, name, type)
	if not (player.realmo and player.realmo.valid)
		ConsPrint(player, "Can't do this outside a level!")
		return
	end
	if not IsAdmin(player)
	and player.ai_ownedbots
	and table.maxn(player.ai_ownedbots) >= CV_AIMaxBots.value
		ConsPrint(player, "Too many bots! Maximum allowed per player: " .. CV_AIMaxBots.value)
		return
	end
	if netgame and CV_AIReserveSlot.value
	and PlayerCount() >= CV_MaxPlayers.value - 1
		ConsPrint(player, "Too many bots for current maxplayers count: " .. CV_MaxPlayers.value)
		if IsAdmin(player)
			ConsPrint(player, "\x82" .. "Admin Only:\x80 Try increasing maxplayers or disabling ai_reserveslot")
		end
		return
	end

	--Use logical defaults in singleplayer
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
	if color
		color = R_GetColorByName($)
	end
	if not color
		color = P_RandomRange(1, 68)
	end

	--Validate name
	if not name or name == ""
		name = player.name .. "Bot"
	end
	local i = 0
	local n = name
	for p in players.iterate
		if p.name == n
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
		ConsPrint(player, "Adding " .. BotType(pbot) .. " " .. pbot.name .. " / " .. skins[skin].name .. " / " .. R_GetNameByColor(color))

		--Set our skin if usable
		if R_SkinUsable(pbot, skin)
			R_SetPlayerSkin(pbot, skin)
		end

		--Force color in singleplayer
		pbot.skincolor = color

		--Set that bot! And figure out authority owner
		SetBot(pbot, #player)
		RegisterOwner(player, pbot)

		--All summoned bots should disconnect when stopped, except SP bots
		if pbot.ai and not SPBot(pbot)
			pbot.ai.ronin = true
		end
	else
		ConsPrint(player, "Unable to add bot!")
	end

	--Remove server proxy bot (if applicable)
	if sbot and sbot.valid
		G_RemovePlayer(#sbot)
	end
end
COM_AddCommand("ADDBOT2", AddBot, COM_SPLITSCREEN)
COM_AddCommand("ADDBOT", AddBot, 0)

--Alter player bot's skin, etc.
local function AlterBot(player, bot, skin, color)
	local pbot = ResolveMultiplePlayersByNum(player, bot)
	if type(pbot) == "table"
		for _, bot in ipairs(pbot)
			AlterBot(player, bot, skin, color)
		end
		return
	end
	if not IsAuthority(player, pbot)
		pbot = nil
	end
	if not (pbot and pbot.valid)
		ConsPrint(player, "Invalid bot! Please specify a bot by number:")
		ListBots(player, nil, #player)
		return
	end

	--Set skin and color
	if skin and skins[skin]
	and R_SkinUsable(pbot, skin)
	and pbot.realmo and pbot.realmo.valid --Must be used in-level
	and pbot.realmo.skin != skins[skin].name
		ConsPrint(player, "Set bot " .. pbot.name .. " skin to " .. skins[skin].name)
		if player != pbot
			ConsPrint(pbot, player.name + " set bot " .. pbot.name .. " skin to " .. skins[skin].name)
		end
		R_SetPlayerSkin(pbot, skin)
	elseif not color
		color = skin --Try skin arg as color
	end
	if color
		color = R_GetColorByName($)
		if color --Not nil or 0, since we shouldn't set SKINCOLOR_NONE
		and color != pbot.skincolor
			ConsPrint(player, "Set bot " .. pbot.name .. " color to " .. R_GetNameByColor(color))
			if player != pbot
				ConsPrint(pbot, player.name + " set bot " .. pbot.name .. " color to " .. R_GetNameByColor(color))
			end
			if pbot.realmo and pbot.realmo.valid
			and pbot.realmo.color == pbot.skincolor
				pbot.realmo.color = color
			end
			pbot.skincolor = color
		end
	end
end
COM_AddCommand("ALTERBOT2", AlterBot, COM_SPLITSCREEN)
COM_AddCommand("ALTERBOT", AlterBot, 0)

--Remove player bot
local function RemoveBot(player, bot)
	local pbot = nil
	if bot != nil --Must check nil as 0 is valid
		pbot = ResolveMultiplePlayersByNum(player, bot)
		if type(pbot) == "table"
			for _, bot in ipairs(pbot)
				RemoveBot(player, bot)
			end
			return
		end
	elseif player.ai_ownedbots
		pbot = TableLast(player.ai_ownedbots)
	elseif player.ai_followers
		--Loop in descending order, instead of just using ipairs
		local b = nil
		for i = table.maxn(player.ai_followers), 1, -1
			b = player.ai_followers[i]
			if IsAuthority(player, b, true)
				pbot = b
				break
			end
		end
	end
	if not IsAuthority(player, pbot)
		pbot = nil
	end
	if not (pbot and pbot.valid and pbot.ai) --Avoid misleading errors on non-ai
		ConsPrint(player, "Invalid bot! Please specify a bot by number:")
		ListBots(player, nil, #player)
		return
	end

	--Stop bot if no owner (real player)
	if not (pbot.ai_owner and pbot.ai_owner.valid)
		SetBot(player, -1, #pbot)
	--Remove owned bot
	else
		ConsPrint(player, "Removing " .. BotType(pbot) .. " " .. pbot.name)
		if player != pbot.ai_owner
			ConsPrint(pbot.ai_owner, player.name .. " removing " .. BotType(pbot) .. " " .. pbot.name)
		end

		--Remove that bot!
		if not (pbot.bot and G_RemovePlayer(#pbot))
			DestroyAI(pbot) --Silently stop bot, should transition to disconnected
			pbot.quittime = INT32_MAX --Skip disconnect time
		end
	end
end
COM_AddCommand("REMOVEBOT2", RemoveBot, COM_SPLITSCREEN)
COM_AddCommand("REMOVEBOT", RemoveBot, 0)

--Override character jump / spin ability AI
--Internal/Admin-only: Optionally specify some other player/bot to override
local function SetAIAbility(player, pbot, abil, type, min, max)
	abil = tonumber($)
	if abil != nil and abil >= min and abil <= max
		local msg = pbot.name .. " " .. type .. " AI override " .. abil
		ConsPrint(player, "Set " .. msg)
		if player != pbot
			ConsPrint(pbot, player.name .. " set " .. msg)
		end
		pbot.ai_override_abil = $ or {}
		pbot.ai_override_abil[type] = abil
	elseif pbot.ai_override_abil and pbot.ai_override_abil[type] != nil
		local msg = pbot.name .. " " .. type .. " AI override " .. pbot.ai_override_abil[type]
		ConsPrint(player, "Cleared " .. msg)
		if player != pbot
			ConsPrint(pbot, player.name .. " cleared " .. msg)
		end
		pbot.ai_override_abil[type] = nil
		if next(pbot.ai_override_abil) == nil
			pbot.ai_override_abil = nil
		end
	else
		local msg = "Invalid " .. type .. " AI override, " .. pbot.name .. " has " .. type .. " AI "
		if type == "spin"
			if pbot.ai
				ConsPrint(player, msg .. pbot.charability2)
			end
			ConsPrint(player,
				"Valid spin abilities:",
				"\x86 -1 = Reset",
				"\x80 0 = None",
				"\x83 1 = Spindash",
				"\x89 2 = Gunslinger",
				"\x8E 3 = Melee"
			)
		else
			if pbot.ai
				ConsPrint(player, msg .. pbot.charability)
			end
			ConsPrint(player,
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
local function OverrideAIAbility(player, abil, abil2, bot)
	local pbot = player
	if bot != nil --Must check nil as 0 is valid
		pbot = ResolveMultiplePlayersByNum(player, bot)
		if type(pbot) == "table"
			for _, bot in ipairs(pbot)
				OverrideAIAbility(player, abil, abil2, bot)
			end
			return
		end
		if not IsAuthority(player, pbot)
			pbot = nil
		end
	end
	if not (pbot and pbot.valid)
		ConsPrint(player, "Invalid bot! Please specify a bot by number:")
		ListBots(player, nil, #player)
		return
	end

	--Set that ability!
	SetAIAbility(player, pbot, abil, "jump", CA_NONE, CA_TWINSPIN)
	SetAIAbility(player, pbot, abil2, "spin", CA2_NONE, CA2_MELEE)
end
COM_AddCommand("OVERRIDEAIABILITY2", OverrideAIAbility, COM_SPLITSCREEN)
COM_AddCommand("OVERRIDEAIABILITY", OverrideAIAbility, 0)

--Admin-only: Debug command for testing out shield AI
--Left in for convenience, use with caution - certain shield values may crash game
COM_AddCommand("DEBUG_BOTSHIELD", function(player, bot, shield, inv, spd, super, rings, ems, scale, abil, abil2)
	bot = ResolvePlayerByNum(bot)
	shield = tonumber(shield)
	if not (bot and bot.valid)
		return
	elseif shield == nil
		ConsPrint(player,
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
		ConsPrint(player, bot.name + " has shield " + bot.powers[pw_shield])
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
local function DumpNestedTable(player, t, level, pt)
	pt[t] = true
	for k, v in pairs(t)
		local msg = k .. " = " .. tostring(v)
		for i = 0, level
			msg = " " .. $
		end
		ConsPrint(player, msg)
		if type(v) == "table" and not pt[v]
			DumpNestedTable(player, v, level + 1, pt)
		end
	end
end
COM_AddCommand("DEBUG_BOTAIDUMP", function(player, bot)
	bot = ResolvePlayerByNum(bot)
	if not (bot and bot.valid)
		return
	end
	if bot.ai
		ConsPrint(player, "-- botai " .. bot.name .. " --")
		DumpNestedTable(player, bot.ai, 0, {})
	end
	if bot.ai_followers
		ConsPrint(player, "-- ai_followers " .. bot.name .. " --")
		DumpNestedTable(player, bot.ai_followers, 0, {})
	end
	if bot.ai_ownedbots
		ConsPrint(player, "-- ai_ownedbots " .. bot.name .. " --")
		DumpNestedTable(player, bot.ai_ownedbots, 0, {})
	end
	if bot.ai_override_abil
		ConsPrint(player, "-- ai_override_abil " .. bot.name .. " --")
		DumpNestedTable(player, bot.ai_override_abil, 0, {})
	end
end, COM_LOCAL)



--[[
	--------------------------------------------------------------------------------
	COMMAND LOGIC
	Handle non-AI behavior such as leader controls etc.
	--------------------------------------------------------------------------------
]]
--Set a new "pick target" for AI leader
local function SetPickTarget(leader, bot)
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
local function CycleFollower(leader, dir)
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
		SetPickTarget(leader, leader.ai_followers[1])
		leader.ai_picktime = TICRATE
	end
	UpdateFollowerIndices(leader)
end

--Swap characters with follower
local function SubCanSwapCharacter(player, skin)
	return player and player.valid
		and player.realmo and player.realmo.valid --Only in-game!
		and R_SkinUsable(player, skin)
		and not (player.pflags & (PF_FULLSTASIS | PF_THOKKED | PF_SHIELDABILITY))
end
local function CanSwapCharacter(leader, bot)
	return bot and bot.valid --Needed for bot.skin arg
		and SubCanSwapCharacter(leader, bot.skin)
		and SubCanSwapCharacter(bot, leader.skin)
		and bot.ai and not bot.ai.cmd_time
		and (IsAuthority(leader, bot, true)
			or (leader.ai and not leader.ai.cmd_time))
		and FixedHypot( --Above infers valid realmo
			R_PointToDist2(
				bot.realmo.x, bot.realmo.y,
				leader.realmo.x, leader.realmo.y
			),
			bot.realmo.z - leader.realmo.z
		) < 384 * bot.realmo.scale + bot.realmo.radius + leader.realmo.radius
end
local function SubSwapCharacter(player, swap)
	--Play effects!
	S_StartSound(player.realmo, sfx_s3k6b)
	P_SpawnGhostMobj(player.realmo)
	P_SpawnMobjFromMobj(player.realmo, 0, 0, 0, MT_SUPERSPARK)

	--Swap skins
	R_SetPlayerSkin(player, swap.skin)

	--Swap colors
	if player.realmo.color == player.skincolor
		player.realmo.color = swap.skincolor
	end
	player.skincolor = swap.skincolor

	--Swap ability AI override (if applicable)
	player.ai_override_abil = swap.ai_override_abil

	--Remember original swap character
	if player != swap.ai_swapchar
		player.ai_swapchar = swap.ai_swapchar
	else
		player.ai_swapchar = nil
	end
end
local function SwapCharacter(leader, bot)
	if not CanSwapCharacter(leader, bot)
		return
	end

	--Swap characters
	local temp = {
		skin = leader.skin,
		skincolor = leader.skincolor,
		ai_override_abil = leader.ai_override_abil,
		ai_swapchar = leader.ai_swapchar or leader
	}
	bot.ai_swapchar = $ or bot
	SubSwapCharacter(leader, bot)
	SubSwapCharacter(bot, temp)
end

--Drive leader commands based on key presses etc.
local function LeaderPreThinkFrameFor(leader)
	--Cycle followers w/ weapon cycle keys
	local pcmd = leader.cmd
	if pcmd.buttons & BT_WEAPONNEXT
		if not leader.ai_pickbuttons
			CycleFollower(leader, 1)
		end
		leader.ai_pickbuttons = true
	elseif pcmd.buttons & BT_WEAPONPREV
		if not leader.ai_pickbuttons
			CycleFollower(leader, -1)
		end
		leader.ai_pickbuttons = true
	--Hold selection for ai_picktime
	elseif leader.ai_picktime
		leader.ai_pickbuttons = nil
		leader.ai_picktime = $ - 1
		if leader.ai_picktime <= 0
			leader.ai_picktime = nil
		elseif leader.ai_followers
			SetPickTarget(leader, leader.ai_followers[1])
		end
	--Inspect followers w/ weapon select keys
	--(preempted by ai_picktime hold from cycling followers)
	elseif pcmd.buttons & BT_WEAPONMASK
		SetPickTarget(leader, leader.ai_followers[pcmd.buttons & BT_WEAPONMASK])
	elseif pcmd.buttons & BT_FIRENORMAL
		SetPickTarget(leader, leader.ai_followers[1])
	elseif leader.ai_picktarget
		leader.ai_picktarget = DestroyObj($)
	end

	--Swap characters?
	if leader.ai_picktarget
		if pcmd.buttons & BT_ATTACK
			if not leader.ai_swapbutton
			and leader.ai_picktarget.valid
				SwapCharacter(leader, leader.ai_picktarget.ai_player)
			end
			leader.ai_swapbutton = true
		else
			leader.ai_swapbutton = nil
		end
	end
end



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

--Similar to above, but for an exact time interval
local function BotTimeExact(bai, time)
	return (leveltime + bai.timeseed) % time == 0
end

--Teleport a bot to leader, optionally fading out
local function Teleport(bot, fadeout)
	if not (bot.valid and bot.ai)
	or not leveltime or bot.exiting --Only valid in levels
	or (bot.pflags & PF_FULLSTASIS) --Whoops
		--Consider teleport "successful" on fatal errors for cleanup
		return true
	end

	--Make sure everything's valid (as this is also called on respawn)
	--Also don't teleport to disconnecting leader, unless AI is in control of it
	--Finally don't teleport to spectating leader, unless AI is in control of us
	local leader = bot.ai.leader
	if not (leader and leader.valid)
	or (leader.quittime and (not leader.ai or leader.ai.cmd_time))
	or (leader.spectator and bot.ai.cmd_time)
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
		return true
	end

	--In a minecart?
	if bot.powers[pw_carry] == CR_MINECART
	and bot.ai.playernosight < 6 * TICRATE
		return false
	end

	--No fadeouts supported in zoom tube or quittime
	if bot.powers[pw_carry] == CR_ZOOMTUBE
	or bot.quittime
		fadeout = false
	end

	--Teleport override?
	if CV_AITeleMode.value
		--Probably successful if we're not in a panic and can see leader
		return not (bot.ai.panic or bot.ai.playernosight)
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

	--Average our momentum w/ leader's - 1/4 ours, 3/4 theirs
	bmo.momx = $ / 4 + pmo.momx * 3/4
	bmo.momy = $ / 4 + pmo.momy * 3/4
	bmo.momz = $ / 4 + pmo.momz * 3/4

	--Zero momy in 2D mode (oops)
	if bmo.flags2 & MF2_TWOD
		bmo.momy = 0
	end

	P_SetOrigin(bmo, pmo.x, pmo.y, z)
	P_SetScale(bmo, pmo.scale)
	bmo.destscale = pmo.destscale
	bmo.angle = pmo.angle

	--Fade in (if needed)
	if bot.powers[pw_flashing] < TICRATE / 2
		bot.powers[pw_flashing] = TICRATE / 2
	end

	--Increment teleporttime safeguard - will instakill if it gets too high
	bot.ai.teleporttime = $ + TICRATE
	return true
end

--Calculate a "prediction factor" based on control state (air, spin, etc.)
local function PredictFactor(bmo, grounded, spinning)
	local pfac = 1 --General prediction mult
	if not grounded
		if spinning
			pfac = 8 --Taken from 2.2 p_user.c (pushfoward >> 3)
		else
			pfac = 4 --Taken from 2.2 p_user.c (pushfoward >> 2)
		end
	elseif spinning
		pfac = 16 --Taken from 2.2 p_user.c (pushfoward >> 4)
	end
	if bmo.eflags & MFE_UNDERWATER
		pfac = $ * 2 --Close enough
	end
	return pfac
end

--Calculate a "desired move" vector to a target, taking into account momentum and angle
local function DesiredMove(bot, bmo, pmo, dist, mindist, leaddist, minmag, pfac, _2d)
	--Calculate momentum for targets that don't set it!
	local pmomx = pmo.momx
	local pmomy = pmo.momy
	local pmomz = pmo.momz
	if not (pmomx or pmomy or pmomz or pmo.player) --No need to do this for players
		if pmo.ai_momlastposx != nil --Transient last position tracking
			--These are TICRATE-dependent, but so are mobj speeds I think
			pmomx = ((pmo.x - pmo.ai_momlastposx) + pmo.ai_momlastx) / 2
			pmomy = ((pmo.y - pmo.ai_momlastposy) + pmo.ai_momlasty) / 2
			pmomz = ((pmo.z - pmo.ai_momlastposz) + pmo.ai_momlastz) / 2
		end
		pmo.ai_momlastposx = pmo.x
		pmo.ai_momlastposy = pmo.y
		pmo.ai_momlastposz = pmo.z
		pmo.ai_momlastx = pmomx
		pmo.ai_momlasty = pmomy
		pmo.ai_momlastz = pmomz
	end

	--Figure out time to target
	local timetotarget = 0
	if not (bot.climbing or bot.spectator)
		--Extrapolate dist out to include Z + heights as well
		dist = FixedHypot($,
			abs((pmo.z + pmo.height / 2) - (bmo.z + bmo.height / 2)))

		--[[
			Calculate "total" momentum between us and target
			Despite only controlling X and Y, factoring in Z momentum does
			still help us intercept Z fast-movers with a lower timetotarget
		]]
		local tmom = FixedHypot(
			FixedHypot(
				pmomx - bmo.momx,
				pmomy - bmo.momy
			),
			pmomz - bmo.momz
		)

		--Calculate time, capped to sane values (influenced by pfac)
		--Note this is independent of TICRATE
		timetotarget = FixedDiv(
			min(dist, 256 * bmo.scale) * pfac,
			max(tmom, 32 * bmo.scale)
		)
	end

	--Figure out movement and prediction angles
	--local mang = R_PointToAngle2(0, 0, bmo.momx, bmo.momy)
	local px = pmo.x + FixedMul(pmomx - bmo.momx, timetotarget)
	local py = pmo.y + FixedMul(pmomy - bmo.momy, timetotarget)
	if leaddist
		local lang = R_PointToAngle2(0, 0, pmomx, pmomy)
		px = $ + FixedMul(cos(lang), leaddist)
		py = $ + FixedMul(sin(lang), leaddist)
	end
	local pang = R_PointToAngle2(bmo.x, bmo.y, px, py)

	--Uncomment this for a handy prediction indicator
	--PosCheckerObj = CheckPos(PosCheckerObj, px, py, pmo.z + pmo.height / 2)
	--PosCheckerObj.eflags = $ & ~MFE_VERTICALFLIP | (bmo.eflags & MFE_VERTICALFLIP)
	--PosCheckerObj.state = S_LOCKON1

	--Stop skidding everywhere! (commented as this isn't really needed anymore)
	--if pfac < 4 --Infers grounded and not spinning
	--and AbsAngle(mang - bmo.angle) < ANGLE_157h
	--and AbsAngle(mang - pang) > ANGLE_157h
	--and bot.speed >= FixedMul(bot.runspeed / 2, bmo.scale)
	--	return 0, 0
	--end

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
	local pdist = R_PointToDist2(bmo.x, bmo.y, px, py) - mindist
	if pdist < 0
		return 0, 0
	end
	local mag = min(max(pdist, minmag), 50 * FRACUNIT)
	return FixedMul(cos(pang), mag) / FRACUNIT, --forwardmove
		FixedMul(sin(pang), -mag) / FRACUNIT --sidemove
end

--Determine if a given target is valid, based on a variety of factors
local function ValidTarget(bot, leader, target, maxtargetdist, maxtargetz, flip, ignoretargets, ability, ability2, pfac)
	if not (target and target.valid and target.health > 0)
		return 0
	end

	--Target type, in preferred order
	--	-2 = passive - vehicles
	--	-1 = active/passive - priority targets (typically set after rules)
	--	1 = active - enemy etc. (more aggressive engagement rules)
	--	2 = passive - rings etc.
	local ttype = 0

	--We want an enemy
	if (ignoretargets & 1 == 0)
	and (target.flags & (MF_BOSS | MF_ENEMY))
	and target.type != MT_ROSY --Oops
	and (
		--Ignore flashing targets unless tagged in CoopOrDie
		target.cd_lastattacker
		or not (target.flags2 & MF2_FRET)
	)
	and not (target.flags2 & (MF2_BOSSFLEE | MF2_BOSSDEAD))
	and bot.realmo.state != S_PLAY_SPRING
		ttype = 1
	--Or, if melee, a shieldless friendly to buff
	elseif ability2 == CA2_MELEE
	and target.player and target.player.valid
	and bot.revitem == MT_LHRT
	and not (
		bot.ai.attackwait
		or target.player.spectator
		or (target.player.powers[pw_shield] & SH_NOSTACK)
		or target.player.revitem == MT_LHRT
		or target.player.spinitem == MT_LHRT
		or target.player.thokitem == MT_LHRT
		or SuperReady(target.player)
	)
	and P_IsObjectOnGround(target)
		if isspecialstage
			ttype = 3 --Rank lower than spheres / rings in special stages
		else
			ttype = 1
		end
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
	)
		ttype = 2
		maxtargetdist = $ / 2 --Rings half-distance
	--Monitors!
	elseif (ignoretargets & 2 == 0)
	and (target.flags & MF_MONITOR) --Skip all these checks otherwise
	and bot.bot != BOT_2PAI --SP bots can't pop monitors
	and (
		target.type == MT_RING_BOX or target.type == MT_1UP_BOX
		or target.type == MT_SCORE1K_BOX or target.type == MT_SCORE10K_BOX
		or target.type == MT_MYSTERY_BOX --Sure why not
		or target.type > MT_NAMECHECK --Just grab any custom monitor? Probably won't hurt
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
		or (
			(leader.powers[pw_gravityboots] > bot.powers[pw_gravityboots]
				or (leader.realmo.eflags & MFE_VERTICALFLIP) > (bot.realmo.eflags & MFE_VERTICALFLIP))
			and (
				target.type == MT_GRAVITY_BOX
				or target.type == MT_GRAVITY_GOLDBOX
			)
		)
	)
		ttype = 1 --Can pull sick jumps for these
	--Other powerups
	elseif (ignoretargets & 2 == 0)
	and bot.bot != BOT_2PAI --SP bots can't grab these
	and (
		(
			target.type == MT_FIREFLOWER
			and (leader.powers[pw_shield] & SH_FIREFLOWER) > (bot.powers[pw_shield] & SH_FIREFLOWER)
		)
		or (
			target.type == MT_STARPOST
			and target.health > bot.starpostnum
		)
		or (target.type == MT_TOKEN and bot.mw_fade != false) --Distinct from nil
		or (target.type >= MT_EMERALD1 and target.type <= MT_EMERALD7)
	)
		ttype = 1
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
		ttype = -2
	--Chaos Mode / Mirewalker emblems? Bit of a hack as foxBot needs better mod support
	elseif target.info.spawnstate == S_EMBLEM1
	and (
		(
			bot.chaos and leader.chaos
			and bot.chaos.goal != leader.chaos.goal
		)
		or (
			(leader.mw_fade or bot.mw_fade)
			and not (target.mw_players and target.mw_players[bot])
		)
	)
		ttype = 1
	else
		return 0
	end

	--Fix occasionally bad floorz / ceilingz values for things
	if not target.ai_validfocz
		FixBadFloorOrCeilingZ(target)
		target.ai_validfocz = true
	end

	--Don't do gunslinger stuff if we ain't slingin'
	if ability2 == CA2_GUNSLINGER
	and (bot.pflags & (PF_JUMPED | PF_THOKKED))
		ability2 = nil
	end

	--Consider our height against airborne targets
	local bmo = bot.realmo
	local bmoz = AdjustedZ(bmo, bmo) * flip
	local targetz = AdjustedZ(bmo, target) * flip
	local targetgrounded = P_IsObjectOnGround(target)
		and (bmo.eflags & MFE_VERTICALFLIP) == (target.eflags & MFE_VERTICALFLIP)
	local maxtargetz_height = maxtargetz
	if not targetgrounded
		if (bot.pflags & PF_JUMPED)
		or (bot.charflags & SF_NOJUMPSPIN)
			maxtargetz_height = $ + bmo.height
		else
			maxtargetz_height = $ + P_GetPlayerSpinHeight(bot)
		end
	end

	--We want to stand on top of rollout rocks
	if target.type == MT_ROLLOUTROCK
		targetz = $ + target.height
	end

	--Decide whether to engage target or not
	if ttype == 1 --Active target, take more risks
		if ability2 == CA2_GUNSLINGER
		and abs(targetz - bmoz) > 256 * bmo.scale
			return 0
		elseif ability == CA_FLY
		and (bot.pflags & PF_THOKKED)
		and bmo.state >= S_PLAY_FLY
		and bmo.state <= S_PLAY_FLY_TIRED
		and targetz - bmoz < -maxtargetdist
			return 0 --Flying characters should ignore enemies far below them
		elseif bot.powers[pw_carry]
		and abs(targetz - bmoz) > maxtargetz_height
		and bot.speed > 8 * bmo.scale --minspeed
			return 0 --Don't divebomb every target when being carried
		elseif targetz - bmoz >= maxtargetz_height
		and ability2 != CA2_GUNSLINGER
		and (
			ability != CA_FLY
			or (
				(
					(bmo.eflags & MFE_UNDERWATER)
					or targetgrounded
				)
				and not (
					bot.powers[pw_invulnerability]
					or bot.powers[pw_super]
				)
			)
		)
			return 0
		elseif targetz - bmoz > maxtargetdist
			return 0
		elseif target.state == S_INVISIBLE
			return 0 --Ignore invisible things
		elseif (target.eflags & MFE_GOOWATER)
		and bmo.momz * flip >= 0
		and (bot.powers[pw_shield] & SH_NOSTACK) != SH_ELEMENTAL
		--Equiv to w - t >= (b - w) + h
		and 2 * WaterTopOrBottom(bmo, target) * flip - targetz - bmoz >= maxtargetz_height
			return 0 --Ignore objects too far down in goop
		elseif bmo.tracer
		and bot.powers[pw_carry] == CR_ROLLOUT
			--Limit range when rolling around
			maxtargetdist = $ / 16 + bmo.tracer.radius
		elseif bot.powers[pw_carry]
			--Limit range when being carried
			maxtargetdist = $ / 4
		elseif ability == CA_FLY
		and targetz - bmoz >= maxtargetz_height
		and not (
			(bot.pflags & PF_THOKKED)
			and bmo.state >= S_PLAY_FLY
			and bmo.state <= S_PLAY_FLY_TIRED
		)
			--Limit range when fly-attacking, unless already flying
			maxtargetdist = $ / 4
		elseif target.cd_lastattacker
		and target.cd_lastattacker.player == bot
			--Limit range on active self-tagged CoopOrDie targets
			if target.cd_frettime
				return 0 --Switch targets if recently merped
			end
			ttype = 3 --Rank lower than passive targets
			maxtargetdist = $ / 4

			--Allow other AI to also attack this
			if target.ai_attacker == bot.ai
				target.ai_attacker = nil
			end
		end
	else --Passive target, play it safe
		if bot.powers[pw_carry]
			return 0
		elseif bot.quittime
			return 0 --Can't grab most passive things while disconnecting
		elseif abs(targetz - bmoz) >= maxtargetz_height
		and not (bot.ai.drowning and target.type == MT_EXTRALARGEBUBBLE)
			return 0
		elseif target.state == S_INVISIBLE
		and target.type != MT_MINECARTSPAWNER
			return 0 --Ignore invisible things (unless it's a cart spawner)
		elseif target.cd_lastattacker
		and target.cd_lastattacker.player == bot
			return 0 --Don't engage passive self-tagged CoopOrDie targets
		end
	end

	--Calculate distance to non-current targets, only allowing those in range
	local dist = nil
	if target != bot.ai.target
		dist = R_PointToDist2(
			--Add momentum to "prefer" targets in current direction
			bmo.x + bmo.momx * 4 * pfac,
			bmo.y + bmo.momy * 4 * pfac,
			target.x, target.y
		)
		if dist > maxtargetdist + bmo.radius + target.radius
			return 0
		end
	end

	--Calculate distance to target using average of bot and leader position
	--This technically allows us to stay engaged at higher ranges, to a point
	if not bot.ai.bored
		local pmo = leader.realmo
		local bpdist = R_PointToDist2(
			(bmo.x - pmo.x) / 2 + pmo.x, --Can't avg via addition as it may overflow
			(bmo.y - pmo.y) / 2 + pmo.y,
			target.x, target.y
		)
		if bpdist > maxtargetdist + pmo.radius + bmo.radius + target.radius
			return 0
		end
	end

	--Attempt to prioritize priority CoopOrDie targets
	if target.cd_lastattacker
	and target.cd_lastattacker.player != bot
	and target.info.cd_aipriority
		ttype = -1
	--Also attempt to prioritize Chaos Mode objectives
	elseif target.info.spawntype == "target"
		ttype = -1
	end

	--However, de-prioritize targets other AI are already attacking
	if (target.ai_attacker and target.ai_attacker != bot.ai)
		ttype = max(1, $ + 2)
	end

	--Note: dist will be nil for current targets
	return ttype, dist
end

--Update our last seen position
local function UpdateLastSeenPos(bai, pmo, pmoz)
	bai.lastseenpos.x = pmo.x + pmo.momx
	bai.lastseenpos.y = pmo.y + pmo.momy
	bai.lastseenpos.z = pmoz + pmo.momz
end

--Drive bot based on whatever unholy mess is in this function
--This is the "WhatToDoNext" entry point for all AI actions
local function PreThinkFrameFor(bot)
	if not bot.valid
		return
	end

	--Find a new "real" leader if ours quit
	local bai = bot.ai
	if not (bai and bai.realleader and bai.realleader.valid)
		--Pick a random leader if default is invalid
		local bestleader = CV_AIDefaultLeader.value
		if bot.ai_lastrealleader and bot.ai_lastrealleader.valid
			bestleader = #bot.ai_lastrealleader
			bot.ai_lastrealleader = nil
		end
		if bestleader < 0 or bestleader > 31
		or not (players[bestleader] and players[bestleader].valid)
		or players[bestleader] == bot
			bestleader = -1
			for player in players.iterate
				if not player.ai --Inspect top leaders only
				and not player.quittime --Avoid disconnecting players
				and GetTopLeader(player, bot) != bot --Also infers player != bot as base case
				--Prefer higher-numbered players to spread out bots more
				and (bestleader < 0 or P_RandomByte() < 128)
					bestleader = #player
				end
			end
		end
		SetBot(bot, bestleader)

		--Make sure SP bots register an owner
		if bot.bot and not (bot.ai_owner and bot.ai_owner.valid)
			RegisterOwner(players[bestleader], bot)
		end
		return
	end

	--Already think this frame?
	if bai.think_last == leveltime
		return
	end
	bai.think_last = leveltime

	--Determine our leader based on followerindex
	--Keeps us self-organized into a reasonable stack
	local leader = nil
	if bai.followerindex > 1
	or bai.realleader.spectator
		leader = bai.realleader.ai_followers[bai.followerindex - 1]
		if not (leader and leader.valid)
			leader = bai.realleader
		end

		--Leader have own followers? Fall in behind them
		if leader.ai_followers
		and leader != bai.realleader --Not containing us
		and leader.ai and not leader.ai.cmd_time
		and leader.ai_followers.tail
		and leader.ai_followers.tail.valid
			leader = leader.ai_followers.tail
		end

		--Leader busy? Follow their leader
		--This isn't ideal performance-wise, but it is accurate
		--We otherwise risk circular-leader issues which aren't ready to be tackled yet
		while leader.ai
		and leader.ai.busyleader
		and leader.ai.busyleader.valid
		and (
			--Stay within group if not player-controlled
			leader != bai.realleader
			or not leader.ai.cmd_time
		)
			leader = leader.ai.busyleader
		end
	else
		leader = bai.realleader
	end

	--Are we busy? Yield a better leader for followers
	if bai.busy
		bai.busyleader = leader

		--Just switch to realleader if player-controlled
		if bai.cmd_time
			leader = bai.realleader
		end
	else
		bai.busyleader = nil
	end

	--Lock in leader
	bai.leader = leader

	--Make sure AI leader thinks first
	if leader.ai
	and leader.ai.think_last != leveltime --Shortcut
		PreThinkFrameFor(leader)
	end

	--Determine if we're "busy" (more AI-specific checks are done later)
	bai.busy = bot.spectator
		or bai.cmd_time

	--Handle SP score here
	if not (netgame or splitscreen)
	and bot.score
		P_AddPlayerScore(leader, bot.score)
		bot.score = 0
	end

	--Handle rings here
	if not isspecialstage
		--Syncing rings?
		if CV_AIStatMode.value & 1 == 0
			--Remember our "real" ring count if newly synced
			if not bai.syncrings
				bai.syncrings = true
				bai.realrings = bot.rings
				bai.realxtralife = bot.xtralife
			end

			--Keep rings if leader spectating (still reset on respawn)
			if leader.spectator
			and not leader.ai --Not mid-leader chain!
			and leader.rings != bai.lastrings
				leader.rings = bai.lastrings
			end

			--Sync those rings!
			if bot.rings != bai.lastrings
			and not (SPBot(bot) and leader.exiting) --Fix SP bot zeroing rings when exiting
				P_GivePlayerRings(leader, bot.rings - bai.lastrings)
			end
			bot.rings = leader.rings

			--Oops! Fix awarding extra extra lives
			bot.xtralife = leader.xtralife
		--Restore our "real" ring count if no longer synced
		elseif bai.syncrings
			bai.syncrings = false
			RestoreRealRings(bot)
		end
		bai.lastrings = bot.rings

		--Syncing lives?
		if CV_AIStatMode.value & 2 == 0
			--Remember our "real" life count if newly synced
			if not bai.synclives
				bai.synclives = true
				bai.reallives = bot.lives
			end

			--Sync those lives!
			if bot.lives > bai.lastlives
			and bot.lives > leader.lives
			and not (SPBot(bot) and leader.exiting) --Probably doesn't hurt? See above
				P_GivePlayerLives(leader, bot.lives - bai.lastlives)
				if leveltime
					P_PlayLivesJingle(leader)
				end
			end
			if bot.lives > 0
				bot.lives = max(leader.lives, 1)
			else
				bot.lives = leader.lives
			end
		--Restore our "real" life count if no longer synced
		elseif bai.synclives
			bai.synclives = false
			RestoreRealLives(bot)
		end
		bai.lastlives = bot.lives
	end

	--****
	--VARS (Player or AI)
	local bmo = bot.realmo
	local pmo = leader.realmo
	local cmd = bot.cmd
	if not (bmo and bmo.valid and pmo and pmo.valid)
		return
	end

	--Elements / Measurements
	local flip = P_MobjFlip(bmo)
	local pmoz = AdjustedZ(bmo, pmo) * flip

	--Handle shield loss here if ai_hurtmode off
	if bai.loseshield
		if not bot.powers[pw_shield]
			bai.loseshield = nil
		elseif BotTimeExact(bai, TICRATE)
			bai.loseshield = nil --Make sure we only try once
			P_RemoveShield(bot)
			S_StartSound(bmo, sfx_corkp)
		end
	end

	--Check line of sight to player
	if CheckSight(bmo, pmo)
		bai.playernosight = 0
		UpdateLastSeenPos(bai, pmo, pmoz)

		--Decrement teleporttime if we can see leader
		bai.teleporttime = max($ - 1, 0)
	else
		bai.playernosight = $ + 1

		--Just instakill on too much teleporting if we still can't see leader
		if bai.teleporttime > 3 * TICRATE
			P_DamageMobj(bmo, nil, nil, 1, DMG_INSTAKILL)
		end
	end

	--Check leader's teleport status
	if leader.ai and leader.ai.doteleport
		bai.playernosight = max($, leader.ai.playernosight - TICRATE / 2 - 1)
		bai.panicjumps = max($, leader.ai.panicjumps - 1)
	end

	--And teleport if necessary
	bai.doteleport = bai.playernosight > 3 * TICRATE
		or bai.panicjumps > 3
	if bai.doteleport and Teleport(bot, true)
		--Post-teleport cleanup
		bai.doteleport = false
		bai.playernosight = TICRATE
		bai.panicjumps = 1
		bai.anxiety = 0
		bai.panic = 0
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

			--Unset ronin as client must have reconnected
			--(unfortunately PlayerJoin does not fire for rejoins)
			bai.ronin = false

			--Terminate AI to avoid interfering with normal SP bot stuff
			--Otherwise AI may take control again too early and confuse things
			--(We won't get another AI until a valid BotTiccmd is generated)
			if SPBot(bot)
				DestroyAI(bot)
				return
			end
		end
		bai.cmd_time = 8 * TICRATE
	end
	if bai.cmd_time > 0
		bai.cmd_time = $ - 1

		--Hold cmd_time if AI is off
		if CV_ExAI.value == 0
			bai.cmd_time = 3 * TICRATE
		end

		--Teleport override?
		if bai.doteleport and CV_AITeleMode.value > 0
			cmd.buttons = $ | CV_AITeleMode.value
		end
		return
	end

	--Bail here if AI is off (allows logic above to flow normally)
	if CV_ExAI.value == 0
		--Just trigger cmd_time logic next tic, without the setup
		--(also means this block only runs once)
		bai.cmd_time = 3 * TICRATE

		--Make sure SP bot AI is destroyed
		if SPBot(bot)
			DestroyAI(bot)
		end
		return
	end

	--****
	--VARS (AI-specific)
	local pcmd = leader.cmd

	--Elements
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
	local bmoz = AdjustedZ(bmo, bmo) * flip
	local pmomang = R_PointToAngle2(0, 0, pmo.momx, pmo.momy)
	local bmomang = R_PointToAngle2(0, 0, bmo.momx, bmo.momy)
	local pspd = leader.speed
	local bspd = bot.speed
	local dist = R_PointToDist2(bmo.x, bmo.y, pmo.x, pmo.y)
	local zdist = pmoz - bmoz
	local predictfloor = PredictFloorOrCeilingZ(bmo, 2) * flip
	local ang = bmo.angle --Used for climbing etc.
	local followmax = touchdist + 1024 * scale --Max follow distance before AI begins to enter "panic" state
	local followthres = touchdist + 92 * scale --Distance that AI will try to reach
	local followmin = touchdist + 32 * scale
	local bmofloor = FloorOrCeilingZ(bmo, bmo) * flip
	local pmofloor = FloorOrCeilingZ(bmo, pmo) * flip
	local jumpheight = FixedMul(bot.jumpfactor, 96 * scale)
	local ability = bot.charability
	local ability2 = bot.charability2
	local bshield = bot.powers[pw_shield] & SH_NOSTACK
	local falling = bmo.momz * flip < 0
	local isjump = bot.pflags & PF_JUMPED --Currently jumping
	local isabil = (bot.pflags & (PF_THOKKED | PF_GLIDING)) --Currently using character ability
		and not (bot.pflags & PF_SHIELDABILITY) --Note this does not cover repeatable shield abilities (bubble / attraction)
	local isspin = bot.pflags & PF_SPINNING --Currently spinning
	local isdash = bot.pflags & PF_STARTDASH --Currently charging spindash
	local bmogrounded = P_IsObjectOnGround(bmo) --Bot ground state
	local pmogrounded = P_IsObjectOnGround(pmo) --Player ground state
	local pfac = PredictFactor(bmo, bmogrounded, isspin)
	local dojump = 0 --Signals whether to input for jump
	local doabil = 0 --Signals whether to input for jump ability. Set -1 to cancel.
	local dospin = 0 --Signals whether to input for spinning
	local dodash = 0 --Signals whether to input for spindashing
	local stalled = bai.move_last --AI is having trouble catching up
		and (bmom < scale or (bspd > bmom and bmom < 2 * scale))
		and not bot.climbing
	local targetdist = CV_AISeekDist.value * scale --Distance to seek enemy targets (reused as actual target dist later)
	local targetz = 0 --Filled in later if target
	local minspeed = 8 * scale --Minimum speed to spin or adjust combat jump range
	local pmag = FixedHypot(pcmd.forwardmove * FRACUNIT, pcmd.sidemove * FRACUNIT)
	local bmosloped = bmo.standingslope and AbsAngle(bmo.standingslope.zangle) > ANGLE_11hh
	local hintdist = 32 * scale --Magic value - min attack range hint, zdists larger than this not considered for spin/melee, etc.
	local jumpdist = hintdist --Relative zdist to jump when following leader (possibly modified based on status)
	local stepheight = FixedMul(MAXSTEPMOVE, scale)

	--Are we spectating?
	if bot.spectator
		--Do spectator stuff
		cmd.forwardmove,
		cmd.sidemove = DesiredMove(bot, bmo, pmo, dist, followthres * 2, FixedSqrt(dist) * 2, 0, pfac, _2d)
		if abs(zdist) > followthres * 2
		or (bai.jump_last and abs(zdist) > followthres)
			if zdist * flip < 0
				cmd.buttons = $ | BT_SPIN
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
			dist + 32 * scale, pmo.z + pmo.height / 2)

		--Maybe press fire to join match? e.g. Chaos Mode
		if BotTimeExact(bai, 5 * TICRATE)
			cmd.buttons = $ | BT_ATTACK
		end

		--Fix 2.2.10 oddity where headless clients don't generate angleturn or aiming
		cmd.angleturn = bmo.angle >> 16
		cmd.aiming = bot.aiming >> 16

		--Debug
		if CV_AIDebug.value > -1
		and CV_AIDebug.value == #bot
			hudtext[1] = "dist " + dist / scale
			hudtext[2] = "zdist " + zdist / scale
			hudtext[3] = "FM " + cmd.forwardmove + " SM " + cmd.sidemove
			hudtext[4] = "Jmp " + (cmd.buttons & BT_JUMP) / BT_JUMP + " Spn " + (cmd.buttons & BT_SPIN) / BT_SPIN
			hudtext[5] = "leader " + #bai.leader + " - " + ShortName(bai.leader)
			if bai.leader != bai.realleader and bai.realleader and bai.realleader.valid
				hudtext[5] = $ + " \x86(" + #bai.realleader + " - " + ShortName(bai.realleader) + ")"
			end
			hudtext[6] = nil
		end
		return
	end

	--Ability overrides?
	if bot.ai_override_abil
		if bot.ai_override_abil.jump != nil
			ability = bot.ai_override_abil.jump
		end
		if bot.ai_override_abil.spin != nil
			ability2 = bot.ai_override_abil.spin
		end
	end

	--Halve jumpheight when on/in goop
	if bmo.eflags & MFE_GOOWATER
		jumpheight = $ / 2
	end

	--Save needless jumping if leader's falling toward us
	if zdist > 0 and pmo.momz * flip < 0
		jumpdist = jumpheight
	end

	--followmin shrinks when airborne to help land
	if not bmogrounded
	and not bot.powers[pw_carry] --But not on vehicles
		followmin = touchdist / 2
	end

	--Custom ability hacks
	if ability > CA_GLIDEANDCLIMB
	and ability < CA_BOUNCE
		if ability == CA_SWIM
		and (bmo.eflags & MFE_UNDERWATER)
			ability = CA_FLY
		elseif ability == CA_SLOWFALL
			ability = CA_FLOAT
		elseif ability == CA_FALLSWITCH
		and (isabil or (not bmogrounded and falling
				and bmoz - bmofloor < hintdist))
			ability = CA_DOUBLEJUMP
		elseif ability == CA_JUMPBOOST
			jumpheight = FixedMul($, FixedMul(bspd, bot.actionspd) / 1000 + scale)
		--Do more advanced combat hacks for these later
		elseif not bai.target
			if ability == CA_JUMPTHOK
			and stalled and bai.anxiety
			and dist < followmax
			and zdist > jumpdist
				ability = CA_DOUBLEJUMP
			elseif ability == CA_HOMINGTHOK
			or ability == CA_JUMPTHOK
				ability = CA_THOK
			end
		end
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
	--	8 = performing longjump for target (set in combat code)
	if not isjump
		bai.predictgap = 0
	end
	if bmom > scale and abs(predictfloor - bmofloor) > stepheight
		bai.predictgap = $ | 1
	end
	if zdist > -hintdist and predictfloor - pmofloor < -jumpheight
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

	--Determine whether to fight
	if bai.thinkfly
		targetdist = $ / 8
	elseif bai.bored
		targetdist = $ * 2

		--Fix sometimes not searching for targets due to waypoint
		if not bai.target
			bai.targetnosight = 0
		end
	end
	if bai.panic or bai.spinmode or bai.flymode
	or bai.targetnosight > 2 * TICRATE --Implies valid target (or waypoint)
	or (bai.targetjumps > 3 and bmogrounded)
		SetTarget(bai, nil)
	elseif not ValidTarget(bot, leader, bai.target, targetdist, jumpheight, flip, ignoretargets, ability, ability2, pfac)
		bai.targetcount = 0

		--If we had a previous target, just reacquire a new one immediately
		--Otherwise, spread search calls out a bit across bots, based on playernum
		if bai.target
		or (
			(leveltime + #bot) % (TICRATE / 2) == 0
			and pspd < 28 * scale --Default runspeed, to keep a consistent feel
		)
			--Gunslingers reset overheat on new target
			--Hammers also reset overheat on successful buffs
			if ability2 == CA2_GUNSLINGER
			or (
				ability2 == CA2_MELEE
				and bai.target and bai.target.valid
				and bai.target.player and bai.target.player.valid
				and (bai.target.player.powers[pw_shield] & SH_NOSTACK)
			)
				bai.attackoverheat = 0
			end

			--Begin the search!
			SetTarget(bai, nil)
			if ignoretargets < 3
				local besttype = 255
				local bestdist = targetdist
				local besttarget = nil
				searchBlockmap(
					"objects",
					function(bmo, mo)
						local ttype, tdist = ValidTarget(bot, leader, mo, targetdist, jumpheight, flip, ignoretargets, ability, ability2, pfac)
						if ttype and CheckSight(bmo, mo)
							if ttype < besttype
							or (ttype == besttype and tdist < bestdist)
								besttype = ttype
								bestdist = tdist
								besttarget = mo
							end
							if mo.flags & (MF_BOSS | MF_ENEMY)
								bai.targetcount = $ + mo.health
							end
						end
					end, bmo,
					bmo.x - targetdist, bmo.x + targetdist,
					bmo.y - targetdist, bmo.y + targetdist
				)
				SetTarget(bai, besttarget)
			--Always bop leader if they need it
			elseif ValidTarget(bot, leader, pmo, targetdist, jumpheight, flip, ignoretargets, ability, ability2, pfac)
			and CheckSight(bmo, pmo)
				SetTarget(bai, pmo)
			end
		end
	end

	--Waypoint! Attempt to negotiate corners
	if bai.playernosight
		if not (bai.waypoint and bai.waypoint.valid)
			bai.waypoint = P_SpawnMobj(bai.lastseenpos.x, bai.lastseenpos.y, bai.lastseenpos.z, MT_FOXAI_POINT)
			bai.waypoint.eflags = $ | (pmo.eflags & MFE_VERTICALFLIP)
			--bai.waypoint.state = S_LOCKON3
			bai.waypoint.ai_type = 1
		end
	elseif bai.waypoint
		bai.waypoint = DestroyObj($)
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
		targetz = AdjustedZ(bmo, bai.target) * flip

		--Override our movement and heading to intercept
		--Avoid self-tagged CoopOrDie targets (kinda fudgy and ignores waypoints, but gets us away)
		if bai.target.cd_lastattacker
		and bai.target.cd_lastattacker.player == bot
			cmd.forwardmove, cmd.sidemove =
				DesiredMove(bot, bmo, pmo, dist, followmin, 0, pmag, pfac, _2d)
		else
			cmd.forwardmove, cmd.sidemove =
				DesiredMove(bot, bmo, bai.target, targetdist, 0, 0, 0, pfac, _2d)
		end
		bmo.angle = R_PointToAngle2(bmo.x - bmo.momx, bmo.y - bmo.momy, bai.target.x, bai.target.y)
		bot.aiming = R_PointToAngle2(0, bmo.z - bmo.momz + bmo.height / 2,
			targetdist + 32 * scale, bai.target.z + bai.target.height / 2)
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
		zdist = AdjustedZ(bmo, bai.waypoint) * flip - bmoz

		--Divert through the waypoint
		cmd.forwardmove, cmd.sidemove =
			DesiredMove(bot, bmo, bai.waypoint, dist, 0, 0, 0, pfac, _2d)
		bmo.angle = R_PointToAngle2(bmo.x - bmo.momx, bmo.y - bmo.momy, bai.waypoint.x, bai.waypoint.y)
		bot.aiming = R_PointToAngle2(0, bmo.z - bmo.momz + bmo.height / 2,
			dist + 32 * scale, bai.waypoint.z + bai.waypoint.height / 2)

		--Check distance to waypoint, updating if we've reached it (may help path to leader)
		if (dist < bmo.radius and abs(zdist) <= jumpdist)
			UpdateLastSeenPos(bai, pmo, pmoz)
			P_SetOrigin(bai.waypoint, bai.lastseenpos.x, bai.lastseenpos.y, bai.lastseenpos.z)
			bai.waypoint.eflags = $ & ~MFE_VERTICALFLIP | (pmo.eflags & MFE_VERTICALFLIP)
			--bai.waypoint.state = S_LOCKON4
			bai.waypoint.ai_type = 0
			bai.targetnosight = 0
		else
			--Finish the dist calc
			dist = $ + R_PointToDist2(bai.waypoint.x, bai.waypoint.y, pmo.x, pmo.y)
		end
	else
		--Clear target / waypoint sight
		bai.targetnosight = 0

		--Lead target if going super fast (and we're close or target behind us)
		local leaddist = 0
		if bspd > leader.normalspeed + pmo.scale and pspd > pmo.scale
		and (dist < followthres or AbsAngle(bmomang - bmo.angle) > ANGLE_90)
			leaddist = followmin + dist + (pmom + bmom) * 2
		--Reduce minimum distance if moving away (so we don't fall behind moving too late)
		elseif dist < followmin and pmom > bmom
		and AbsAngle(pmomang - bmo.angle) < ANGLE_135
		and not bot.powers[pw_carry] --But not on vehicles
			followmin = 0 --Distance remains natural due to pmom > bmom check
		end

		--Normal follow movement and heading
		cmd.forwardmove, cmd.sidemove =
			DesiredMove(bot, bmo, pmo, dist, followmin, leaddist, pmag, pfac, _2d)
		bmo.angle = R_PointToAngle2(bmo.x - bmo.momx, bmo.y - bmo.momy, pmo.x, pmo.y)
		bot.aiming = R_PointToAngle2(0, bmo.z - bmo.momz + bmo.height / 2,
			dist + 32 * scale, pmo.z + pmo.height / 2)
	end

	--Check water
	bai.drowning = 0
	if bmo.eflags & MFE_UNDERWATER
		followmax = $ / 2
		if bot.powers[pw_underwater] > 0
		and bot.powers[pw_underwater] < 16 * TICRATE
			bai.drowning = 1
			if bot.powers[pw_underwater] < 8 * TICRATE
			or WaterTopOrBottom(bmo, bmo) * flip - bmoz < jumpheight + bmo.height / 2
				bai.drowning = 2
			end
		end
	end

	--Check anxiety
	if bai.bored
		bai.anxiety = 0
		bai.panic = 0
	elseif ((dist > followmax --Too far away
			or zdist > jumpheight) --Too low w/o enemy
		and (bmogrounded or not bai.target or bai.target.player))
	or bai.stalltics > TICRATE / 2 --Something in my way!
		bai.anxiety = min($ + 2, 2 * TICRATE)
		if bai.anxiety >= 2 * TICRATE
			bai.panic = 1
		end
	elseif not isjump or zdist <= 0
		bai.anxiety = max($ - 1, 0)
		bai.panic = 0
	end

	--Over a pit / in danger w/o enemy
	if not bmogrounded and falling and zdist > 0
	and bmofloor < bmoz - jumpheight * 2
	and (not bai.target or bai.target.player)
	and FixedHypot(dist, zdist) > followthres * 2
	and not bot.powers[pw_carry]
		bai.panic = 1
		bai.anxiety = 2 * TICRATE
	end

	--Carry pre-orientation (to avoid snapping leader's camera around)
	if (bot.pflags & PF_CANCARRY) and dist < touchdist * 2
		cmd.angleturn = pcmd.angleturn
		bmo.angle = pmo.angle
	end

	--Being carried?
	if bot.powers[pw_carry]
		bot.pflags = $ | PF_DIRECTIONCHAR --This just looks nicer

		--Override orientation on minecart
		if bot.powers[pw_carry] == CR_MINECART and bmo.tracer
			bmo.angle = bmo.tracer.angle
			bot.aiming = 0
		end

		--Aaahh!
		if bot.powers[pw_carry] == CR_PTERABYTE
			cmd.forwardmove = P_RandomRange(-50, 50)
			cmd.sidemove = P_RandomRange(-50, 50)
			if bai.jump_last
				doabil = -1
			else
				dojump = 1
				doabil = 1
			end
		end

		--Fix silly ERZ zoom tube bug
		if bot.powers[pw_carry] == CR_ZOOMTUBE
			bai.zoom_last = true
		end

		--Override vertical aim if we're being carried by leader
		--(so we're not just staring at the sky looking up - in fact, angle down a bit)
		if bmo.tracer == pmo and not bai.target
			bot.aiming = R_PointToAngle2(0, 16 * scale, 32 * scale, bmo.momz)
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
		and bmo.tracer == pmo and (bmom < minspeed * 2
			or bmo.momz * flip < -minspeed)
		and leader.powers[pw_tailsfly] < TICRATE / 2
		and falling
		and not (bmo.eflags & MFE_GOOWATER)
			dojump = 1
			bai.flymode = 1
		--Peace out!
		elseif bmo.tracer == pmo
		and bmo.momz * flip < -minspeed * 2
			dojump = 1
		end
	--Fix silly ERZ zoom tube bug
	elseif bai.zoom_last
		cmd.forwardmove = 0
		cmd.sidemove = 0
		bai.zoom_last = nil
	end

	--Check boredom, carried down the leader chain
	--Also force idle if waiting around for minecarts
	if leader.ai and leader.ai.idlecount
		bai.idlecount = max($ + 1, leader.ai.idlecount)
	elseif leader.powers[pw_carry] == CR_MINECART
	and bot.powers[pw_carry] != CR_MINECART
		bai.idlecount = max($ + 1, 100 * TICRATE)
	elseif pcmd.buttons == 0 and pmag == 0
	and (bai.bored or (bmogrounded and bspd < scale))
		bai.idlecount = $ + 1

		--Aggressive bots get bored slightly faster
		if ignoretargets < 3
		and BotTime(bai, 1, 3)
			bai.idlecount = $ + 1
		end
	else
		bai.idlecount = 0
	end
	if bai.idlecount > (8 + bai.timeseed / 24) * TICRATE
		if not bai.bored
			bai.bored = 88 --Get a new bored behavior
		end
	else
		bai.bored = 0
	end

	--Swap characters!?
	--Reset to preferred character if swapped w/ other AI
	if bot.ai_swapchar
	and bot.ai_swapchar.valid
	and bot.ai_swapchar.ai
	and not bot.ai_swapchar.ai.cmd_time
	and BotTimeExact(bai, TICRATE)
		SwapCharacter(bot, bot.ai_swapchar)
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

			--Do superfly on gold arrow only (Tails AI toggles between them)
			if bai.overlay and bai.overlay.valid
			and bai.overlay.colorized
				bai.flymode = 3
			else
				bai.flymode = 1
			end
		end
		--Check positioning
		--Thinker for co-op fly
		if not (bai.bored or bai.drowning)
		and dist < touchdist / 2
		and abs(zdist) < (pmo.height + bmo.height) / 2
		and bmogrounded and (pmogrounded or bai.thinkfly)
		and not ((bot.pflags | leader.pflags) & (PF_STASIS | PF_SPINNING))
		and not (pspd or bspd or leader.spectator)
		and (ability == CA_FLY or SuperReady(bot))
			bai.thinkfly = 1

			--Tell leader bot to stand still this frame
			--(should be safe since they think first)
			if leader.ai and not leader.ai.stalltics
			and not leader.ai.cmd_time --Oops
				pcmd.forwardmove = 0
				pcmd.sidemove = 0
			end
		else
			bai.thinkfly = 0
		end
		--Ready for takeoff
		if bai.flymode == 1
			bai.thinkfly = 0
			dojump = 1
			--Make sure we're not too high up
			if zdist < -pmo.height
				doabil = -1
			elseif falling
			or pmo.momz * flip < 0
			or zdist > hintdist
				doabil = 1
			end
			bmo.angle = pmo.angle

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
			if pcmd.buttons & BT_SPIN
				doabil = -1
			else
				doabil = 1
			end
			bmo.angle = pmo.angle
			bot.aiming = R_PointToAngle2(0, 16 * scale, 32 * scale, bmo.momz)

			--End flymode
			if not leader.powers[pw_carry]
				bai.flymode = 0
			end
		--Super!
		elseif bai.flymode == 3
			bai.thinkfly = 0
			if zdist > -hintdist
				dojump = 1
			end
			if bshield
				S_StartSound(bmo, sfx_shldls)
				P_RemoveShield(bot)
				bot.powers[pw_flashing] = max($, TICRATE)
			end
			if isjump and falling
				dodash = 1
				bai.flymode = 0
			end
		end
	else
		bai.flymode = 0
		bai.thinkfly = 0
	end

	--********
	--SPINNING
	if not (bai.panic or bai.flymode or bai.target)
	and (leader.pflags & PF_SPINNING)
	and (isdash or not (leader.pflags & PF_JUMPED))
		--Allow followers to also spin, even if we aren't
		if ability2 != CA2_SPINDASH
			bai.busy = true

			--Also trail behind a little
			cmd.forwardmove, cmd.sidemove =
				DesiredMove(bot, bmo, pmo, dist, followthres, 0, 0, pfac, _2d)
			bai.spinmode = 0
		--Spindash
		elseif leader.dashspeed > 0
			if dist > touchdist and not isdash --Do positioning
				--Same as our normal follow DesiredMove but w/ no mindist / leaddist / minmag
				cmd.forwardmove, cmd.sidemove =
					DesiredMove(bot, bmo, pmo, dist, 0, 0, 0, pfac, _2d)
				bai.spinmode = 0
			else
				bot.pflags = $ | PF_AUTOBRAKE | PF_APPLYAUTOBRAKE
				cmd.forwardmove = 0
				cmd.sidemove = 0
				bmo.angle = pmo.angle

				--Spin if ready, or just delay if not
				if leader.dashspeed > leader.maxdash / 4
				and bmogrounded
					dodash = 1
				end
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
			if bspd > minspeed
			and AbsAngle(bmomang - bmo.angle) < ANGLE_22h
			and (isspin or BotTimeExact(bai, TICRATE / 8))
				dospin = 1
			end
			bai.spinmode = 1
		end
	else
		bai.spinmode = 0
	end

	--Leader pushing against something? Attack it!
	--Here so we can override spinmode
	--Also carry this down the leader chain if one exists
	--Or a spectating leader holding spin against the ground
	--Or someone holding Toss Flag
	if (leader.ai and leader.ai.pushtics > TICRATE / 8)
	or (leader.spectator and (pcmd.buttons & BT_SPIN))
	or pcmd.buttons & BT_TOSSFLAG
		pmag = 50 * FRACUNIT
	end
	if pmag > 45 * FRACUNIT and pspd < pmo.scale / 2
	and not (leader.climbing or bai.flymode)
		if bai.pushtics > TICRATE / 2
			bai.busy = true --Fix derping out if our leader suddenly jumps etc.
			if dist > touchdist and not isdash --Do positioning
			and (not isabil or dist > touchdist * 2)
				--Same as spinmode above
				cmd.forwardmove, cmd.sidemove =
					DesiredMove(bot, bmo, pmo, dist, 0, 0, 0, pfac, _2d)
				bai.targetnosight = 3 * TICRATE --Recall bot from any target
			else
				--Helpmode!
				SetTarget(bai, pmo)
				targetdist = dist
				targetz = zdist

				--Stop and aim at what we're aiming at
				if bspd > scale
					bot.pflags = $ | PF_AUTOBRAKE | PF_APPLYAUTOBRAKE
					cmd.forwardmove = 0
					cmd.sidemove = 0
				else
					cmd.forwardmove = 50
					cmd.sidemove = 0
				end
				bmo.angle = pmo.angle
				bot.pflags = $ & ~PF_DIRECTIONCHAR --Ensure accurate melee

				--Spin! Or melee etc.
				if pmogrounded
				and ability2 != CA2_GUNSLINGER
					--Tap key for non-spin characters
					if ability2 != CA2_SPINDASH
						dospin = 1
					elseif bmogrounded
						dodash = 1
					end
				--Do ability
				else
					dojump = 1
					doabil = 1
				end
				bai.spinmode = 1 --Lock behavior
			end
		else
			bai.pushtics = $ + 1
		end
	elseif bai.pushtics > 0
		bai.busy = true --Fix silly aiming angles
		if isspin
			if isdash
				bmo.angle = pmo.angle
			elseif bmom
				bmo.angle = bmomang
				dospin = 1
			end
			cmd.forwardmove = 50
			cmd.sidemove = 0
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
	and bai.stalltics < TICRATE * 3/4
	and ability2 != CA2_GUNSLINGER
		dodash = 1
	end

	--******
	--FOLLOW
	if not (bai.flymode or bai.spinmode or bai.target or bot.climbing)
		--Bored
		if bai.bored and not (bai.drowning or bai.panic)
		and bot.powers[pw_carry] != CR_MINECART
			local imirror = 1
			if bai.timeseed & 1 --Odd timeseeds idle in reverse direction
				imirror = -1
			end

			--Set movement magnitudes / angle
			--Add a tic to ensure we change angles after behaviors
			if bai.bored > 80
			or BotTimeExact(bai, 2 * TICRATE + 1)
			or (stalled and BotTimeExact(bai, TICRATE / 2 + 1))
				bai.bored = P_RandomRange(-25, 55)
				if P_RandomByte() < 128
					bai.bored = abs($) --Prefer moving toward leader
				end
			end

			--Wander about
			local max = 6 + 255 / bai.timeseed
			if isdash
				cmd.forwardmove = 0
				cmd.sidemove = 0
			elseif bai.bored > 50 --Dance! (if close enough)
				--Retain normal follow movement if too far
				if dist < followthres
					if BotTime(bai, 1, 2)
						imirror = -imirror
					end
					cmd.forwardmove = P_RandomRange(-25, 50) * imirror
					cmd.sidemove = P_RandomRange(-25, 50) * imirror
				end
			elseif BotTime(bai, 1, max)
				cmd.forwardmove = bai.bored
				cmd.sidemove = 0
			elseif BotTime(bai, 2, max)
				cmd.forwardmove = 0
				cmd.sidemove = bai.bored * imirror
			elseif BotTime(bai, 3, max)
			or abs(bai.bored) < 20
				cmd.forwardmove = bai.bored
				cmd.sidemove = bai.bored * imirror
			else
				cmd.forwardmove = 0
				cmd.sidemove = 0
			end

			--Set angle if still
			if not bspd
				bmo.angle = bai.bored * ANGLE_11hh
			end

			--Jump? Do abilities?
			if isabil and abs(bai.bored) < 40
				doabil = 1
			elseif BotTime(bai, 3, max - 1)
				if abs(bai.bored) < 5
				--We want dashing and/or shield abilities, but not super! D'oh
				and not P_SuperReady(bot)
					dospin = 1
					dodash = 1
				elseif abs(bai.bored) < 15
					dojump = 1
					if abs(bai.bored) < 10
					and not bmogrounded and falling
						if BotTime(bai, 2, 4)
						and not P_SuperReady(bot) --Same here
							dodash = 1
						else
							doabil = 1
						end
					end
				end
			end
		--Too far
		elseif bai.panic or dist > followthres
			if CV_AICatchup.value and dist > followthres * 2
			and pspd > bot.normalspeed * 4/5
			and AbsAngle(pmomang - bmomang) <= ANGLE_90
				bot.powers[pw_sneakers] = max($, 1)
			end
		--Water panic?
		elseif bai.drowning
		and dist < followmin
			local imirror = 1
			if bai.timeseed & 1 --Odd timeseeds panic in reverse direction
				imirror = -1
			end
			bmo.angle = $ + ANGLE_45 * imirror
			cmd.forwardmove = 50
		--Hit the brakes?
		elseif dist < touchdist
			bot.pflags = $ | PF_AUTOBRAKE | PF_APPLYAUTOBRAKE
		end
	end

	--*********
	--JUMP
	if not (bai.flymode or bai.spinmode or bai.target or isdash or bot.climbing)
	and (bai.panic or bot.powers[pw_carry] != CR_PLAYER) --Not in player carry state, unless in a panic
	and (bot.powers[pw_carry] != CR_MINECART or BotTime(bai, 1, 16)) --Derpy minecart hack
		--Start jump
		if (zdist > jumpdist
			and ((leader.pflags & (PF_JUMPED | PF_THOKKED))
				or bai.waypoint)) --Following
		or (zdist > jumpheight and bai.panic) --Vertical catch-up
		or (stalled and not bmosloped
			and pmofloor - bmofloor > stepheight)
		or bai.stalltics > TICRATE
		or (isspin and not isjump and bmom
			and (bspd <= max(minspeed, bot.normalspeed / 2)
				or AbsAngle(bmomang - bmo.angle) > ANGLE_157h)) --Spinning
		or ((bai.predictgap & 3 == 3) --Jumping a gap w/ low floor rel. to leader
			and not bot.powers[pw_carry]) --Not in carry state
		or (bai.predictgap & 4) --Jumping out of special stage water
		or bai.drowning == 2
			dojump = 1

			--Force ability getting out of special stage water
			if falling and (bai.predictgap & 4)
				doabil = 1
			end

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
			--Thok / Super Float
			if ability == CA_THOK
				if bot.actionspd > bspd * 3/2
				and (
					dist > followmax / 2
					or ((bai.predictgap & 2)
						and zdist <= stepheight)
				)
					dojump = 1
					if (falling or (dist > followmax and zdist <= 0
							and BotTimeExact(bai, TICRATE / 4)))
					--Mix in fire shield half the time
					and not (
						bshield == SH_FLAMEAURA
						and not isabil and BotTime(bai, 2, 4)
					)
						doabil = 1
					end
				end

				--Super? Use the special float ability in midair too
				if bot.powers[pw_super]
					local isspinabil = isjump and bai.spin_last
					if (isspinabil and zdist > 0)
					or (
						not bmogrounded and falling
						and (
							(bai.panic and zdist > 0)
							or zdist > jumpdist
							or (bai.predictgap & 2)
						)
					)
					or (
						dist > followmax
						and bai.playernosight < TICRATE / 2
					)
						dojump = 1
						if falling or isspinabil
							dodash = 1
						end
					end
				end
			--Fly
			elseif ability == CA_FLY
				if (isabil and zdist > 0)
				or (
					not bmogrounded and falling
					and (
						(bai.panic and zdist > 0)
						or zdist > jumpdist
						or ((bai.predictgap & 2) --Flying over low floor rel. to leader
							and zdist > 0)
					)
				)
				or bai.drowning == 2
					dojump = 1
					if falling or isabil
						doabil = 2 --Can defer to shield double-jump if not anxious
					end
				elseif zdist < -jumpheight * 2
				or (pmogrounded and dist < followthres and zdist < 0)
				or (bmo.eflags & MFE_GOOWATER)
					doabil = -1
				end
			--Glide and climb / Float / Pogo Bounce
			elseif (ability == CA_GLIDEANDCLIMB or ability == CA_FLOAT or ability == CA_BOUNCE)
				if (isabil and zdist > 0)
				or (
					not bmogrounded and falling
					and (
						(bai.panic and zdist > 0)
						or zdist > jumpdist
						or (bai.predictgap & 2)
					)
				)
				or (
					dist > followmax
					and (
						ability != CA_FLOAT
						or bai.playernosight < TICRATE / 2
					)
					and (
						ability != CA_GLIDEANDCLIMB
						or bai.playernosight > TICRATE / 2
					)
				)
				or (
					ability == CA_BOUNCE
					and (
						bai.drowning == 2
						or (isabil and (leader.pflags & PF_THOKKED))
					)
				)
					dojump = 1
					if falling or isabil
						doabil = 2
					end
				end
				if ability == CA_GLIDEANDCLIMB
				and isabil and not bot.climbing
				and (
					dist < followthres
					or (
						zdist > jumpheight * 2
						and AbsAngle(bmomang - bmo.angle) > ANGLE_90
					)
				)
					--Match up angles for better wall linking
					if pmom > scale
						bmo.angle = pmomang
					else
						bmo.angle = pmo.angle
					end
				end
			--Double-jump?
			elseif (ability == CA_DOUBLEJUMP or ability == CA_AIRDRILL)
				if ability == CA_AIRDRILL
				and isabil and zdist < 0
				and dist < touchdist
					doabil = -1
				elseif (isabil and zdist > 0)
				or (
					not bmogrounded and falling
					and (
						(bai.panic and zdist > 0)
						or zdist > jumpdist
						or ((bai.predictgap & 2)
							and zdist > 0)
					)
				)
				or bai.drowning == 2
				or (
					dist > followmax
					and ability != CA_AIRDRILL
				)
					dojump = 1
					if (falling or isabil)
					--Mix in double-jump shields half the time
					and not (
						not isabil and BotTime(bai, 2, 4)
						--and not (bot.charflags & SF_NOJUMPDAMAGE) --2.2.9 all characters now spin
						and (
							bshield == SH_THUNDERCOIN
							or bshield == SH_WHIRLWIND
							or (
								bshield == SH_BUBBLEWRAP
								and bmoz - bmofloor < jumpheight
							)
						)
					)
						doabil = 1
					end
				end
			end

			--Why not fire shield?
			if not (doabil or isabil)
			and bshield == SH_FLAMEAURA
			and (
				dist > followmax / 2
				or ((bai.predictgap & 2)
					and zdist <= stepheight)
			)
				dojump = 1
				if (falling or (dist > followmax and zdist <= 0
						and BotTimeExact(bai, TICRATE / 4)))
					dodash = 1 --Use shield ability
				end
			end
		end
	end

	--Climb controls
	if bot.climbing
		local dmf = zdist
		local dms = dist
		local dmgd = pmogrounded
		if bai.target
			dmf = targetz - bmoz
			dms = targetdist
			dmgd = P_IsObjectOnGround(bai.target)
		end
		--Don't wiggle around if target's off the wall
		if AbsAngle(bmo.angle - ang) < ANGLE_67h
		or AbsAngle(bmo.angle - ang) > ANGLE_112h
			dms = 0
		--Shorthand for relative angles >= 180 - meaning, move left
		elseif ang - bmo.angle < 0
			dms = -$
		end
		if dmgd and AbsAngle(bmo.angle - ang) < ANGLE_67h
			cmd.forwardmove = 50
			cmd.sidemove = 0
		elseif dmgd or FixedHypot(abs(dmf), abs(dms)) > touchdist
			cmd.forwardmove = min(max(dmf / scale, -50), 50)
			cmd.sidemove = min(max(dms / scale, -50), 50)
		else
			cmd.forwardmove = 0
			cmd.sidemove = 0
		end
		if AbsAngle(ang - bmo.angle) > ANGLE_112h
		and (
			bai.target
			or (dist > followthres * 2
				and zdist <= jumpheight * 2)
			or zdist < -jumpheight
		)
			doabil = -1
		end

		--Hold our previous angle when climbing
		bmo.angle = ang
	end

	--Emergency obstacle evasion!
	if bai.waypoint
	and bai.targetnosight > TICRATE
		if BotTime(bai, 2, 4)
			cmd.sidemove = 50
		else
			cmd.sidemove = -50
		end
		if BotTime(bai, 2, 10)
			cmd.forwardmove = -50
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
				bai.attackoverheat = 4 * TICRATE
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
		local maxdist = 256 * scale --Distance to catch up to.
		local mindist = bai.target.radius + bmo.radius + hintdist --Distance to attack from. Gunslingers avoid getting this close
		local targetfloor = FloorOrCeilingZ(bmo, bai.target) * flip
		local attkey = BT_JUMP
		local attack = 0
		local attshield = (bai.target.flags & (MF_BOSS | MF_ENEMY))
			and (bshield == SH_ATTRACT
				or (bshield == SH_ARMAGEDDON and bai.targetcount > 4
					and not (bai.target.flags2 & MF2_FRET)))
		--Rings! And other collectibles
		if (bai.target.type >= MT_RING and bai.target.type <= MT_FLINGBLUESPHERE)
		or bai.target.type == MT_COIN or bai.target.type == MT_FLINGCOIN
		or bai.target.type == MT_FIREFLOWER
		or bai.target.type == MT_STARPOST
		or bai.target.type == MT_TOKEN
		or (bai.target.type >= MT_EMERALD1 and bai.target.type <= MT_EMERALD7)
		or bai.target.info.spawnstate == S_EMBLEM1 --Chaos Mode hack
			--Run into them if within targetfloor vs character standing height
			if bmogrounded
			and targetz - targetfloor < P_GetPlayerHeight(bot)
				attkey = -1
			end
		--Jump for air bubbles! Or vehicles etc.
		elseif bai.target.type == MT_EXTRALARGEBUBBLE
		or bai.target.type == MT_MINECARTSPAWNER
			--Run into them if within height
			if bmogrounded
			and abs(targetz - bmoz) < bmo.height / 2
				attkey = -1
			end
		--Avoid self-tagged CoopOrDie targets
		elseif bai.target.cd_lastattacker
		and bai.target.cd_lastattacker.player == bot
			--Do nothing, default to jump
		--Override if we have an offensive shield or we're rolling out
		elseif attshield
		or bai.target.type == MT_ROLLOUTROCK
			--Do nothing, default to jump
		--If we're invulnerable just run into stuff!
		elseif bmogrounded
		and (bot.powers[pw_invulnerability]
			or bot.powers[pw_super]
			or (bot.dashmode > 3 * TICRATE and (bot.charflags & SF_MACHINE)))
		and (bai.target.flags & (MF_BOSS | MF_ENEMY))
		and abs(targetz - bmoz) < bmo.height / 2
			attkey = -1
		--Fire flower hack
		elseif (bot.powers[pw_shield] & SH_FIREFLOWER)
		and (bai.target.flags & (MF_BOSS | MF_ENEMY | MF_MONITOR))
		and targetdist > mindist
			--Run into / shoot them if within height
			if bmogrounded
			and abs(targetz - bmoz) < bmo.height / 2
				attkey = -1
			end
			if BotTimeExact(bai, TICRATE / 4)
				cmd.buttons = $ | BT_ATTACK
			end
		--Gunslingers shoot from a distance
		elseif ability2 == CA2_GUNSLINGER
			if BotTime(bai, 31, 32) --Randomly (rarely) jump too
			and bmogrounded and not bai.attackwait
			and not bai.targetnosight
				mindist = max($, abs(targetz - bmoz) * 3/2)
				maxdist = max($, 768 * scale) + mindist
				attkey = BT_SPIN
			end
		--Melee only attacks on ground if it makes sense
		elseif ability2 == CA2_MELEE
			if BotTime(bai, 7, 8) --Randomly jump too
			and bmogrounded and abs(targetz - bmoz) < hintdist
				attkey = BT_SPIN --Otherwise default to jump below
				mindist = $ + bmom * 3 --Account for <3 range
			end
		--But other no-jump characters always ground-attack
		elseif bot.charflags & SF_NOJUMPDAMAGE
			attkey = BT_SPIN
			mindist = $ + bmom
		--Finally jump characters randomly spin
		elseif ability2 == CA2_SPINDASH
		and (isspin or bmosloped or BotTime(bai, 1, 8)
			--Always spin spin-attack enemies tagged in CoopOrDie
			or (bai.target.cd_lastattacker --Inferred not us
				and bai.target.info.cd_aispinattack))
		and bmogrounded and abs(targetz - bmoz) < hintdist
			attkey = BT_SPIN
			mindist = $ + bmom * 16

			--Slope hack (always want to dash)
			if bmosloped
				maxdist = $ + targetdist
			end

			--Min dash speed hack
			if targetdist < maxdist
			and bspd <= minspeed
			and (isdash or not isspin)
				mindist = $ + maxdist

				--Halt!
				bot.pflags = $ | PF_AUTOBRAKE | PF_APPLYAUTOBRAKE
				cmd.forwardmove = 0
				cmd.sidemove = 0
			end
		end

		--Don't do gunslinger stuff if jump-attacking etc.
		if ability2 == CA2_GUNSLINGER and attkey != BT_SPIN
		and not bai.attackwait --Gunslingers get special attackwait behavior
			ability2 = nil
		end

		--Stay engaged if already jumped or spinning
		if ability2 != CA2_GUNSLINGER
		and (isjump or isabil or isspin) --isspin infers isdash
			mindist = $ + targetdist
		--Determine if we should commit to a longer jump
		elseif targetdist > maxdist
		or abs(targetz - bmoz) > jumpheight
		or bmom <= minspeed / 2
		or bai.targetjumps > 2
			bai.longjump = 1
		else
			bai.longjump = 0
		end
		if targetz - bmoz > jumpheight + bmo.height
			bai.longjump = 2 --Safe to set midair due to dojump logic
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
		elseif isspin and not (isjump or isdash)
			dojump = 1
		end

		--Gunslingers gets special AI
		if ability2 == CA2_GUNSLINGER
			--Make Fang find another angle after shots
			if bai.attackwait
				dojump = 1
				if ability == CA_BOUNCE
					doabil = 1
				end
				cmd.forwardmove = 15
				if BotTime(bai, 4, 8)
					cmd.sidemove = 50
				else
					cmd.sidemove = -50
				end
			--Too close, back up!
			elseif targetdist < mindist
				if _2d
					if bai.target.x < bmo.x
						cmd.sidemove = 50
					else
						cmd.sidemove = -50
					end
				else
					cmd.forwardmove = -50
				end
			--Leader might be blocking shot
			elseif dist < followthres
			and targetdist >= R_PointToDist2(pmo.x, pmo.y, bai.target.x, bai.target.y)
				cmd.forwardmove = 15
				if BotTime(bai, 4, 8)
					cmd.sidemove = 30
				else
					cmd.sidemove = -30
				end
			--Fire!
			elseif targetdist < maxdist
				attack = 1

				--Halt!
				bot.pflags = $ | PF_AUTOBRAKE | PF_APPLYAUTOBRAKE
				cmd.forwardmove = 0
				cmd.sidemove = 0
			end
		--Other types just engage within mindist
		elseif targetdist < mindist
			attack = 1

			--Hit the brakes?
			if targetdist < bai.target.radius + bmo.radius
				bot.pflags = $ | PF_AUTOBRAKE | PF_APPLYAUTOBRAKE
			end
		end

		--Attack
		if attack
			if attkey == BT_JUMP
			and not isdash --Release charged dash first
				if bmogrounded or bai.longjump
				or (bai.target.height * flip) * 3/4 + targetz - bmoz > 0
					dojump = 1

					--Lock in longjump behavior, even if we leave combat
					if bai.longjump
						bai.predictgap = $ | 8
					end

					--Count targetjumps
					if bmogrounded and not (isjump or isabil)
						bai.targetjumps = $ + 1
					end
				end

				--Bubble shield check!
				if (bshield == SH_ELEMENTAL
					or bshield == SH_BUBBLEWRAP)
				and not bmogrounded
				and (falling or not (bot.pflags & PF_THOKKED))
				and targetdist < bai.target.radius + bmo.radius
				and bai.target.height * flip + targetz - bmoz < 0
				and not (
					--Don't ground-pound self-tagged CoopOrDie targets
					bai.target.cd_lastattacker
					and bai.target.cd_lastattacker.player == bot
					and bshield == SH_ELEMENTAL
				)
					dodash = 1 --Bop!
				--Hammer double-jump hack
				elseif ability == CA_TWINSPIN
				and not isabil and not bmogrounded
				and ((bai.target.flags & (MF_BOSS | MF_ENEMY | MF_MONITOR))
					or bai.target.player)
				and targetdist < bai.target.radius + bmo.radius + hintdist
				and abs(targetz - bmoz) < (bai.target.height + bmo.height) / 2 + hintdist
					doabil = 1
				--Fang double-jump hack
				elseif ability == CA_BOUNCE
				and not bmogrounded and (falling or isabil)
				and (targetz - targetfloor > jumpheight
					or (bai.target.flags & (MF_BOSS | MF_ENEMY | MF_MONITOR)))
				and (
					not (bai.target.flags & (MF_BOSS | MF_ENEMY | MF_MONITOR))
					or (isabil and targetdist < maxdist)
					or targetfloor - bmofloor > jumpheight
					or (
						targetdist < bai.target.radius + bmo.radius + hintdist
						and targetz - bmoz < 0
					)
				)
					doabil = 1
				--Double-jump?
				elseif ability == CA_DOUBLEJUMP
				and (
					isabil
					or (
						not bmogrounded and falling
						and (
							targetz - bmoz > hintdist
							or (
								targetdist > bai.target.radius + bmo.radius + hintdist
								and bmoz - bmofloor < hintdist
							)
						)
					)
				)
					--Mix in double-jump shields half the time
					if not (
						not isabil and BotTime(bai, 2, 4)
						--and not (bot.charflags & SF_NOJUMPDAMAGE) --2.2.9 all characters now spin
						and (
							bshield == SH_THUNDERCOIN
							or (
								bshield == SH_WHIRLWIND
								and not (bai.target.flags & (MF_BOSS | MF_ENEMY))
							)
							or (
								bshield == SH_BUBBLEWRAP
								and bmoz - bmofloor < jumpheight
							)
						)
					)
						doabil = 1
					end
				--Don't do any further abilities on self-tagged CoopOrDie targets
				elseif bai.target.cd_lastattacker
				and bai.target.cd_lastattacker.player == bot
					--Do nothing
				--Maybe fly-attack / evade target?
				elseif ability == CA_FLY
				and not bmogrounded
				and (
					isabil
					or (falling and bai.longjump == 2)
				)
					if targetz - bmoz > bmo.height
					and (dist > touchdist or zdist < -pmo.height) --Avoid picking up leader
					and not (
						(bai.target.flags & (MF_BOSS | MF_ENEMY))
						and (bmo.eflags & MFE_UNDERWATER)
						and not (
							bot.powers[pw_invulnerability]
							or bot.powers[pw_super]
						)
					)
						doabil = 1
					elseif isabil --Also check state since we're doing additional behavior
					and bmo.state >= S_PLAY_FLY
					and bmo.state <= S_PLAY_FLY_TIRED
						if targetfloor < bmofloor + jumpheight
						or not P_IsObjectOnGround(bai.target)
						or (bmo.eflags & MFE_VERTICALFLIP) != (bai.target.eflags & MFE_VERTICALFLIP)
							doabil = -1
						end

						--Back up if too close to enemy
						if targetdist < bai.target.radius + bmo.radius + hintdist * 2
						and (bai.target.flags & (MF_BOSS | MF_ENEMY))
						and not (
							bot.powers[pw_invulnerability]
							or bot.powers[pw_super]
						)
							if _2d
								if bai.target.x < bmo.x
									cmd.sidemove = 50
								else
									cmd.sidemove = -50
								end
							else
								cmd.forwardmove = -50
							end
						end
					end
				--Use offensive shields
				elseif attshield
				and BotTimeExact(bai, TICRATE / 4)
				and not bmogrounded and (falling
					or abs((bai.target.height + hintdist) * flip + targetz - bmoz) < hintdist / 2)
				and targetdist < FixedMul(RING_DIST, scale) --Lock range
					dodash = 1 --Should fire the shield
				--Thok / fire shield hack
				elseif (ability == CA_THOK
					or bshield == SH_FLAMEAURA)
				and not bmogrounded and falling
				and targetdist > bai.target.radius + bmo.radius + hintdist
				and (bai.target.height * flip) / 4 + targetz - bmoz < 0
				and bai.target.height * flip + targetz - bmoz > 0
					--Mix in fire shield half the time if thokking
					if ability != CA_THOK
					or (
						bshield == SH_FLAMEAURA
						--and not (bot.charflags & SF_NOJUMPDAMAGE) --2.2.9 all characters now spin
						and not isabil and BotTime(bai, 2, 4)
					)
						dodash = 1
					else
						doabil = 1
					end
				--Glide / slide hack!
				elseif ability == CA_GLIDEANDCLIMB
				and (
					isabil
					or (
						not bmogrounded and falling
						and targetdist > bai.target.radius + bmo.radius + hintdist
						and targetz - bmoz <= 0
						and (bai.target.height * flip) * 5/4 + targetz - bmoz > 0
					)
				)
					doabil = 1
				--Homing thok?
				elseif ability == CA_HOMINGTHOK
				and BotTimeExact(bai, TICRATE / 4)
				and not bmogrounded and (falling
					or abs((bai.target.height + hintdist) * flip + targetz - bmoz) < hintdist / 2)
				and targetdist < FixedMul(RING_DIST, scale) --Lock range
					doabil = 1
				--Jump-thok?
				elseif ability == CA_JUMPTHOK
				and not bmogrounded and (falling or isabil)
				and (
					(not isabil
						and targetdist > bai.target.radius + bmo.radius + maxdist * 2)
					or (bai.target.height * flip + targetz - bmoz > jumpheight / 2
						and targetdist > bai.target.radius + bmo.radius + hintdist)
				)
					doabil = 1 --Fire shield still used above when appropriate
				--Air drill!?
				elseif ability == CA_AIRDRILL
				and not bmogrounded and (falling or isabil)
					if targetdist > bai.target.radius + bmo.radius + hintdist * 2
					and (
						targetz - bmoz > bmo.height
						or bmoz - bmofloor < hintdist
					)
						doabil = 1
					elseif isabil
					and targetz - bmoz < 0
					and targetdist < bai.target.radius + bmo.radius + hintdist
						doabil = -1
					end
				--Telekinesis!?
				elseif ability == CA_TELEKINESIS
				and not (bmogrounded or isabil)
				and targetdist < 384 * scale
				and (bai.target.flags & (MF_BOSS | MF_ENEMY))
				and not bshield
				and not P_SuperReady(bot) --Would block pulling targets in
					if falling
					and bai.target.height * flip + targetz - bmoz > 0
					and targetz - (bmo.height * flip + bmoz) < 0
						if BotTime(bai, 15, 16)
							dodash = 1
						else
							doabil = 1 --Teehee
						end
					end

					--Halt!
					bot.pflags = $ | PF_AUTOBRAKE | PF_APPLYAUTOBRAKE
					cmd.forwardmove = 0
					cmd.sidemove = 0
				end
			elseif attkey == BT_SPIN
				if ability2 == CA2_SPINDASH and bmogrounded
					--Only spin we're accurately on target, or very close to target
					if bspd > minspeed
					and (
						AbsAngle(bmomang - bmo.angle) < ANGLE_22h / 10
						or targetdist < bai.target.radius + bmo.radius + hintdist
					)
						dospin = 1
					--Otherwise rev a dash (bigger charge when sloped)
					elseif (bmosloped
						and bot.dashspeed < bot.maxdash * 2/3
						--Release if about to slide off slope edge
						and not (bai.predictgap & 1))
					or bot.dashspeed < bot.maxdash / 3
						dodash = 1
					end
				--Make sure we're facing the right way if stand-attacking
				elseif bmogrounded
				and (ability2 == CA2_GUNSLINGER or ability2 == CA2_MELEE)
				and AbsAngle(bot.drawangle - bmo.angle) > ANGLE_45
				and (
					ability2 != CA2_MELEE or bai.target.player
					or targetdist > bai.target.radius + bmo.radius + hintdist
				)
					--Do nothing
				else
					dospin = 1
					dodash = 1

					--Maybe jump-shot for a bit
					if ability2 == CA2_GUNSLINGER
					and BotTime(bai, 4, 48)
						dojump = 1
						bai.longjump = 0
					end
				end
			end
		end

		--Platforming during combat
		if not isdash
		and (
			(isjump and not attack)
			or (stalled and not bmosloped
				and targetfloor - bmofloor > stepheight)
			or bai.stalltics > TICRATE
			or (bai.predictgap & 5) --Jumping a gap / out of special stage water
		)
			dojump = 1

			--Count targetjumps
			if bmogrounded and not (isjump or isabil)
				bai.targetjumps = $ + 1
			end
		end
	end

	--Special action - cull bad momentum w/ force shield or ground-pound
	if isjump and falling
	and not (doabil or isabil)
	and (
		(bshield & SH_FORCE)
		or (
			bshield == SH_ELEMENTAL
			and bmoz - bmofloor < jumpheight
		)
	)
	and bmom > minspeed
	and AbsAngle(bmomang - bmo.angle) > ANGLE_157h
		dodash = 1
	end

	--Maybe use shield double-jump?
	--Outside of dojump block for whirlwind shield (should be safe)
	if not bmogrounded and falling
	and not ((doabil and (doabil != 2 or bai.anxiety))
		or isabil or bot.climbing)
	and not bot.powers[pw_carry]
	and (
		bshield == SH_THUNDERCOIN
		or bshield == SH_WHIRLWIND
		or (
			bshield == SH_BUBBLEWRAP
			and bmoz - bmofloor < jumpheight
		)
	)
	and (
		(
			--In combat - no whirlwind shield
			bai.target and not bai.target.player
			--and not (bot.charflags & SF_NOJUMPDAMAGE) --2.2.9 all characters now spin
			and not (
				--We'll allow whirlwind for ring etc. collection though
				bshield == SH_WHIRLWIND
				and (bai.target.flags & (MF_BOSS | MF_ENEMY))
			)
			and (
				targetz - bmoz > hintdist
				or (
					targetdist > bai.target.radius + bmo.radius + hintdist
					and bmoz - bmofloor < hintdist
				)
			)
		)
		or (
			--Out of combat - any shield
			(not bai.target or bai.target.player)
			and (
				zdist > jumpdist --Double-jump
				or ((bai.predictgap & 2)
					and zdist > 0)
				or bai.drowning == 2
				or dist > followmax
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
		or (bot.powers[pw_carry] and not bai.jump_last) --Being carried?
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
	and not (
		ability == CA_FLY --Flight input check
		and not (bot.charflags & SF_MULTIABILITY)
		and (bai.jump_last or (isabil and bot.fly1))
	)
		cmd.buttons = $ | BT_JUMP
	--"Force cancel" ability
	elseif doabil < 0
	and (
		(ability == CA_FLY and isabil --If flying, descend
			and bmo.state >= S_PLAY_FLY --Oops
			and bmo.state <= S_PLAY_FLY_TIRED)
		or (ability == CA_AIRDRILL and isabil --If arcing, descend
			and not P_SuperReady(bot)) --Can still be triggered in drill state
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
		cmd.buttons = $ | BT_SPIN
	end

	--Charge spindash
	if dodash
	and (
		not bmogrounded --Flight descend / alt abilities / transform / etc.
		or isdash --Already spinning
		or (bspd < 2 * scale --Spin only from standstill
			and not bai.spin_last)
	)
		cmd.buttons = $ | BT_SPIN
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
		bai.playernosight = 0 --Don't spawn waypoints or try to teleport
		bai.stalltics = $ + 1
		cmd.buttons = $ & ~BT_JUMP
		if leader.playerstate == PST_LIVE
		and (
			bmoz - bmofloor < 0
			or bai.stalltics > 6 * TICRATE
		)
		and not bai.jump_last
			cmd.buttons = $ | BT_JUMP
		end
	end

	--In Stasis? (e.g. OLDC Voting, or strange pw_nocontrol mechanics)
	if (bot.pflags & PF_FULLSTASIS) or bot.powers[pw_nocontrol]
		cmd.buttons = pcmd.buttons --Just copy leader buttons
	end

	--Fix 2.2.10 oddity where headless clients don't generate angleturn or aiming
	if cmd.angleturn != pcmd.angleturn --Oops, check for leader carry
		cmd.angleturn = bmo.angle >> 16
	end
	cmd.aiming = bot.aiming >> 16

	--*******
	--History
	if cmd.buttons & BT_JUMP
		bai.jump_last = 1
	else
		bai.jump_last = 0
	end
	if cmd.buttons & BT_SPIN
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
	if bai.thinkfly == 1
		if not (bai.overlay and bai.overlay.valid)
			bai.overlay = P_SpawnMobj(bmo.x, bmo.y, bmo.z, MT_OVERLAY)
			bai.overlay.target = bmo
			bai.overlay.state = S_FLIGHTINDICATOR
			bai.overlaytime = TICRATE
		end
		if SuperReady(bot)
		and (ability != CA_FLY or bai.overlaytime % (2 * TICRATE) < TICRATE)
			bai.overlay.colorized = true
			bai.overlay.color = SKINCOLOR_YELLOW
		elseif bai.overlay.colorized
			bai.overlay.colorized = false
			bai.overlay.color = SKINCOLOR_NONE
		end
		bai.overlaytime = $ + 1
	elseif bai.overlay
		bai.overlay = DestroyObj($)
	end

	--Debug
	if CV_AIDebug.value > -1
	and CV_AIDebug.value == #bot
		local fight = 0
		local helpmode = 0
		if bai.target and bai.target.valid
			if bai.target.player
				helpmode = 1
			else
				fight = 1
			end
		end
		local p = "follow"
		if bai.thinkfly then p = "thinkfly"
		elseif bai.flymode then p = "flymode " .. bai.flymode
		elseif helpmode then p = "\x81" + "helpmode"
		elseif bai.target and bai.targetnosight then p = "\x84" + "tgtnosight " + bai.targetnosight
		elseif fight then p = "\x83" + "fight"
		elseif bai.targetnosight then p = "\x86" + "wptnosight " + bai.targetnosight
		elseif bai.playernosight then p = "\x87" + "plrnosight " + bai.playernosight
		elseif dist > followthres then p = "follow (far)"
		elseif dist < followmin then p = "follow (close)" end
		local p2 = ""
		if bai.attackwait then p2 = $ .. "\x86" .. "attackwait " end
		if bai.spinmode then p2 = $ .. "spinmode " + bot.dashspeed / FRACUNIT + " " end
		if bai.drowning then p2 = $ .. "\x85" .. "drowning " .. bai.drowning .. " " end
		if bai.bored then p2 = $ .. "\x86" .. "bored " .. bai.bored .. " " end
		if bai.panic then p2 = $ .. "\x85" .. "panic " + bai.anxiety .. " "
		elseif bai.anxiety then p2 = $ .. "\x82" .. "anxiety " + bai.anxiety .. " " end
		if bai.doteleport then p2 = $ .. "\x84" .. "teleport! " end
		if bai.teleporttime then p2 = $ .. "\x86" .. "teleporttime " .. bai.teleporttime end
		--AI States
		hudtext[1] = p
		hudtext[2] = p2
		--Distance
		hudtext[3] = "dist " + dist / scale + "/" + followmax / scale
		if dist > followmax then hudtext[3] = "\x85" .. $ end
		hudtext[4] = "zdist " + zdist / scale + "/" + jumpheight / scale
		if zdist > jumpheight then hudtext[4] = "\x85" .. $ end
		--Physics and Action states
		if isabil then isabil = 1 else isabil = 0 end
		if (bot.pflags & PF_SHIELDABILITY) then isabil = $ + 2 end
		hudtext[5] = "jasd \x86" + min(isjump,1)..isabil..min(isspin,1)..min(isdash,1) + "\x80|" + dojump..doabil..dospin..dodash
		hudtext[6] = "gap " + bai.predictgap + " stl " + bai.stalltics
		--Inputs
		hudtext[7] = "FM " + cmd.forwardmove + " SM " + cmd.sidemove
		if bot.pflags & PF_APPLYAUTOBRAKE then hudtext[7] = "\x86" .. $ .. " *" end
		hudtext[8] = "Jmp " + (cmd.buttons & BT_JUMP) / BT_JUMP + " Spn " + (cmd.buttons & BT_SPIN) / BT_SPIN
		--Target
		if fight
			hudtext[9] = "\x83" + "target " + #bai.target.info + " - " + string.gsub(tostring(bai.target), "userdata: ", "")
				+ " " + bai.targetcount + " " + targetdist / scale
		elseif helpmode
			hudtext[9] = "\x81" + "target " + #bai.target.player + " - " + ShortName(bai.target.player)
		else
			hudtext[9] = "leader " + #bai.leader + " - " + ShortName(bai.leader)
			if bai.leader != bai.realleader and bai.realleader and bai.realleader.valid
				hudtext[9] = $ + " \x86(" + #bai.realleader + " - " + ShortName(bai.realleader) + ")"
			end
		end
		--Waypoint?
		if bai.waypoint
			hudtext[10] = ""
			hudtext[11] = "waypoint " + string.gsub(tostring(bai.waypoint), "userdata: ", "")
			if bai.waypoint.ai_type
				hudtext[11] = "\x87" + $
			else
				hudtext[11] = "\x86" + $
			end
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
		--Handle bots
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

		--Handle follower cycling?
		--(may also apply to player-controlled bots)
		if player.ai_followers or player.ai_picktarget
			LeaderPreThinkFrameFor(player)
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

--Handle MapLoad for bots
addHook("MapLoad", function(mapnum)
	for player in players.iterate
		if player.ai
			--Fix bug where "real" ring counts aren't reset on map change
			player.ai.syncrings = false
		end
	end

	--Set stage vars
	isspecialstage = G_IsSpecialStage(mapnum)
end)

--Handle damage for bots (simple "ouch" instead of losing rings etc.)
local function NotifyLoseShield(bot, basebot)
	--basebot nil on initial call, but automatically set after
	if bot != basebot
		if bot.ai_followers
			for _, b in ipairs(bot.ai_followers)
				NotifyLoseShield(b, basebot or bot)
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
			CV_AIHurtMode.value == 0
			or (
				CV_AIHurtMode.value == 1
				and not target.player.powers[pw_shield]
			)
		)
			S_StartSound(target, sfx_shldls)
			P_DoPlayerPain(target.player, source, inflictor)
			return true
		--Handle shield loss if ai_hurtmode off
		elseif CV_AIHurtMode.value == 0
		and not target.player.ai
		and not target.player.powers[pw_shield]
			NotifyLoseShield(target.player)
		end
	end
end, MT_PLAYER)

--Handle special stage damage for bots
addHook("ShouldDamage", function(target, inflictor, source, damage, damagetype)
	if isspecialstage
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
		Teleport(target.player, false)
		return false
	end
end, MT_PLAYER)

--Handle death for bots
addHook("MobjDeath", function(target, inflictor, source, damagetype)
	--Handle shield loss if ai_hurtmode off
	if CV_AIHurtMode.value == 0
	and target.player and target.player.valid
	and not target.player.ai
		NotifyLoseShield(target.player)
	end
end, MT_PLAYER)

--Handle pickup rules for bots
local function CanPickupItem(leader)
	--Allow pickups if leader is dead, oops
	return not (leader.mo and leader.mo.valid and leader.mo.health > 0)
		or P_CanPickupItem(leader)
end
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
	and not CanPickupItem(GetTopLeader(toucher.player.ai.leader, toucher.player))
		return true
	end
end
addHook("TouchSpecial", CanPickup, MT_FLINGRING)
addHook("TouchSpecial", CanPickup, MT_FLINGCOIN)

--Handle (re)spawning for bots
addHook("PlayerSpawn", function(player)
	if player.ai
		--Fix resetting leader's rings to our startrings
		player.ai.lastrings = player.rings

		--Fix spectators not resetting some vars due to reduced AI
		if player.spectator
			ResetAI(player.ai)
		end

		--Queue teleport to player, unless we're still in sight
		--Check leveltime to only teleport after we've initially spawned in
		if leveltime
			player.ai.playernosight = 3 * TICRATE

			--Do an immediate teleport if necessary
			if player.ai.teleporttime > 3 * TICRATE
				player.ai.teleporttime = 0
				Teleport(player, false)
			end
		end
	elseif not player.jointime
	and CV_AIDefaultLeader.value >= 0
	and CV_AIDefaultLeader.value != #player
		--Defaults to no ai/leader, but bot will sort itself out
		PreThinkFrameFor(player)
	end
end)

--Handle joining players
addHook("PlayerJoin", function(playernum)
	--Kick most recent headless bot if too many and we're trying to reserve a slot
	if netgame and CV_AIReserveSlot.value
	and PlayerCount() >= CV_MaxPlayers.value - 1
		local bestbot = nil
		for player in players.iterate
			if player.ai
			and (player.ai.ronin or player.ai_owner)
			and (
				not (bestbot and bestbot.valid)
				or player.jointime < bestbot.jointime
			)
				bestbot = player
			end
		end
		if bestbot and bestbot.valid
			if bestbot.ai_owner and bestbot.ai_owner.valid
				ConsPrint(bestbot.ai_owner, "Server full - removing most recent bot to make room for new players")
			end
			RemoveBot(server, #bestbot)
		end
	end
end)

--Handle sudden quitting for bots
addHook("PlayerQuit", function(player, reason)
	if player.ai
		DestroyAI(player)
	end

	--Unregister ourself from player owner
	UnregisterOwner(player.ai_owner, player)

	--Kick all owned bots
	while player.ai_ownedbots
	and player.ai_ownedbots[1]
	and player.ai_ownedbots[1].valid
		RemoveBot(player, #player.ai_ownedbots[1])
		UnregisterOwner(player, player.ai_ownedbots[1]) --Just in case
	end
end)

--SP Only: Handle (re)spawning for bots
addHook("BotRespawn", function(pmo, bmo)
	--Allow game to reset SP bot as normal if player-controlled or dead
	if CV_ExAI.value == 0
	or not (server and server.valid) or server.exiting --Derpy hack as only mobjs are passed in
	or not (bmo.player and bmo.player.valid and bmo.player.ai)
		return
	--Treat BOT_MPAI as a normal player
	elseif bmo.player.bot == BOT_MPAI
		return false
	--Just destroy AI if dead, since SP bots don't get a PlayerSpawn event on respawn
	--This resolves ring-sync issues on respawn and probably other things too
	elseif bmo.player.playerstate == PST_DEAD
		DestroyAI(bmo.player)
	end
	return false
end)

--SP Only: Delegate SP AI to foxBot
addHook("BotTiccmd", function(bot, cmd)
	--Fix bug where we don't respawn w/ coopstarposts
	if bot.outofcoop
	and bot.ai.leader.starpostnum != bot.starpostnum
		if SPBot(bot)
			DestroyAI(bot)
		end
		bot.outofcoop = false
		bot.playerstate = PST_REBORN
		return true
	end

	--Treat BOT_MPAI as a normal player
	if bot.bot == BOT_MPAI
		--Except fix weird starpostnum bug w/ coopstarposts
		if CV_CoopStarposts.value
		and bot.ai
		and bot.ai.leader
		and bot.ai.leader.valid
			bot.starpostnum = max($, bot.ai.leader.starpostnum)
		end
		return true
	end

	--Fix issue where SP bot grants early perfect bonus
	if not (server and server.valid) or server.exiting
		bot.rings = 0
		if bot.ai
			bot.ai.lastrings = 0
			DestroyAI(bot)
		end
		return
	end

	--Bail if no AI
	--Also fix botleader getting reset on map change etc. due to blocking normal AI
	if CV_ExAI.value == 0
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
		local leader = GetTopLeader(bot.ai.leader, bot)
		if leader and leader.valid
			local pshield = leader.powers[pw_shield] & SH_NOSTACK
			if leader.powers[pw_shield]
			and pshield != SH_PINK
			and not bot.powers[pw_shield]
			and BotTimeExact(bot.ai, TICRATE)
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
	PreThinkFrameFor(bot)
	return true
end)

--HUD hook!
hud.add(function(v, stplyr, cam)
	--If not previous text in buffer... (e.g. debug)
	if hudtext[1] == nil
		--And we have HUD enabled...
		if CV_AIShowHud.value == 0
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
				hudtext[1] = "Leading " + ShortName(target)
				if stplyr.ai_picktime
					hudtext[1] = "\x8A" .. $
				end
				if ai and ai.cmd_time
					hudtext[1] = $ .. " \x81(player-controlled)"
				elseif target.realmo and target.realmo.valid and target.realmo.skin
					hudtext[1] = $ .. " \x86(" .. target.realmo.skin .. ")"
				end
				hudtext[2] = nil
			end
		--Or are we a bot?
		elseif ai
			target = ai.leader
			if target and target.valid
				hudtext[1] = "Following " + ShortName(target)
				if target != ai.realleader
				and ai.realleader and ai.realleader.valid
					if ai.realleader.spectator
						hudtext[1] = $ + " \x87(" + ShortName(ai.realleader) + " KO'd)"
					else
						hudtext[1] = $ + " \x83(" + ShortName(ai.realleader) + ")"
					end
				end
				hudtext[2] = nil
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
			hudtext[2] = ""
			if ai.doteleport
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
				if ai.playernosight
					hudtext[3] = "\x87" + $
				end
			end
			hudtext[4] = nil

			if ai.cmd_time > 0
			and ai.cmd_time < 3 * TICRATE
				hudtext[4] = ""
				hudtext[5] = "\x81" + "AI control in " .. ai.cmd_time / TICRATE + 1 .. "..."
				hudtext[6] = nil
			elseif ai != stplyr.ai --Infers ai_picktarget as target
			and CanSwapCharacter(stplyr, target)
				hudtext[4] = ""
				hudtext[5] = "\x81Press \x82[Fire]\x81 to swap characters"
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
local function BotHelp(player, advanced)
	print("\x87 foxBot! v1.6: 2022-04-17")
	print("\x81  Based on ExAI v2.0: 2019-12-31")
	if not advanced
		print("")
		print("\x83 Use \"bothelp 1\" to show advanced commands!")
	end
	if advanced
	or not netgame --Show in menus
	or IsAdmin(player)
		print("")
		print("\x87 SP / MP Server Admin:")
		print("\x80  ai_sys - Enable/Disable AI")
		print("\x80  ai_ignore - Ignore targets? \x86(1 = enemies, 2 = rings / monitors, 3 = all)")
		print("\x80  ai_seekdist - Distance to seek enemies, rings, etc.")
		print("\x80  ai_catchup - Allow AI catchup boost?")
	end
	if advanced
	or (IsAdmin(player) and (netgame or splitscreen))
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
COM_AddCommand("BOTHELP", BotHelp, COM_LOCAL)



--[[
	--------------------------------------------------------------------------------
	INIT ACTIONS
	Actions to take once we've successfully initialized
	--------------------------------------------------------------------------------
]]
BotHelp() --Display help
