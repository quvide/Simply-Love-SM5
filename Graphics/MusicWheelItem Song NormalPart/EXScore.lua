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
local function EXColorForHighScore(score)
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

    local aw_res = AwardMap[award]
	return SL.JudgmentColors["FA+"][aw_res]
end

local function SetGetGSCachedEX(steps)
    -- Adapted from SL-ChartParser.lua
    -- StepsType, a string like "dance-single" or "pump-double"
    local stepsType = ToEnumShortString( steps:GetStepsType() ):gsub("_", "-"):lower()
    -- Difficulty, a string like "Beginner" or "Challenge"
    local difficulty = ToEnumShortString( steps:GetDifficulty() )
    -- An arbitary but unique string provided by the stepartist, needed here to identify Edit charts
    local description = steps:GetDescription()

    local filepath = steps:GetFilename()

    local charthash = CacheGetChartHash(filepath, difficulty, description)
    if charthash == nil then
        local simfileString, fileType = GetSimfileString(steps)
        local chartString, BPMs = GetSimfileChartString(simfileString, stepsType, difficulty, description, fileType)
        charthash = BinaryToHex(CRYPTMAN:SHA1String(chartString..BPMs)):sub(1, 16)
        CacheSetChartHash(filepath, difficulty, description, charthash)
    end

    local playerName = PROFILEMAN:GetPlayerName(player)
    local cachedEX = CacheGetGSEX(charthash, playerName)

    if cachedEX ~= nil then
        return cachedEX
    end

    return nil
end

local function GetLocalBestEX(song, steps)
    local pn = ToEnumShortString(player)
    local highscores = PROFILEMAN:GetProfile(pn):GetHighScoreList(song, steps):GetHighScores()

    local best_ex = nil
    local hs_for_best_ex = nil
    for hs in ivalues(highscores) do
        local ex = CalculateExScoreFromHighscoreAndSteps(hs, steps, pn)
        if ex ~= nil and best_ex == nil then
            best_ex = ex
            hs_for_best_ex = hs
        elseif ex ~= nil and ex > best_ex then
            best_ex = ex
            hs_for_best_ex = hs
        end
    end

    return best_ex, hs_for_best_ex
end

local function UpdateYPosition(actor)
    if GAMESTATE:GetNumSidesJoined() == 2 then
        if player == PLAYER_1 then
            actor:y(-11)
        else
            actor:y(4)
        end
    else
        actor:y(-4)
    end
end

local function EXScore_DBG(message)
    -- lua.Info(message)
end

-- Add EX scores to the song wheel as well.
-- It will be centered to the item if only one player is enabled, and stacked otherwise.
return Def.BitmapText {
    Font = "Wendy/_wendy monospace numbers",
    Text = "",

    InitCommand = function(self)
        self:visible(false)
        self:zoom(0.2)
        self:x(32)
        UpdateYPosition(self)
    end,

    PlayerJoinedMessageCommand = function(self)
        self:visible(GAMESTATE:IsPlayerEnabled(player))
        UpdateYPosition(self)
    end,

    PlayerUnjoinedMessageCommand = function(self)
        self:visible(GAMESTATE:IsPlayerEnabled(player))
        UpdateYPosition(self)
    end,

    SetCommand = function(self, params)
        EXScore_DBG("Running SetCommand")

        -- Goal here is to utilize different levels of caches to do as little
        -- processing as possible to keep the UI snappy.

        -- Only display EX score if a profile is found for an enabled player.
        if not GAMESTATE:IsPlayerEnabled(player) or not PROFILEMAN:IsPersistentProfile(player) then
            self:visible(false):settext("")
            return
        end

        local song = nil

        -- If there's a params.Song, we are being called by the engine.
        -- In this case we want to check if this actor is already displaying the
        -- score for this song.
        if params ~= nil and params.Song ~= nil then
            song = params.Song
            if self.Song == song then
                -- Song hasn't changed, don't need to update anything!
                EXScore_DBG("Early return due to song being the same as previously")
                return
            end
        -- self.Song is set, so we must have already displayed a score for this song.
        -- There's a possibility that we're running SetCommand due to
        -- CacheUpdatedGSEXMessageCommand running us.
        elseif self.Song ~=nil then
            song = self.Song
        -- This branch is ran when
        -- 1. The engine runs us with a nil params.Song
        -- 2. CacheUpdatedGSEX runs us but SetCommand has not yet ran completely.
        else
            EXScore_DBG("Early return due to nil song. ")
            return
        end

        if song ~= nil then EXScore_DBG("SetCommand song is " .. song:GetMainTitle()) end

        -- If we have reached this point, we have a song.
        -- If there is an early return past this point,
        -- something was invalid and we don't want to display anything.
        self:visible(false):settext("")

        local currentSteps = GAMESTATE:GetCurrentSteps(player)
        if currentSteps == nil then
            EXScore_DBG("Early return due to nil currentSteps")
            return
        end

        local allSteps = SongUtil.GetPlayableSteps(song)
        -- Show value that matches the currently selected difficulty.
        local steps = nil
        if #allSteps == 1 then
            -- If there's only a single difficulty, don't try to match the difficulty. Just show the only one.
            -- This is important for tournament packs which usually have other difficulties removed.
            steps = allSteps[1]
        else
            -- TODO: Match the engine (or theme?) behaviour on which difficulty will be autoselected from this chart
            -- if there's no exact match.
            for k, v in ipairs(allSteps) do
                if v:GetDifficulty() == currentSteps:GetDifficulty() then
                    steps = v
                end
            end
        end

        if steps == nil then
            EXScore_DBG("Early return due to nil steps")
            return
        end

        EXScore_DBG("Actually calculating something for " .. song:GetMainTitle())

        -- Local scores
        local best_ex, hs_for_best_ex = GetLocalBestEX(song, steps)

        -- GrooveStats cache
        local groovestats_ex = nil
        if ThemePrefs.Get("EnableGrooveStats") then
            groovestats_ex = SetGetGSCachedEX(steps)
        end

        -- Display the best score
        if best_ex ~= nil and best_ex >= tonumber(groovestats_ex or "0") then
            self:settext(("%05.2f"):format(best_ex))
            self:diffuse(EXColorForHighScore(hs_for_best_ex))
            self:visible(true)
        elseif groovestats_ex ~= nil and tonumber(groovestats_ex) > (best_ex or 0) then
            self:settext(groovestats_ex)
            self:diffuse(color("#ffffff"))
            self:visible(true)
        end

        -- Flag that we are already displaying an accurate result for the song
        self.Song = song
    end,

    CacheUpdatedGSEXMessageCommand = function(self, params)
        EXScore_DBG("Got CacheUpdatedGSEX " .. tostring(params.Song))
        if params.Song == self.Song then
            self:playcommand("Set"--[[, { CacheUpdatedGSEX_Song = params.Song }]])
        else
            EXScore_DBG("CacheUpdatedGSEX not calling Set due to self.Song not matching")
        end
    end
}