local ADDON, ns = ...

local MUSIC_PATH = "Interface\\AddOns\\" .. ADDON .. "\\music\\"
local STOP_GRACE = 1.0      -- seconds a travel state may drop before the song stops (form swaps, remounts)
local FADE_MS = 1500        -- fade-out when stopping a non-Music-channel song

-- Canonical WoW sound channel names, keyed by what you can type.
local CHANNELS = {
	music = "Music",
	master = "Master",
	sfx = "SFX",
	ambience = "Ambience",
	dialog = "Dialog",
}

local function say(msg)
	print("|cffffd100Chocobo|r: " .. msg)
end

---------------------------------------------------------------------------
-- Secret-value safety (12.x): any query may come back secret or error under
-- restrictions. query() returns false in that case ("can't tell right now"),
-- otherwise true plus the real value -- which may legitimately be nil
-- (GetShapeshiftFormID returns nil when you're in no form).
---------------------------------------------------------------------------
local issecretvalue = issecretvalue or function() return false end

local function query(fn, ...)
	local ok, v = pcall(fn, ...)
	if not ok or issecretvalue(v) then return false end
	return true, v
end

-- Boolean test helper: nil = unknown, otherwise true/false.
local function flag(fn, ...)
	local ok, v = query(fn, ...)
	if not ok then return nil end
	return v and true or false
end

local function formID()
	local ok, f = query(GetShapeshiftFormID)
	if not ok then return nil end
	return f or 0
end

-- Aspect of the Cheetah / Aspect of the Pack (classic and modern IDs). We also
-- match by localized name so any Forever-specific spell ID is still caught.
local CHEETAH_IDS = { 5118, 13159, 186257, 186258 }
local cheetahNames

local function hasCheetah()
	if not cheetahNames then
		cheetahNames = {}
		for _, id in ipairs(CHEETAH_IDS) do
			local ok, name = query(C_Spell.GetSpellName, id)
			if ok and name then cheetahNames[name] = true end
		end
	end
	local unknown = false
	for _, id in ipairs(CHEETAH_IDS) do
		local ok, aura = pcall(C_UnitAuras.GetPlayerAuraBySpellID, id)
		if not ok or issecretvalue(aura) then
			unknown = true
		elseif aura then
			return true
		end
	end
	for name in pairs(cheetahNames) do
		local ok, aura = pcall(C_UnitAuras.GetAuraDataBySpellName, "player", name, "HELPFUL")
		if not ok or issecretvalue(aura) then
			unknown = true
		elseif aura then
			return true
		end
	end
	if unknown then return nil end
	return false
end

-- Each trigger's test returns true/false, or nil when it can't tell right now.
local TRIGGERS = {
	{ key = "mount",      label = "Mounted",                          test = function() return flag(IsMounted) end },
	{ key = "travelform", label = "Druid Travel/Aquatic/Flight Form", test = function()
		local f = formID()
		if f == nil then return nil end
		return f == 3 or f == 4 or f == 27 or f == 29
	end },
	{ key = "ghostwolf",  label = "Shaman Ghost Wolf",                test = function()
		local f = formID()
		if f == nil then return nil end
		return f == 16
	end },
	{ key = "cheetah",    label = "Aspect of the Cheetah/Pack",       test = hasCheetah },
	{ key = "taxi",       label = "Flight paths",                     test = function() return flag(UnitOnTaxi, "player") end },
}
local TRIGGER_BY_KEY = {}
for _, t in ipairs(TRIGGERS) do TRIGGER_BY_KEY[t.key] = t end

---------------------------------------------------------------------------
-- Saved settings (per character)
---------------------------------------------------------------------------
local db

local function initDB()
	ChocoboDB = ChocoboDB or {}
	db = ChocoboDB
	db.enabled = db.enabled or {}
	for _, t in ipairs(TRIGGERS) do
		if db.enabled[t.key] == nil then db.enabled[t.key] = true end
	end
	if not db.channel or not CHANNELS[db.channel:lower()] then db.channel = "Music" end
end

---------------------------------------------------------------------------
-- Shuffle bag: every song plays once before any repeats, and a reshuffle
-- never starts with the song that just played.
---------------------------------------------------------------------------
local bag, lastIndex = {}, nil

local function nextSong()
	local n = #ns.songs
	if #bag == 0 then
		for i = 1, n do bag[i] = i end
		for i = n, 2, -1 do
			local j = math.random(i)
			bag[i], bag[j] = bag[j], bag[i]
		end
		if n > 1 and bag[n] == lastIndex then bag[n], bag[1] = bag[1], bag[n] end
	end
	lastIndex = table.remove(bag)
	return ns.songs[lastIndex]
end

---------------------------------------------------------------------------
-- Playback. Music channel uses PlayMusic (loops natively, replaces zone music).
-- Other channels use PlaySoundFile, re-triggered when the song ends.
---------------------------------------------------------------------------
local playing -- { song, channel, handle, timer }

local function stopSong()
	local p = playing
	if not p then return end
	playing = nil
	if p.timer then p.timer:Cancel() end
	if p.channel == "Music" then
		StopMusic()
	elseif p.handle then
		StopSound(p.handle, FADE_MS)
	end
end

local function startSong(verbose)
	stopSong()
	local song = nextSong()
	if not song then return end
	local file = MUSIC_PATH .. song.file
	local p = { song = song, channel = db.channel }
	playing = p
	if verbose then say(("playing %s on the %s channel"):format(song.name, p.channel)) end
	if p.channel == "Music" then
		PlayMusic(file)
	else
		local function play()
			if playing ~= p then return end
			local willPlay, handle = PlaySoundFile(file, p.channel)
			if not willPlay and verbose then
				say("the client refused " .. song.file .. " (missing file, or the " .. p.channel .. " channel is off/muted)")
			end
			p.handle = handle
			p.timer = C_Timer.NewTimer(song.length, play)
		end
		play()
	end
end

---------------------------------------------------------------------------
-- State tracking
---------------------------------------------------------------------------
local inCombat = false
local testing = false  -- /chocobo test on|off: forces "travelling" (not saved)
local TEST_TRIGGER = { key = "test", label = "Test mode" }
local known = {}   -- last definite answer per trigger
local stopTimer

local function activeTrigger()
	if inCombat then return nil end
	if testing then return TEST_TRIGGER end
	for _, t in ipairs(TRIGGERS) do
		if db.enabled[t.key] then
			local v = t.test()
			if v == nil then v = known[t.key] else known[t.key] = v end
			if v then return t end
		end
	end
	return nil
end

local function cancelStopTimer()
	if stopTimer then stopTimer:Cancel(); stopTimer = nil end
end

local function update()
	if not db then return end
	if activeTrigger() then
		cancelStopTimer()
		if not playing then startSong(testing) end
	elseif playing then
		if inCombat then
			cancelStopTimer()
			stopSong()
		elseif not stopTimer then
			stopTimer = C_Timer.NewTimer(STOP_GRACE, function()
				stopTimer = nil
				if not activeTrigger() then stopSong() end
			end)
		end
	end
end

local function updateSoon()
	C_Timer.After(0.3, update)
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------
local frame = CreateFrame("Frame")
frame:RegisterEvent("PLAYER_LOGIN")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")
frame:RegisterEvent("PLAYER_MOUNT_DISPLAY_CHANGED")
frame:RegisterEvent("UPDATE_SHAPESHIFT_FORM")
frame:RegisterEvent("PLAYER_REGEN_DISABLED")
frame:RegisterEvent("PLAYER_REGEN_ENABLED")
frame:RegisterEvent("PLAYER_CONTROL_LOST")
frame:RegisterEvent("PLAYER_CONTROL_GAINED")
frame:RegisterUnitEvent("UNIT_AURA", "player")

frame:SetScript("OnEvent", function(_, event)
	if event == "PLAYER_LOGIN" then
		initDB()
		inCombat = InCombatLockdown() and true or false
	elseif event == "PLAYER_REGEN_DISABLED" then
		inCombat = true
	elseif event == "PLAYER_REGEN_ENABLED" then
		inCombat = false
	elseif event == "PLAYER_CONTROL_LOST" or event == "PLAYER_CONTROL_GAINED"
		or event == "PLAYER_ENTERING_WORLD" then
		-- taxi state and mount state settle a moment after these fire
		updateSoon()
	end
	update()
end)

---------------------------------------------------------------------------
-- Slash command
---------------------------------------------------------------------------
local function onOff(v)
	return v and "|cff40ff40on|r" or "|cffff4040off|r"
end

local function musicDisabled()
	local ok, v = query(C_CVar.GetCVar, "Sound_EnableMusic")
	return ok and v == "0"
end

local function status()
	for _, t in ipairs(TRIGGERS) do
		say(("%-10s %s  (%s)"):format(t.key, onOff(db.enabled[t.key]), t.label))
	end
	say("channel    " .. db.channel)
	if testing then say("test mode " .. onOff(true)) end
	if playing then say("now playing: " .. playing.song.name) end
	say("usage: /chocobo <" .. table.concat((function()
		local keys = {}
		for _, t in ipairs(TRIGGERS) do keys[#keys + 1] = t.key end
		return keys
	end)(), "|") .. "> on|off,  /chocobo channel music|master|sfx|ambience|dialog,  /chocobo test on|off")
	if db.channel == "Music" and musicDisabled() then
		say("your Music channel is disabled in Sound settings - try /chocobo channel sfx")
	end
end

SLASH_CHOCOBO1 = "/chocobo"
SlashCmdList.CHOCOBO = function(msg)
	if not db then return end
	local cmd, arg = (msg or ""):lower():match("^%s*(%S*)%s*(%S*)")

	if cmd == "" then
		status()
		return
	end

	if cmd == "channel" then
		local channel = CHANNELS[arg]
		if not channel then
			say("channel must be one of: music, master, sfx, ambience, dialog (currently " .. db.channel .. ")")
			return
		end
		db.channel = channel
		say("playing on the " .. channel .. " channel")
		if channel == "Music" and musicDisabled() then
			say("note: your Music channel is disabled in Sound settings")
		end
		if playing then
			stopSong()
			update()
		end
		return
	end

	if cmd == "test" then
		if arg == "on" then
			testing = true
		elseif arg == "off" then
			testing = false
		elseif arg == "" then
			testing = not testing
		else
			say("use /chocobo test on or /chocobo test off")
			return
		end
		say("test mode " .. onOff(testing))
		if testing and inCombat then say("you're in combat - it will start when combat ends") end
		if testing and playing then
			-- already playing because you're travelling; restart so you hear the start
			stopSong()
		end
		if not testing then
			-- skip the grace period so you hear the stop immediately
			cancelStopTimer()
			if not activeTrigger() then stopSong() end
		end
		update()
		return
	end

	local t = TRIGGER_BY_KEY[cmd]
	if not t then
		say("unknown option '" .. cmd .. "'")
		status()
		return
	end
	local value
	if arg == "on" then
		value = true
	elseif arg == "off" then
		value = false
	elseif arg == "" then
		value = not db.enabled[t.key]
	else
		say("use on or off")
		return
	end
	db.enabled[t.key] = value
	say(t.label .. " " .. onOff(value))
	update()
end
