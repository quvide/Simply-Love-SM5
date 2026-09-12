-- Fetches each joined player's best ArrowCloud score for charts the wheel
-- visits and stores it in the score cache (Scripts/SL-Cache.lua) so the music
-- wheel can show it as a third source next to local and GrooveStats scores.
--
-- Chart identity is the engine's GrooveStats hash (steps:GetGrooveStatsHash()),
-- computed at song load and stored in the song cache, so it is available for
-- every chart at any time with no parsing. Score.lua reads the cache by the
-- same accessor.
--
-- Two triggers:
--   * Every wheel step (CurrentSongChanged / CurrentSteps<P>Changed, coalesced
--     into one pass per frame). Charts that already have an ArrowCloud row are
--     skipped, so holding a scroll through a pack requests only the unknown ones.
--   * ChartParsed, once the wheel has rested on a chart. This always refreshes
--     the focused chart (subject to the short response cache below) and also
--     checks that the theme's Lua hash agrees with the engine hash.
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

local BASE_URL = "https://api.arrowcloud.dance"
local REQUEST_TIMEOUT = 10
-- Responses are reused for this long so re-focusing a chart does not re-request it.
local RESPONSE_CACHE_SECONDS = 60
-- A response with no score for the player writes no cache row, so nothing stops a
-- wheel step from asking again. Such responses are remembered for longer; the
-- rested trigger (ChartParsed) ignores them and asks again.
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
	EX = CacheSetACEX,
	ITG = CacheSetACITG,
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

local function RemoveStaleResponses()
	local now = GetTimeSinceStart()
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

local function CancelAll()
	for entry in ivalues(Outstanding) do
		entry.handler:Cancel()
	end
	Outstanding = {}
	Pending = {}
end

local function SendRequest(self, ctx)
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
			if self.leaving_screen then return end
			if response.error then
				local err = ToEnumShortString(response.error)
				if err ~= "Cancelled" then
					lua.Warn("ArrowCloudScores: request failed (" .. err .. "), pausing for " .. ERROR_PAUSE_SECONDS .. "s")
					PausedUntil = GetTimeSinceStart() + ERROR_PAUSE_SECONDS
					CancelAll()
				end
				return
			end
			if response.statusCode ~= 200 then
				if AC_DEBUG then AC_DBG("HTTP " .. tostring(response.statusCode) .. " for " .. key) end
				-- Unknown chart (404), bad key (401) and the like: do not ask again on
				-- every wheel step. The rested trigger still retries.
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

-- Builds the request context for a player's current steps, or nil when there is
-- nothing to request (no key, no steps, empty hash, no persistent profile).
local function ContextFor(player, song)
	local pn = ToEnumShortString(player)
	local api_key = SL[pn].ArrowCloudApiKey or ""
	if api_key == "" or not PROFILEMAN:IsPersistentProfile(player) then return nil end

	local steps = GAMESTATE:GetCurrentSteps(player)
	if steps == nil then return nil end
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

-- Sends a request for ctx unless a fresh response or an outstanding request
-- already covers it. With refresh_empty, a remembered empty response does not
-- count as coverage.
local function Fetch(self, ctx, refresh_empty)
	local cached = ResponseCache[ctx.key]
	if cached ~= nil and not (refresh_empty and cached.empty) then
		StoreBestScores(cached.body, ctx)
	elseif not Pending[ctx.key] then
		SendRequest(self, ctx)
	end
end

return Def.Actor{
	InitCommand = function(self)
		self.leaving_screen = false
		self.step_pending = false
	end,
	OffCommand = function(self)
		self.leaving_screen = true
		CancelAll()
	end,
	CancelCommand = function(self)
		self.leaving_screen = true
		CancelAll()
	end,

	-- One wheel step broadcasts CurrentSongChanged and CurrentSteps<P>Changed
	-- back to back; coalesce them into a single pass on the next update.
	CurrentSongChangedMessageCommand = function(self) self:playcommand("RequestStep") end,
	CurrentStepsP1ChangedMessageCommand = function(self) self:playcommand("RequestStep") end,
	CurrentStepsP2ChangedMessageCommand = function(self) self:playcommand("RequestStep") end,
	RequestStepCommand = function(self)
		if not self.step_pending then
			self.step_pending = true
			self:queuecommand("WheelStep")
		end
	end,

	-- Wheel step: request only charts with no ArrowCloud row yet.
	WheelStepCommand = function(self)
		self.step_pending = false
		if GAMESTATE:IsCourseMode() then return end
		local song = GAMESTATE:GetCurrentSong()
		if song == nil then return end

		RemoveStaleResponses()
		for player in ivalues(GAMESTATE:GetHumanPlayers()) do
			local ctx = ContextFor(player, song)
			if ctx ~= nil and not HasRow(ctx) then
				Fetch(self, ctx)
			end
		end
	end,

	-- Wheel rested: refresh the focused chart even if a row exists.
	ChartParsedMessageCommand = function(self)
		if GAMESTATE:IsCourseMode() then return end
		local song = GAMESTATE:GetCurrentSong()
		if song == nil then return end

		RemoveStaleResponses()
		for player in ivalues(GAMESTATE:GetHumanPlayers()) do
			local ctx = ContextFor(player, song)
			if ctx ~= nil then
				-- The GrooveStats pane and score submission still use the theme's Lua
				-- parser hash. Both must agree for cache rows to be found; report if not.
				local lua_hash = SL[ctx.pn].Streams.Hash
				if lua_hash ~= nil and lua_hash ~= "" and lua_hash ~= ctx.hash then
					lua.Warn("ArrowCloudScores: hash mismatch for " .. song:GetMainTitle() .. " " .. ctx.pn .. ": engine=" .. ctx.hash .. " theme=" .. lua_hash)
				end
				Fetch(self, ctx, true)
			end
		end
	end,
}
