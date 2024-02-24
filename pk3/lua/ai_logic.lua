--[[
	--------------------------------------------------------------------------------
	AI LOGIC
	Actual AI behavior etc.
	--------------------------------------------------------------------------------
]]
local fb = __foxBot

--Returns true for a specified minimum time within a maximum time period
--Used for pseudo-random behaviors like strafing or attack mixups
--e.g. BotTime(bai, 2, 8) will return true for 2s out of every 8s
function fb.BotTime(bai, mintime, maxtime)
	return (leveltime + bai.timeseed) % (maxtime * TICRATE) < mintime * TICRATE
end

--Similar to above, but for an exact time interval
function fb.BotTimeExact(bai, time)
	return (leveltime + bai.timeseed) % time == 0
end

--Teleport a bot to leader, optionally fading out
function fb.Teleport(bot, fadeout)
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

	--CoopOrDie rebirth?
	if leader.cdinfo and leader.cdinfo.finished
	and bot.cdinfo and not bot.cdinfo.finished
		bot.pflags = $ | PF_FINISHED
		return true
	end

	--Teleport override?
	if fb.CV_AITeleMode.value
		--Probably successful if we're not in a panic and can see leader
		return not (bot.ai.panic or bot.ai.playernosight)
	end

	--Fade out (if needed), teleporting after
	if not fadeout
		bot.ai.teleporttime = max($ + 1, TICRATE / 2) --Skip the fadeout time
	else
		bot.ai.teleporttime = $ + 1
		bot.powers[pw_flashing] = max($, TICRATE)
	end
	if bot.ai.teleporttime < TICRATE / 2
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
	bot.powers[pw_flashing] = max($, TICRATE / 2)
	return true
end

--Calculate a "prediction factor" based on control state (air, spin, etc.)
function fb.PredictFactor(bmo, grounded, spinning)
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
function fb.DesiredMove(bot, bmo, pmo, dist, mindist, leaddist, minmag, pfac, _2d)
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
	--fb.PosCheckerObj = fb.CheckPos(fb.PosCheckerObj, px, py, pmo.z + pmo.height / 2)
	--fb.PosCheckerObj.eflags = $ & ~MFE_VERTICALFLIP | (bmo.eflags & MFE_VERTICALFLIP)
	--fb.PosCheckerObj.state = S_LOCKON1

	--Stop skidding everywhere! (commented as this isn't really needed anymore)
	--if pfac < 4 --Infers grounded and not spinning
	--and fb.AbsAngle(mang - bmo.angle) < ANGLE_157h
	--and fb.AbsAngle(mang - pang) > ANGLE_157h
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
function fb.ValidTarget(bot, leader, target, maxtargetdist, maxtargetz, flip, ignoretargets, ability, ability2, pfac)
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
		or fb.SuperReady(target.player)
	)
	and P_IsObjectOnGround(target)
		if fb.isspecialstage
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
		fb.FixBadFloorOrCeilingZ(target)
		target.ai_validfocz = true
	end

	--Don't do gunslinger stuff if we ain't slingin'
	if ability2 == CA2_GUNSLINGER
	and (bot.pflags & (PF_JUMPED | PF_THOKKED))
		ability2 = nil
	end

	--Consider our height against airborne targets
	local bmo = bot.realmo
	local bmoz = fb.AdjustedZ(bmo, bmo) * flip
	local targetz = fb.AdjustedZ(bmo, target) * flip
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
		and 2 * fb.WaterTopOrBottom(bmo, target) * flip - targetz - bmoz >= maxtargetz_height
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
function fb.UpdateLastSeenPos(bai, pmo, pmoz)
	bai.lastseenpos.x = pmo.x + pmo.momx
	bai.lastseenpos.y = pmo.y + pmo.momy
	bai.lastseenpos.z = pmoz + pmo.momz
end

--Drive bot based on whatever unholy mess is in this function
--This is the "WhatToDoNext" entry point for all AI actions
function fb.PreThinkFrameFor(bot)
	if not bot.valid
		return
	end

	--Find a new "real" leader if ours quit
	local bai = bot.ai
	if not (bai and bai.realleader and bai.realleader.valid)
		--Pick a random leader if default is invalid
		local bestleader = fb.CV_AIDefaultLeader.value
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
				and fb.GetTopLeader(player, bot) != bot --Also infers player != bot as base case
				--Prefer higher-numbered players to spread out bots more
				and (bestleader < 0 or P_RandomByte() < 128)
					bestleader = #player
				end
			end
		end
		fb.SetBot(bot, bestleader)

		--Make sure SP bots register an owner
		if bot.bot and not (bot.ai_owner and bot.ai_owner.valid)
			fb.RegisterOwner(players[bestleader], bot)
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
		fb.PreThinkFrameFor(leader)
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
	if not fb.isspecialstage
		--Syncing rings?
		if fb.CV_AIStatMode.value & 1 == 0
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
			and not (fb.SPBot(bot) and leader.exiting) --Fix SP bot zeroing rings when exiting
				P_GivePlayerRings(leader, bot.rings - bai.lastrings)
			end
			bot.rings = leader.rings

			--Oops! Fix awarding extra extra lives
			bot.xtralife = leader.xtralife
		--Restore our "real" ring count if no longer synced
		elseif bai.syncrings
			bai.syncrings = false
			fb.RestoreRealRings(bot)
		end
		bai.lastrings = bot.rings

		--Syncing lives?
		if fb.CV_AIStatMode.value & 2 == 0
			--Remember our "real" life count if newly synced
			if not bai.synclives
				bai.synclives = true
				bai.reallives = bot.lives
			end

			--Sync those lives!
			if bot.lives > bai.lastlives
			and bot.lives > leader.lives
			and not (fb.SPBot(bot) and leader.exiting) --Probably doesn't hurt? See above
				P_GivePlayerLives(leader, bot.lives - bai.lastlives)
				if leveltime
					P_PlayLivesJingle(leader)
				end
			end
			if bot.lives > 0 and not bot.spectator
				bot.lives = max(leader.lives, 1)
			else
				bot.lives = leader.lives
			end
		--Restore our "real" life count if no longer synced
		elseif bai.synclives
			bai.synclives = false
			fb.RestoreRealLives(bot)
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
	local pmoz = fb.AdjustedZ(bmo, pmo) * flip

	--Handle shield loss here if ai_hurtmode off
	if bai.loseshield
		if not bot.powers[pw_shield]
			bai.loseshield = nil
		elseif fb.BotTimeExact(bai, TICRATE)
			bai.loseshield = nil --Make sure we only try once
			P_RemoveShield(bot)
			S_StartSound(bmo, sfx_corkp)
		end
	end

	--Check line of sight to player
	if fb.CheckSight(bmo, pmo)
		bai.playernosight = 0
		fb.UpdateLastSeenPos(bai, pmo, pmoz)
	else
		bai.playernosight = $ + 1

		--Just instakill on too much teleporting if we still can't see leader
		if bai.doteleport and bai.stalltics > 6 * TICRATE
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
	if bai.doteleport and fb.Teleport(bot, true)
		--Post-teleport cleanup
		bai.teleporttime = 0
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
			fb.Repossess(bot)

			--Unset ronin as client must have reconnected
			--(unfortunately PlayerJoin does not fire for rejoins)
			bai.ronin = false
			fb.UnregisterOwner(bot.ai_owner, bot)

			--Terminate AI to avoid interfering with normal SP bot stuff
			--Otherwise AI may take control again too early and confuse things
			--(We won't get another AI until a valid BotTiccmd is generated)
			if fb.SPBot(bot)
				fb.DestroyAI(bot)
				return
			end
		end
		bai.cmd_time = 8 * TICRATE
	end
	if bai.cmd_time > 0
		bai.cmd_time = $ - 1

		--Hold cmd_time if AI is off
		if fb.CV_ExAI.value == 0
			bai.cmd_time = 3 * TICRATE
		end

		--Teleport override?
		if bai.doteleport and fb.CV_AITeleMode.value > 0
			cmd.buttons = $ | fb.CV_AITeleMode.value
		end
		return
	end

	--Bail here if AI is off (allows logic above to flow normally)
	if fb.CV_ExAI.value == 0
		--Just trigger cmd_time logic next tic, without the setup
		--(also means this block only runs once)
		bai.cmd_time = 3 * TICRATE

		--Make sure SP bot AI is destroyed
		if fb.SPBot(bot)
			fb.DestroyAI(bot)
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
	local ignoretargets = fb.CV_AIIgnore.value
	local pmom = FixedHypot(pmo.momx, pmo.momy)
	local bmom = FixedHypot(bmo.momx, bmo.momy)
	local bmoz = fb.AdjustedZ(bmo, bmo) * flip
	local pmomang = R_PointToAngle2(0, 0, pmo.momx, pmo.momy)
	local bmomang = R_PointToAngle2(0, 0, bmo.momx, bmo.momy)
	local pspd = leader.speed
	local bspd = bot.speed
	local dist = R_PointToDist2(bmo.x, bmo.y, pmo.x, pmo.y)
	local zdist = pmoz - bmoz
	local predictfloor = fb.PredictFloorOrCeilingZ(bmo, 2) * flip
	local ang = bmo.angle --Used for climbing etc.
	local followmax = touchdist + 1024 * scale --Max follow distance before AI begins to enter "panic" state
	local followthres = touchdist + 92 * scale --Distance that AI will try to reach
	local followmin = touchdist + 32 * scale
	local bmofloor = fb.FloorOrCeilingZ(bmo, bmo) * flip
	local pmofloor = fb.FloorOrCeilingZ(bmo, pmo) * flip
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
	local pfac = fb.PredictFactor(bmo, bmogrounded, isspin)
	local dojump = 0 --Signals whether to input for jump
	local doabil = 0 --Signals whether to input for jump ability. Set -1 to cancel.
	local dospin = 0 --Signals whether to input for spinning
	local dodash = 0 --Signals whether to input for spindashing
	local stalled = bai.move_last --AI is having trouble catching up
		and (bmom < scale or (bspd > bmom and bmom < 2 * scale))
		and not bot.climbing
	local targetdist = fb.CV_AISeekDist.value * scale --Distance to seek enemy targets (reused as actual target dist later)
	local targetz = 0 --Filled in later if target
	local minspeed = 8 * scale --Minimum speed to spin or adjust combat jump range
	local pmag = FixedHypot(pcmd.forwardmove * FRACUNIT, pcmd.sidemove * FRACUNIT)
	local bmosloped = bmo.standingslope and fb.AbsAngle(bmo.standingslope.zangle) > ANGLE_11hh
	local hintdist = 32 * scale --Magic value - min attack range hint, zdists larger than this not considered for spin/melee, etc.
	local jumpdist = hintdist --Relative zdist to jump when following leader (possibly modified based on status)
	local stepheight = FixedMul(MAXSTEPMOVE, scale)

	--Are we spectating?
	if bot.spectator
		--Do spectator stuff
		cmd.forwardmove,
		cmd.sidemove = fb.DesiredMove(bot, bmo, pmo, dist, followthres * 2, FixedSqrt(dist) * 2, 0, pfac, _2d)
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
		if fb.BotTimeExact(bai, 5 * TICRATE)
			cmd.buttons = $ | BT_ATTACK
		end

		--Fix 2.2.10 oddity where headless clients don't generate angleturn or aiming
		cmd.angleturn = bmo.angle >> 16
		cmd.aiming = bot.aiming >> 16

		--Debug
		if fb.CV_AIDebug.value > -1
		and fb.CV_AIDebug.value == #bot
			fb.hudtext[1] = "dist " + dist / scale
			fb.hudtext[2] = "zdist " + zdist / scale
			fb.hudtext[3] = "FM " + cmd.forwardmove + " SM " + cmd.sidemove
			fb.hudtext[4] = "Jmp " + (cmd.buttons & BT_JUMP) / BT_JUMP + " Spn " + (cmd.buttons & BT_SPIN) / BT_SPIN
			fb.hudtext[5] = "leader " + #bai.leader + " - " + fb.ShortName(bai.leader)
			if bai.leader != bai.realleader and bai.realleader and bai.realleader.valid
				fb.hudtext[5] = $ + " \x86(" + #bai.realleader + " - " + fb.ShortName(bai.realleader) + ")"
			end
			fb.hudtext[6] = nil
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
	if bot.quittime and fb.CV_AIKeepDisconnected.value
		bot.quittime = 0 --We're still here!
		bai.ronin = true --But we have no master
		if not bot.ai_owner
			fb.RegisterOwner(bai.realleader, bot)
		end
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
	if fb.isspecialstage
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
		fb.SetTarget(bai, nil)
	elseif not fb.ValidTarget(bot, leader, bai.target, targetdist, jumpheight, flip, ignoretargets, ability, ability2, pfac)
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
			fb.SetTarget(bai, nil)
			if ignoretargets < 3
				local besttype = 255
				local bestdist = targetdist
				local besttarget = nil
				searchBlockmap(
					"objects",
					function(bmo, mo)
						local ttype, tdist = fb.ValidTarget(bot, leader, mo, targetdist, jumpheight, flip, ignoretargets, ability, ability2, pfac)
						if ttype and fb.CheckSight(bmo, mo)
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
				fb.SetTarget(bai, besttarget)
			--Always bop leader if they need it
			elseif fb.ValidTarget(bot, leader, pmo, targetdist, jumpheight, flip, ignoretargets, ability, ability2, pfac)
			and fb.CheckSight(bmo, pmo)
				fb.SetTarget(bai, pmo)
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
		bai.waypoint = fb.DestroyObj($)
	end

	--Determine movement
	if bai.target --Above checks infer bai.target.valid
		--Check target sight
		if fb.CheckSight(bmo, bai.target)
			bai.targetnosight = 0
		else
			bai.targetnosight = $ + 1
		end

		--Used in fight logic later
		targetdist = R_PointToDist2(bmo.x, bmo.y, bai.target.x, bai.target.y)
		targetz = fb.AdjustedZ(bmo, bai.target) * flip

		--Override our movement and heading to intercept
		--Avoid self-tagged CoopOrDie targets (kinda fudgy and ignores waypoints, but gets us away)
		if bai.target.cd_lastattacker
		and bai.target.cd_lastattacker.player == bot
			cmd.forwardmove, cmd.sidemove =
				fb.DesiredMove(bot, bmo, pmo, dist, followmin, 0, pmag, pfac, _2d)
		else
			cmd.forwardmove, cmd.sidemove =
				fb.DesiredMove(bot, bmo, bai.target, targetdist, 0, 0, 0, pfac, _2d)
		end
		bmo.angle = R_PointToAngle2(bmo.x - bmo.momx, bmo.y - bmo.momy, bai.target.x, bai.target.y)
		bot.aiming = R_PointToAngle2(0, bmo.z - bmo.momz + bmo.height / 2,
			targetdist + 32 * scale, bai.target.z + bai.target.height / 2)
	--Waypoint!
	elseif bai.waypoint
		--Check waypoint sight
		if fb.CheckSight(bmo, bai.waypoint)
			bai.targetnosight = 0
		else
			bai.targetnosight = $ + 1
		end

		--dist eventually recalculates as a total path length (left partial here for aiming vector)
		--zdist just gets overwritten so we ascend/descend appropriately
		dist = R_PointToDist2(bmo.x, bmo.y, bai.waypoint.x, bai.waypoint.y)
		zdist = fb.AdjustedZ(bmo, bai.waypoint) * flip - bmoz

		--Divert through the waypoint
		cmd.forwardmove, cmd.sidemove =
			fb.DesiredMove(bot, bmo, bai.waypoint, dist, 0, 0, 0, pfac, _2d)
		bmo.angle = R_PointToAngle2(bmo.x - bmo.momx, bmo.y - bmo.momy, bai.waypoint.x, bai.waypoint.y)
		bot.aiming = R_PointToAngle2(0, bmo.z - bmo.momz + bmo.height / 2,
			dist + 32 * scale, bai.waypoint.z + bai.waypoint.height / 2)

		--Check distance to waypoint, updating if we've reached it (may help path to leader)
		if (dist < bmo.radius and abs(zdist) <= jumpdist)
			fb.UpdateLastSeenPos(bai, pmo, pmoz)
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
		and (dist < followthres or fb.AbsAngle(bmomang - bmo.angle) > ANGLE_90)
			leaddist = followmin + dist + (pmom + bmom) * 2
		--Reduce minimum distance if moving away (so we don't fall behind moving too late)
		elseif dist < followmin and pmom > bmom
		and fb.AbsAngle(pmomang - bmo.angle) < ANGLE_135
		and not bot.powers[pw_carry] --But not on vehicles
			followmin = 0 --Distance remains natural due to pmom > bmom check
		end

		--Normal follow movement and heading
		cmd.forwardmove, cmd.sidemove =
			fb.DesiredMove(bot, bmo, pmo, dist, followmin, leaddist, pmag, pfac, _2d)
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
			or fb.WaterTopOrBottom(bmo, bmo) * flip - bmoz < jumpheight + bmo.height / 2
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
		and fb.BotTime(bai, 1, 3)
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
	and fb.BotTimeExact(bai, TICRATE)
		fb.SwapCharacter(bot, bot.ai_swapchar)
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
		and (ability == CA_FLY or fb.SuperReady(bot))
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
				fb.DesiredMove(bot, bmo, pmo, dist, followthres, 0, 0, pfac, _2d)
			bai.spinmode = 0
		--Spindash
		elseif leader.dashspeed > 0
			if dist > touchdist and not isdash --Do positioning
				--Same as our normal follow DesiredMove but w/ no mindist / leaddist / minmag
				cmd.forwardmove, cmd.sidemove =
					fb.DesiredMove(bot, bmo, pmo, dist, 0, 0, 0, pfac, _2d)
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
			and fb.AbsAngle(bmomang - bmo.angle) < ANGLE_22h
			and (isspin or fb.BotTimeExact(bai, TICRATE / 8))
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
					fb.DesiredMove(bot, bmo, pmo, dist, 0, 0, 0, pfac, _2d)
				bai.targetnosight = 3 * TICRATE --Recall bot from any target
			else
				--Helpmode!
				fb.SetTarget(bai, pmo)
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
			or fb.BotTimeExact(bai, 2 * TICRATE + 1)
			or (stalled and fb.BotTimeExact(bai, TICRATE / 2 + 1))
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
					if fb.BotTime(bai, 1, 2)
						imirror = -imirror
					end
					cmd.forwardmove = P_RandomRange(-25, 50) * imirror
					cmd.sidemove = P_RandomRange(-25, 50) * imirror
				end
			elseif fb.BotTime(bai, 1, max)
				cmd.forwardmove = bai.bored
				cmd.sidemove = 0
			elseif fb.BotTime(bai, 2, max)
				cmd.forwardmove = 0
				cmd.sidemove = bai.bored * imirror
			elseif fb.BotTime(bai, 3, max)
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
			elseif fb.BotTime(bai, 3, max - 1)
				if abs(bai.bored) < 5
				--We want dashing and/or shield abilities, but not super! D'oh
				and not P_SuperReady(bot)
					dospin = 1
					dodash = 1
				elseif abs(bai.bored) < 15
					dojump = 1
					if abs(bai.bored) < 10
					and not bmogrounded and falling
						if fb.BotTime(bai, 2, 4)
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
			if fb.CV_AICatchup.value and dist > followthres * 2
			and pspd > bot.normalspeed * 4/5
			and fb.AbsAngle(pmomang - bmomang) <= ANGLE_90
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
	and (bot.powers[pw_carry] != CR_MINECART or fb.BotTime(bai, 1, 16)) --Derpy minecart hack
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
				or fb.AbsAngle(bmomang - bmo.angle) > ANGLE_157h)) --Spinning
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
							and fb.BotTimeExact(bai, TICRATE / 4)))
					--Mix in fire shield half the time
					and not (
						bshield == SH_FLAMEAURA
						and not isabil and fb.BotTime(bai, 2, 4)
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
						and fb.AbsAngle(bmomang - bmo.angle) > ANGLE_90
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
						not isabil and fb.BotTime(bai, 2, 4)
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
						and fb.BotTimeExact(bai, TICRATE / 4)))
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
		if fb.AbsAngle(bmo.angle - ang) < ANGLE_67h
		or fb.AbsAngle(bmo.angle - ang) > ANGLE_112h
			dms = 0
		--Shorthand for relative angles >= 180 - meaning, move left
		elseif ang - bmo.angle < 0
			dms = -$
		end
		if dmgd and fb.AbsAngle(bmo.angle - ang) < ANGLE_67h
			cmd.forwardmove = 50
			cmd.sidemove = 0
		elseif dmgd or FixedHypot(abs(dmf), abs(dms)) > touchdist
			cmd.forwardmove = min(max(dmf / scale, -50), 50)
			cmd.sidemove = min(max(dms / scale, -50), 50)
		else
			cmd.forwardmove = 0
			cmd.sidemove = 0
		end
		if fb.AbsAngle(ang - bmo.angle) > ANGLE_112h
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
		if fb.BotTime(bai, 2, 4)
			cmd.sidemove = 50
		else
			cmd.sidemove = -50
		end
		if fb.BotTime(bai, 2, 10)
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
		local targetfloor = fb.FloorOrCeilingZ(bmo, bai.target) * flip
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
			if fb.BotTimeExact(bai, TICRATE / 4)
				cmd.buttons = $ | BT_ATTACK
			end
		--Gunslingers shoot from a distance
		elseif ability2 == CA2_GUNSLINGER
			if fb.BotTime(bai, 31, 32) --Randomly (rarely) jump too
			and bmogrounded and not bai.attackwait
			and not bai.targetnosight
				mindist = max($, abs(targetz - bmoz) * 3/2)
				maxdist = max($, 768 * scale) + mindist
				attkey = BT_SPIN
			end
		--Melee only attacks on ground if it makes sense
		elseif ability2 == CA2_MELEE
			if fb.BotTime(bai, 7, 8) --Randomly jump too
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
		and (isspin or bmosloped or fb.BotTime(bai, 1, 8)
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
		if bmom and fb.AbsAngle(bmomang - bmo.angle) < ANGLE_22h
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
				if fb.BotTime(bai, 4, 8)
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
				if fb.BotTime(bai, 4, 8)
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
						not isabil and fb.BotTime(bai, 2, 4)
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
				and fb.BotTimeExact(bai, TICRATE / 4)
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
						and not isabil and fb.BotTime(bai, 2, 4)
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
				and fb.BotTimeExact(bai, TICRATE / 4)
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
						if fb.BotTime(bai, 15, 16)
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
						fb.AbsAngle(bmomang - bmo.angle) < ANGLE_22h / 10
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
				and fb.AbsAngle(bot.drawangle - bmo.angle) > ANGLE_45
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
					and fb.BotTime(bai, 4, 48)
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
	and fb.AbsAngle(bmomang - bmo.angle) > ANGLE_157h
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
	if bai.doteleport and fb.CV_AITeleMode.value > 0
		cmd.buttons = $ | fb.CV_AITeleMode.value
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
		if fb.SuperReady(bot)
		and (ability != CA_FLY or bai.overlaytime % (2 * TICRATE) < TICRATE)
			bai.overlay.colorized = true
			bai.overlay.color = SKINCOLOR_YELLOW
		elseif bai.overlay.colorized
			bai.overlay.colorized = false
			bai.overlay.color = SKINCOLOR_NONE
		end
		bai.overlaytime = $ + 1
	elseif bai.overlay
		bai.overlay = fb.DestroyObj($)
	end

	--Debug
	if fb.CV_AIDebug.value > -1
	and fb.CV_AIDebug.value == #bot
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
		if bai.doteleport then p2 = $ .. "\x84" .. "teleport! " .. bai.teleporttime end
		--AI States
		fb.hudtext[1] = p
		fb.hudtext[2] = p2
		--Distance
		fb.hudtext[3] = "dist " + dist / scale + "/" + followmax / scale
		if dist > followmax then fb.hudtext[3] = "\x85" .. $ end
		fb.hudtext[4] = "zdist " + zdist / scale + "/" + jumpheight / scale
		if zdist > jumpheight then fb.hudtext[4] = "\x85" .. $ end
		--Physics and Action states
		if isabil then isabil = 1 else isabil = 0 end
		if (bot.pflags & PF_SHIELDABILITY) then isabil = $ + 2 end
		fb.hudtext[5] = "jasd \x86" + min(isjump,1)..isabil..min(isspin,1)..min(isdash,1) + "\x80|" + dojump..doabil..dospin..dodash
		fb.hudtext[6] = "gap " + bai.predictgap + " stl " + bai.stalltics
		--Inputs
		fb.hudtext[7] = "FM " + cmd.forwardmove + " SM " + cmd.sidemove
		if bot.pflags & PF_APPLYAUTOBRAKE then fb.hudtext[7] = "\x86" .. $ .. " *" end
		fb.hudtext[8] = "Jmp " + (cmd.buttons & BT_JUMP) / BT_JUMP + " Spn " + (cmd.buttons & BT_SPIN) / BT_SPIN
		--Target
		if fight
			fb.hudtext[9] = "\x83" + "target " + #bai.target.info + " - " + string.gsub(tostring(bai.target), "userdata: ", "")
				+ " " + bai.targetcount + " " + targetdist / scale
		elseif helpmode
			fb.hudtext[9] = "\x81" + "target " + #bai.target.player + " - " + fb.ShortName(bai.target.player)
		else
			fb.hudtext[9] = "leader " + #bai.leader + " - " + fb.ShortName(bai.leader)
			if bai.leader != bai.realleader and bai.realleader and bai.realleader.valid
				fb.hudtext[9] = $ + " \x86(" + #bai.realleader + " - " + fb.ShortName(bai.realleader) + ")"
			end
		end
		--Waypoint?
		if bai.waypoint
			fb.hudtext[10] = ""
			fb.hudtext[11] = "waypoint " + string.gsub(tostring(bai.waypoint), "userdata: ", "")
			if bai.waypoint.ai_type
				fb.hudtext[11] = "\x87" + $
			else
				fb.hudtext[11] = "\x86" + $
			end
		end
	end
end
