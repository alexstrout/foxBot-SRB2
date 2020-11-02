--[[
	foxBot v0.Something by fox
	Based heavily on VL_ExAI-v2.lua by CoboltBW: https://mb.srb2.org/showthread.php?t=46020
	Initially an experiment to run bots off of PreThinkFrame instead of BotTickCmd
	This allowed AI to control a real player for use in netgames etc.
	Since they're no longer "bots" to the game, it integrates a few concepts from ClassicCoop-v1.3.lua by FuriousFox: https://mb.srb2.org/showthread.php?t=41377
	Such as ring-sharing, nullifying damage, etc. to behave more like a true SP bot, as player.bot is read-only
]]

local CV_ExAI = CV_RegisterVar{
	name = "ai_sys",
	defaultvalue = "On",
	flags = CV_NETVAR,
	PossibleValue = CV_OnOff
}
local CV_AIDebug = CV_RegisterVar{
	name = "ai_debug",
	defaultvalue = "-1",
	flags = 0,
	PossibleValue = {MIN = -1, MAX = 31}
}
local CV_AISeekDist = CV_RegisterVar{
	name = "ai_seekdist",
	defaultvalue = "512",
	flags = CV_NETVAR,
	PossibleValue = {MIN = 0, MAX = 9999}
}
local CV_AIAttack = CV_RegisterVar{
	name = "ai_attack",
	defaultvalue = "On",
	flags = CV_NETVAR,
	PossibleValue = CV_OnOff
}
local CV_AICatchup = CV_RegisterVar{
	name = "ai_catchup",
	defaultvalue = "Off",
	flags = CV_NETVAR,
	PossibleValue = CV_OnOff
}
local CV_AIKeepDisconnected = CV_RegisterVar{
	name = "ai_keepdisconnected",
	defaultvalue = "On",
	flags = CV_NETVAR,
	PossibleValue = CV_OnOff
}

local function ResetAI(ai)
	ai.jump_last = 0 --Jump history
	ai.spin_last = 0 --Spin history
	ai.move_last = 0 --Directional input history
	ai.anxiety = 0 --Catch-up counter
	ai.panic = 0 --Catch-up mode
	ai.flymode = 0 --0 = No interaction. 1 = Grab Sonic. 2 = Sonic is latched.
	ai.spinmode = 0 --If 1, Tails is spinning or preparing to charge spindash
	ai.thinkfly = 0 --If 1, Tails will attempt to fly when Sonic jumps
	ai.idlecount = 0 --Checks the amount of time without any player inputs
	ai.bored = 0 --AI will act independently if "bored".
	ai.drowning = 0 --AI drowning panic. 2 = Tails flies for air.
	ai.target = nil --Enemy to target
	ai.fight = 0 --Actively seeking/fighting an enemy
	ai.helpmode = 0 --Used by Amy AI to hammer-shield the player
	ai.targetnosight = 0 --How long the target has been out of view
	ai.playernosight = 0 --How long the player has been out of view
	ai.stalltics = 0 --Time that AI has struggled to move
	ai.attackwait = 0 --Tics to wait before attacking again
	ai.attackoverheat = 0 --Used by Fang to determine whether to wait
	ai.lastrings = 0 --Last ring count of bot/leader
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
	if num >= 0 and num < 32
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

local function Teleport(bot)
	if not (bot.valid and bot.ai)
		return
	end

	--Fix bug where respawning in boss grants leader our startrings
	bot.ai.lastrings = bot.rings

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
end
addHook("PlayerSpawn", Teleport)

local function AbsAngle(ang)
	if ang > ANGLE_180
		return InvAngle(ang)
	end
	return ang
end
local function DesiredMove(bmo, pmo, dist, speed, grounded, spinning)
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
			min(dist, 512 * FRACUNIT) * pfac,
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
	)
	local mag = min(pdist, 50 * FRACUNIT)
	return FixedMul(cos(pang), mag) / FRACUNIT, --forwardmove
		FixedMul(sin(pang), -mag) / FRACUNIT --sidemove
end

local function FloorOrCeilingZ(bmo, pmo)
	if bmo.flags2 & MF2_OBJECTFLIP
	or bmo.eflags & MFE_VERTICALFLIP
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

local function PreThinkFrameFor(bot)
	if not (bot.valid and bot.mo)
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
		SetBot(bot, bestleader)
		return
	end
	local leader = bai.leader
	if not leader.mo
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

	--Handle rings here
	--TODO HACK Special stages still have issues w/ ring duplication
	--Note that combi etc. are fine w/ the logic below
	if not G_IsSpecialStage()
		--Need to check both as we may get startrings on respawn
		local ringdiff = bot.rings - max(bai.lastrings, leader.rings)
		if ringdiff > 0
			P_GivePlayerRings(leader, ringdiff)
		end
		bot.rings = leader.rings
		bai.lastrings = leader.rings
		bot.lives = leader.lives
	end

	--****
	--VARS
	local aggressive = CV_AIAttack.value
	local catchup = CV_AICatchup.value
	local bmo = bot.mo
	local pmo = leader.mo
	local pcmd = leader.cmd
	local cmd = bot.cmd

	--Elements
	local water = 0
	if bmo.eflags&MFE_UNDERWATER then water = 1 end
	local flip = 1
	if (bmo.flags2 & MF2_OBJECTFLIP) or (bmo.eflags & MFE_VERTICALFLIP) then
		flip = -1
	end
	local _2d = (bmo.flags2 & MF2_TWOD or twodlevel)
	local scale = bmo.scale

	--Measurements
	local pmom = FixedHypot(pmo.momx,pmo.momy)
	local bmom = FixedHypot(bmo.momx,bmo.momy)
	local dist = R_PointToDist2(bmo.x,bmo.y,pmo.x,pmo.y)
	local zdist = FixedMul(pmo.z-bmo.z,scale*flip)
	local pfac = 1 --Steps ahead to predict movement
	local xpredict = bmo.momx*pfac+bmo.x
	local ypredict = bmo.momy*pfac+bmo.y
	local zpredict = bmo.momz*pfac+bmo.z
	local predictfloor = FloorOrCeilingZAtPos(bai, bmo, xpredict, ypredict, zpredict) * flip
	local ang = R_PointToAngle2(bmo.x-bmo.momx,bmo.y-bmo.momy,pmo.x,pmo.y)
	local followmax = 128*8*scale --Max follow distance before AI begins to enter "panic" state
	local followthres = 92*scale --Distance that AI will try to reach
	local followmin = 32*scale
	local comfortheight = 96*scale
	local touchdist = 24*scale
	local bmofloor = FloorOrCeilingZ(bmo, bmo) * flip
	local pmofloor = FloorOrCeilingZ(bmo, pmo) * flip
	local jumpheight = FixedMul(bot.jumpfactor*10,10*scale)
	local ability = bot.charability
	local ability2 = bot.charability2
	local enemydist = 0
	local enemyang = 0
	local falling = (bmo.momz*flip < 0)
	local predictgap = 0 --Predicts a gap which needs to be jumped
	local isjump = min(bot.pflags&(PF_JUMPED),1) --Currently jumping
	local isabil = min(bot.pflags&(PF_THOKKED|PF_GLIDING|PF_BOUNCING),1) --Currently using ability
	local isspin = min(bot.pflags&(PF_SPINNING),1) --Currently spinning
	local isdash = min(bot.pflags&(PF_STARTDASH),1) --Currently charging spindash
	local bmogrounded = (P_IsObjectOnGround(bmo) and not(bot.pflags&PF_BOUNCING)) --Bot ground state
	local pmogrounded = P_IsObjectOnGround(pmo) --Player ground state
	local dojump = 0 --Signals whether to input for jump
	local doabil = 0 --Signals whether to input for jump ability. Set -1 to cancel.
	local dospin = 0 --Signals whether to input for spinning
	local dodash = 0 --Signals whether to input for spindashing
	local targetfloor = nil
	local stalled = bmom --[[+ abs(bmo.momz)]] < scale and bai.move_last --AI is having trouble catching up
	local targetdist = CV_AISeekDist.value*FRACUNIT --Distance to seek enemy targets
	local dmf, dms = DesiredMove(bmo, pmo, dist, bmom, bmogrounded, isspin)
	local enemydmf, enemydms = 0, 0

	--Check line of sight to player
	if P_CheckSight(bmo,pmo)
		bai.playernosight = 0
	else
		bai.playernosight = $ + 1
	end

	--And teleport if necessary
	--Also teleport if stuck above/below player (e.g. on FOF)
	if bai.playernosight > 96
	or (bai.panic and pmogrounded and dist < followthres and abs(zdist) > followmax)
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

	--Set a few flags AI expects - no analog or autobrake, but do use dchar
	bot.pflags = $
		& ~PF_ANALOGMODE
		| PF_DIRECTIONCHAR
		& ~PF_AUTOBRAKE

	--Gun cooldown for Fang
	if bai.fight == 0 then
		bai.attackoverheat = 0
		bai.attackwait = 0
	end
	if bot.panim == PA_ABILITY2 and ability2 == CA2_GUNSLINGER then
		bai.attackoverheat = $+1
		if bai.attackoverheat > 60 then
			bai.attackwait = 1
		end
	elseif bai.attackoverheat > 0
		bai.attackoverheat = $-1
	else bai.attackwait = 0
	end

	--Predict platforming
	--	1 = predicted gap
	--	2 = predicted low floor relative to leader
	--	3 = both
	if abs(predictfloor-bmofloor) > 24*scale
		then predictgap = 1
	end
	if zdist > -64 * scale and predictfloor - pmofloor < -24 * scale
		predictgap = $ | 2
	end

	bai.helpmode = 0
	--Non-Tails bots are more aggressive
--	if ability != CA_FLY then aggressive = 1 end
	if stalled then bai.stalltics = $+1
	else bai.stalltics = 0
	end
	--Find targets
	if not(bai.anxiety) and (aggressive or bai.bored) then
		searchBlockmap("objects",function (bmo,mo)
			if mo == nil then return end
			if (mo.flags&MF_BOSS or mo.flags&MF_ENEMY) and mo.health
				and P_CheckSight(bmo,mo)
				local dist = R_PointToDist2(bmo.x,bmo.y,mo.x,mo.y)
				if (dist < targetdist)
					and (abs(mo.z - bmo.z) < FRACUNIT*280)
					and (bai.target == nil or not(bai.target.valid)
						or (bai.target.info.spawnhealth > 1)
						or R_PointToDist2(bmo.x,bmo.y,bai.target.x,bai.target.y) > dist
						)
					then
					bai.target = mo
					return
				end
			end
		end,bmo,bmo.x-targetdist,bmo.x+targetdist,bmo.y-targetdist,bmo.y+targetdist)
--		searchBlockmap("objects",function(bmo,fn) print(fn.type) end, bmo)
	end
	if bai.target and bai.target.valid then
		targetfloor = FloorOrCeilingZ(bmo, bai.target) * flip
	end
	--Determine whether to fight
	if bai.panic|bai.spinmode|bai.flymode --If panicking
		or (pmom >= leader.runspeed)
		or not((aggressive|bai.bored|bai.fight) and bai.target and bai.target.valid) --Not ready to fight; target invalid
		or not(bai.target.flags&MF_BOSS or bai.target.flags&MF_ENEMY) --Not a boss/enemy
		or not(bai.target.health) --No health
		or (bai.target.flags2&MF2_FRET or bai.target.flags2&MF2_BOSSFLEE or bai.target.flags2&MF2_BOSSDEAD) --flashing/escape/dead state
		or (abs(targetfloor - bmo.z * flip) > FixedMul(bot.jumpfactor,100*scale) and not (ability2 == CA2_GUNSLINGER)) --Unsafe to attack
		then
		bai.target = nil
		bai.fight = 0
		bai.targetnosight = 0
	else
		enemydist = R_PointToDist2(bmo.x,bmo.y,bai.target.x,bai.target.y)
		if enemydist > targetdist then --Too far
			bai.target = nil
			bai.fight = 0
			bai.targetnosight = 0
		elseif not P_CheckSight(bmo,bai.target) then --Can't see
			bai.targetnosight = $+1
			if bai.targetnosight >= 70 then
				bai.target = nil
				bai.fight = 0
				bai.targetnosight = 0
			end
		else
			enemyang = R_PointToAngle2(bmo.x-bmo.momx,bmo.y-bmo.momy,bai.target.x,bai.target.y)
			enemydmf, enemydms = DesiredMove(bmo, bai.target, enemydist, bmom, bmogrounded, isspin)
			bai.fight = 1
			bai.targetnosight = 0
		end
	end

	--Check water
	bai.drowning = 0
	if (water) then
		followmin = 48*scale
		followthres = 48*scale
		followmax = $/2
		if bot.powers[pw_underwater] < 35*16 then
			bai.drowning = 1
			bai.thinkfly = 0
	 		if bot.powers[pw_underwater] < 35*8 then
	 			bai.drowning = 2
	 		end
		end
	end


	--Check anxiety
	if bai.spinmode or bai.bored or bai.fight then
		bai.anxiety = 0
		bai.panic = 0
	elseif dist > followmax --Too far away
		or zdist > comfortheight --Too high/low
		or stalled --Something in my way!
		then
		bai.anxiety = min($+2,70)
		if bai.anxiety >= 70 then bai.panic = 1 end
	elseif not(bot.pflags&PF_JUMPED) or dist < followmin then
		bai.anxiety = max($-1,0)
		bai.panic = 0
	end
	--Over a pit / In danger
	if bmofloor < pmofloor-comfortheight*2
		and dist > followthres*2 then
		bai.panic = 1
		bai.anxiety = 70
		bai.fight = 0
	end
	--Orientation
	if bot.pflags&PF_SPINNING or bot.pflags&PF_STARTDASH or bai.flymode == 2
		cmd.angleturn = pcmd.angleturn --Allows us to actually turn other player
		bmo.angle = pmo.angle
	elseif not(bot.climbing) and (dist > followthres or not(bot.pflags&PF_GLIDING)) then
		bmo.angle = ang
	end

	--Set default move here - only overridden when necessary
	cmd.forwardmove = dmf
	cmd.sidemove = dms

	--Being carried?
	if bot.powers[pw_carry]
		bot.pflags = $ | PF_DIRECTIONCHAR --This just looks nicer
	elseif bai.flymode == 2
		bot.pflags = $ | (leader.pflags & PF_AUTOBRAKE) --Use leader's autobrake settings
	end

	--Does the player need help?
	if ability2 == CA2_MELEE and not(leader.powers[pw_shield]&SH_NOSTACK or leader.charability2 == CA2_MELEE)
		and not(bai.spinmode|bai.anxiety|bai.panic|bai.fight) and dist < followmax then
		bai.helpmode = 1
	else
		bai.helpmode = 0
	end


	--Check boredom
	if (pcmd.buttons == 0 and pcmd.forwardmove == 0 and pcmd.sidemove == 0)
		and not(bai.drowning|bai.panic|bai.fight|bai.helpmode)
		and bmogrounded
		then
		bai.idlecount = $+1
	else
		bai.idlecount = 0
	end
	if bai.idlecount > 35*8 or (aggressive and bai.idlecount > 35*3) then
		bai.bored = 1
	else
		bai.bored = 0
	end

	--********
	--HELP MODE
	if bai.helpmode
		--cmd.forwardmove = 25
		bot.pflags = $ & ~PF_DIRECTIONCHAR --Use strafing in combat (helps w/ melee etc.)
		bmo.angle = ang
		if dist < scale*64 then
			dospin = 1
			dodash = 1
		end
	end

	--********
	--FLY MODE
	if ability == CA_FLY then
		--Update carry state
		--Actually, just let bots carry anyone
		--Only the leader will actually set flymode, which makes sense
		--SP bots still need this set though
		--if bai.flymode then
		if bot.bot and isabil then
			bot.pflags = $ | PF_CANCARRY
		--else
		--	bot.pflags = $ & ~PF_CANCARRY
		end

		--spinmode check
		if bai.spinmode == 1 then bai.thinkfly = 0
		else
			--Activate co-op flight
			if bai.thinkfly == 1 and leader.pflags&PF_JUMPED then
				dojump = 1
				doabil = 1
				bai.flymode = 1
				bai.thinkfly = 0
			end
			--Check positioning
			--Thinker for co-op fly
			if not(bai.bored) and not(bai.drowning) and dist < followmin --[[touchdist]] and P_IsObjectOnGround(pmo) and P_IsObjectOnGround(bmo)
				and not(leader.pflags&PF_STASIS)
				and pcmd.forwardmove == 0 and pcmd.sidemove == 0
				and leader.dashspeed == 0
				and pmom == 0 and bmom == 0
				then
				bai.thinkfly = 1
			else bai.thinkfly = 0
			end
			--Set carried state
			if pmo.tracer == bmo
				and leader.powers[pw_carry]
				then
				bai.flymode = 2
			end
			--Ready for takeoff
			if bai.flymode == 1 then
				bai.thinkfly = 0
				if zdist < -64 * scale
				or bmo.momz*flip > scale then --Make sure we're not too high up
					doabil = -1
				else
					doabil = 1
				end
				--Abort if player moves away or spins
				if dist > followthres or leader.dashspeed > 0
					bai.flymode = 0
				end
			--Carrying; Read player inputs
			elseif bai.flymode == 2 then
				cmd.forwardmove = pcmd.forwardmove
				cmd.sidemove = pcmd.sidemove
				if pcmd.buttons&BT_USE then
					doabil = -1
				else
					doabil = 1
				end
				--End flymode
				if not(leader.powers[pw_carry])
					then
					bai.flymode = 0
				end
			end
		end
		if bai.flymode > 0 and bmogrounded and not(pcmd.buttons&BT_JUMP)
		then bai.flymode = 0 end
	else
		bai.flymode = 0
		bai.thinkfly = 0
	end

	--********
	--SPINNING
	if ability2 == CA2_SPINDASH then
		if (bai.panic or bai.flymode or bai.fight) or not(leader.pflags&PF_SPINNING) or leader.pflags&PF_JUMPED then bai.spinmode = 0
		else
			if not(_2d)
			--Spindash
				if (leader.dashspeed)
					bot.pflags = $ | PF_AUTOBRAKE --Hit the brakes!
					if dist < followthres and dist > touchdist then --Do positioning
						bmo.angle = ang
						cmd.forwardmove = 50
						bai.spinmode = 1
					elseif dist < touchdist then
						bmo.angle = pmo.angle
						dodash = 1
						bai.spinmode = 1
					else bai.spinmode = 0
					end
				--Spin
				elseif (leader.pflags&PF_SPINNING and not(leader.pflags&PF_STARTDASH)) then
					dospin = 1
					dodash = 0
					bmo.angle = ang
					cmd.forwardmove = 50
					bai.spinmode = 1
				else bai.spinmode = 0
				end
			--2D mode
			else
				if ((leader.dashspeed and bmom == 0) or (leader.dashspeed == bot.dashspeed and leader.pflags&PF_SPINNING))
					then
					dospin = 1
					dodash = 1
					bai.spinmode = 1
				end
			end
		end
	else
		bai.spinmode = 0
	end
	--******
	--FOLLOW
	if not(bai.flymode or bai.spinmode or bai.fight --[[or bai.helpmode]] or bot.climbing) then
		--Bored
		if bai.bored then
			local b1 = 256|128|64
			local b2 = 128|64
			local b3 = 64
			cmd.forwardmove = 0
			cmd.sidemove = 0
			if bai.idlecount&b1 == b1 then
				cmd.forwardmove = 35
				bmo.angle = ang + ANGLE_270
			elseif bai.idlecount&b2 == b2 then
				cmd.forwardmove = 25
				bmo.angle = ang + ANGLE_67h
			elseif bai.idlecount&b3 == b3 then
				cmd.forwardmove = 15
				bmo.angle = ang + ANGLE_337h
			else
				bmo.angle = bai.idlecount*(ANG1/2)
			end
		--Too far
		elseif bai.panic or dist > followthres then
			if catchup and dist > followthres * 2
			and not bot.powers[pw_sneakers]
				bot.powers[pw_sneakers] = 2
			end
			--if not(_2d) then cmd.forwardmove = 50
			--elseif pmo.x > bmo.x then cmd.sidemove = 50
			--else cmd.sidemove = -50 end
		--Within threshold
		elseif not(bai.panic) and dist > followmin and abs(zdist) < 192*scale then
			--if not(_2d) then cmd.forwardmove = FixedHypot(pcmd.forwardmove,pcmd.sidemove)
			--else cmd.sidemove = pcmd.sidemove end
		--Below min
		elseif dist < followmin then
			if not(bai.drowning) then
				bot.pflags = $ | PF_AUTOBRAKE --Hit the brakes!
				--Copy inputs
				--bmo.angle = pmo.angle
				--bot.drawangle = ang
				cmd.forwardmove = pcmd.forwardmove*8/10
				cmd.sidemove = pcmd.sidemove*8/10

				--Maybe back up a little
				if dist < touchdist
				and not cmd.forwardmove
				and not bai.thinkfly
					cmd.forwardmove = -25
				end
			else --Water panic?
				bmo.angle = ang+ANGLE_45
				cmd.forwardmove = 50
			end
		end
	end

	--*********
	--JUMP
	if not(bai.flymode|bai.spinmode|bai.fight) then

		--Flying catch-up code
		if isabil and ability == CA_FLY then
			--cmd.forwardmove = min(50,dist/scale/8)
			if zdist > 64 * scale
			or bai.drowning == 2
			or bai.playernosight > 16
			or predictgap & 2 --Flying over low floor rel. to leader
				doabil = 1
				dojump = 1
			elseif zdist < -256 * scale
				doabil = -1
			end
		end


		--Start jump
		if (
			(zdist > 32*scale and leader.pflags & PF_JUMPED) --Following
			or (zdist > 64*scale and bai.panic) --Vertical catch-up
			or (bai.stalltics > 15
				and (not bot.powers[pw_carry])) --Not in carry state
			or(isspin) --Spinning
			or predictgap == 3 --Jumping a gap w/ low floor rel. to leader
			) then
			dojump = 1
--			print("start jump")

		--Hold jump
		elseif isjump and (zdist > 0 or bai.panic or predictgap or stalled) then
			dojump = 1
--			print("hold jump")
		end

		--********
		--ABILITIES
		if not(bai.fight) then
			--Thok
			if ability == CA_THOK and (bai.panic or dist > followmax)
				then
				dojump = 1
				doabil = 1
			--Fly
			elseif ability == CA_FLY and (bai.drowning == 2 or bai.panic)
				if zdist > 64 * scale
				or bai.drowning == 2
				or bai.playernosight > 16
				or predictgap & 2 --Flying over low floor rel. to leader
					doabil = 1
					dojump = 1
				elseif zdist < -256 * scale
					doabil = -1
				end
			--Glide and climb / Float
			elseif (ability == CA_GLIDEANDCLIMB or ability == CA_FLOAT)
				and (
					(bai.panic --Panic behavior
						and (bmofloor < pmofloor - 64 * scale or (dist > followmax and bai.playernosight > 16))
					)
					or (isabil --Using ability
						and (
							(abs(zdist) > 0 and dist > followmax) --Far away
							or (zdist > 0) --Below player
						)
						and not(bmogrounded)
					)
				)
				then
				dojump = 1
				doabil = 1
				if (dist < followmin and ability == CA_GLIDEANDCLIMB) then
					bmo.angle = pmo.angle --Match up angles for better wall linking
				end
			--Pogo Bounce
			elseif (ability == CA_BOUNCE)
				and (
					(bai.panic and (bmofloor < pmofloor or dist > followthres))
					or (isabil --Using ability
						and (
							(abs(zdist) > 0 and dist > followmax) --Far away
							or (zdist > 0) --Below player
						)
						and not(bmogrounded)
					)
				)
				then
				dojump = 1
				doabil = 1
			end
		end
	end
	--Climb controls
	if bot.climbing
		if not(bai.fight) and zdist > 0
			then cmd.forwardmove = 50
		end
		if (bai.stalltics > 30
		or AbsAngle(ang - bmo.angle) > ANGLE_112h)
			then doabil = -1
		end
	end

	if bai.anxiety and bai.playernosight > 64 then
		if leveltime&(64|32) == 64|32 then
			cmd.sidemove = 50
		elseif leveltime&32 then
			cmd.sidemove = -50
		end
	end

	--*******
	--FIGHT
	if bai.fight then
		bot.pflags = $ & ~PF_DIRECTIONCHAR --Use strafing in combat (helps w/ melee etc.)
		bmo.angle = enemyang
		cmd.forwardmove = enemydmf
		cmd.sidemove = enemydms
		local dist = 128*scale --Distance to catch up to.
		local mindist = 64*scale --Distance to attack from. Gunslingers avoid getting this close
		local attkey = BT_JUMP
		local attack = 0
		--Standard fight behavior
		if ability2 == CA2_GUNSLINGER then --Gunslingers shoot from a distance
			mindist = abs(bai.target.z-bmo.z)*3/2
			dist = max($+mindist,512*scale)
			attkey = BT_USE
		elseif ability2 == CA2_MELEE then
			mindist = 96*scale
			attkey = BT_USE
		elseif bot.charflags&SF_NOJUMPDAMAGE then
			mindist = 128*scale
			attkey = BT_USE
		else --Jump attack should be timed relative to movespeed
			mindist = bmom*10+ 24*scale
		end

		if enemydist < mindist then --We're close now
			if ability2 == CA2_GUNSLINGER then --Can't shoot too close
				cmd.forwardmove = -50
			else
				attack = 1
				--cmd.forwardmove = 20
			end
		elseif enemydist > dist then --Too far
			--cmd.forwardmove = 50
		else --Midrange
			if ability2 == CA2_GUNSLINGER then
				if not(bai.attackwait)
				attack = 1
				--Make Fang find another angle after shots
				else
					dojump = 1
					if predictfloor-bmofloor > -32*scale then
--						bmo.angle = leveltime*FRACUNIT
						if leveltime&128 then cmd.sidemove = 30
						else cmd.sidemove = -30
						end
					end
				end
			--else
			--	cmd.forwardmove = 30 --Moderate speed so we don't overshoot the target
			end
		end
		--Attack
		if attack then
			if (attkey == BT_JUMP and (bmogrounded or (bai.target.height / 3 + bai.target.z-bmo.z)*flip >= 0))
				then dojump = 1
			elseif (attkey == BT_USE)
				then
				dospin = 1
				dodash = 1
			end
		end
		--Platforming during combat
		if (ability2 != CA2_GUNSLINGER and enemydist < followthres and bai.target.z > bmo.z+32*scale) --Target above us
				or (bai.stalltics > 15) --Stalled
				or (predictgap & 1) --Jumping a gap
				or (isjump and stalled)
			then
			dojump = 1
		end
	end

	--**********
	--DO INPUTS
	--Jump action
	if (dojump) then
		if ((isjump and bai.jump_last and not falling) --Already jumping
				or (bmogrounded and not bai.jump_last)) --Not jumping yet
			and not(isabil or bot.climbing) --Not using abilities
			then cmd.buttons = $|BT_JUMP
		elseif bot.climbing then --Climb up to position
			cmd.forwardmove = 50
		end
	end
	--Ability
	if (doabil == 1) then
		if ((isjump and not bai.jump_last) --Jump, released input
				or (isabil)) --Already using ability
			and not(bot.climbing) --Not climbing
			and not(ability == CA_FLY and bai.jump_last) --Flight input check
			then cmd.buttons = $|BT_JUMP
		elseif bot.climbing then --Climb up to position
			cmd.forwardmove = 50
		end
	--"Force cancel" ability
	elseif (doabil == -1)
		and ((ability == CA_FLY and isabil) --If flying, descend
			or bot.climbing) --If climbing, let go
		then
		if not bai.spin_last then
			cmd.buttons = $|BT_USE
		end
		cmd.buttons = $&~BT_JUMP
	end

	--Spin while moving
	if (dospin) then
		if (not(bmogrounded) --For air hammers
				or (abs(cmd.forwardmove)+abs(cmd.sidemove) > 0 and (bmom > scale*5 or ability2 == CA2_MELEE))) --Don't spin while stationary
			and not(bai.spin_last)
			then cmd.buttons = $|BT_USE
		end
	end
	--Charge spindash (spin from standstill)
	if (dodash) then
		if (not(bmogrounded) --Air hammers
				or (bmom < scale and not bai.spin_last) --Spin only from standstill
				or (isdash) --Already spinning
			) then
			cmd.buttons = $|BT_USE
		end
	end

	--*******
	--History
	if (cmd.buttons&BT_JUMP) then
		bai.jump_last = 1
	else
		bai.jump_last = 0
	end
	if (cmd.buttons&BT_USE) then
		bai.spin_last = 1
	else
		bai.spin_last = 0
	end
	if FixedHypot(cmd.forwardmove,cmd.sidemove) >= 30 then
		bai.move_last = 1
	else
		bai.move_last = 0
	end

	--*******
	--Aesthetic
	--thinkfly overlay
	if bai.overlay == nil or bai.overlay.valid == false then
		bai.overlay = P_SpawnMobj(bmo.x, bmo.y, bmo.z, MT_OVERLAY)
		bai.overlay.target = bmo
	end
	if bai.thinkfly == 1 then
		if bai.overlay.state == S_NULL then
			bai.overlay.state = S_FLIGHTINDICATOR
		end
	else bai.overlay.state = S_NULL
	end

	--Debug
	local debug = CV_AIDebug.value
	if debug > -1 and debug < 32
	and players[debug] == bot
		local p = "follow"
		if bai.flymode == 1 then p = "flymode (ready)"
		elseif bai.flymode == 2 then p = "flymode (carrying)"
		elseif bai.helpmode then p = "helpmode"
		elseif bai.targetnosight then p = "\x82 targetnosight " + bai.targetnosight
		elseif bai.fight then p = "fight"
		elseif bai.drowning then p = "\x85 drowning"
		elseif bai.panic then p = "\x85 panic (anxiety " + bai.anxiety + ")"
		elseif bai.bored then p = "bored"
		elseif bai.thinkfly then p = "thinkfly"
		elseif bai.anxiety then p = "\x82 anxiety " + bai.anxiety
		elseif bai.playernosight then p = "\x82 playernosight " + bai.playernosight
		elseif bai.spinmode then p = "spinmode (dashspeed " + bot.dashspeed/FRACUNIT+")"
		elseif dist > followthres then p = "follow (far)"
		elseif dist < followmin then p = "follow (close)"
		end
		local dcol = ""
		if dist > followmax then dcol = "\x85" end
		local zcol = ""
		if zdist > comfortheight then zcol = "\x85" end
		--AI States
		print("AI ["+bai.bored..bai.helpmode..bai.fight..bai.attackwait..bai.thinkfly..bai.flymode..bai.spinmode..bai.drowning..bai.anxiety..bai.panic+"] "+ p)
		--Distance
		print(dcol + "dist " + dist/scale +"/"+ followmax/scale + "  " + zcol + "zdist " + zdist/scale +"/"+ comfortheight/scale)
		--Physics and Action states
		print("perf " + isjump..isabil..isspin..isdash + "|" + dojump..doabil..dospin..dodash + "  gap " + predictgap + "  stall " + bai.stalltics)
		--Inputs
		print("FM "+cmd.forwardmove + "  SM " + cmd.sidemove+"	Jmp "+(cmd.buttons&BT_JUMP)/BT_JUMP+"  Spn "+(cmd.buttons&BT_USE)/BT_USE+ "  Th "+(bot.pflags&PF_THOKKED)/PF_THOKKED)
	end
end

addHook("PreThinkFrame", function()
	if CV_ExAI.value == 0
		return
	end
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
		S_StartSound(target, sfx_shldls)
		P_DoPlayerPain(target.player)
		return false
	end
end, MT_PLAYER)

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
		"\x80   Note: rejointimeout must also be > 0 for this to work!",
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
