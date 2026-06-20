--!strict
--[[
	RaceManager
	------------
	게임의 핵심 루프를 담당합니다.
	1) 대기열(Queue): 참가 패드/버튼으로 모임
	2) 카운트다운: 최소 인원이 모이면 시작
	3) 경주: 랜덤 트랙 생성 → 차량 스폰 → 체크포인트/랩 추적
	4) 결과: 순위 산정 → 보상 지급 → 라운지 복귀

	상태: "Idle" → "Queue" → "Countdown" → "Racing" → (정리) → "Idle"
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GameConfig = require(ReplicatedStorage.GameConfig)
local Remotes = require(ReplicatedStorage.Remotes)
local DataManager = require(script.Parent.DataManager)
local CarSpawner = require(script.Parent.CarSpawner)
local TrackGenerator = require(script.Parent.TrackGenerator)
local LoungeBuilder = require(script.Parent.LoungeBuilder)

local RaceManager = {}

local CHECKPOINT_RADIUS = 30 -- 체크포인트 통과 판정 거리(평면)

type RacerState = {
	player: Player,
	car: Model?,
	nextCp: number, -- 다음으로 통과해야 할 체크포인트(1~N)
	lap: number,
	finished: boolean,
	finishTime: number?,
	place: number?,
}

local state = "Idle"
local queue: { Player } = {}
local racers: { [number]: RacerState } = {} -- userId -> RacerState
local currentTrack: TrackGenerator.TrackInfo? = nil
local raceConnection: RBXScriptConnection? = nil
local countdownActive = false

-- =====================================================================
-- 유틸
-- =====================================================================
local function isInQueue(player: Player): boolean
	for _, p in ipairs(queue) do
		if p == player then
			return true
		end
	end
	return false
end

local function removeFromQueue(player: Player)
	for i, p in ipairs(queue) do
		if p == player then
			table.remove(queue, i)
			break
		end
	end
end

local function broadcastQueue()
	Remotes.Event("QueueStateChanged"):FireAllClients({
		state = state,
		count = #queue,
		max = GameConfig.Race.maxPlayers,
		min = GameConfig.Race.minPlayers,
	})
end

local function notify(player: Player, message: string)
	Remotes.Event("Notify"):FireClient(player, message)
end

-- =====================================================================
-- 대기열
-- =====================================================================
function RaceManager.joinQueue(player: Player)
	if state == "Racing" then
		notify(player, "경주가 진행 중입니다. 잠시 후 다시 시도하세요.")
		return
	end
	if isInQueue(player) then
		return
	end
	if #queue >= GameConfig.Race.maxPlayers then
		notify(player, "대기열이 가득 찼습니다.")
		return
	end
	table.insert(queue, player)
	if state == "Idle" then
		state = "Queue"
	end
	broadcastQueue()
	RaceManager.tryStartCountdown()
end

function RaceManager.leaveQueue(player: Player)
	if not isInQueue(player) then
		return
	end
	removeFromQueue(player)
	if #queue == 0 and state == "Queue" then
		state = "Idle"
	end
	broadcastQueue()
end

function RaceManager.tryStartCountdown()
	if state ~= "Queue" or countdownActive then
		return
	end
	if #queue < GameConfig.Race.minPlayers then
		return
	end
	countdownActive = true
	task.spawn(function()
		local remaining = GameConfig.Race.lobbyCountdown
		while remaining > 0 do
			-- 인원이 최소 미만으로 떨어지면 취소
			if #queue < GameConfig.Race.minPlayers then
				countdownActive = false
				state = #queue > 0 and "Queue" or "Idle"
				broadcastQueue()
				Remotes.Event("QueueStateChanged"):FireAllClients({
					state = state,
					count = #queue,
					max = GameConfig.Race.maxPlayers,
					min = GameConfig.Race.minPlayers,
					countdown = nil,
				})
				return
			end
			Remotes.Event("QueueStateChanged"):FireAllClients({
				state = "Countdown",
				count = #queue,
				max = GameConfig.Race.maxPlayers,
				min = GameConfig.Race.minPlayers,
				countdown = remaining,
			})
			task.wait(1)
			remaining -= 1
		end
		countdownActive = false
		RaceManager.startRace()
	end)
end

-- =====================================================================
-- 경주 시작
-- =====================================================================
function RaceManager.startRace()
	if state == "Racing" then
		return
	end
	state = "Racing"

	-- 참가자 확정(대기열 스냅샷, 최대 인원 제한)
	local participants: { Player } = {}
	for _, p in ipairs(queue) do
		if #participants >= GameConfig.Race.maxPlayers then
			break
		end
		if p.Parent and DataManager.isLoaded(p) then
			table.insert(participants, p)
		end
	end
	table.clear(queue)
	broadcastQueue()

	if #participants == 0 then
		state = "Idle"
		return
	end

	-- 랜덤 트랙 선택 및 생성
	local trackIndex = math.random(1, GameConfig.Race.trackCount)
	local trackFolder = Instance.new("Folder")
	trackFolder.Name = "ActiveRace"
	trackFolder.Parent = workspace
	currentTrack = TrackGenerator.build(trackIndex, trackFolder)
	local track = currentTrack :: TrackGenerator.TrackInfo

	-- 차량 스폰 + 레이서 상태 초기화
	racers = {}
	for i, player in ipairs(participants) do
		local spawnCFrame = track.spawnCFrames[i] or track.startCFrame * CFrame.new(0, 4, 10 + i * 6)
		local car = CarSpawner.spawnFor(player, spawnCFrame, trackFolder)
		racers[player.UserId] = {
			player = player,
			car = car,
			nextCp = 2, -- 출발선(cp1) 뒤에서 시작 → 다음은 2번
			lap = 0,
			finished = false,
		}
	end

	-- 경주 시작 카운트다운(3,2,1,GO) 동안 차량 고정
	RaceManager.freezeCars(true)
	task.spawn(function()
		for n = 3, 1, -1 do
			Remotes.Event("RaceCountdown"):FireAllClients({ value = n, track = track.displayName })
			task.wait(1)
		end
		Remotes.Event("RaceCountdown"):FireAllClients({ value = 0, track = track.displayName }) -- GO!
		RaceManager.freezeCars(false)
		RaceManager.beginTracking()
	end)

	Remotes.Event("RaceStateChanged"):FireAllClients({
		state = "Racing",
		track = track.displayName,
		laps = GameConfig.Race.laps,
	})
end

function RaceManager.freezeCars(frozen: boolean)
	for _, racer in pairs(racers) do
		local car = racer.car
		if car and car.PrimaryPart then
			car.PrimaryPart.Anchored = frozen
		end
	end
end

-- =====================================================================
-- 진행 추적 (체크포인트/랩)
-- =====================================================================
function RaceManager.beginTracking()
	local track = currentTrack
	if not track then
		return
	end
	local startTime = os.clock()
	local finishedCount = 0

	if raceConnection then
		raceConnection:Disconnect()
	end

	raceConnection = RunService.Heartbeat:Connect(function()
		if state ~= "Racing" then
			return
		end
		local n = track.checkpointCount

		for _, racer in pairs(racers) do
			if racer.finished then
				continue
			end
			local car = racer.car
			if not car or not car.PrimaryPart or not car.Parent then
				continue
			end
			local carPos = car.PrimaryPart.Position
			local cp = track.checkpoints[racer.nextCp]
			if cp then
				local d = (Vector3.new(carPos.X, 0, carPos.Z) - Vector3.new(cp.Position.X, 0, cp.Position.Z)).Magnitude
				if d <= CHECKPOINT_RADIUS then
					-- 체크포인트 통과
					if racer.nextCp == 1 then
						racer.lap += 1
						if racer.lap >= GameConfig.Race.laps then
							-- 완주
							racer.finished = true
							racer.finishTime = os.clock() - startTime
							finishedCount += 1
							racer.place = finishedCount
							RaceManager.onRacerFinished(racer)
						end
					end
					racer.nextCp = (racer.nextCp % n) + 1
				end
			end
		end

		-- 남은 레이서가 모두 완주했거나 제한 시간 초과 시 종료
		local anyRacer = false
		local allFinished = true
		for _, r in pairs(racers) do
			anyRacer = true
			if not r.finished then
				allFinished = false
				break
			end
		end
		local elapsed = os.clock() - startTime
		if (anyRacer and allFinished) or elapsed >= GameConfig.Race.raceTimeLimit then
			RaceManager.endRace()
		end
	end)
end

function RaceManager.onRacerFinished(racer: RacerState)
	local place = racer.place or 0
	local reward = GameConfig.Economy.rewardsByPlace[place] or GameConfig.Economy.finishReward
	DataManager.addMoney(racer.player, reward)
	DataManager.recordRace(racer.player, place == 1)
	notify(racer.player, ("%d등! +%d 머니"):format(place, reward))
end

-- =====================================================================
-- 경주 종료 / 정리
-- =====================================================================
function RaceManager.endRace()
	if state ~= "Racing" then
		return
	end
	state = "Cleanup"
	if raceConnection then
		raceConnection:Disconnect()
		raceConnection = nil
	end

	-- 완주 못한 레이서 처리(완주 보상 없음, 기록만)
	local results = {}
	for _, racer in pairs(racers) do
		if not racer.finished then
			DataManager.recordRace(racer.player, false)
		end
		table.insert(results, {
			name = racer.player.DisplayName,
			place = racer.place,
			finished = racer.finished,
			time = racer.finishTime,
		})
	end

	-- 완주 순위대로 정렬
	table.sort(results, function(a, b)
		local ap = a.place or math.huge
		local bp = b.place or math.huge
		return ap < bp
	end)

	Remotes.Event("RaceFinished"):FireAllClients({ results = results })

	-- 결과 표시 후 라운지 복귀
	task.wait(5)
	RaceManager.returnAllToLounge()

	-- 트랙/차량 정리
	local active = workspace:FindFirstChild("ActiveRace")
	if active then
		active:Destroy()
	end
	racers = {}
	currentTrack = nil
	state = "Idle"
	broadcastQueue()
	Remotes.Event("RaceStateChanged"):FireAllClients({ state = "Idle" })
end

function RaceManager.returnAllToLounge()
	local spawnCFrame = LoungeBuilder.getSpawnCFrame()
	for _, racer in pairs(racers) do
		local player = racer.player
		if racer.car then
			racer.car:Destroy()
		end
		local character = player.Character
		if character and character:FindFirstChild("HumanoidRootPart") then
			task.spawn(function()
				character:PivotTo(spawnCFrame * CFrame.new(math.random(-15, 15), 0, math.random(-15, 15)))
			end)
		end
	end
end

-- 플레이어 퇴장 처리
function RaceManager.onPlayerLeaving(player: Player)
	removeFromQueue(player)
	local racer = racers[player.UserId]
	if racer then
		if racer.car then
			racer.car:Destroy()
		end
		racers[player.UserId] = nil
	end
end

function RaceManager.init()
	Players.PlayerRemoving:Connect(RaceManager.onPlayerLeaving)
	broadcastQueue()
end

return RaceManager
