--[[
	foxBot v0.Something by fox
	Based heavily on VL_ExAI-v2.lua by CoboltBW: https://mb.srb2.org/showthread.php?t=46020
	Initially an experiment to run bots off of PreThinkFrame instead of BotTickCmd
	This allowed AI to control a real player for use in netgames etc.
	Since they're no longer "bots" to the game, it integrates a few concepts from ClassicCoop-v1.3.lua by FuriousFox: https://mb.srb2.org/showthread.php?t=41377
	Such as ring-sharing, nullifying damage, etc. to behave more like a true SP bot, as player.bot is read-only
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
local CV_AIAttack = CV_RegisterVar({
	name = "ai_attack",
	defaultvalue = "On",
	flags = CV_NETVAR|CV_SHOWMODIF,
	PossibleValue = CV_OnOff
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
	PossibleValue = {MIN = -1, MAX = 31}
})
local CV_AIHurtMode = CV_RegisterVar({
	name = "ai_hurtmode",
	defaultvalue = "0",
	flags = CV_NETVAR|CV_SHOWMODIF,
	PossibleValue = {MIN = 0, MAX = 2}
})

local function ResetAI(ai)
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
	ai.pre_teleport = 0 --Used for pre-teleport effects
	ai.cmd_time = 0 --If > 0, suppress bot ai in favor of player controls
end
local function SetupAI(player)
	--Create ai holding object (and set it up) if needed
	--Otherwise, do nothing
	if not player.ai
		player.ai = {
			--Don't reset these
			leader = nil, --Bot's leader
			lastrings = player.rings, --Last ring count of bot (used to sync w/ leader)
			overlay = nil, --Speech bubble overlay - only (re)create this if needed in think logic
			poschecker = nil, --Position checker (for lack of P_CeilingzAtPos function) - same as above
			pflags = player.pflags, --Original pflags
			ronin = false --Headless bot from disconnected client?
		}
		ResetAI(player.ai)
	end
end
local function DestroyObj(mobj)
	if mobj and mobj.valid
		mobj.state = S_NULL
		if mobj.valid
			P_KillMobj(mobj) --Unsure if needed? But just in case
		end
	end
end
local function Repossess(player)
	--Reset our original analog etc. prefs
	player.pflags = $
		& ~PF_ANALOGMODE | (player.ai.pflags & PF_ANALOGMODE)
		& ~PF_DIRECTIONCHAR | (player.ai.pflags & PF_DIRECTIONCHAR)
		& ~PF_AUTOBRAKE | (player.ai.pflags & PF_AUTOBRAKE)

	--Could cycle chasecam to apply fresh pflags from menu
	--But eh, I'd say changing options while AI-driven is "not supported"
	--COM_BufInsertText(player, "toggle chasecam; toggle chasecam")

	--Destroy our thinkfly overlay if it's around
	DestroyObj(player.ai.overlay)
	player.ai.overlay = nil

	--Destroy our poschecker if it's around
	DestroyObj(player.ai.poschecker)
	player.ai.poschecker = nil

	--Reset anything else
	ResetAI(player.ai)
end
local function DestroyAI(player)
	--Destroy ai holding objects (and all children) if needed
	--Otherwise, do nothing
	if player.ai
		--Reset pflags etc. for player
		Repossess(player)

		--Kick headless bots w/ no client
		--Otherwise they sit and do nothing
		if player.ai.ronin
			player.quittime = 1
		end

		--My work here is done
		player.ai = nil
		collectgarbage()
	end
end

addHook("MapChange", function()
	for player in players.iterate
		if player.ai
			ResetAI(player.ai)
		end
	end
end)

local function ResolvePlayerByNum(num)
	if type(num) != "number"
		num = tonumber(num)
	end
	if num != nil and num >= 0 and num < 32
		return players[num]
	end
	return nil
end
local function GetTopLeader(bot, basebot)
	if bot and bot != basebot and bot.ai
	and bot.ai.leader and bot.ai.leader.valid
		return GetTopLeader(bot.ai.leader, basebot)
	end
	return bot
end
local function SetBot(player, leader, bot)
	local pbot = player
	if bot
		pbot = ResolvePlayerByNum(bot)
	end
	if not (pbot and pbot.valid)
		CONS_Printf(player, "Invalid bot! Please specify a target by number (e.g. from \"nodes\" command)")
		return
	end

	SetupAI(pbot)
	local pleader = ResolvePlayerByNum(leader)
	if GetTopLeader(pleader, pbot) == pbot --Also infers pleader != pbot as base case
		pleader = nil
	end
	if pleader and pleader.valid
		CONS_Printf(player, "Set bot " + pbot.name + " following " + pleader.name)
		if player != pbot
			CONS_Printf(pbot, player.name + " set bot " + pbot.name + " following " + pleader.name)
		end
	elseif pbot.ai.leader
		CONS_Printf(player, "Stopping bot " + pbot.name)
		if player != pbot
			CONS_Printf(pbot, player.name + " stopping bot " + pbot.name)
		end
	else
		CONS_Printf(player, "Invalid target! Please specify a target by number (e.g. from \"nodes\" command)")
		if player != pbot
			CONS_Printf(pbot, player.name + " tried to set invalid target on " + pbot.name)
		end
	end
	pbot.ai.leader = pleader

	--Destroy ai if no leader set
	if pleader == nil
		DestroyAI(pbot)
	end
end
COM_AddCommand("SETBOTA", SetBot, COM_ADMIN)
COM_AddCommand("SETBOT", function(player, leader)
	SetBot(player, leader)
end, 0)

COM_AddCommand("GRANTSHIELD", function(player, bot, shield, inv)
	bot = ResolvePlayerByNum(bot)
	shield = tonumber(shield)
	inv = tonumber(inv)
	if not (bot and shield != nil)
		return
	end
	P_SwitchShield(bot, shield)
	local msg = player.name + " granted " + bot.name + " shield " + shield
	if inv
		bot.powers[pw_invulnerability] = inv
		msg = $ + " invulnerability " + inv
	end
	print(msg)
end, COM_ADMIN)

local function Teleport(bot)
	if not (bot.valid and bot.ai)
	or bot.exiting or (bot.pflags & PF_FULLSTASIS) --Whoops
		return
	end

	--Make sure everything's valid (as this is also called on respawn)
	--Check leveltime to only teleport after we've initially spawned in
	local leader = bot.ai.leader
	if not (leveltime and leader and leader.valid)
		return
	end
	local bmo = bot.mo
	local pmo = leader.mo
	if not (bmo and pmo)
		return
	end

	--Fade out, teleporting after
	if not (bot.ai.pre_teleport or bot.powers[pw_flashing])
		bot.powers[pw_flashing] = TICRATE / 2
		bot.ai.pre_teleport = TICRATE / 2 + 1024
		return
	elseif bot.ai.pre_teleport > 1024
		bot.ai.pre_teleport = $ - 1
		return
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
	bot.powers[pw_underwater] = leader.powers[pw_underwater]
	bot.powers[pw_spacetime] = leader.powers[pw_spacetime]
	bot.powers[pw_gravityboots] = leader.powers[pw_gravityboots]
	bot.powers[pw_nocontrol] = leader.powers[pw_nocontrol]

	P_ResetPlayer(bot)
	bmo.state = S_PLAY_JUMP --Looks/feels nicer
	bot.pflags = $ | PF_JUMPED
	--bmo.momx = pmo.momx --Feels better left alone
	--bmo.momy = pmo.momy
	--bmo.momz = pmo.momz

	P_TeleportMove(bmo, pmo.x, pmo.y, z)
	P_SetScale(bmo, pmo.scale)
	bmo.destscale = pmo.destscale

	--Fade in
	bot.powers[pw_flashing] = TICRATE / 2
	bot.ai.pre_teleport = 0
	bot.ai.panicjumps = 0
end

local function AbsAngle(ang)
	if ang > ANGLE_180
		return InvAngle(ang)
	end
	return ang
end
local function DesiredMove(bmo, pmo, dist, mindist, minmag, speed, grounded, spinning)
	if not dist
		return 0, 0
	end

	--Figure out time to target
	local timetotarget = 0
	if speed
		--Calculate prediction factor based on control state (air, spin)
		local pfac = 2 --General prediction
		if spinning
			pfac = $ * 16 --Taken from 2.2 p_user.c (pushfoward >> 4)
		elseif not grounded
			if spinning
				pfac = $ * 8 --Taken from 2.2 p_user.c (pushfoward >> 3)
			else
				pfac = $ * 4 --Taken from 2.2 p_user.c (pushfoward >> 2)
			end
		end

		--Calculate time, capped to sane values (influenced by pfac)
		--Note this is independent of TICRATE
		timetotarget = FixedDiv(
			min(dist, 256 * FRACUNIT) * pfac,
			max(speed, 32 * FRACUNIT)
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
	local pang = R_PointToAngle2(
		bmo.x,
		bmo.y,
		px,
		py
	)

	--Stop skidding everywhere!
	if grounded and dist > 24 * FRACUNIT
	and AbsAngle(mang - pang) > ANGLE_157h
	and speed >= FixedMul(bmo.player.runspeed / 2, bmo.scale)
		return 0, 0
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

local function FloorOrCeilingZ(bmo, pmo)
	if (bmo.flags2 & MF2_OBJECTFLIP)
	or (bmo.eflags & MFE_VERTICALFLIP)
		return pmo.ceilingz
	end
	return pmo.floorz
end
local function FloorOrCeilingZAtPos(bai, bmo, x, y, z)
	--Work around lack of a P_CeilingzAtPos function
	local pc = bai.poschecker
	if not (pc and pc.valid)
		pc = P_SpawnMobj(x, y, z + bmo.height, MT_OVERLAY)
		bai.poschecker = pc
		pc.target = pc
		pc.state = S_INVISIBLE
		--pc.state = S_FLIGHTINDICATOR
	else
		P_TeleportMove(pc, x, y, z + bmo.height)
	end
	return FloorOrCeilingZ(bmo, pc)
end

local function ValidTarget(bot, leader, target, maxtargetdist, maxtargetz, flip)
	if not (target and target.valid and target.health)
		return false
	end

	--We want an enemy or, if melee, a shieldless friendly to buff
	if not (
		(target.flags & (MF_BOSS | MF_ENEMY))
		and not (target.flags2 & MF2_FRET) --Flashing
		and not (target.flags2 & MF2_BOSSFLEE)
		and not (target.flags2 & MF2_BOSSDEAD)
	) and not (
		bot.charability2 == CA2_MELEE
		and target.player and target.player.valid
		and target.player.charability2 != CA2_MELEE
		and not (target.player.powers[pw_shield] & SH_NOSTACK)
		and P_IsObjectOnGround(target)
	)
		return false
	end

	local bmo = bot.mo
	if bot.charability2 == CA2_GUNSLINGER
		--Gunslingers don't care about targetfloor
		if abs(target.z - bmo.z) > 200 * FRACUNIT
			return false
		end
	elseif abs(FloorOrCeilingZ(bmo, target) * flip - bmo.z * flip) > maxtargetz
		return false
	end

	local pmo = leader.mo
	local dist = R_PointToDist2(
		(bmo.x + pmo.x) / 2,
		(bmo.y + pmo.y) / 2,
		target.x,
		target.y
	)
	if dist > maxtargetdist
		return false
	end

	return true, dist
end

local function PreThinkFrameFor(bot)
	if not (bot.valid and bot.mo and bot.mo.valid)
		return
	end

	--Find a new leader if ours quit
	local bai = bot.ai
	if not (bai and bai.leader and bai.leader.valid)
		local bestleader = -1
		for player in players.iterate
			if GetTopLeader(player, bot) != bot --Also infers player != bot as base case
			--Prefer higher-numbered players to spread out bots more
			and (bestleader < 0 or P_RandomByte() > 127)
				bestleader = #player
			end
		end
		--Override w/ default leader? (if exists)
		if CV_AIDefaultLeader.value >= 0
		and players[CV_AIDefaultLeader.value]
			bestleader = CV_AIDefaultLeader.value
		end
		SetBot(bot, bestleader)
		return
	end
	local leader = bai.leader
	if not (leader.mo and leader.mo.valid)
		return
	end

	--Handle rings here
	--TODO HACK Special stages still have issues w/ ring duplication
	--Note that combi etc. is fine w/ the logic below
	if not G_IsSpecialStage()
		local ringdiff = bot.rings - bai.lastrings
		if ringdiff
			P_GivePlayerRings(leader, ringdiff)

			--Grant a max 1s grace period to leader if hurt
			if ringdiff < 0
			and leader.powers[pw_flashing] < TICRATE
				leader.powers[pw_flashing] = TICRATE
			end
		end
		bot.rings = leader.rings
		bai.lastrings = leader.rings
		bot.lives = leader.lives
	end

	--****
	--VARS
	local bmo = bot.mo
	local pmo = leader.mo
	local pcmd = leader.cmd
	local cmd = bot.cmd

	--Elements
	local flip = 1
	if (bmo.flags2 & MF2_OBJECTFLIP)
	or (bmo.eflags & MFE_VERTICALFLIP)
		flip = -1
	end
	local _2d = twodlevel or (bmo.flags2 & MF2_TWOD)
	local scale = bmo.scale

	--Measurements
	local aggressive = CV_AIAttack.value
	local pmom = FixedHypot(pmo.momx, pmo.momy)
	local bmom = FixedHypot(bmo.momx, bmo.momy)
	local dist = R_PointToDist2(bmo.x, bmo.y, pmo.x, pmo.y)
	local zdist = FixedMul(pmo.z - bmo.z, scale * flip)
	local pfac = 1 --Steps ahead to predict movement
	local xpredict = bmo.momx * pfac + bmo.x
	local ypredict = bmo.momy * pfac + bmo.y
	local zpredict = bmo.momz * pfac + bmo.z
	local predictfloor = FloorOrCeilingZAtPos(bai, bmo, xpredict, ypredict, zpredict) * flip
	local ang = R_PointToAngle2(bmo.x - bmo.momx, bmo.y - bmo.momy, pmo.x, pmo.y)
	local followmax = 1024 * scale --Max follow distance before AI begins to enter "panic" state
	local followthres = 92 * scale --Distance that AI will try to reach
	local followmin = 32 * scale
	local comfortheight = 96 * scale
	local touchdist = 24 * scale
	local bmofloor = FloorOrCeilingZ(bmo, bmo) * flip
	local pmofloor = FloorOrCeilingZ(bmo, pmo) * flip
	local jumpheight = FixedMul(bot.jumpfactor, 96 * scale)
	local ability = bot.charability
	local ability2 = bot.charability2
	local falling = (bmo.momz * flip < 0)
	local predictgap = 0 --Predicts a gap which needs to be jumped
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
	local stalled = bmom --[[+ abs(bmo.momz)]] <= scale and bai.move_last --AI is having trouble catching up
	local targetdist = CV_AISeekDist.value * FRACUNIT --Distance to seek enemy targets
	local pmag = FixedHypot(pcmd.forwardmove * FRACUNIT, pcmd.sidemove * FRACUNIT)
	local dmf, dms = DesiredMove(bmo, pmo, dist, followmin, pmag, bmom, bmogrounded, isspin)

	--Check line of sight to player
	if P_CheckSight(bmo, pmo)
		bai.playernosight = 0
	else
		bai.playernosight = $ + 1
	end

	--And teleport if necessary
	--Also teleport if stuck above/below player (e.g. on FOF)
	if bai.playernosight > 3 * TICRATE
	or (bai.panic and pmogrounded and dist < followthres and abs(zdist) > followmax)
	or bai.panicjumps > 3
		Teleport(bot)
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
		end
		bai.cmd_time = 8 * TICRATE
	end
	if bai.cmd_time > 0
		bai.cmd_time = $ - 1

		--Remember any pflags changes while in control
		bai.pflags = bot.pflags
		return
	end

	--Bail here if AI is off (allows logic above to flow normally)
	if CV_ExAI.value == 0
		return
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
	if bmom > scale and abs(predictfloor - bmofloor) > 24 * scale
		predictgap = 1
	end
	if zdist > -64 * scale and predictfloor - pmofloor < -24 * scale
		predictgap = $ | 2
	end

	if stalled
		bai.stalltics = $ + 1
	else
		bai.stalltics = 0
	end

	--Determine whether to fight
	if bai.panic or bai.spinmode or bai.flymode
		bai.target = nil
	end
	if ValidTarget(bot, leader, bai.target, targetdist, jumpheight, flip)
		if P_CheckSight(bmo, bai.target)
			bai.targetnosight = 0
		else
			bai.targetnosight = $ + 1
			if bai.targetnosight > 2 * TICRATE
				bai.target = nil
			end
		end
		if bai.target
			--Used in fight logic later
			targetdist = R_PointToDist2(bmo.x, bmo.y, bai.target.x, bai.target.y)

			--Override our movement and heading to intercept
			dmf, dms = DesiredMove(bmo, bai.target, targetdist, 0, 0, bmom, bmogrounded, isspin)
			ang = R_PointToAngle2(bmo.x - bmo.momx, bmo.y - bmo.momy, bai.target.x, bai.target.y)
		end
	else
		bai.target = nil
		bai.targetnosight = 0
		bai.targetcount = 0

		--Spread search calls out a bit across bots, based on playernum
		--New target (if any) just gets processed next tic
		if (leveltime + #bot) % TICRATE == TICRATE / 2
		and (aggressive or bai.bored)
		and pmom < leader.runspeed
			local bpx = (bmo.x + pmo.x) / 2
			local bpy = (bmo.y + pmo.y) / 2
			searchBlockmap(
				"objects",
				function(bmo, mo)
					local tvalid, tdist = ValidTarget(bot, leader, mo, targetdist, jumpheight, flip)
					if tvalid and P_CheckSight(bmo, mo)
						targetdist = tdist
						bai.target = mo
						bai.targetcount = $ + 1
					end
				end, bmo,
				bpx - targetdist, bpx + targetdist,
				bpy - targetdist, bpy + targetdist
			)
			if bai.target
				return
			end
		end
	end

	--Set default move here - only overridden when necessary
	cmd.forwardmove = dmf
	cmd.sidemove = dms

	--Check water
	bai.drowning = 0
	if bmo.eflags & MFE_UNDERWATER
		followmin = 48 * scale
		followthres = 48 * scale
		followmax = $ / 2
		if bot.powers[pw_underwater] < 16 * TICRATE
			bai.drowning = 1
			bai.thinkfly = 0
	 		if bot.powers[pw_underwater] < 8 * TICRATE
	 			bai.drowning = 2
	 		end
		end
	end

	--Check anxiety
	if bai.bored
		bai.anxiety = 0
		bai.panic = 0
	elseif dist > followmax --Too far away
	or zdist > comfortheight --Too low
	or stalled --Something in my way!
		bai.anxiety = min($ + 2, 2 * TICRATE)
		if bai.anxiety >= 2 * TICRATE
			bai.panic = 1
		end
	elseif not isjump or dist < followmin
		bai.anxiety = max($ - 1, 0)
		bai.panic = 0
	end

	--Over a pit / In danger
	if bmofloor < pmofloor - comfortheight * 2
	and dist > followthres * 2
		bai.panic = 1
		bai.anxiety = 2 * TICRATE
	end

	--Set carried state (here so orientation is tic-accurate)
	if pmo.tracer == bmo and leader.powers[pw_carry]
		bai.flymode = 2
	end

	--Orientation
	if bai.flymode == 2
		bot.pflags = $ | (leader.pflags & PF_AUTOBRAKE) --Use leader's autobrake settings

		--Allow leader to actually turn us
		cmd.angleturn = pcmd.angleturn
		bmo.angle = pmo.angle
	elseif isdash
		bmo.angle = pmo.angle
	elseif not bot.climbing
	and (
		bai.target
		or dist > followthres
		or not (bot.pflags & PF_GLIDING)
	)
		bmo.angle = ang
	end

	--Being carried?
	if bot.powers[pw_carry]
		bot.pflags = $ | PF_DIRECTIONCHAR --This just looks nicer
	end

	--Check boredom
	if pcmd.buttons == 0 and pcmd.forwardmove == 0 and pcmd.sidemove == 0
	and bmogrounded and (bai.bored or bmom < scale)
	and not (bai.drowning or bai.panic)
		bai.idlecount = $ + 2

		--Aggressive bots get bored slightly faster
		if aggressive
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
	--FLY MODE
	if ability == CA_FLY
		--Update carry state
		--Actually, just let bots carry anyone
		--Only the leader will actually set flymode, which makes sense
		--SP bots still need this set though
		--if bai.flymode
		if bot.bot and isabil
			bot.pflags = $ | PF_CANCARRY
		--else
		--	bot.pflags = $ & ~PF_CANCARRY
		end

		--spinmode check
		if bai.spinmode == 1
			bai.thinkfly = 0
		else
			--Activate co-op flight
			if bai.thinkfly == 1
			and (leader.pflags & PF_JUMPED)
				dojump = 1
				doabil = 1
				bai.flymode = 1
				bai.thinkfly = 0
			end
			--Check positioning
			--Thinker for co-op fly
			if not (bai.bored or bai.drowning)
			and dist < touchdist
			and bmogrounded and pmogrounded
			and not (leader.pflags & PF_STASIS)
			and not (pcmd.forwardmove or pcmd.sidemove)
			and not leader.dashspeed
			and not (pmom or bmom)
				bai.thinkfly = 1
			else
				bai.thinkfly = 0
			end
			--Ready for takeoff
			if bai.flymode == 1
				bai.thinkfly = 0
				if zdist < -64 * scale
				or bmo.momz*flip > scale --Make sure we're not too high up
					doabil = -1
				else
					doabil = 1
				end
				--Abort if player moves away or spins
				if dist > followthres or leader.dashspeed > 0
					bai.flymode = 0
				end
			--Carrying; Read player inputs
			elseif bai.flymode == 2
				cmd.forwardmove = pcmd.forwardmove
				cmd.sidemove = pcmd.sidemove
				if pcmd.buttons & BT_USE
					doabil = -1
				else
					doabil = 1
				end
				--End flymode
				if not leader.powers[pw_carry]
					bai.flymode = 0
				end
			end
		end
		if bai.flymode > 0
		and bmogrounded
		and not (pcmd.buttons & BT_JUMP)
			bai.flymode = 0
		end
	else
		bai.flymode = 0
		bai.thinkfly = 0
	end

	--********
	--SPINNING
	if ability2 == CA2_SPINDASH
		if bai.panic or bai.flymode or bai.target
		or not (leader.pflags & (PF_SPINNING | PF_JUMPED))
			bai.spinmode = 0
		else
			if not _2d
				--Spindash
				if leader.dashspeed
					bot.pflags = $ | PF_AUTOBRAKE --Hit the brakes!
					if dist < followthres and dist > touchdist --Do positioning
						bmo.angle = ang
						cmd.forwardmove = 50
						bai.spinmode = 1
					elseif dist < touchdist
						bmo.angle = pmo.angle
						dodash = 1
						bai.spinmode = 1
					else
						bai.spinmode = 0
					end
				--Spin
				elseif (leader.pflags & PF_SPINNING) and not (leader.pflags & PF_STARTDASH)
					dospin = 1
					dodash = 0
					bmo.angle = ang
					cmd.forwardmove = 50
					bai.spinmode = 1
				else
					bai.spinmode = 0
				end
			--2D mode
			elseif (leader.dashspeed and not bmom)
			or (leader.dashspeed == bot.dashspeed and (leader.pflags & PF_SPINNING))
				dospin = 1
				dodash = 1
				bai.spinmode = 1
			end
		end
	else
		bai.spinmode = 0
	end

	--******
	--FOLLOW
	if not (bai.flymode or bai.spinmode or bai.target or bot.climbing)
		--Bored
		if bai.bored
			local b1 = 256|128|64
			local b2 = 128|64
			local b3 = 64
			cmd.forwardmove = 0
			cmd.sidemove = 0
			if bai.idlecount & b1 == b1
				cmd.forwardmove = 35
				bmo.angle = ang + ANGLE_270
			elseif bai.idlecount & b2 == b2
				cmd.forwardmove = 25
				bmo.angle = ang + ANGLE_67h
			elseif bai.idlecount & b3 == b3
				cmd.forwardmove = 15
				bmo.angle = ang + ANGLE_337h
			else
				bmo.angle = bai.idlecount * (ANG1 / 2)
			end
		--Too far
		elseif bai.panic or dist > followthres
			if CV_AICatchup.value and dist > followthres * 2
			and not bot.powers[pw_sneakers]
				bot.powers[pw_sneakers] = 2
			end
		--Within threshold
		elseif dist > followmin and abs(zdist) < comfortheight * 2
			--Do nothing
		--Below min
		elseif dist < followmin
			if not bai.drowning
				bot.pflags = $ | PF_AUTOBRAKE --Hit the brakes!
			else --Water panic?
				bmo.angle = ang + ANGLE_45
				cmd.forwardmove = 50
			end
		end
	end

	--*********
	--JUMP
	if not (bai.flymode or bai.spinmode or bai.target)
		--Flying catch-up code
		if isabil and ability == CA_FLY
			if zdist > 64 * scale
			or bai.drowning == 2
			or bai.playernosight > 16
			or (predictgap & 2) --Flying over low floor rel. to leader
				doabil = 1
				dojump = 1
			elseif zdist < -256 * scale
				doabil = -1
			end
		end


		--Start jump
		if (zdist > 32 * scale and (leader.pflags & PF_JUMPED)) --Following
		or (zdist > 64 * scale and bai.panic) --Vertical catch-up
		or (bai.stalltics > TICRATE / 2
			and (not bot.powers[pw_carry])) --Not in carry state
		or isspin --Spinning
		or predictgap == 3 --Jumping a gap w/ low floor rel. to leader
		or (predictgap and stalled) --Fallback stuck check
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
		elseif isjump and (zdist > 0 or bai.panic or predictgap or stalled)
			dojump = 1
		end

		--********
		--ABILITIES
		if not bai.target
			--Thok
			if ability == CA_THOK and (bai.panic or dist > followmax / 2)
				dojump = 1
				doabil = 1
			--Fly
			elseif ability == CA_FLY and (bai.drowning == 2 or bai.panic)
				if zdist > 64 * scale
				or bai.drowning == 2
				or bai.playernosight > 16
				or (predictgap & 2) --Flying over low floor rel. to leader
					doabil = 1
					dojump = 1
				elseif zdist < -256 * scale
					doabil = -1
				end
			--Glide and climb / Float
			elseif (ability == CA_GLIDEANDCLIMB or ability == CA_FLOAT)
			and (
				(
					bai.panic --Panic behavior
					and (bmofloor < pmofloor - 64 * scale or (dist > followmax and bai.playernosight > TICRATE / 2))
				)
				or (
					isabil --Using ability
					and (
						(abs(zdist) > 0 and dist > followmax) --Far away
						or (zdist > 0) --Below player
					)
					and not bmogrounded
				)
			)
				dojump = 1
				doabil = 1
				if (dist < followmin and ability == CA_GLIDEANDCLIMB)
					bmo.angle = pmo.angle --Match up angles for better wall linking
				end
			--Pogo Bounce
			elseif (ability == CA_BOUNCE)
			and (
				(
					bai.panic
					and (bmofloor < pmofloor - 96 * scale or dist > followmax)
				)
				or (
					isabil --Using ability
					and (
						(abs(zdist) > 0 and dist > followmax) --Far away
						or (zdist > 0) --Below player
					)
					and not bmogrounded
				)
			)
				dojump = 1
				doabil = 1
			end

			--Why not fire shield?
			if not (doabil or isabil)
			and bot.powers[pw_shield] == SH_FLAMEAURA
			and dist > followmax / 2
				dojump = 1
				dodash = 1 --Use shield ability
			end
		end
	end

	--Climb controls
	if bot.climbing
		if not bai.target and zdist > 0
			cmd.forwardmove = 50
		end
		if bai.stalltics > TICRATE
		or AbsAngle(ang - bmo.angle) > ANGLE_112h
			doabil = -1
		end
	end

	if bai.anxiety and bai.playernosight > TICRATE
		if leveltime % TICRATE
			cmd.sidemove = 50
		else
			cmd.sidemove = -50
		end
	end

	--Gun cooldown for Fang
	if ability2 == CA2_GUNSLINGER and bot.panim == PA_ABILITY2
		bai.attackoverheat = $ + 1
		if bai.attackoverheat > 2 * TICRATE
			bai.attackwait = 1
		end
	elseif bai.attackoverheat > 0
		bai.attackoverheat = $ - 1
	else
		bai.attackwait = 0
	end

	--*******
	--FIGHT
	if bai.target and bai.target.valid
		bot.pflags = $ & ~PF_DIRECTIONCHAR --Use strafing in combat (helps w/ melee etc.)
		local maxdist = 256 * scale --Distance to catch up to.
		local mindist = 128 * scale --Distance to attack from. Gunslingers avoid getting this close
		local attkey = 0
		local attack = 0
		--Override if we have an offensive shield
		local attshield = bot.powers[pw_shield] == SH_ATTRACT
			or (bot.powers[pw_shield] == SH_ARMAGEDDON and bai.targetcount > 2)
		if attshield
			--Do nothing
		--If we're invulnerable just run into stuff!
		elseif bot.powers[pw_invulnerability]
		and abs(bai.target.z - bmo.z) < bmo.height
			attkey = -1
		--Standard fight behavior
		elseif ability2 == CA2_GUNSLINGER --Gunslingers shoot from a distance
			mindist = abs(bai.target.z - bmo.z) * 3/2
			maxdist = max($ + mindist, 512 * scale)
			attkey = BT_USE
		elseif ability2 == CA2_MELEE
			--Only attack on ground if it makes sense
			if bmogrounded
			and (
				bai.target.player
				or abs(bai.target.z - bmo.z) < 16 * scale
			)
				--Otherwise default to jump below
				attkey = BT_USE
			end
		elseif bot.charflags & SF_NOJUMPDAMAGE
			attkey = BT_USE
		end

		--Default to jump if nothing specified
		if not attkey
			attkey = BT_JUMP

			--Jump attack should be timed relative to movespeed
			if bmogrounded
				mindist = min($ / 4 + bmom * 12, maxdist)
			end
		end

		if targetdist < mindist --We're close now
			if ability2 == CA2_GUNSLINGER --Can't shoot too close
				cmd.forwardmove = -50
			else
				attack = 1
			end
		elseif targetdist > maxdist --Too far
			--Do nothing
		else --Midrange
			if ability2 == CA2_GUNSLINGER
				if not bai.attackwait
					attack = 1
				--Make Fang find another angle after shots
				else
					dojump = 1
					if predictfloor - bmofloor > -32 * scale
						if leveltime & (3 * TICRATE)
							cmd.sidemove = 30
						else
							cmd.sidemove = -30
						end
					end
				end
			end
		end
		--Attack
		if attack
			if attkey == BT_JUMP
			and (bmogrounded or (bai.target.height / 2 + bai.target.z - bmo.z) * flip >= 0)
				dojump = 1
			elseif attkey == BT_USE
				dospin = 1
				dodash = 1
			--Use offensive shields
			elseif attshield
			and targetdist < mindist
				dodash = 1 --Should fire the shield
			end

			--Hammer double-jump hack
			if ability2 == CA2_MELEE and attkey == BT_JUMP
			and not isabil and not bmogrounded
			and targetdist < mindist / 2
			and abs(bai.target.z - bmo.z) < mindist / 4
				doabil = 1

				--Need to stop holding the button - should swing next tic
				if bai.jump_last
					bai.jump_last = 0
					cmd.buttons = $ & ~BT_JUMP
					return
				end
			end

			--Bubble shield check!
			if targetdist < mindist / 4
			and (bai.target.z - bmo.z) * flip < 0
			and (
				bot.powers[pw_shield] == SH_ELEMENTAL
				or bot.powers[pw_shield] == SH_BUBBLEWRAP
				or (
					(bot.powers[pw_shield] & SH_FORCE)
					and not (bot.charflags & SF_NOJUMPDAMAGE)
				)
			)
				dodash = 1 --Bop!
			end
		end
		--Platforming during combat
		if bai.stalltics > TICRATE / 2 --Stalled
		or (predictgap & 1) --Jumping a gap
		or (isjump and stalled)
		or (
			ability2 != CA2_GUNSLINGER
			and targetdist < followthres
			and (bai.target.z - bmo.z) * flip > 32 * scale --Target above us
		)
			dojump = 1
		end
	end

	--**********
	--DO INPUTS
	--Jump action
	if dojump
		if (
			(isjump and bai.jump_last and not falling) --Already jumping
			or (bmogrounded and not bai.jump_last) --Not jumping yet
		)
		and not (isabil or bot.climbing) --Not using abilities
			cmd.buttons = $ | BT_JUMP
		elseif bot.climbing --Climb up to position
			cmd.forwardmove = 50
		--Maybe use shield double-jump?
		elseif not bmogrounded and falling
		and not (doabil or isabil)
		and (
			(
				--Can attack w/ thunder shield unless no jump damage
				bot.powers[pw_shield] == SH_THUNDERCOIN
				and (not bai.target or bai.target.player
					or not (bot.charflags & SF_NOJUMPDAMAGE))
			)
			or (
				--Can't attack w/ whirlwind shield
				bot.powers[pw_shield] == SH_WHIRLWIND
				and (not bai.target or bai.target.player)
			)
		)
			dodash = 1 --Use shield double-jump

			--Force alternate control as well, in case we stepped off a ledge
			cmd.buttons = $ | BT_JUMP
		end
	end
	--Ability
	if doabil == 1
		if (
			isabil --Already using ability
			or (isjump and not bai.jump_last) --Jump, released input
		)
		and not bot.climbing --Not climbing
		and not (ability == CA_FLY and bai.jump_last) --Flight input check
			cmd.buttons = $ | BT_JUMP
		elseif bot.climbing --Climb up to position
			cmd.forwardmove = 50
		end
	--"Force cancel" ability
	elseif (doabil == -1)
		and (
			(ability == CA_FLY and isabil) --If flying, descend
			or bot.climbing --If climbing, let go
		)
		if not bai.spin_last
			cmd.buttons = $ | BT_USE
		end
		cmd.buttons = $ & ~BT_JUMP
	end

	--Spin while moving
	if dospin
		if (
			not bmogrounded --For air hammers
			or (
				--Don't spin while stationary
				abs(cmd.forwardmove) + abs(cmd.sidemove) > 0
				and (bmom > scale * 5 or ability2 == CA2_MELEE)
			)
		)
		and not bai.spin_last
			cmd.buttons = $ | BT_USE
		end
	end
	--Charge spindash (spin from standstill)
	if dodash
		if (
			not bmogrounded --Air hammers
			or isdash --Already spinning
			or (bmom < scale and not bai.spin_last) --Spin only from standstill
		)
			cmd.buttons = $ | BT_USE
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
	if FixedHypot(cmd.forwardmove, cmd.sidemove) >= 30
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
	else
		bai.overlay.state = S_NULL
	end

	--Debug
	local debug = CV_AIDebug.value
	if debug > -1 and debug < 32
	and players[debug] == bot
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
		elseif helpmode then p = "helpmode"
		elseif bai.targetnosight then p = "\x82 targetnosight " + bai.targetnosight
		elseif fight then p = "fight"
		elseif bai.drowning then p = "\x85 drowning"
		elseif bai.panic then p = "\x85 panic (anxiety " + bai.anxiety + ")"
		elseif bai.bored then p = "bored"
		elseif bai.thinkfly then p = "thinkfly"
		elseif bai.anxiety then p = "\x82 anxiety " + bai.anxiety
		elseif bai.playernosight then p = "\x82 playernosight " + bai.playernosight
		elseif bai.spinmode then p = "spinmode (dashspeed " + bot.dashspeed / FRACUNIT + ")"
		elseif dist > followthres then p = "follow (far)"
		elseif dist < followmin then p = "follow (close)"
		end
		local dcol = ""
		if dist > followmax then dcol = "\x85" end
		local zcol = ""
		if zdist > comfortheight then zcol = "\x85" end
		--AI States
		print("AI [" + bai.bored..helpmode..fight..bai.attackwait..bai.thinkfly..bai.flymode..bai.spinmode..bai.drowning..bai.anxiety..bai.panic + "] " + p)
		--Distance
		print(dcol + "dist " + dist / scale + "/" + followmax / scale + "  " + zcol + "zdist " + zdist / scale + "/" + comfortheight / scale)
		--Physics and Action states
		print("perf " + isjump..isabil..isspin..isdash + "|" + dojump..doabil..dospin..dodash + "  gap " + predictgap + "  stall " + bai.stalltics)
		--Inputs
		print("FM " + cmd.forwardmove + "	SM " + cmd.sidemove + "	Jmp " + (cmd.buttons & BT_JUMP) / BT_JUMP + "  Spn " + (cmd.buttons & BT_USE) / BT_USE + "  Th " + (bot.pflags & PF_THOKKED) / PF_THOKKED)
	end
end

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

addHook("ShouldDamage", function(target, inflictor, source, damage, damagetype)
	if not (source and source.player)
	and damagetype < DMG_DEATHMASK
	and target.player and target.player.valid
	and target.player.ai
	and target.player.powers[pw_flashing] == 0
	and target.player.rings > 0
	and (
		CV_AIHurtMode.value == 0
		or (
			CV_AIHurtMode.value == 1
			and not target.player.powers[pw_shield]
		)
	)
		S_StartSound(target, sfx_shldls)
		P_DoPlayerPain(target.player)
		return false
	end
end, MT_PLAYER)

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

addHook("BotRespawn", function(player, bot)
	if CV_ExAI.value == 0
		return
	end
	return false
end)
addHook("BotTiccmd", function(bot, cmd)
	if CV_ExAI.value == 0
		return
	end

	--Hook no longer needed once ai set up (PreThinkFrame handles instead)
	if bot.ai
		return true
	end

	--Defaults to no ai/leader, but bot will sort itself out
	PreThinkFrameFor(bot)
	return true
end)



local function BotHelp(player)
	print("\x87 foxBot! - Version 0.Something, 2020/xx/xx",
		"\x81  Based on ExAI - Version 1.0, 2019/12/27",
		"",
		"\x87 SP / MP Server Admin Convars:",
		"\x80  ai_sys - Enable/Disable AI",
		"\x80  ai_attack - Attack enemies?",
		"\x80  ai_seekdist - Distance to attack enemies",
		"",
		"\x87 MP Server Admin Convars:",
		"\x80  ai_catchup - Allow AI catchup boost? (MP only, sorry!)",
		"\x80  ai_keepdisconnected - Allow AI to remain after client disconnect?",
		"\x83   Note: rejointimeout must also be > 0 for this to work!",
		"\x80  ai_defaultleader - Default players to AI following this leader?",
		"\x80  ai_hurtmode - Allow AI to get hurt? (1 = shield loss, 2 = ring loss)",
		"",
		"\x87 SP / MP Client Convars:",
		"\x80  ai_debug - stream local variables and cmd inputs to console?",
		"",
		"\x87 MP Client Commands:",
		"\x80  setbot <playernum> - follow target player by number (e.g. from \"nodes\" command)")
	if not player
		print("", "\x87 Use \"bothelp\" to show this again!")
	end
end
COM_AddCommand("BOTHELP", BotHelp, COM_LOCAL)
BotHelp()
