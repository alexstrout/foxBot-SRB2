--[[
	--------------------------------------------------------------------------------
	GLOBAL CONVARS
	(see "bothelp" at bottom for a description of each)
	--------------------------------------------------------------------------------
]]
local fb = __foxBot

fb.CV_MaxPlayers = CV_FindVar("maxplayers")

fb.CV_CoopStarposts = CV_FindVar("coopstarposts")

fb.CV_ExAI = CV_RegisterVar({
	name = "ai_sys",
	defaultvalue = "On",
	flags = CV_NETVAR|CV_SHOWMODIF,
	PossibleValue = CV_OnOff
})

fb.CV_AIDebug = CV_RegisterVar({
	name = "ai_debug",
	defaultvalue = "-1",
	flags = 0,
	PossibleValue = {MIN = -1, MAX = 31}
})

fb.CV_AISeekDist = CV_RegisterVar({
	name = "ai_seekdist",
	defaultvalue = "512",
	flags = CV_NETVAR|CV_SHOWMODIF,
	PossibleValue = {MIN = 64, MAX = 1536}
})

fb.CV_AIIgnore = CV_RegisterVar({
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

fb.CV_AICatchup = CV_RegisterVar({
	name = "ai_catchup",
	defaultvalue = "Off",
	flags = CV_NETVAR|CV_SHOWMODIF,
	PossibleValue = CV_OnOff
})

fb.CV_AIKeepDisconnected = CV_RegisterVar({
	name = "ai_keepdisconnected",
	defaultvalue = "On",
	flags = CV_NETVAR|CV_SHOWMODIF,
	PossibleValue = CV_OnOff
})

fb.CV_AIDefaultLeader = CV_RegisterVar({
	name = "ai_defaultleader",
	defaultvalue = "32",
	flags = CV_NETVAR|CV_SHOWMODIF,
	PossibleValue = {MIN = -1, MAX = 32}
})

fb.CV_AIMaxBots = CV_RegisterVar({
	name = "ai_maxbots",
	defaultvalue = "2",
	flags = CV_NETVAR|CV_SHOWMODIF,
	PossibleValue = {MIN = 0, MAX = 32}
})

fb.CV_AIReserveSlot = CV_RegisterVar({
	name = "ai_reserveslot",
	defaultvalue = "On",
	flags = CV_NETVAR|CV_SHOWMODIF,
	PossibleValue = CV_OnOff
})

fb.CV_AIHurtMode = CV_RegisterVar({
	name = "ai_hurtmode",
	defaultvalue = "Off",
	flags = CV_NETVAR|CV_SHOWMODIF,
	PossibleValue = {
		Off = 0,
		ShieldLoss = 1,
		RingLoss = 2
	}
})

fb.CV_AIStatMode = CV_RegisterVar({
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

fb.CV_AITeleMode = CV_RegisterVar({
	name = "ai_telemode",
	defaultvalue = "0",
	flags = CV_NETVAR|CV_SHOWMODIF,
	PossibleValue = {MIN = 0, MAX = UINT16_MAX}
})

fb.CV_AIShowHud = CV_RegisterVar({
	name = "ai_showhud",
	defaultvalue = "On",
	flags = 0,
	PossibleValue = CV_OnOff
})
