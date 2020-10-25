--foxBot v0.Something by fox
--Based heavily on VL_ExAI-v2.lua by CoboltBW: https://mb.srb2.org/showthread.php?t=46020
--Initially an experiment to run bots off of PreThinkFrame instead of BotTickCmd
--This allowed AI to control a real player for use in netgames etc.
--Since they're no longer "bots" to the game, it integrates a few concepts from ClassicCoop-v1.3.lua by FuriousFox: https://mb.srb2.org/showthread.php?t=41377
--Such as ring-sharing, nullifying damage, etc. to behave more like a true SP bot, as player.bot is read-only

local CV_ExAI = CV_RegisterVar{
	name = 'ai_sys',
	defaultvalue = 'On',
	flags  = 0,
	PossibleValue = CV_OnOff
}
local CV_AIDebug = CV_RegisterVar{
	name = 'ai_debug',
	defaultvalue = 'Off',
	flags  = 0,
	PossibleValue = CV_OnOff
}
local CV_AISeekDist = CV_RegisterVar{
	name = 'ai_seekdist',
	defaultvalue = '512',
	flags = 0,
	PossibleValue = {MIN = 0, MAX = 9999}
}
local CV_AIAttack = CV_RegisterVar{
	name = 'ai_attack',
	defaultvalue = 'On',
	flags = 0,
	PossibleValue = CV_OnOff
}

local jump_last = 0 --Jump history
local spin_last = 0 --Spin history
local move_last = 0 --Directional input history
local anxiety = 0 --Catch-up counter
local panic = 0 --Catch-up mode
local flymode = 0 --0 = No interaction. 1 = Grab Sonic. 2 = Sonic is latched.
local spinmode = 0 --If 1, Tails is spinning or preparing to charge spindash
local thinkfly = 0 --If 1, Tails will attempt to fly when Sonic jumps
local idlecount = 0 --Checks the amount of time without any player inputs
local bored = 0 --AI will act independently if "bored".
local drowning = 0 --AI drowning panic. 2 = Tails flies for air.
local overlay = nil --Speech bubble overlay
local target = nil --Enemy to target
local fight = 0 --Actively seeking/fighting an enemy
local helpmode = 0 --Used by Amy AI to hammer-shield the player
local targetnosight = 0 --How long the target has been out of view
local playernosight = 0 --How long the player has been out of view
local stalltics = 0 --Time that AI has struggled to move
local attackwait = 0 --Tics to wait before attacking again
local attackoverheat = 0 --Used by Fang to determine whether to wait
local lastrings = 0 --Last ring count of bot/leader



addHook('MapLoad', function()
	jump_last = 1
	spin_last = 1
	move_last = 0
	anxiety = 0
	panic = 0
	flymode = 0
	spinmode = 0
	thinkfly = 0
	idlecount = 0
	bored = 0
	drowning = 0
	fight = 0
	--overlay = nil
	target = nil
	helpmode = 0
	targetnosight = 0
	playernosight = 0
	stalltics = 0
	attackoverheat = 0
	attackwait = 0
	lastrings = 0
end)

local thisbot = nil
local targetplayer = nil
COM_AddCommand("SETBOT", function(player, bot, target)
	local pbot = players[tonumber(bot)]
	local ptarget = player
	if target
		ptarget = players[tonumber(target)]
	end
	if pbot and ptarget and pbot != ptarget
		thisbot = pbot
		targetplayer = ptarget
		CONS_Printf(player, "Set bot " + pbot.name + " following " + ptarget.name)
	else
		thisbot = nil
		targetplayer = nil
		CONS_Printf(player, "Bot cleared")
	end
end, COM_ADMIN)

addHook("ShouldDamage", function(target, inflictor, source, damage, damagetype)
	if target == thisbot.mo
	and thisbot.powers[pw_flashing] == 0 and targetplayer.rings > 0
		S_StartSound(target, sfx_shldls)
		P_DoPlayerPain(target.player)
		return false
	end
end, MT_PLAYER)

local function teleport(player)
	if player == thisbot
		P_DoPlayerPain(player)
		P_TeleportMove(player.mo, targetplayer.mo.x, targetplayer.mo.y, targetplayer.mo.z)
		player.mo.momx = targetplayer.mo.momx
		player.mo.momy = targetplayer.mo.momy
		player.mo.momz = targetplayer.mo.momz
		player.mo.angle = targetplayer.mo.angle

		--Added this to deal with zoom tubes, rope hangs, and swings
		player.pflags = 0
		player.mo.state = S_PLAY_STND
		player.mo.tracer = nil

		--Copy targetplayer's gravity and scale settings
		player.mo.scale = targetplayer.mo.scale
		if targetplayer.mo.flags2 & MF2_OBJECTFLIP
			player.mo.flags2 = $1 | MF2_OBJECTFLIP
		else
			player.mo.flags2 = $1 & ~MF2_OBJECTFLIP
		end
	end
end
addHook("PlayerSpawn", teleport)

addHook("PreThinkFrame", function()
	local bot = thisbot
	if (bot == nil or CV_ExAI.value == 0)
		--or (players[0] == bot)
		then return false
	end

	--Handle rings here
	if not(G_IsSpecialStage())
		if bot.rings > targetplayer.rings
		and (lastrings == 0 or targetplayer.rings > 0)
			P_GivePlayerRings(targetplayer, bot.rings - targetplayer.rings)
		end
		bot.lives = targetplayer.lives
		bot.rings = targetplayer.rings
		lastrings = bot.rings
	end

	--Teleport here
	--if panic or playernosight > 128
	if playernosight > 96
		teleport(thisbot)
	end

	--****
	--VARS
	local aggressive = CV_AIAttack.value
	local player = targetplayer --players[0]
	local bmo = bot.mo
	local pmo = player.mo
	local pcmd = player.cmd
	local cmd = bot.cmd

	--Elements
	local water = 0
	if bot.mo.eflags&MFE_UNDERWATER then water = 1 end
	local flip = 1
	if (bot.mo.flags2 & MF2_OBJECTFLIP) or (bot.mo.eflags & MFE_VERTICALFLIP) then
		flip = -1
	end
	local _2d = (bot.mo.flags2 & MF2_TWOD or twodlevel)
	local scale = bot.mo.scale

	--Measurements
	local pmom = FixedHypot(pmo.momx,pmo.momy)
	local bmom = FixedHypot(bot.mo.momx,bot.mo.momy)
	local dist = R_PointToDist2(bot.mo.x,bot.mo.y,pmo.x,pmo.y)
	local zdist = FixedMul(pmo.z-bot.mo.z,scale*flip)
	local pfac = 1 --Steps ahead to predict movement
	local xpredict = bot.mo.momx*pfac+bot.mo.x
	local ypredict = bot.mo.momy*pfac+bot.mo.y
	local zpredict = bot.mo.momz*pfac+bot.mo.z
	local predictfloor = P_FloorzAtPos(xpredict,ypredict,zpredict,bot.mo.height)
	local ang = R_PointToAngle2(bot.mo.x-bot.mo.momx,bot.mo.y-bot.mo.momy,pmo.x,pmo.y)
	local followmax = 128*8*scale --Max follow distance before AI begins to enter "panic" state
	local followthres = 92*scale --Distance that AI will try to reach
	local followmin = 32*scale
	local comfortheight = 96*scale
	local touchdist = 24*scale
	local bmofloor = P_FloorzAtPos(bot.mo.x,bot.mo.y,bot.mo.z,bot.mo.height)
	local pmofloor = P_FloorzAtPos(pmo.x,pmo.y,pmo.z,pmo.height)
	local jumpheight = FixedMul(bot.jumpfactor*10,10*scale)
	local ability = bot.charability
	local ability2 = bot.charability2
	local enemydist = 0
	local enemyang = 0
	local falling = (bot.mo.momz*flip < 0)
	local predictgap = 0 --Predicts a gap which needs to be jumped
	local isjump = min(bot.pflags&(PF_JUMPED),1) --Currently jumping
	local isabil = min(bot.pflags&(PF_THOKKED|PF_GLIDING|PF_BOUNCING),1) --Currently using ability
	local isspin = min(bot.pflags&(PF_SPINNING),1) --Currently spinning
	local isdash = min(bot.pflags&(PF_STARTDASH),1) --Currently charging spindash
	local bmogrounded = (P_IsObjectOnGround(bot.mo) and not(bot.pflags&PF_BOUNCING)) --Bot ground state
	local pmogrounded = P_IsObjectOnGround(pmo) --Player ground state
	local dojump = 0 --Signals whether to input for jump
	local doabil = 0 --Signals whether to input for jump ability. Set -1 to cancel.
	local dospin = 0 --Signals whether to input for spinning
	local dodash = 0 --Signals whether to input for spindashing
	local targetfloor = nil
	local stalled = (bmom/*+abs(bmo.momz)*/ < scale and move_last) --AI is having trouble catching up
	local targetdist = CV_AISeekDist.value*FRACUNIT --Distance to seek enemy targets

	--Gun cooldown for Fang
	if fight == 0 then
		attackoverheat = 0
		attackwait = 0
	end
	if bot.panim == PA_ABILITY2 and ability2 == CA2_GUNSLINGER then
		attackoverheat = $+1
		if attackoverheat > 60 then
			attackwait = 1
		end
	elseif attackoverheat > 0
		attackoverheat = $-1
	else attackwait = 0
	end

	--Check line of sight to player
	if P_CheckSight(bmo,pmo) then playernosight = 0
	else playernosight = $+1
	end

	--Predict platforming
	if abs(predictfloor-bmofloor) > 24*scale
		then predictgap = 1
	end

	helpmode = 0
	--Non-Tails bots are more aggressive
--	if ability != CA_FLY then aggressive = 1 end
	if stalled then stalltics = $+1
	else stalltics = 0
	end
	--Find targets
	if not(anxiety) and (aggressive or bored) then
		searchBlockmap("objects",function (bmo,mo)
			if mo == nil then return end
			if (mo.flags&MF_BOSS or mo.flags&MF_ENEMY) and mo.health
				and P_CheckSight(bmo,mo)
				local dist = R_PointToDist2(bmo.x,bmo.y,mo.x,mo.y)
				if (dist < targetdist)
					and (abs(mo.z - bmo.z) < FRACUNIT*280)
					and (target == nil or not(target.valid)
						or (target.info.spawnhealth > 1)
						or R_PointToDist2(bmo.x,bmo.y,target.x,target.y) > dist
						)
					then
					target = mo
					return true
				end
			end
		end,bmo,bmo.x-targetdist,bmo.x+targetdist,bmo.y-targetdist,bmo.y+targetdist)
--		searchBlockmap("objects",function(bmo,fn) print(fn.type) end, bmo)
	end
	if target and target.valid then
		targetfloor = P_FloorzAtPos(target.x,target.y,target.z,target.height)
	end
	--Determine whether to fight
	if panic|spinmode|flymode --If panicking
		or (pmom >= player.runspeed)
		or not((aggressive|bored|fight) and target and target.valid) --Not ready to fight; target invalid
		or not(target.flags&MF_BOSS or target.flags&MF_ENEMY) --Not a boss/enemy
		or not(target.health) --No health
		or (target.flags2&MF2_FRET or target.flags2&MF2_BOSSFLEE or target.flags2&MF2_BOSSDEAD) --flashing/escape/dead state
		or (abs(targetfloor-bot.mo.z) > FixedMul(bot.jumpfactor,100*scale) and not (ability2 == CA2_GUNSLINGER)) --Unsafe to attack
		then
		target = nil
		fight = 0
	else
		enemydist = R_PointToDist2(bot.mo.x,bot.mo.y,target.x,target.y)
		if enemydist > targetdist then --Too far
			target = nil
			fight = 0
		elseif not P_CheckSight(bot.mo,target) then --Can't see
			targetnosight = $+1
			if targetnosight >= 70 then
				target = nil
				fight = 0
			end
		else
			enemyang = R_PointToAngle2(bot.mo.x-bot.mo.momx*pfac,bot.mo.y-bot.mo.momy*pfac,target.x,target.y)
			fight = 1
			targetnosight = 0
		end
	end

	--Check water
	drowning = 0
	if (water) then
		followmin = 48*scale
		followthres = 48*scale
		followmax = $/2
		if bot.powers[pw_underwater] < 35*16 then
			drowning = 1
			thinkfly = 0
	 		if bot.powers[pw_underwater] < 35*8 then
	 			drowning = 2
	 		end
		end
	end


	--Check anxiety
	if spinmode or bored or fight then
		anxiety = 0
		panic = 0
	elseif dist > followmax --Too far away
		or zdist > comfortheight --Too high/low
		or stalled --Something in my way!
		then
		anxiety = min($+2,70)
		if anxiety >= 70 then panic = 1 end
	elseif not(bot.pflags&PF_JUMPED) or dist < followmin then
		anxiety = max($-1,0)
		panic = 0
	end
	--Over a pit / In danger
	if bmofloor < pmofloor-comfortheight*2*flip
		and dist > followthres*2 then
		panic = 1
		anxiety = 70
		fight = 0
	end
	--Orientation
	if (bot.pflags&PF_SPINNING or bot.pflags&PF_STARTDASH /*or flymode == 2*/) then
		bot.mo.angle = pmo.angle
	elseif not(bot.climbing) and (dist > followthres or not(bot.pflags&PF_GLIDING)) then
		bot.mo.angle = ang
	end

	--Does the player need help?
	if ability2 == CA2_MELEE and not(player.powers[pw_shield]&SH_NOSTACK or player.charability2 == CA2_MELEE)
		and not(spinmode|anxiety|panic|fight) and dist < followmax then
		helpmode = 1
	else
		helpmode = 0
	end


	--Check boredom
	if (pcmd.buttons == 0 and pcmd.forwardmove == 0 and pcmd.sidemove == 0)
		and not(drowning|panic|fight|helpmode)
		and bmogrounded
		then
		idlecount = $+1
	else
		idlecount = 0
	end
	if idlecount > 35*8 or (aggressive and idlecount > 35*3) then
		bored = 1
	else
		bored = 0
	end

	--********
	--HELP MODE
	if helpmode
		cmd.forwardmove = 25
		bot.mo.angle = ang
		if dist < scale*64 then
			dospin = 1
			dodash = 1
		end
	end

	--********
	--FLY MODE
	if ability == CA_FLY then
		--Update carry state
		if flymode then
			bot.pflags = $ | PF_CANCARRY
		else
			bot.pflags = $ & ~PF_CANCARRY
		end
		--spinmode check
		if spinmode == 1 then thinkfly = 0
		else
			--Activate co-op flight
			if thinkfly == 1 and player.pflags&PF_JUMPED then
				dojump = 1
				doabil = 1
				flymode = 1
				thinkfly = 0
			end
			--Check positioning
			--Thinker for co-op fly
			if not(bored) and not(drowning) and dist < touchdist and P_IsObjectOnGround(pmo) and P_IsObjectOnGround(bot.mo)
				and not(player.pflags&PF_STASIS)
				and pcmd.forwardmove == 0 and pcmd.sidemove == 0
				and player.dashspeed == 0
				and pmom == 0 and bmom == 0
				then
				thinkfly = 1
			else thinkfly = 0
			end
			--Set carried state
			if pmo.tracer == bot.mo
				and player.powers[pw_carry]
				then
				flymode = 2
			end
			--Ready for takeoff
			if flymode == 1 then
				thinkfly = 0
				if zdist < -64*scale or bot.mo.momz*flip > scale then --Make sure we're not too high up
					doabil = -1
				else
					doabil = 1
				end
				--Abort if player moves away or spins
				if dist > followthres or player.dashspeed > 0
					flymode = 0
				end
			--Carrying; Read player inputs
			elseif flymode == 2 then
				cmd.forwardmove = pcmd.forwardmove
				cmd.sidemove = pcmd.sidemove
				if pcmd.buttons&BT_USE then
					doabil = -1
				else
					doabil = 1
				end
				--End flymode
				if not(player.powers[pw_carry])
					then
					flymode = 0
				end
			end
		end
		if flymode > 0 and bmogrounded and not(pcmd.buttons&BT_JUMP)
		then flymode = 0 end
	else
		flymode = 0
		thinkfly = 0
	end

	--********
	--SPINNING
	if ability2 == CA2_SPINDASH then
		if (panic or flymode or fight) or not(player.pflags&PF_SPINNING) or player.pflags&PF_JUMPED then spinmode = 0
		else
			if not(_2d)
			--Spindash
				if (player.dashspeed)
					if dist < followthres and dist > touchdist then --Do positioning
						bot.mo.angle = ang
						cmd.forwardmove = 50
						spinmode = 1
					elseif dist < touchdist then
						bot.mo.angle = pmo.angle
						dodash = 1
						spinmode = 1
					else spinmode = 0
					end
				--Spin
				elseif (player.pflags&PF_SPINNING and not(player.pflags&PF_STARTDASH)) then
					dospin = 1
					dodash = 0
					bot.mo.angle = ang
					cmd.forwardmove = 50
					spinmode = 1
				else spinmode = 0
				end
			--2D mode
			else
				if ((player.dashspeed and bmom == 0) or (player.dashspeed == bot.dashspeed and player.pflags&PF_SPINNING))
					then
					dospin = 1
					dodash = 1
					spinmode = 1
				end
			end
		end
	else
		spinmode = 0
	end
	--******
	--FOLLOW
	if not(flymode or spinmode or fight /*or helpmode*/ or bot.climbing) then
		--Bored
		if bored then
			local b1 = 256|128|64
			local b2 = 128|64
			local b3 = 64
			if idlecount&b1 == b1 then
				cmd.forwardmove = 35
				bot.mo.angle = ang + ANGLE_270
			elseif idlecount&b2 == b2 then
				cmd.forwardmove = 25
				bot.mo.angle = ang + ANGLE_67h
			elseif idlecount&b3 == b3 then
				cmd.forwardmove = 15
				bot.mo.angle = ang + ANGLE_337h
			else
				bot.mo.angle = idlecount*(ANG1/2)
			end
		--Too far
		elseif panic or dist > followthres then
			if not(_2d) then cmd.forwardmove = 50
			elseif pmo.x > bot.mo.x then cmd.sidemove = 50
			else cmd.sidemove = -50 end
		--Within threshold
		elseif not(panic) and dist > followmin and abs(zdist) < 192*scale then
			if not(_2d) then cmd.forwardmove = FixedHypot(pcmd.forwardmove,pcmd.sidemove)
			else cmd.sidemove = pcmd.sidemove end
		--Below min
		elseif dist < followmin then
			if not(drowning) then
				--Copy inputs
				bot.mo.angle = pmo.angle
				bot.drawangle = ang
				cmd.forwardmove = pcmd.forwardmove*8/10
				cmd.sidemove = pcmd.sidemove*8/10
			else --Water panic?
				bot.mo.angle = ang+ANGLE_45
				cmd.forwardmove = 50
			end
		end
	end

	--*********
	--JUMP
	if not(flymode|spinmode|fight) then

		--Flying catch-up code
		if isabil and ability == CA_FLY then
			cmd.forwardmove = min(50,dist/scale/8)
			if zdist < -64*scale and(drowning!=2) then doabil = -1
			elseif zdist > 0 then
				doabil = 1
				dojump = 1
			end
		end


		--Start jump
		if (
			(zdist > 32*scale and player.pflags & PF_JUMPED) --Following
			or (zdist > 64*scale and panic) --Vertical catch-up
			or (stalltics > 25
				and (not bot.powers[pw_carry])) --Not in carry state
			or(isspin) --Spinning
			) then
			dojump = 1
--			print("start jump")

		--Hold jump
		elseif isjump and (zdist > 0 or panic) then
			dojump = 1
--			print("hold jump")
		end

		--********
		--ABILITIES
		if not(fight) then
			--Thok
			if ability == CA_THOK and (panic or dist > followmax)
				then
				dojump = 1
				doabil = 1
			--Fly
			elseif ability == CA_FLY and (drowning == 2 or panic)
				then
				dojump = 1
				doabil = 1
			--Glide and climb / Float
			elseif (ability == CA_GLIDEANDCLIMB or ability == CA_FLOAT)
				and (
					(zdist > 16*scale and dist > followthres)
					or (
						(panic --Panic behavior
							and (bmofloor*flip < pmofloor or dist > followmax or playernosight)
						)
						or (isabil --Using ability
							and (
								(abs(zdist) > 0 and dist > followmax) --Far away
								or (zdist > 0) --Below player
							)
							and not(bmogrounded)
						)
					)
				)
				then
				dojump = 1
				doabil = 1
				if (dist < followmin and ability == CA_GLIDEANDCLIMB) then
					bot.mo.angle = pmo.angle --Match up angles for better wall linking
				end
			--Pogo Bounce
			elseif (ability == CA_BOUNCE)
				and (
					(panic and (bmofloor*flip < pmofloor or dist > followthres))
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
		if not(fight) and zdist > 0
			then cmd.forwardmove = 50
		end
		if (stalltics > 30)
			then doabil = -1
		end
	end

	if anxiety and playernosight > 64 then
		if leveltime&(64|32) == 64|32 then
			cmd.sidemove = 50
		elseif leveltime&32 then
			cmd.sidemove = -50
		end
	end

	--*******
	--FIGHT
	if fight then
		bot.mo.angle = enemyang
		local dist = 128*scale --Distance to catch up to.
		local mindist = 64*scale --Distance to attack from. Gunslingers avoid getting this close
		local attkey = BT_JUMP
		local attack = 0
		--Standard fight behavior
		if ability2 == CA2_GUNSLINGER then --Gunslingers shoot from a distance
			mindist = abs(target.z-bot.mo.z)*3/2
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
				cmd.forwardmove = 20
			end
		elseif enemydist > dist then --Too far
			cmd.forwardmove = 50
		else --Midrange
			if ability2 == CA2_GUNSLINGER then
				if not(attackwait)
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
			else
				cmd.forwardmove = 30 --Moderate speed so we don't overshoot the target
			end
		end
		--Attack
		if attack then
			if (attkey == BT_JUMP and (target.z-bot.mo.z)*flip >= 0)
				then dojump = 1
			elseif (attkey == BT_USE)
				then
				dospin = 1
				dodash = 1
			end
		end
		--Platforming during combat
		if (ability2 != CA2_GUNSLINGER and enemydist < followthres and target.z > bot.mo.z+32*scale) --Target above us
				or (stalltics > 25) --Stalled
				or (predictgap)--Jumping a gap
			then
			dojump = 1
		end
	end

	--**********
	--DO INPUTS
	--Jump action
	if (dojump) then
		if ((isjump and jump_last and not falling) --Already jumping
				or (bmogrounded and not jump_last)) --Not jumping yet
			and not(isabil or bot.climbing) --Not using abilities
			then cmd.buttons = $|BT_JUMP
		elseif bot.climbing then --Climb up to position
			cmd.forwardmove = 50
		end
	end
	--Ability
	if (doabil == 1) then
		if ((isjump and not jump_last) --Jump, released input
				or (isabil)) --Already using ability
			and not(bot.climbing) --Not climbing
			and not(ability == CA_FLY and jump_last) --Flight input check
			then cmd.buttons = $|BT_JUMP
		elseif bot.climbing then --Climb up to position
			cmd.forwardmove = 50
		end
	--"Force cancel" ability
	elseif (doabil == -1)
		and ((ability == CA_FLY and isabil) --If flying, descend
			or bot.climbing) --If climbing, let go
		then
		if not spin_last then
			cmd.buttons = $|BT_USE
		end
		cmd.buttons = $&~BT_JUMP
	end

	--Spin while moving
	if (dospin) then
		if (not(bmogrounded) --For air hammers
				or (abs(cmd.forwardmove)+abs(cmd.sidemove) > 0 and (bmom > scale*5 or ability2 == CA2_MELEE))) --Don't spin while stationary
			and not(spin_last)
			then cmd.buttons = $|BT_USE
		end
	end
	--Charge spindash (spin from standstill)
	if (dodash) then
		if (not(bmogrounded) --Air hammers
				or (bmom < scale and not spin_last) --Spin only from standstill
				or (isdash) --Already spinning
			) then
			cmd.buttons = $|BT_USE
		end
	end

	--*******
	--History
	if (cmd.buttons&BT_JUMP) then
		jump_last = 1
	else
		jump_last = 0
	end
	if (cmd.buttons&BT_USE) then
		spin_last = 1
	else
		spin_last = 0
	end
	if FixedHypot(cmd.forwardmove,cmd.sidemove) >= 30 then
		move_last = 1
	else
		move_last = 0
	end

	--*******
	--Aesthetic
	--thinkfly overlay
	if overlay == nil or overlay.valid == false then
		overlay = P_SpawnMobj(bot.mo.x, bot.mo.y, bot.mo.z, MT_OVERLAY)
		overlay.target = bot.mo
	end
	if thinkfly == 1 then
		if overlay.state == S_NULL then
			overlay.state = S_FLIGHTINDICATOR
		end
	else overlay.state = S_NULL
	end

	--Debug
	if CV_AIDebug.value == 1 then
		local p = "follow"
		if flymode == 1 then p = "flymode (ready)"
		elseif flymode == 2 then p = "flymode (carrying)"
		elseif helpmode then p = "helpmode"
		elseif targetnosight then p = "\x82 targetnosight " + targetnosight
		elseif fight then p = "fight"
		elseif drowning then p = "\x85 drowning"
		elseif panic then p = "\x85 panic (anxiety " + anxiety + ")"
		elseif bored then p = "bored"
		elseif thinkfly then p = "thinkfly"
		elseif anxiety then p = "\x82 anxiety " + anxiety
		elseif playernosight then p = "\x82 playernosight " + playernosight
		elseif spinmode then p = "spinmode (dashspeed " + bot.dashspeed/FRACUNIT+")"
		elseif dist > followthres then p = "follow (far)"
		elseif dist < followmin then p = "follow (close)"
		end
		local dcol = ""
		if dist > followmax then dcol = "\x85" end
		local zcol = ""
		if zdist > comfortheight then zcol = "\x85" end
		--AI States
		print("AI ["+bored..helpmode..fight..attackwait..thinkfly..flymode..spinmode..drowning..anxiety..panic+"] "+ p)
		--Distance
		print(dcol + "dist " + dist/scale +"/"+ followmax/scale + "  " + zcol + "zdist " + zdist/scale +"/"+ comfortheight/scale)
		--Physics and Action states
		print("perf " + isjump..isabil..isspin..isdash + "|" + dojump..doabil..dospin..dodash + "  gap " + predictgap + "  stall " + stalltics)
		--Inputs
		print("FM "+cmd.forwardmove + "  SM " + cmd.sidemove+"	Jmp "+(cmd.buttons&BT_JUMP)/BT_JUMP+"  Spn "+(cmd.buttons&BT_USE)/BT_USE+ "  Th "+(bot.pflags&PF_THOKKED)/PF_THOKKED)
	end

	return true
end)



print("\x81 ExAI - Version 1.0 - Released 2019/12/27",
"\x81 Enable/disable via ai_sys in console.",
"\x81 Use ai_attack and ai_seekdist to control AI aggressiveness.",
"\x81 Enable ai_debug to stream local variables and cmd inputs.")
