--!strict
--[[
	MusicController (클라이언트)
	---------------------------
	레이싱 분위기의 배경음악(BGM)을 재생/전환합니다.
	- 라운지(대기)와 레이스(주행)용 곡을 각각 미리 로드
	- 경주 시작/종료(RaceStateChanged)에 맞춰 크로스페이드로 전환
	- 엔진 사운드와 동일하게 GameConfig.Music의 "후보 id 목록"을 순회하며
	  실제로 로드되는 첫 곡을 선택 → 모더레이션/권한으로 일부가 막혀도 견고하게 동작

	소리가 안 들리면 GameConfig.Music.loungeIds / raceIds 맨 앞에
	동작하는 음악 에셋 id를 추가하세요(Studio 도구상자 → 오디오에서 가져오기).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local GameConfig = require(ReplicatedStorage.GameConfig)
local Remotes = require(ReplicatedStorage.Remotes)

local cfg = (GameConfig :: any).Music
if not cfg or cfg.enabled == false then
	return
end

local VOLUME: number = cfg.volume or 0.28
local FADE: number = cfg.fadeTime or 0.8

-- 후보 id 목록에서 실제로 로드되는 첫 사운드를 만들어 반환(없으면 nil)
local function loadFirstPlayable(ids: { number }?): Sound?
	if type(ids) ~= "table" then
		return nil
	end
	for _, id in ipairs(ids) do
		local s = Instance.new("Sound")
		s.SoundId = "rbxassetid://" .. tostring(id)
		s.Looped = true
		s.Volume = 0
		s.Parent = SoundService
		-- 로드 대기(최대 5초). 로드 실패/모더레이션 시 다음 후보로.
		local t0 = os.clock()
		while not s.IsLoaded and os.clock() - t0 < 5 do
			RunService.Heartbeat:Wait()
		end
		if s.IsLoaded and s.TimeLength > 0 then
			return s
		end
		s:Destroy()
	end
	return nil
end

local loungeSound: Sound? = nil
local raceSound: Sound? = nil
local current: Sound? = nil
local desired: "lounge" | "race" = "lounge"

local function crossfadeTo(target: Sound?)
	if current == target then
		return
	end
	local old = current
	current = target
	if target then
		target.Volume = 0
		if not target.IsPlaying then
			target:Play()
		end
		TweenService:Create(target, TweenInfo.new(FADE), { Volume = VOLUME }):Play()
	end
	if old then
		local tw = TweenService:Create(old, TweenInfo.new(FADE), { Volume = 0 })
		tw.Completed:Connect(function()
			if current ~= old then
				old:Pause()
			end
		end)
		tw:Play()
	end
end

local function applyDesired()
	crossfadeTo(if desired == "race" then raceSound else loungeSound)
end

-- 경주 상태에 맞춰 곡 전환(로드가 끝나기 전이라도 desired만 갱신 → 로드 후 반영)
Remotes.Event("RaceStateChanged").OnClientEvent:Connect(function(info)
	desired = if info and info.state == "Racing" then "race" else "lounge"
	applyDesired()
end)

-- 두 곡을 백그라운드에서 미리 로드한 뒤 현재 상태에 맞는 곡 재생
task.spawn(function()
	loungeSound = loadFirstPlayable(cfg.loungeIds)
	raceSound = loadFirstPlayable(cfg.raceIds)
	-- 레이스 곡만 로드되면 라운지에서도 그 곡을, 그 반대도 마찬가지로 대체 사용
	if not loungeSound then
		loungeSound = raceSound
	end
	if not raceSound then
		raceSound = loungeSound
	end
	if not loungeSound and not raceSound then
		warn("[MusicController] 재생 가능한 BGM 에셋이 없습니다. GameConfig.Music의 id를 동작하는 곡으로 바꿔주세요.")
		return
	end
	applyDesired()
end)
