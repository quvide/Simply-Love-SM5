-- Display best EX from stored highscores
local player = ...

local function CalculateExScoreFromHighscoreAndSteps(hs, steps, pn)
   	-- white fa count is stored in score 🤯
    -- https://discord.com/channels/292111865658474496/958039182327029840/1156796786061606972
	local score = hs:GetScore()
	local ex_counts = {
        W0 = hs:GetTapNoteScore(ToEnumShortString("TNS_W1")) - score,
		W1 = score,
		W2 = hs:GetTapNoteScore(ToEnumShortString("TNS_W2")),
		W3 = hs:GetTapNoteScore(ToEnumShortString("TNS_W3")),
		W4 = hs:GetTapNoteScore(ToEnumShortString("TNS_W4")),
		W5 = hs:GetTapNoteScore(ToEnumShortString("TNS_W5")),
		Miss = hs:GetTapNoteScore(ToEnumShortString("TNS_Miss")),
		Held = hs:GetHoldNoteScore(ToEnumShortString("HNS_Held")),
		LetGo = hs:GetHoldNoteScore(ToEnumShortString("HNS_LetGo")),
		HitMine = hs:GetTapNoteScore(ToEnumShortString("TNS_HitMine"))
	}

    local use_actual_w0_weight = true
    local po_NoMines = false -- can't determine from highscore?
	return CalculateExScoreNoGlobalState(steps, pn, po_NoMines, ex_counts, use_actual_w0_weight)
end

local function MusicRateFromHighscore(hs)
    local rate = string.match(hs:GetModifiers(), "([%d%.]+)xMusic")
    return tonumber(rate) or 1
end

-- Based on GetLamp
-- Colors in SL.JudgementColors["FA+"]:
-- 1: blue    (FFC)
-- 2: white   (normal)
-- 3: gold    (FEC)
-- 4: green   (FC)
-- 5: purple  (FBFC)
-- 6: red     (fail)
-- Still called AwardMap since it's mostly based on the awards...
local AwardMap = {
	["StageAward_FullComboW1"] = 1,
	["StageAward_FullComboW2"] = 3,
	["StageAward_SingleDigitW2"] = 3,
	["StageAward_OneW2"] = 3,
	["StageAward_FullComboW3"] = 4,
	["StageAward_SingleDigitW3"] = 4,
	["StageAward_OneW3"] = 4,
	["StageAward_100PercentW3"] = 4,
	-- The StageAwards below technically doesn't exist, but we create them on the
	-- fly below.
	["StageAward_FullComboW0"] = 5,
    ["normal"] = 2,
    ["fail"] = 6
}

-- Based on GetLamp
local function AwardMapIndexColorForHighScore(score)
	local award = score:GetStageAward()
    local grade = score:GetGrade()

    -- quint
	if grade == "Grade_Tier01" then
		if score:GetPercentDP() == 1.0 and score:GetScore() < score:GetTapNoteScore("TapNoteScore_W1") and score:GetScore() == 0 then
			award = "StageAward_FullComboW0"
		end
	end

    if grade == "Grade_Failed" then
        award = "fail"
    end

    if award == nil then
        award = "normal"
    end

    local award_table_index = AwardMap[award]
    if award_table_index == nil then
        -- there are some other weird GetStageAward values for scores with a lot of greats, ignore them
        award_table_index = AwardMap["normal"]
    end

    return award_table_index
end

local function SetGetGSCachedScore(steps, ex)
    local chart_gs_hash = steps:GetGrooveStatsHash()
    local player_name = PROFILEMAN:GetPlayerName(player)

    local cached_score = nil
    local t = SLProf.Begin()
    if ex then
        cached_score = CacheGetGSEX(player_name, chart_gs_hash)
    else
        cached_score = CacheGetGSITG(player_name, chart_gs_hash)
    end
    SLProf.End("GS.CacheGet", t)

    if cached_score ~= nil then
        return cached_score
    end

    return nil
end

-- ArrowCloud rows are written by ScreenSelectMusic overlay/ArrowCloudScores.lua.
-- The colour index is only present when the grade pins the lamp down.
---@return string?, table?
local function GetACCachedScore(steps, ex)
    local chart_gs_hash = steps:GetGrooveStatsHash()
    local player_name = PROFILEMAN:GetPlayerName(player)

    local t = SLProf.Begin()
    local cached_score, cached_idx
    if ex then
        cached_score, cached_idx = CacheGetACEX(player_name, chart_gs_hash)
    else
        cached_score, cached_idx = CacheGetACITG(player_name, chart_gs_hash)
    end
    SLProf.End("AC.CacheGet", t)

    if cached_score == nil then
        return nil, nil
    end
    local color = cached_idx ~= nil and SL.JudgmentColors["FA+"][tonumber(cached_idx)] or nil
    return cached_score, color
end

local function GetSetLocalCachedScore(song, steps, ex)
    local pn = ToEnumShortString(player)
    local chart_gs_hash = steps:GetGrooveStatsHash()
    local current_song = GAMESTATE:GetCurrentSong()

    local player_name = PROFILEMAN:GetPlayerName(player)
    local t = SLProf.Begin()
    local highscores = PROFILEMAN:GetProfile(pn):GetHighScoreList(song, steps):GetHighScores()
    SLProf.End("Local.GetHighScores", t)

    -- The cache is keyed by chart hash, so a row may have come from another copy of the
    -- same chart in a different pack, or from a play whose profile was never saved. The
    -- cached row is treated as authoritative: the live high score list only replaces it
    -- when it offers a strictly better score. Scores are "%05.2f" strings, compared numerically.
    local function MergeWithCache(live_score, live_idx, cached_score, cached_idx, setter)
        if cached_score ~= nil and (live_score == nil or tonumber(cached_score) >= tonumber(live_score)) then
            return cached_score, tonumber(cached_idx)
        end
        if live_score ~= nil then
            t = SLProf.Begin()
            -- without ("%d"):format, the index gets stored as a float string in sqlite
            setter(player_name, chart_gs_hash, live_score, ("%d"):format(live_idx))
            SLProf.End("Local.CacheSet", t)
        end
        return live_score, live_idx
    end

    if ex then
        t = SLProf.Begin()
        local cached_ex, cached_award_map_idx = CacheGetLocalEX(player_name, chart_gs_hash)
        SLProf.End("Local.CacheGet", t)

        if cached_ex ~= nil and song ~= current_song then
            return cached_ex, SL.JudgmentColors["FA+"][tonumber(cached_award_map_idx)]
        end

        -- Calculate from all local scores
        t = SLProf.Begin()
        SLProf.Count("Local.EXCalc.highscores", #highscores)
        ---@type number?
        local live_ex = nil
        local hs_for_live_ex = nil
        for hs in ivalues(highscores) do
            if MusicRateFromHighscore(hs) >= 1 then
                local ex_value = CalculateExScoreFromHighscoreAndSteps(hs, steps, pn)
                if ex_value ~= nil and (live_ex == nil or ex_value > live_ex) then
                    live_ex = ex_value
                    hs_for_live_ex = hs
                end
            end
        end
        SLProf.End("Local.EXCalc", t)

        local live_ex_string, live_idx = nil, nil
        if live_ex ~= nil then
            live_ex_string = ("%05.2f"):format(live_ex)
            live_idx = AwardMapIndexColorForHighScore(hs_for_live_ex)
        end

        local best_ex, best_idx = MergeWithCache(live_ex_string, live_idx, cached_ex, cached_award_map_idx, CacheSetLocalEX)
        return best_ex, SL.JudgmentColors["FA+"][best_idx]
    else -- ITG score
        t = SLProf.Begin()
        local cached_itg, cached_award_map_idx = CacheGetLocalITG(player_name, chart_gs_hash)
        SLProf.End("Local.CacheGet", t)

        if cached_itg ~= nil and song ~= current_song then
            return cached_itg, SL.JudgmentColors["FA+"][tonumber(cached_award_map_idx)]
        end

        -- The high score list is ordered by PercentDP under PercentageScoring, so the first
        -- eligible entry is the best one.
        local live_itg_string, live_idx = nil, nil
        for hs in ivalues(highscores) do
            if MusicRateFromHighscore(hs) >= 1 then
                live_itg_string = ("%05.2f"):format(hs:GetPercentDP() * 100)
                -- TODO: does AwardMapIndexColorForHighScore work properly for ITG scores?
                live_idx = AwardMapIndexColorForHighScore(hs)
                break
            end
        end

        local best_itg, best_idx = MergeWithCache(live_itg_string, live_idx, cached_itg, cached_award_map_idx, CacheSetLocalITG)
        return best_itg, SL.JudgmentColors["FA+"][best_idx]
    end
end

local function UpdatePosition(actor)
    local p1setting = PlayerMusicWheelScore(PLAYER_1)
    local p2setting = PlayerMusicWheelScore(PLAYER_2)
    if GAMESTATE:GetNumSidesJoined() == 2 and p1setting == p2setting and (p1setting == PlayerMusicWheelScore_ReplaceGrade or p1setting == PlayerMusicWheelScore_Yes) then
        if player == PLAYER_1 then
            actor:y(-11)
        else
            actor:y(4)
        end
    else
        actor:y(-4)
    end
    
    if PlayerMusicWheelScore(player) == PlayerMusicWheelScore_ReplaceGrade then
        if GAMESTATE:GetNumSidesJoined() == 2 and player == PLAYER_1 and PlayerMusicWheelScore(PLAYER_2) ~= PlayerMusicWheelScore_ReplaceGrade then
            -- 2 players, we're P1 and P2 has grade
            actor:x(20)
            actor:maxwidth(160)
        elseif GAMESTATE:GetNumSidesJoined() == 2 and player == PLAYER_2 and PlayerMusicWheelScore(PLAYER_1) ~= PlayerMusicWheelScore_ReplaceGrade then
            -- 2 players, we're P2 and P1 has grade
            actor:x(50)
            actor:maxwidth(0)
        else
            actor:x(32)
            actor:maxwidth(0)
        end
    else
        -- Similar to ITL_EXScore.lua
        actor:x(_screen.w / WideScale(2.15, 2.14) - 35)
    end
end

-- Guard call sites that build their message (concatenation, GetSongDir etc.) with this
-- flag so the argument is not evaluated when logging is off.
local EXSCORE_DEBUG = false
local function EXScore_DBG(message)
    lua.Info(message)
end

-- The body of SetCommand. Returns a short label describing which exit was taken,
-- which SetCommand uses as the profiler section name.
local function RunSet(self, params)
    if EXSCORE_DEBUG then EXScore_DBG("Running SetCommand") end

    -- stored for RefreshCommand
    if params and params.Song then
        self.LatestSetSong = params.Song
    end

    -- Section headers, sort entries etc. carry no Song, and the engine hides the whole
    -- Song NormalPart for them, so there is nothing to compute or lay out. Bail before
    -- the gates. The CacheUpdatedGS replay passes no Song either but must proceed.
    if params == nil or (params.Song == nil and params.CacheUpdatedGS == nil) then
        if EXSCORE_DEBUG then EXScore_DBG("Early return due to nil song.") end
        return "exit_nil_song"
    end

    -- Goal here is to utilize different levels of caches to do as little
    -- processing as possible to keep the UI snappy.

    local currentDifficulty, currentStepsType
    local currentSteps = GAMESTATE:GetCurrentSteps(player)
    if currentSteps == nil then
        -- We're probably on a group header. Match grade behaviour.
        currentDifficulty = GAMESTATE:GetPreferredDifficulty(player)
        currentStepsType = GAMESTATE:GetCurrentStyle():GetStepsType()
    else
        currentDifficulty = currentSteps:GetDifficulty()
        currentStepsType = currentSteps:GetStepsType()
    end
    
    local currentSong = GAMESTATE:GetCurrentSong()

    local song = nil

    -- If there's a params.Song, we are being called by the engine.
    -- In this case we want to check if this actor is already displaying the
    -- score for this song. If the the difficulty has changed, the steps
    -- are probably different too. Don't want to move the step selection logic
    -- so high up as it's more complicated.
    if params ~= nil and params.Song ~= nil then
        song = params.Song
        if self.Song == song and self.Difficulty == currentDifficulty then
            -- Song could have multiple steps with the same Difficulty
            if song ~= currentSong or self.Steps == currentSteps then
                -- Song and difficulty hasn't changed, don't need to update anything!
                if EXSCORE_DEBUG then EXScore_DBG("Early return due to song being the same as previously") end
                return "exit_cache_hit"
            end
        end
    -- If we're running due to the groovestats cache being updated (CacheUpdatedGSMessageCommand)
    -- self.Song must also be set on an earlier round, otherwise the first valid run of this command
    -- will get the latest cached value anyways.
    elseif params ~= nil and params.CacheUpdatedGS ~=nil and self.Song ~=nil then
        song = self.Song
    -- This branch is ran when
    -- 1. The engine runs us with a nil params.Song
    -- 2. CacheUpdatedGS runs us but SetCommand has not yet ran completely.
    else
        if EXSCORE_DEBUG then EXScore_DBG("Early return due to nil song.") end
        return "exit_nil_song"
    end

    if EXSCORE_DEBUG and song ~= nil then EXScore_DBG("SetCommand song is " .. song:GetSongDir()) end

    -- The gates sit below the cache check on purpose. The cache is only populated on
    -- the full path, which these gates protect, and every event that can change their
    -- answer (join, unjoin, profile switch, mode change via a screen reload) clears it,
    -- so a cache hit implies the gates already passed for the state on screen.

    -- Only display score if enabled in settings
    if PlayerMusicWheelScore(player) == PlayerMusicWheelScore_No then
        self:visible(false)
        return "exit_mode_no"
    end

    -- Only display EX score if a profile is found for an enabled player.
    if not GAMESTATE:IsPlayerEnabled(player) or not PROFILEMAN:IsPersistentProfile(player) then
        self:visible(false):settext("")
        return "exit_not_enabled"
    end

    -- Layout depends only on joined players and their modes. Those change only on
    -- join/unjoin/profile switch, and RefreshCommand clears the cache for those, so
    -- every such change reaches this point. No need to do it on the cache-hit path.
    local t = SLProf.Begin()
    UpdatePosition(self)
    SLProf.End("Set.UpdatePosition", t)

    -- If we have reached this point, we have a song.
    -- If there is an early return past this point,
    -- something was invalid and we don't want to display anything.
    self:visible(false):settext("")
    self.Song = nil
    self.Difficulty = nil
    self.Steps = nil

    local steps = nil
    -- currentStep doesn't guarantee currentSteps isn't nil
    if song == currentSong and currentSteps then
        steps = currentSteps
    else
        -- Show value from a different song that matches the currently selected difficulty.
        t = SLProf.Begin()
        local allSteps = SongUtil.GetPlayableSteps(song)
        SLProf.End("Set.GetPlayableSteps", t)
        if #allSteps == 1 then
            -- If there's only a single difficulty, don't try to match the difficulty. Just show the only one.
            -- This is important for tournament packs which usually have other difficulties removed.
            steps = allSteps[1]
        else
            -- Matches the engine behaviour on which Grade is displayed
            for v in ivalues(allSteps) do
                if v:GetStepsType() == currentStepsType and v:GetDifficulty() == currentDifficulty then
                    steps = v
                    break
                end
            end
        end
    end

    if steps == nil then
        if EXSCORE_DEBUG then EXScore_DBG("Early return due to nil steps") end
        return "exit_nil_steps"
    end

    if EXSCORE_DEBUG then EXScore_DBG("Actually calculating something for " .. song:GetMainTitle()) end

    ---@type boolean
    local showExScore = SL[ToEnumShortString(player)].ActiveModifiers.ShowExScore

    -- Local score. GetSetLocalCached... will recalculate if this song is the currently selected song.
    ---@type string?
    local local_score = nil
    ---@type table?
    local local_score_color = nil

    -- GrooveStats score. GetSetGSCached... will not call the API, that's done by PaneDisplay.
    -- PaneDisplay broadcasts CacheUpdatedGS when it writes something to the cache.
    ---@type string?
    local groovestats_score = nil

    -- ArrowCloud score, fetched and cached by ArrowCloudScores.lua on ScreenSelectMusic,
    -- which broadcasts CacheUpdatedGS as well.
    ---@type string?
    local arrowcloud_score = nil
    ---@type table?
    local arrowcloud_score_color = nil

    t = SLProf.Begin()
    local_score, local_score_color = GetSetLocalCachedScore(song, steps, showExScore)
    SLProf.End("Set.LocalScore", t)
    if ThemePrefs.Get("EnableGrooveStats") then
        t = SLProf.Begin()
        groovestats_score = SetGetGSCachedScore(steps, showExScore)
        SLProf.End("Set.GSScore", t)
    end
    if (SL[ToEnumShortString(player)].ArrowCloudApiKey or "") ~= "" then
        t = SLProf.Begin()
        -- Ask for this chart's row if the cache has none. This runs once per song
        -- this item shows (the cache-hit path above skips it), so every chart in
        -- view is requested as soon as the wheel shows it. A hot response fills
        -- the row synchronously, hence the request goes before the read.
        ArrowCloudScores.Request(player, steps, song)
        arrowcloud_score, arrowcloud_score_color = GetACCachedScore(steps, showExScore)
        SLProf.End("Set.ACScore", t)
    end

    if EXSCORE_DEBUG then EXScore_DBG(song:GetMainTitle() .. " -- local_score: " .. tostring(local_score) .. " local_score_color: " .. tostring(local_score_color) .. " ac: " .. tostring(arrowcloud_score) .. " gs: " .. tostring(groovestats_score)) end

    -- Display the best score. Candidates are considered in priority order and a
    -- later one only wins by being strictly higher, so on a tie the source that
    -- knows the most about the lamp is shown: local (full judgment counts), then
    -- ArrowCloud (grade pins the lamp down at the extremes), then GrooveStats
    -- (score only). A source without a known lamp colour is drawn white.
    t = SLProf.Begin()
    local white = color("#ffffff")
    local best_score, best_color, best_value = nil, nil, nil
    local function Consider(score, score_color)
        local value = score ~= nil and tonumber(score) or nil
        if value ~= nil and (best_value == nil or value > best_value) then
            best_score, best_color, best_value = score, score_color or white, value
        end
    end
    Consider(local_score, local_score_color)
    Consider(arrowcloud_score, arrowcloud_score_color)
    Consider(groovestats_score, nil)

    if best_score ~= nil then
        self:settext(best_score)
        self:diffuse(best_color)
        self:visible(true)
    end

    SLProf.End("Set.Display", t)

    -- Flag that we are already displaying an accurate result for the song & difficulty pair
    self.Song = song
    self.Difficulty = currentDifficulty
    self.Steps = steps
    return "full"
end

-- Add EX scores to the song wheel as well.
-- It will be centered to the item if only one player is enabled, and stacked otherwise.
return Def.BitmapText {
    Font = "Wendy/_wendy monospace numbers",
    Text = "",

    InitCommand = function(self)
        self:visible(false)
        self:zoom(0.2)
        UpdatePosition(self)
    end,

    PlayerJoinedMessageCommand = function(self) self:queuecommand("Refresh") end,
    PlayerUnjoinedMessageCommand = function(self) self:queuecommand("Refresh") end,
    PlayerProfileSetMessageCommand = function(self) self:queuecommand("Refresh") end,

    RefreshCommand = function(self)
        self.Song = nil
        self:visible(false)
        if self.LatestSetSong then
            self:playcommand("Set", { Song = self.LatestSetSong })
        end
    end,

    SetCommand = function(self, params)
        local t = SLProf.Begin()
        local outcome = RunSet(self, params)
        SLProf.End("Set." .. outcome, t)
        SLProf.MaybeDump()
    end,

    CacheUpdatedGSMessageCommand = function(self, params)
        if EXSCORE_DEBUG then EXScore_DBG("Got CacheUpdatedGS " .. tostring(params.Song)) end
        -- Optimization: only refresh the song that was updated.
        if params.Song == self.Song then
            self:playcommand("Set", { CacheUpdatedGS = true })
        else
            if EXSCORE_DEBUG then EXScore_DBG("CacheUpdatedGS not calling Set due to self.Song not matching") end
        end
    end
}