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
local Lighting = game:GetService("Lighting")

local GameConfig = require(ReplicatedStorage.GameConfig)
local Remotes = require(ReplicatedStorage.Remotes)
local DataManager = require(script.Parent.DataManager)
local CarSpawner = require(script.Parent.CarSpawner)
local TrackGenerator = require(script.Parent.TrackGenerator)
local LoungeBuilder = require(script.Parent.LoungeBuilder)
local LeaderboardService = require(script.Parent.LeaderboardService)

local RaceManager = {}

local CHECKPOINT_RADIUS = 30 -- 체크포인트 통과 판정 거리(평면)

type RacerState = {
	player: Player?, -- 봇이면 nil
	isBot: boolean, -- AI 봇 여부
	userId: number, -- 사람=UserId, 봇=음수 합성 id (racers 테이블 키)
	name: string, -- 차 이름표/순위 표시용 이름
	car: Model?,
	nextCp: number, -- 다음으로 통과해야 할 체크포인트(1~N)
	lap: number,
	progress: number, -- 통과한 체크포인트 누적 수 (실시간 순위용)
	finished: boolean,
	finishTime: number?,
	place: number?,
	item: string?, -- 보유 중인 아이템 id (없으면 nil)
	-- 봇 키네매틱 주행 상태
	route: { Vector3 }?, -- 따라가는 경로(트랙 minimapPath)
	routePos: number?, -- 경로상의 부동소수 인덱스(정수부=세그먼트, 소수부=세그먼트 내 진행)
	speed: number?, -- 봇 기본 주행 속도(studs/sec)
	laneOffset: number?, -- 중앙선 기준 좌우 차선 오프셋(봇끼리 겹침 방지)
}

local state = "Idle"
local queue: { Player } = {}
local racers: { [number]: RacerState } = {} -- userId -> RacerState
local currentTrack: TrackGenerator.TrackInfo? = nil
local raceConnection: RBXScriptConnection? = nil
local countdownActive = false

-- 라운지(기본) 조명 스냅샷 — init에서 1회 캡처, 테마 적용 후 복원에 사용
type LightingSnapshot = {
	clockTime: number,
	brightness: number,
	ambient: Color3,
	outdoor: Color3,
	fog: Color3,
	fogStart: number,
	fogEnd: number,
}
local defaultLighting: LightingSnapshot? = nil

local function captureLighting(): LightingSnapshot
	return {
		clockTime = Lighting.ClockTime,
		brightness = Lighting.Brightness,
		ambient = Lighting.Ambient,
		outdoor = Lighting.OutdoorAmbient,
		fog = Lighting.FogColor,
		fogStart = Lighting.FogStart,
		fogEnd = Lighting.FogEnd,
	}
end

local function applyLighting(l: LightingSnapshot)
	Lighting.ClockTime = l.clockTime
	Lighting.Brightness = l.brightness
	Lighting.Ambient = l.ambient
	Lighting.OutdoorAmbient = l.outdoor
	Lighting.FogColor = l.fog
	Lighting.FogStart = l.fogStart
	Lighting.FogEnd = l.fogEnd
end

-- 테마 조명 적용 (테마에 lighting이 없으면 기본 유지)
local function applyThemeLighting(lighting: TrackGenerator.ThemeLighting?)
	if not lighting then
		return
	end
	if not defaultLighting then
		defaultLighting = captureLighting()
	end
	applyLighting({
		clockTime = lighting.clockTime,
		brightness = lighting.brightness,
		ambient = lighting.ambient,
		outdoor = lighting.outdoor,
		fog = lighting.fog,
		fogStart = lighting.fogStart,
		fogEnd = lighting.fogEnd,
	})
end

-- 라운지 기본 조명으로 복원
local function restoreLighting()
	if defaultLighting then
		applyLighting(defaultLighting)
	end
end

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

-- 현재 경주가 진행 중인지(외부 모듈에서 조회). state는 모듈 로컬이라 getter로 노출.
function RaceManager.isRacing(): boolean
	return state == "Racing"
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
-- =====================================================================
-- AI 봇 키네매틱 주행
-- =====================================================================
local BOT_RIDE_HEIGHT = 0.8 -- 시트 중심 높이(바퀴가 지면에 닿도록; 도로 윗면 y=0 기준)

-- 경로(route)상의 부동소수 인덱스 routePos에서 차량 CFrame을 계산
local function botCFrameAt(route: { Vector3 }, routePos: number, laneOffset: number): CFrame
	local n = #route
	local baseIdx = math.floor(routePos)
	local frac = routePos - baseIdx
	local i0 = ((baseIdx - 1) % n) + 1
	local i1 = (i0 % n) + 1
	local a, b = route[i0], route[i1]
	local pos = a:Lerp(b, frac)
	local dir = b - a
	local flat = Vector3.new(dir.X, 0, dir.Z)
	local look = if flat.Magnitude > 0.01 then CFrame.lookAt(pos, pos + flat.Unit) else CFrame.new(pos)
	return look * CFrame.new(laneOffset, BOT_RIDE_HEIGHT, 0)
end

-- 봇 한 명을 dt만큼 경로를 따라 전진시키고 차량을 이동
local function advanceBot(racer: RacerState, dt: number, leaderProgress: number)
	local route = racer.route
	local car = racer.car
	if not route or #route < 2 or not car or not car.PrimaryPart then
		return
	end
	local cfg = (GameConfig :: any).Bots
	-- 고무줄 보정: 선두와 진행도(통과 체크포인트 수) 차이에 따라 속도 가감
	local behind = leaderProgress - racer.progress
	local adjust = math.clamp(behind * cfg.rubberbandGain, cfg.rubberbandMin, cfg.rubberbandMax)
	local speed = math.clamp((racer.speed or cfg.baseSpeed) + adjust, cfg.minSpeed, cfg.maxSpeed)

	local n = #route
	local routePos = racer.routePos or 1
	local baseIdx = math.floor(routePos)
	local frac = routePos - baseIdx
	local i0 = ((baseIdx - 1) % n) + 1
	local i1 = (i0 % n) + 1
	local segLen = math.max((route[i1] - route[i0]).Magnitude, 0.1)
	frac += (speed * dt) / segLen
	-- 한 프레임에 여러 세그먼트를 넘길 수 있으니 루프 처리
	while frac >= 1 do
		frac -= 1
		baseIdx += 1
		i0 = ((baseIdx - 1) % n) + 1
		i1 = (i0 % n) + 1
		segLen = math.max((route[i1] - route[i0]).Magnitude, 0.1)
	end
	racer.routePos = baseIdx + frac
	car:PivotTo(botCFrameAt(route, racer.routePos, racer.laneOffset or 0))
end

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

	-- 진입 로딩 화면 ON: 트랙 생성(수백 파트)과 차량 스폰/순간이동 히치를 가린다.
	-- 한 프레임 양보해 로딩 신호가 무거운 동기 빌드보다 먼저 전송되게 함.
	for _, p in ipairs(participants) do
		Remotes.Event("RaceLoading"):FireClient(p, true)
	end
	task.wait()

	-- 랜덤 트랙 선택 및 생성
	local trackIndex = math.random(1, GameConfig.Race.trackCount)
	local trackFolder = Instance.new("Folder")
	trackFolder.Name = "ActiveRace"
	trackFolder.Parent = workspace
	currentTrack = TrackGenerator.build(trackIndex, trackFolder)
	local track = currentTrack :: TrackGenerator.TrackInfo

	-- 테마 조명 적용(분위기). 라운지 기본값은 init에서 캡처해 두고 종료 시 복원.
	applyThemeLighting(track.lighting)

	-- 차량 스폰 + 레이서 상태 초기화
	racers = {}
	for i, player in ipairs(participants) do
		local spawnCFrame = track.spawnCFrames[i] or track.startCFrame * CFrame.new(0, 4, 10 + i * 6)
		local car = CarSpawner.spawnFor(player, spawnCFrame, trackFolder)
		racers[player.UserId] = {
			player = player,
			isBot = false,
			userId = player.UserId,
			name = player.DisplayName,
			car = car,
			nextCp = 2, -- 출발선(cp1) 뒤에서 시작 → 다음은 2번
			lap = 0,
			progress = 0,
			finished = false,
		}
	end

	-- 빈 자리를 AI 봇으로 채워 항상 경주가 성립하게 함(실제 인원 < maxPlayers)
	local botCfg = (GameConfig :: any).Bots
	if botCfg and botCfg.enabled then
		local route = track.minimapPath
		local need = GameConfig.Race.maxPlayers - #participants
		local spawnedBots = 0
		if not route or #route < 2 then
			warn(("[RaceManager] 봇 경로(minimapPath)가 비어 있어 봇을 못 만듭니다 (#route=%d)"):format(route and #route or 0))
		end
		for j = 1, need do
			local botName = botCfg.names[((j - 1) % #botCfg.names) + 1]
			local bodyColor = botCfg.bodyColors[((j - 1) % #botCfg.bodyColors) + 1]
			-- 시작선 부근에서 조금씩 뒤로 stagger + 좌우로 분산해 봇끼리 겹치지 않게
			local laneOffset = (((j - 1) % 5) - 2) * 7
			local routePos = 1 - j * 0.7
			local botUserId = -(1000 + j) -- 실제 UserId와 충돌하지 않는 음수 키
			local car = CarSpawner.spawnBot(botCFrameAt(route, routePos, laneOffset), trackFolder, botName, bodyColor)
			if car then
				spawnedBots += 1
			else
				warn(("[RaceManager] 봇 '%s' 차량 생성 실패(spawnBot이 nil 반환)"):format(botName))
			end
			racers[botUserId] = {
				player = nil,
				isBot = true,
				userId = botUserId,
				name = botName,
				car = car,
				nextCp = 2,
				lap = 0,
				progress = 0,
				finished = false,
				route = route,
				routePos = routePos,
				speed = botCfg.baseSpeed + (math.random() - 0.5) * 2 * botCfg.speedVariance,
				laneOffset = laneOffset,
			}
		end
		print(("[RaceManager] AI 봇 %d/%d대 생성 (사람 %d명, maxPlayers=%d)"):format(spawnedBots, need, #participants, GameConfig.Race.maxPlayers))
	end

	-- 부스트 패드 / 오일 슬릭 상호작용 연결
	RaceManager.setupTrackItems(track)

	-- 미니맵용 트랙 외곽선/바운드 전달
	local pathData = {}
	for i, p in ipairs(track.minimapPath) do
		pathData[i] = { x = p.X, z = p.Z }
	end
	Remotes.Event("RaceSetup"):FireAllClients({
		track = track.displayName,
		laps = track.lapCount,
		path = pathData,
		bounds = track.bounds,
	})

	-- 경주 시작 카운트다운(3,2,1,GO) 동안 차량 고정
	RaceManager.freezeCars(true)
	task.spawn(function()
		-- 진입 로딩 화면을 잠시 더 유지해 트랙 파트 복제까지 가린 뒤 해제 → 트랙이 보이고 카운트다운 시작
		task.wait(GameConfig.Race.entryLoadTime)
		for _, p in ipairs(participants) do
			if p.Parent then
				Remotes.Event("RaceLoading"):FireClient(p, false)
			end
		end
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
		laps = track.lapCount,
	})
end

function RaceManager.freezeCars(frozen: boolean)
	for _, racer in pairs(racers) do
		-- 봇은 키네매틱(항상 앵커, 서버가 CFrame으로 이동) → 고정/해제 대상에서 제외
		if racer.isBot then
			continue
		end
		local car = racer.car
		if not (car and car.PrimaryPart) then
			continue
		end
		local seat = car.PrimaryPart :: VehicleSeat
		-- ⚠️ "출발 직후 안 움직이고, 내렸다 다시 타야 가던" 버그의 근본 수정:
		-- 앵커로 동결하면 네트워크 소유권이 박탈된다 → 앵커 대신 RaceFrozen 속성으로 동결.
		-- 더 중요한 건 GO(해제) 직전에 착석 + 소유권을 "검증하며 재확립"하는 것:
		-- 스폰 때 소유권 설정이 프레임 경합으로 실패했어도 여기서 확실히 되돌린다.
		if frozen then
			-- 동결: 속성만 켠다. (소유권은 spawnFor의 seatDriver가 확립)
			seat:SetAttribute("RaceFrozen", true)
		else
			-- GO: 동결 해제 전에 운전자 착석 + 소유권을 확실히 재확인 → 그 다음 풀어야
			--      클라이언트가 그 즉시 방향키로 출발(소유권 없으면 클라의 속도 쓰기가 무시됨).
			local player = racer.player
			local char = player and player.Character
			local humanoid = char and char:FindFirstChildOfClass("Humanoid")
			if player and humanoid then
				CarSpawner.seatDriver(seat, humanoid, player)
			end
			seat:SetAttribute("RaceFrozen", false)
		end
	end
end

-- 닿은 파트로부터 소속 차량 모델을 찾음
local function findCarModel(hit: BasePart): Model?
	local node: Instance? = hit
	while node and node ~= workspace do
		if node:IsA("Model") and node:GetAttribute("OwnerUserId") then
			return node
		end
		node = node.Parent
	end
	return nil
end

-- =====================================================================
-- 아이템 시스템 (마리오카트식): 박스 획득 + 바나나/로켓/물풍선 사용
-- 효과는 차량 시트의 어트리뷰트(종료 시각)로 전달되어 클라 CarController가 반영
-- =====================================================================

-- 닿은 파트로부터 소속 레이서 상태를 찾음
local function racerFromHit(hit: BasePart): RacerState?
	local car = findCarModel(hit)
	if not car then
		return nil
	end
	local userId = car:GetAttribute("OwnerUserId")
	if typeof(userId) ~= "number" then
		return nil
	end
	return racers[userId]
end

-- 순위 기반 가중치 랜덤으로 아이템 1개 선택 (D)
-- rank: 현재 레이서 순위(1=1위), total: 전체 참가수
local function pickRandomItem(rank: number, total: number): string
	-- rankPools 티어 결정: 상위 30% → front, 하위 40% → back, 나머지 → mid
	local rankPools = (GameConfig.Items :: any).rankPools
	local pool: { { id: string, weight: number } }? = nil
	if rankPools then
		local frontCut = math.ceil(total * 0.3)
		local backCut  = math.ceil(total * 0.6)
		if rank <= frontCut then
			pool = rankPools.front
		elseif rank > backCut then
			pool = rankPools.back
		else
			pool = rankPools.mid
		end
	end
	-- rankPools 없거나 tier 미탐색 시 기존 pool 폴백
	if not pool then
		pool = GameConfig.Items.pool
	end
	local totalWeight = 0
	for _, e in ipairs(pool) do
		totalWeight += e.weight
	end
	local r = math.random() * totalWeight
	local acc = 0
	for _, e in ipairs(pool) do
		acc += e.weight
		if r <= acc then
			return e.id
		end
	end
	return pool[1].id
end

-- 박스 표시(?) 토글
local function setBoxVisible(box: BasePart, visible: boolean)
	box.Transparency = visible and 0.2 or 1
	for _, c in ipairs(box:GetChildren()) do
		if c:IsA("BillboardGui") or c:IsA("SurfaceGui") then
			c.Enabled = visible
		end
	end
end

-- 아이템 박스 통과 처리: 비어 있으면 순위 기반 랜덤 지급 + 박스 일시 비활성화 후 재생성 (D)
local function onItemBoxTouched(box: BasePart, racer: RacerState)
	if not box:GetAttribute("Active") then
		return
	end
	if racer.item then
		return -- 이미 보유 중이면 받지 않음
	end
	-- 봇 nil 가드: 봇은 아이템 UI가 없으므로 지급하지 않음 (D)
	if racer.isBot then
		return
	end
	box:SetAttribute("Active", false)
	setBoxVisible(box, false)

	-- 현재 순위를 progress 기준으로 즉석 계산해 pickRandomItem에 전달 (D)
	local myRank = 1
	local total = 0
	for _, r in pairs(racers) do
		total += 1
		if r.progress > racer.progress then
			myRank += 1
		end
	end
	total = math.max(total, 1)

	local itemId = pickRandomItem(myRank, total)
	racer.item = itemId
	-- racer.player는 봇 가드로 여기서는 반드시 non-nil
	if racer.player then
		Remotes.Event("ItemUpdated"):FireClient(racer.player, itemId)
	end

	task.delay(GameConfig.Items.boxRespawnTime, function()
		if box.Parent and state == "Racing" then
			box:SetAttribute("Active", true)
			setBoxVisible(box, true)
		end
	end)
end

local function itemParent(): Instance
	local t = currentTrack
	if t and t.model and t.model.Parent then
		return t.model
	end
	return workspace
end

-- 바나나: 차 뒤에 떨어뜨려 두고, 밟은 차량을 회전(미끄러짐)시킴
local function dropBanana(racer: RacerState)
	local car = racer.car
	if not car or not car.PrimaryPart then
		return
	end
	local cfg = GameConfig.Items.banana
	local seat = car.PrimaryPart
	local dropPos = (seat.CFrame * CFrame.new(0, -0.4, cfg.dropBackOffset)).Position

	local banana = Instance.new("Part")
	banana.Name = "Banana"
	banana.Shape = Enum.PartType.Ball
	banana.Anchored = true
	banana.CanCollide = false
	banana.Size = Vector3.new(2.8, 2.8, 2.8)
	banana.Color = cfg.color
	banana.Material = Enum.Material.SmoothPlastic
	banana.CFrame = CFrame.new(dropPos)
	banana.Parent = itemParent()

	local bb = Instance.new("BillboardGui")
	bb.Size = UDim2.fromOffset(42, 42)
	bb.StudsOffset = Vector3.new(0, 1.6, 0)
	bb.Adornee = banana
	bb.Parent = banana
	local lbl = Instance.new("TextLabel")
	lbl.Size = UDim2.fromScale(1, 1)
	lbl.BackgroundTransparency = 1
	lbl.Text = cfg.emoji
	lbl.TextScaled = true
	lbl.Parent = bb

	local placedAt = workspace:GetServerTimeNow()
	local consumed = false
	banana.Touched:Connect(function(hit)
		if consumed or state ~= "Racing" then
			return
		end
		local victim = racerFromHit(hit)
		if not victim or not victim.car or not victim.car.PrimaryPart then
			return
		end
		-- 봇은 아이템 피격 면역 (C)
		if victim.isBot then
			return
		end
		local now = workspace:GetServerTimeNow()
		-- 투하 직후 본인 면역
		if racer.player and victim.player and victim.player.UserId == racer.player.UserId and (now - placedAt) < cfg.armDelay then
			return
		end
		-- 방어막(ShieldEndTime) 유효 시 피격 스킵 (C)
		local shieldEnd = victim.car.PrimaryPart:GetAttribute("ShieldEndTime")
		if typeof(shieldEnd) == "number" and now < shieldEnd then
			return
		end
		consumed = true
		victim.car.PrimaryPart:SetAttribute("SpinEndTime", now + cfg.spinDuration)
		if victim.player then
			Remotes.Event("ItemEffect"):FireAllClients({ kind = "banana", userId = victim.player.UserId })
		end
		banana:Destroy()
	end)

	task.delay(cfg.life, function()
		if banana.Parent then
			banana:Destroy()
		end
	end)
end

-- 기름통: 차 뒤에 떨어뜨려 밟은 상대를 감속시킴. dropBanana 패턴 복제 (C)
local function dropSlick(racer: RacerState)
	local car = racer.car
	if not car or not car.PrimaryPart then
		return
	end
	local cfg = (GameConfig.Items :: any).slick
	local seat = car.PrimaryPart
	local dropPos = (seat.CFrame * CFrame.new(0, -0.3, cfg.dropBackOffset)).Position

	local slick = Instance.new("Part")
	slick.Name = "OilSlick"
	slick.Shape = Enum.PartType.Cylinder
	slick.Anchored = true
	slick.CanCollide = false
	slick.Size = Vector3.new(0.4, 6, 6)
	slick.Color = cfg.color
	slick.Material = Enum.Material.SmoothPlastic
	slick.Transparency = 0.25
	slick.CFrame = CFrame.new(dropPos) * CFrame.Angles(0, 0, math.pi / 2)
	slick.Parent = itemParent()

	local bb = Instance.new("BillboardGui")
	bb.Size = UDim2.fromOffset(42, 42)
	bb.StudsOffset = Vector3.new(0, 1.8, 0)
	bb.Adornee = slick
	bb.Parent = slick
	local lbl = Instance.new("TextLabel")
	lbl.Size = UDim2.fromScale(1, 1)
	lbl.BackgroundTransparency = 1
	lbl.Text = cfg.emoji
	lbl.TextScaled = true
	lbl.Parent = bb

	local lastHit: { [number]: number } = {} -- userId → 마지막 피격 시각(반복 발화 디바운스)
	slick.Touched:Connect(function(hit)
		if state ~= "Racing" then
			return
		end
		local victim = racerFromHit(hit)
		if not victim or not victim.car or not victim.car.PrimaryPart then
			return
		end
		-- 봇은 아이템 피격 면역 (C)
		if victim.isBot then
			return
		end
		-- 본인 면역
		if victim.userId == racer.userId then
			return
		end
		local now = workspace:GetServerTimeNow()
		-- 방어막(ShieldEndTime) 유효 시 피격 스킵 (C)
		local shieldEnd = victim.car.PrimaryPart:GetAttribute("ShieldEndTime")
		if typeof(shieldEnd) == "number" and now < shieldEnd then
			return
		end
		-- 디바운스: Touched는 물리 스텝마다 반복 발화하므로 감속 지속시간 내 재발화 차단
		if (lastHit[victim.userId] or 0) + cfg.slowDuration > now then
			return
		end
		lastHit[victim.userId] = now
		victim.car.PrimaryPart:SetAttribute("SlowEndTime", now + cfg.slowDuration)
		if victim.player then
			notify(victim.player, "🛢️ 기름통을 밟았어요! 속도가 느려져요!")
		end
	end)

	task.delay(cfg.life, function()
		if slick.Parent then
			slick:Destroy()
		end
	end)
end

-- 로켓: 사용자 본인을 잠깐 엄청 빠르게 가속
local function useRocket(racer: RacerState)
	local car = racer.car
	if not car or not car.PrimaryPart then
		return
	end
	local cfg = GameConfig.Items.rocket
	local now = workspace:GetServerTimeNow()
	car.PrimaryPart:SetAttribute("RocketEndTime", now + cfg.duration)
	Remotes.Event("ItemEffect"):FireAllClients({ kind = "rocket", userId = racer.player.UserId })
end

-- 가두는 물풍선 버블(시각효과): 피격 차량에 부착되어 일정 시간 후 제거
local function spawnFreezeBubble(racer: RacerState, duration: number)
	local car = racer.car
	if not car or not car.PrimaryPart then
		return
	end
	local seat = car.PrimaryPart
	local bubble = Instance.new("Part")
	bubble.Name = "FreezeBubble"
	bubble.Shape = Enum.PartType.Ball
	bubble.Anchored = false
	bubble.CanCollide = false
	bubble.Massless = true
	bubble.Size = Vector3.new(15, 15, 15)
	bubble.Color = GameConfig.Items.balloon.color
	bubble.Material = Enum.Material.Glass
	bubble.Transparency = 0.5
	bubble.CFrame = seat.CFrame
	bubble.Parent = itemParent()
	local weld = Instance.new("WeldConstraint")
	weld.Part0 = seat
	weld.Part1 = bubble
	weld.Parent = bubble
	task.delay(duration, function()
		if bubble.Parent then
			bubble:Destroy()
		end
	end)
end

-- 전방 원뿔 안에서 사정거리 내 가장 가까운 다른 레이서 탐색
local function findFreezeTarget(racer: RacerState): RacerState?
	local car = racer.car
	if not car or not car.PrimaryPart then
		return nil
	end
	local cfg = GameConfig.Items.balloon
	local origin = car.PrimaryPart.Position
	local forward = car.PrimaryPart.CFrame.LookVector
	local best: RacerState? = nil
	local bestDist = math.huge
	for _, other in pairs(racers) do
		-- 봇은 키네매틱이라 아이템 효과 면역 → 물풍선 대상에서 제외
		if not other.isBot and other.userId ~= racer.userId and other.car and other.car.PrimaryPart and not other.finished then
			local toOther = other.car.PrimaryPart.Position - origin
			local dist = toOther.Magnitude
			if dist > 1 and dist <= cfg.range then
				if forward:Dot(toOther.Unit) >= cfg.coneDot and dist < bestDist then
					bestDist = dist
					best = other
				end
			end
		end
	end
	return best
end

-- 물풍선: 앞쪽 가까운 상대를 3초간 가둠. 맞출 상대가 없으면 소모하지 않음
local function useBalloon(racer: RacerState): boolean
	local cfg = GameConfig.Items.balloon
	local target = findFreezeTarget(racer)
	if not target or not target.car or not target.car.PrimaryPart then
		if racer.player then
			notify(racer.player, "앞에 맞출 상대가 없어요!")
		end
		return false
	end
	local now = workspace:GetServerTimeNow()
	-- 방어막(ShieldEndTime) 유효 시 피격 스킵 (C)
	local shieldEnd = target.car.PrimaryPart:GetAttribute("ShieldEndTime")
	if typeof(shieldEnd) == "number" and now < shieldEnd then
		if racer.player then
			notify(racer.player, "상대방의 방어막이 물풍선을 막았어요!")
		end
		return false
	end
	target.car.PrimaryPart:SetAttribute("FreezeEndTime", now + cfg.freezeDuration)
	spawnFreezeBubble(target, cfg.freezeDuration)
	Remotes.Event("ItemEffect"):FireAllClients({
		kind = "balloon",
		fromUserId = racer.player and racer.player.UserId or 0,
		userId = target.player and target.player.UserId or 0,
	})
	if target.player then
		notify(target.player, "💧 물풍선에 맞았어요! 잠시 갇힘!")
	end
	return true
end

-- 버섯(대시): 본인 속도를 잠깐 폭발적으로 높임 (C)
local function useMushroom(racer: RacerState)
	local car = racer.car
	if not car or not car.PrimaryPart then
		return
	end
	local cfg = (GameConfig.Items :: any).mushroom
	local now = workspace:GetServerTimeNow()
	car.PrimaryPart:SetAttribute("BoostItemEndTime", now + cfg.duration)
	Remotes.Event("ItemEffect"):FireAllClients({ kind = "mushroom", userId = racer.userId })
end

-- 방어막: 본인에게 일정 시간 공격 무효화 방어막 부여 (C)
local function useShield(racer: RacerState)
	local car = racer.car
	if not car or not car.PrimaryPart then
		return
	end
	local cfg = (GameConfig.Items :: any).shield
	local now = workspace:GetServerTimeNow()
	car.PrimaryPart:SetAttribute("ShieldEndTime", now + cfg.duration)
	Remotes.Event("ItemEffect"):FireAllClients({ kind = "shield", userId = racer.userId })
end

-- 번개: 본인보다 앞선 모든 사람 레이서를 짧게 감속 (C, 봇 제외)
local function useLightning(racer: RacerState)
	local cfg = (GameConfig.Items :: any).lightning
	local now = workspace:GetServerTimeNow()
	local myProgress = racer.progress
	local hitCount = 0
	for _, other in pairs(racers) do
		-- 봇 제외, 본인 제외, 앞선(더 많이 진행한) 사람 레이서만 (C)
		if not other.isBot and other.userId ~= racer.userId and other.progress > myProgress then
			if other.car and other.car.PrimaryPart then
				-- 방어막(ShieldEndTime) 유효 시 스킵 (C)
				local shieldEnd = other.car.PrimaryPart:GetAttribute("ShieldEndTime")
				if typeof(shieldEnd) == "number" and now < shieldEnd then
					continue
				end
				other.car.PrimaryPart:SetAttribute("SlowEndTime", now + cfg.slowDuration)
				if other.player then
					notify(other.player, "⚡ 번개 공격! 잠시 속도가 느려졌어요!")
				end
				hitCount += 1
			end
		end
	end
	Remotes.Event("ItemEffect"):FireAllClients({ kind = "lightning", userId = racer.userId })
	if hitCount == 0 and racer.player then
		notify(racer.player, "⚡ 번개! (앞에 맞출 사람 레이서가 없어요)")
	end
end

-- 보유 아이템 사용 요청 처리 (클라 RequestUseItem → Main.server에서 호출)
function RaceManager.useItem(player: Player)
	if state ~= "Racing" then
		return
	end
	local racer = racers[player.UserId]
	if not racer or not racer.item or not racer.car or not racer.car.PrimaryPart then
		return
	end
	-- 갇혀 있는 동안에는 사용 불가
	local now = workspace:GetServerTimeNow()
	local frozenEnd = racer.car.PrimaryPart:GetAttribute("FreezeEndTime")
	if typeof(frozenEnd) == "number" and now < frozenEnd then
		return
	end

	local item = racer.item
	local consumed = true
	if item == "banana" then
		dropBanana(racer)
	elseif item == "rocket" then
		useRocket(racer)
	elseif item == "balloon" then
		consumed = useBalloon(racer)
	elseif item == "mushroom" then
		-- 버섯 대시: 본인 가속 (C)
		useMushroom(racer)
	elseif item == "slick" then
		-- 기름통: 뒤에 투하 (C)
		dropSlick(racer)
	elseif item == "shield" then
		-- 방어막: 본인 방어 (C)
		useShield(racer)
	elseif item == "lightning" then
		-- 번개: 앞선 사람 레이서 전체 감속 (C)
		useLightning(racer)
	end

	if consumed then
		racer.item = nil
		Remotes.Event("ItemUpdated"):FireClient(player, "none")
	end
end

-- 부스트 패드 / 오일 슬릭 / 아이템 박스에 Touched 핸들러 연결
function RaceManager.setupTrackItems(track: TrackGenerator.TrackInfo)
	local lastTouch: { [string]: number } = {} -- "itemId:userId" -> 시각 (디바운스)

	local function bind(item: BasePart, kind: string, duration: number, attrName: string)
		item.Touched:Connect(function(hit)
			if state ~= "Racing" then
				return
			end
			local car = findCarModel(hit)
			if not car or not car.PrimaryPart then
				return
			end
			local userId = car:GetAttribute("OwnerUserId")
			local key = tostring(item:GetDebugId()) .. ":" .. tostring(userId)
			local now = workspace:GetServerTimeNow()
			if lastTouch[key] and now - lastTouch[key] < duration + 0.3 then
				return
			end
			lastTouch[key] = now
			-- 효과 종료 시각을 어트리뷰트로 기록 → 클라 CarController가 읽음
			car.PrimaryPart:SetAttribute(attrName, now + duration)
		end)
	end

	for _, pad in ipairs(track.boostPads) do
		bind(pad, "boost", GameConfig.Boost.duration, "BoostEndTime")
	end
	for _, oil in ipairs(track.oilSlicks) do
		bind(oil, "oil", GameConfig.Obstacles.slowDuration, "SlowEndTime")
	end

	-- 아이템 박스: 통과 시 랜덤 아이템 지급
	for _, box in ipairs(track.itemBoxes) do
		box.Touched:Connect(function(hit)
			if state ~= "Racing" then
				return
			end
			local racer = racerFromHit(hit)
			if racer then
				onItemBoxTouched(box, racer)
			end
		end)
	end
end

-- 실시간 순위 계산 (완주자 우선, 그다음 진행도/근접도)
local function computeRanking(track: TrackGenerator.TrackInfo): { RacerState }
	local list: { RacerState } = {}
	for _, racer in pairs(racers) do
		table.insert(list, racer)
	end
	table.sort(list, function(a, b)
		-- 완주자는 최종 순위(place)로 정렬되어 항상 앞
		if a.finished ~= b.finished then
			return a.finished
		end
		if a.finished and b.finished then
			return (a.place or 999) < (b.place or 999)
		end
		-- 미완주: 진행도(통과 체크포인트 수) 높은 쪽이 앞
		if a.progress ~= b.progress then
			return a.progress > b.progress
		end
		-- 동일 진행도: 다음 체크포인트에 더 가까운 쪽이 앞
		local cpA = track.checkpoints[a.nextCp]
		local cpB = track.checkpoints[b.nextCp]
		local da, db = math.huge, math.huge
		if a.car and a.car.PrimaryPart and cpA then
			da = (a.car.PrimaryPart.Position - cpA.Position).Magnitude
		end
		if b.car and b.car.PrimaryPart and cpB then
			db = (b.car.PrimaryPart.Position - cpB.Position).Magnitude
		end
		return da < db
	end)
	return list
end

-- 실시간 순위/차량 위치를 클라이언트로 브로드캐스트
function RaceManager.broadcastProgress(track: TrackGenerator.TrackInfo)
	local ranked = computeRanking(track)
	local payload = {}
	for rank, racer in ipairs(ranked) do
		local pos = racer.car and racer.car.PrimaryPart and racer.car.PrimaryPart.Position or Vector3.zero
		payload[rank] = {
			userId = racer.userId,
			name = racer.name,
			isBot = racer.isBot,
			x = pos.X,
			z = pos.Z,
			place = rank,
			lap = math.min(racer.lap + 1, track.lapCount),
			finished = racer.finished,
		}
	end
	Remotes.Event("RaceProgress"):FireAllClients({
		racers = payload,
		laps = track.lapCount,
		total = #ranked, -- 전체 참가 인원(순위 "N/총원" 표시용)
	})
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
	local broadcastAccum = 0

	if raceConnection then
		raceConnection:Disconnect()
	end

	raceConnection = RunService.Heartbeat:Connect(function(dt: number)
		if state ~= "Racing" then
			return
		end
		local n = track.checkpointCount

		-- 봇 키네매틱 주행 갱신(체크포인트 판정 전에 위치를 최신화)
		-- 고무줄 기준 = "사람 선두의 진행도". 사람이 앞서면 봇이 가속, 뒤처지면 봇이 감속 →
		-- 항상 접전을 유지하되 사람이 충분히 이길 수 있는 난이도(중간).
		local humanLead = 0
		local anyHumanProg = false
		for _, r in pairs(racers) do
			if not r.isBot then
				anyHumanProg = true
				if r.progress > humanLead then
					humanLead = r.progress
				end
			end
		end
		if not anyHumanProg then
			-- 사람이 없으면(전원 완주/퇴장 직전) 봇 진행도 최대값을 기준으로
			for _, r in pairs(racers) do
				if r.progress > humanLead then
					humanLead = r.progress
				end
			end
		end
		for _, r in pairs(racers) do
			if r.isBot and not r.finished then
				advanceBot(r, dt, humanLead)
			end
		end

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
					racer.progress += 1
					if racer.nextCp == 1 then
						racer.lap += 1
						if racer.lap >= track.lapCount then
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

		-- 실시간 순위/미니맵 주기적 브로드캐스트
		broadcastAccum += dt
		if broadcastAccum >= GameConfig.Race.progressBroadcastInterval then
			broadcastAccum = 0
			RaceManager.broadcastProgress(track)
		end

		-- 종료 조건은 "사람" 기준: 사람이 모두 완주했거나(봇은 기다리지 않음),
		-- 사람이 한 명도 안 남았거나(전원 퇴장), 제한 시간 초과 시 종료.
		-- (봇만 남은 경주를 raceTimeLimit까지 끌지 않도록 함)
		local anyHuman = false
		local allHumansFinished = true
		for _, r in pairs(racers) do
			if not r.isBot then
				anyHuman = true
				if not r.finished then
					allHumansFinished = false
					break
				end
			end
		end
		local elapsed = os.clock() - startTime
		if not anyHuman or allHumansFinished or elapsed >= GameConfig.Race.raceTimeLimit then
			RaceManager.endRace()
		end
	end)
end

function RaceManager.onRacerFinished(racer: RacerState)
	-- 봇은 순위(place)만 차지하고 보상/기록/리더보드 제출은 없음
	local player = racer.player
	if racer.isBot or not player then
		return
	end
	local place = racer.place or 0
	local reward = GameConfig.Economy.rewardsByPlace[place] or GameConfig.Economy.finishReward
	DataManager.addMoney(player, reward)
	DataManager.recordRace(player, place == 1)
	notify(player, ("%d등! +%d 머니"):format(place, reward))

	-- 최고 기록 갱신 + 글로벌 순위표 제출
	local time = racer.finishTime
	if time and time > 0 then
		local improved = DataManager.updateBestTime(player, time)
		if improved then
			notify(player, ("🏆 개인 신기록! %.2f초"):format(time))
		end
		LeaderboardService.submit(player.UserId, player.DisplayName, time)
	end
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

	-- 완주 못한 레이서 처리(완주 보상 없음, 사람만 기록)
	local results = {}
	for _, racer in pairs(racers) do
		if not racer.finished and racer.player then
			DataManager.recordRace(racer.player, false)
		end
		-- userId 포함: 시상대 클라이언트가 차량 식별에 사용 (F)
		table.insert(results, {
			name = racer.name,
			isBot = racer.isBot,
			place = racer.place,
			finished = racer.finished,
			time = racer.finishTime,
			userId = racer.userId,
		})
	end

	-- 완주 순위대로 정렬
	table.sort(results, function(a, b)
		local ap = a.place or math.huge
		local bp = b.place or math.huge
		return ap < bp
	end)

	Remotes.Event("RaceFinished"):FireAllClients({ results = results })

	-- 시상대 이벤트: top3 추출 후 클라에 시네마틱 시상식 알림 (F)
	local top3 = { results[1], results[2], results[3] }
	Remotes.Event("PodiumStart"):FireAllClients({ results = results, top3 = top3 })

	-- podiumDuration 동안 top3 차량 Anchored 고정 + 제자리 회전(F, best-effort, nil 가드)
	local podiumDuration = (GameConfig.Race :: any).podiumDuration or 9
	local podiumConn: RBXScriptConnection? = nil
	do
		-- top3 항목에서 racer 참조 미리 수집 (userId로 룩업)
		local top3racers: { RacerState? } = {}
		for i = 1, 3 do
			local entry = top3[i]
			top3racers[i] = (entry and entry.userId) and racers[entry.userId] or nil
		end
		podiumConn = RunService.Heartbeat:Connect(function(dt: number)
			for i = 1, 3 do
				local r = top3racers[i]
				if not r then continue end
				local c = r.car
				if not c or not c.PrimaryPart then continue end
				-- 앵커 고정 (F)
				if not c.PrimaryPart.Anchored then
					c.PrimaryPart.Anchored = true
				end
				-- 제자리 Y축 회전 60°/초 (best-effort PivotTo)
				pcall(function()
					c:PivotTo(c:GetPivot() * CFrame.fromAxisAngle(Vector3.new(0, 1, 0), math.rad(dt * 60)))
				end)
			end
		end)
	end

	-- podiumDuration 동안 대기 후 정리 시작 (F: 기존 task.wait(5) 교체)
	task.wait(podiumDuration)
	if podiumConn then
		podiumConn:Disconnect()
		podiumConn = nil
	end

	-- 테마 조명 → 라운지 기본 조명 복원(라운지로 돌아가기 전에 복원)
	restoreLighting()
	RaceManager.returnAllToLounge()

	-- 트랙/차량 정리: returnAllToLounge 이후에 ActiveRace 파괴 (F)
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

-- 추락 버그 수정: 캐릭터를 먼저 라운지로 이동(동기) → 이후 차량 파괴 (F)
-- task.spawn 비동기 순서 역전으로 차량 파괴 후 캐릭터가 허공에 뜨던 문제 제거
function RaceManager.returnAllToLounge()
	local spawnCFrame = LoungeBuilder.getSpawnCFrame()
	for _, racer in pairs(racers) do
		-- 봇은 캐릭터 없으므로 차량만 정리
		local player = racer.player
		if player then
			local character = player.Character
			if character and character:FindFirstChild("HumanoidRootPart") then
				-- 차량 파괴 전 먼저 동기로 텔레포트 → 허공 추락 방지 (F)
				character:PivotTo(spawnCFrame * CFrame.new(math.random(-15, 15), 0, math.random(-15, 15)))
			end
		end
		-- 텔레포트 완료 이후 차량 파괴 (F)
		if racer.car then
			racer.car:Destroy()
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

-- 출발 후에도 차가 안 움직일 때(네트워크 소유권이 운전자에게 없을 때) 클라이언트가 보내는
-- 자가복구 요청. 사용자가 손으로 하던 "내렸다 다시 타기"를 서버가 자동으로 재현한다.
-- (수동 재탑승이 통하는 이유 = 엔진이 "착석 순간" 시트 소유권을 운전자에게 자동 부여하기 때문.
--  서버의 SetNetworkOwner가 환경에 따라 안 먹어도, 이 재착석 경로는 확실히 통한다.)
local function handleDriveFix(player: Player)
	local racer = racers[player.UserId]
	if not racer or racer.isBot then
		return
	end
	local car = racer.car
	if not (car and car.PrimaryPart and car.PrimaryPart:IsA("VehicleSeat")) then
		return
	end
	local seat = car.PrimaryPart :: VehicleSeat
	local char = player.Character
	local humanoid = char and char:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.Health <= 0 then
		return
	end
	-- 이미 운전자가 소유 중이고 정상 착석이면(예: 벽에 막혀 안 가는 정상 상황) 건드리지 않는다.
	local owner: Player? = nil
	local ok = pcall(function()
		owner = seat:GetNetworkOwner()
	end)
	if ok and owner == player and seat.Occupant == humanoid then
		return
	end
	-- 소유권이 없다 → 잠깐 일어섰다 다시 앉혀(=수동 재탑승) 엔진이 소유권을 재부여하게 한다.
	pcall(function()
		humanoid.Sit = false
	end)
	task.wait(0.12)
	if seat.Parent and humanoid.Parent and humanoid.Health > 0 then
		CarSpawner.seatDriver(seat, humanoid, player)
		seat:SetAttribute("RaceFrozen", false) -- 복구 시 동결 잔류 방지
	end
end

function RaceManager.init()
	Players.PlayerRemoving:Connect(RaceManager.onPlayerLeaving)
	-- 출발 후 차량이 안 움직이는 소유권 누락 자가복구 요청 처리
	Remotes.Event("RequestDriveFix").OnServerEvent:Connect(handleDriveFix)
	-- 라운지 기본 조명 스냅샷(테마 조명 적용 후 복원 기준값)
	defaultLighting = captureLighting()
	broadcastQueue()
end

return RaceManager
