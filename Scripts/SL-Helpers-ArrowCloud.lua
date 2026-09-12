-- -----------------------------------------------------------------------
-- ArrowCloud helpers shared between the ArrowCloud module and the theme.
--
-- The module (Modules/ArrowCloud.lua) owns the ArrowCloud.ini file in the
-- player's profile: it creates it, writes the key after a QR login and reads it
-- back for score submission. This file only mirrors the key into SL[pn] so that
-- screens which do not go through the module (the music wheel score cache) can
-- authenticate. The module calls ParseArrowCloudIni itself after a login so the
-- in-memory copy is refreshed without a profile reload.

local profile_slot = {
	[PLAYER_1] = "ProfileSlot_Player1",
	[PLAYER_2] = "ProfileSlot_Player2"
}

-- Reads <profile>/ArrowCloud.ini and stores the API key in SL[pn].ArrowCloudApiKey.
-- Read-only on purpose: the ini is created and rewritten by the module.
ParseArrowCloudIni = function(player)
	if not player or not profile_slot[player] then return end

	local pn = ToEnumShortString(player)
	SL[pn].ArrowCloudApiKey = ""

	local dir = PROFILEMAN:GetProfileDir(profile_slot[player])
	-- We require an explicit profile to be loaded.
	if not dir or #dir == 0 then return end

	local path = dir .. "ArrowCloud.ini"
	if not FILEMAN:DoesFileExist(path) then return end

	local contents = IniFile.ReadFile(path)
	local section = contents and contents["ArrowCloud"]
	if type(section) ~= "table" then return end

	local key = section["ApiKey"]
	if type(key) == "string" and #key > 0 then
		SL[pn].ArrowCloudApiKey = key
	end
end

-- -----------------------------------------------------------------------
-- ArrowCloudScores: fetches a player's best ArrowCloud score for a chart and
-- stores it in the score cache (Scripts/SL-Cache.lua) so the music wheel can
-- show it as a third source next to local and GrooveStats scores.
--
-- Callers:
--   * Every music wheel item (Graphics/MusicWheelItem Song NormalPart/Score.lua)
--     calls Request for the chart it displays when it finds no ArrowCloud row,
--     so the charts in view are fetched as soon as the wheel shows them.
--   * ScreenSelectMusic overlay/ArrowCloudScores.lua cancels outstanding
--     requests when the screen goes away and refreshes the focused chart on
--     ChartParsed.
--
-- Chart identity is the engine's GrooveStats hash (steps:GetGrooveStatsHash()),
-- computed at song load and stored in the song cache, so it is available for
-- every chart at any time with no parsing.
--
-- Requests are NOT cancelled when the wheel moves on. A late response still
-- fills the cache for the song it was requested for. The engine runs HTTP
-- requests through a single worker, one at a time, so the number of outstanding
-- requests is capped and the oldest queued one is dropped past the cap; the one
-- in flight is kept since it is closest to finishing.
--
-- Response shape (GET /v1/chart/{hash}/leaderboards, Bearer auth):
--   { leaderboards = { { type = "EX"|"ITG"|"HardEX", scores = { { isSelf, score, grade, ... } } } } }
-- The caller's own best row is always included and flagged isSelf.

ArrowCloudScores = {}

local BASE_URL = "https://api.arrowcloud.dance"
local REQUEST_TIMEOUT = 10
-- Responses are reused for this long so re-focusing a chart does not re-request it.
local RESPONSE_CACHE_SECONDS = 60
-- A response with no score for the player writes no cache row, so nothing stops a
-- wheel item from asking again. Such responses are remembered for longer; the
-- rested refresh ignores them and asks again.
local EMPTY_RESPONSE_CACHE_SECONDS = 15 * 60
-- After a transport error (offline, DNS, blocked host) every queued request would
-- fail the same way, each after its own connect timeout. Drop them and pause.
local ERROR_PAUSE_SECONDS = 60
local MAX_OUTSTANDING = 100

local AC_DEBUG = false
local function AC_DBG(message)
	lua.Info("ArrowCloudScores: " .. message)
end

-- Leaderboard type -> cache setter. HardEX has no local counterpart and is skipped.
local Setters = {
	EX = function(...) CacheSetACEX(...) end,
	ITG = function(...) CacheSetACITG(...) end,
}

-- The grade alone pins the lamp down only at the extremes. Indices refer to
-- SL.JudgmentColors["FA+"] as used by the wheel item (see AwardMap in
-- Graphics/MusicWheelItem Song NormalPart/Score.lua):
--   Quint: EX 100, every note in the W0 window     -> 5 (purple)
--   Quad:  money 100, every note W1 or better, all holds held, no mines -> 1 (blue)
--   F:     failed                                   -> 6 (red)
-- Any other grade may or may not be a full combo, so no colour is stored and the
-- wheel draws the score white.
local GradeToAwardMapIndex = {
	Quint = 5,
	Quad = 1,
	F = 6,
}

-- response cache: key -> { body = <decoded table>, timestamp = <seconds since start>, empty = <bool> }
local ResponseCache = {}
-- requests sent and not yet answered, oldest first: { handler = <HttpRequestFuture>, key = <string> }
local Outstanding = {}
-- key -> true while a request for that key is outstanding
local Pending = {}
-- no requests are sent before this time (seconds since start)
local PausedUntil = 0
local LastStaleSweep = 0

-- The key covers the API key so a profile switch never reuses another account's response.
local function RequestKey(pn, hash, api_key)
	return pn .. "|" .. hash .. "|" .. api_key
end

local function RemoveOutstanding(key)
	for i, entry in ipairs(Outstanding) do
		if entry.key == key then
			table.remove(Outstanding, i)
			break
		end
	end
	Pending[key] = nil
end

-- Sweeps expired responses at most once a second; Request runs from every wheel item.
local function RemoveStaleResponses()
	local now = GetTimeSinceStart()
	if now - LastStaleSweep < 1 then return end
	LastStaleSweep = now
	for key, entry in pairs(ResponseCache) do
		local ttl = entry.empty and EMPTY_RESPONSE_CACHE_SECONDS or RESPONSE_CACHE_SECONDS
		if now - entry.timestamp >= ttl then
			ResponseCache[key] = nil
		end
	end
end

-- Writes the isSelf rows of the EX and ITG leaderboards to the cache and
-- replays the wheel item for the song the request was made for.
-- Returns true when at least one row was written.
local function StoreBestScores(body, ctx)
	if type(body) ~= "table" or type(body.leaderboards) ~= "table" then return false end

	local stored = false
	for lb in ivalues(body.leaderboards) do
		local setter = Setters[lb.type]
		if setter and type(lb.scores) == "table" then
			for entry in ivalues(lb.scores) do
				if entry.isSelf then
					local score = tonumber(entry.score)
					if score ~= nil then
						local idx = GradeToAwardMapIndex[entry.grade]
						-- Same "%05.2f" format as the local rows so they compare numerically.
						setter(ctx.player_name, ctx.hash, ("%05.2f"):format(score), idx and ("%d"):format(idx) or nil)
						stored = true
						if AC_DEBUG then AC_DBG(lb.type .. " " .. ctx.hash .. " " .. tostring(entry.score) .. " grade=" .. tostring(entry.grade)) end
					end
					break
				end
			end
		end
	end

	if stored then
		-- Score.lua listens to this for GrooveStats updates too; it refreshes only
		-- the item whose song matches, so a late response for a song the wheel has
		-- moved past still lands on the right item.
		MESSAGEMAN:Broadcast("CacheUpdatedGS", { Song = ctx.song })
	end
	return stored
end

function ArrowCloudScores.CancelAll()
	for entry in ivalues(Outstanding) do
		entry.handler:Cancel()
	end
	Outstanding = {}
	Pending = {}
end

local function SendRequest(ctx)
	if GetTimeSinceStart() < PausedUntil then return end

	-- Keep the in-flight request (index 1) and drop the oldest queued one.
	while #Outstanding >= MAX_OUTSTANDING do
		local victim = table.remove(Outstanding, 2)
		Pending[victim.key] = nil
		victim.handler:Cancel()
		if AC_DEBUG then AC_DBG("dropped queued request " .. victim.key) end
	end

	local key = ctx.key
	Pending[key] = true
	local entry = { key = key }
	entry.handler = NETWORK:HttpRequest{
		url = BASE_URL .. "/v1/chart/" .. ctx.hash .. "/leaderboards",
		method = "GET",
		headers = {
			["Authorization"] = "Bearer " .. ctx.api_key,
		},
		connectTimeout = REQUEST_TIMEOUT,
		transferTimeout = REQUEST_TIMEOUT,
		onResponse = function(response)
			RemoveOutstanding(key)
			if response.error then
				local err = ToEnumShortString(response.error)
				if err ~= "Cancelled" then
					lua.Warn("ArrowCloudScores: request failed (" .. err .. "), pausing for " .. ERROR_PAUSE_SECONDS .. "s")
					PausedUntil = GetTimeSinceStart() + ERROR_PAUSE_SECONDS
					ArrowCloudScores.CancelAll()
				end
				return
			end
			if response.statusCode ~= 200 then
				if AC_DEBUG then AC_DBG("HTTP " .. tostring(response.statusCode) .. " for " .. key) end
				-- Unknown chart (404), bad key (401) and the like: do not ask again from
				-- every wheel item. The rested refresh still retries.
				ResponseCache[key] = { body = {}, timestamp = GetTimeSinceStart(), empty = true }
				return
			end
			local body = JsonDecode(response.body)
			if type(body) ~= "table" then return end
			local stored = StoreBestScores(body, ctx)
			ResponseCache[key] = { body = body, timestamp = GetTimeSinceStart(), empty = not stored }
		end,
	}
	Outstanding[#Outstanding + 1] = entry
end

-- Builds the request context, or nil when there is nothing to request
-- (no key, empty hash, no persistent profile).
local function ContextFor(player, steps, song)
	if steps == nil or song == nil then return nil end
	local pn = ToEnumShortString(player)
	local api_key = SL[pn].ArrowCloudApiKey or ""
	if api_key == "" or not PROFILEMAN:IsPersistentProfile(player) then return nil end

	local hash = steps:GetGrooveStatsHash()
	if hash == nil or hash == "" then return nil end

	return {
		key = RequestKey(pn, hash, api_key),
		pn = pn,
		hash = hash,
		api_key = api_key,
		player_name = PROFILEMAN:GetPlayerName(player),
		song = song,
	}
end

local function HasRow(ctx)
	return CacheGetACEX(ctx.player_name, ctx.hash) ~= nil or CacheGetACITG(ctx.player_name, ctx.hash) ~= nil
end

-- Requests the player's best score for steps unless a cache row, a fresh
-- response or an outstanding request already covers it. With refresh, an
-- existing row or a remembered empty response does not count as coverage.
-- Cheap when nothing is needed: a few table lookups.
function ArrowCloudScores.Request(player, steps, song, refresh)
	local ctx = ContextFor(player, steps, song)
	if ctx == nil then return end
	if not refresh and HasRow(ctx) then return end

	RemoveStaleResponses()
	local cached = ResponseCache[ctx.key]
	if cached ~= nil and not (refresh and cached.empty) then
		StoreBestScores(cached.body, ctx)
	elseif not Pending[ctx.key] then
		SendRequest(ctx)
	end
end
