local fb = __foxBot_1

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

		--Calculate "total" momentum between us and target
		--Despite only controlling X and Y, factoring in Z momentum does
		--still help us intercept Z fast-movers with a lower timetotarget
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

fb.AddAIHook("followLeader", function(player)
	if not (
		player.ai
		and player.ai.leader
		and player.ai.leader.valid
	)
		return
	end

	local bmo = player.realmo
	local pmo = player.ai.leader.realmo
	if not (bmo.valid or pmo.valid)
		return
	end

	local cmd = player.cmd
	local dist = R_PointToDist2(bmo.x, bmo.y, pmo.x, pmo.y)

	--fb.DesiredMove(bot, bmo, pmo, dist, mindist, leaddist, minmag, pfac, _2d)
	cmd.forwardmove, cmd.sidemove = fb.DesiredMove(player, bmo, pmo,
		dist, 0, FixedSqrt(dist) * 2,
		0, 1, false
	)

	bmo.angle = R_PointToAngle2(bmo.x, bmo.y, pmo.x, pmo.y)
	player.aiming = R_PointToAngle2(0, bmo.z + bmo.height / 2,
		dist + 32 * bmo.scale, pmo.z + pmo.height / 2)
end)
