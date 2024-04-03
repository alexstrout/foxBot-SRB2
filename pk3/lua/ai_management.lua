local fb = __foxBot_1

local function ResolvePlayer(node)
	--Check node number first
	local num = tonumber(node)
	if num != nil and num >= 0 and num < 32
		return players[num]
	end

	--Then try name
	if node
		for player in players.iterate
			if string.upper(player.name) == string.upper(node)
				return player
			end
		end
	end

	--Nothing found
	return nil
end

function fb.SetBot(player, leader, bot)
	--Default to calling player
	local pbot = player

	--Check bot parameter
	if bot != nil --0 is valid here
		pbot = ResolvePlayer(bot)
		if not (pbot and pbot.valid)
			CONS_Printf(player, "Invalid bot " .. bot)
			return
		end
	end

	--Check leader parameter
	local pleader = ResolvePlayer(leader)
	if not (pleader and pleader.valid)
		--Simply unassign bot if applicable
		if pbot.ai
			--Remove from squad, removing squad if empty
			pleader = pbot.ai.leader
			if pleader and pleader.valid and pleader.ai_squad
				for k, b in ipairs(pleader.ai_squad)
					if b == pbot
						table.remove(pleader.ai_squad, k)
						break
					end
				end
				if not pleader.ai_squad[1]
					pleader.ai_squad = nil
				end
			end

			pbot.ai = nil
			CONS_Printf(player, "Stopping bot " .. pbot.name)
		elseif leader != nil --0 is valid here
			CONS_Printf(player, "Invalid leader " .. leader)
		else
			CONS_Printf(player, "Please specify a leader to follow!")
		end
		return
	end

	--Leader valid! Setup AI
	pbot.ai = {
		leader = pleader
	}

	--Assign to squad
	if not pleader.ai_squad
		pleader.ai_squad = {}
	end
	table.insert(pleader.ai_squad, pbot)
	pbot.ai_squad = pleader.ai_squad

	--Done!
	local msg = "Following " .. pleader.name
	if pbot != player
		msg = pbot.name .. ": " .. $
	end
	CONS_Printf(player, msg)
end

COM_AddCommand("setbot", fb.SetBot, 0)
