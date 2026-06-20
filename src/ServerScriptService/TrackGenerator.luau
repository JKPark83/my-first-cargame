--!strict
--[[
	TrackGenerator
	---------------
	코드로 트랙을 절차적으로 생성합니다.
	- 시드(seed) 기반으로 매번 동일하게 재현되는 닫힌 루프 트랙 10종
	- 도로 세그먼트 / 체크포인트 / 출발 스폰 / 결승선을 배치
	- 경주 시작 시 RaceManager가 랜덤으로 하나를 골라 build() 호출

	트랙은 평면(아케이드)으로 생성되며, 체크포인트를 순서대로 통과하면
	랩이 인정됩니다(결승선 = 1번 체크포인트).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local GameConfig = require(ReplicatedStorage.GameConfig)

local TrackGenerator = {}

local ROAD_WIDTH = 48
local ROAD_THICKNESS = 2
local WALL_HEIGHT = 8
local CHECKPOINT_EVERY = 1 -- 모든 경로 노드를 체크포인트로 사용
local NODE_COUNT = 16 -- 루프를 구성하는 제어점 수
local BASE_RADIUS = 320 -- 트랙 기본 반경

export type TrackInfo = {
	index: number,
	displayName: string,
	model: Model,
	startCFrame: CFrame,
	spawnCFrames: { CFrame },
	checkpoints: { BasePart }, -- 순서대로 통과해야 하는 체크포인트
	checkpointCount: number,
}

-- 시드 기반 의사난수 생성기 (재현 가능)
local function makeRandom(seed: number): Random
	return Random.new(seed)
end

-- 루프를 구성하는 평면상의 노드(위치) 목록 생성
local function generateNodes(rng: Random): { Vector3 }
	local nodes: { Vector3 } = {}
	for i = 1, NODE_COUNT do
		local angle = (i - 1) / NODE_COUNT * math.pi * 2
		-- 반경에 노이즈를 주어 트랙마다 모양이 달라지게 함
		local radiusJitter = rng:NextNumber(0.65, 1.35)
		local radius = BASE_RADIUS * radiusJitter
		-- 약간의 고저차(아케이드라 완만하게)
		local x = math.cos(angle) * radius
		local z = math.sin(angle) * radius * rng:NextNumber(0.8, 1.2)
		nodes[i] = Vector3.new(x, 0, z)
	end
	return nodes
end

-- Catmull-Rom 스플라인으로 노드 사이를 부드럽게 보간
local function catmullRom(p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3, t: number): Vector3
	local t2 = t * t
	local t3 = t2 * t
	return 0.5
		* (
			(2 * p1)
			+ (-p0 + p2) * t
			+ (2 * p0 - 5 * p1 + 4 * p2 - p3) * t2
			+ (-p0 + 3 * p1 - 3 * p2 + p3) * t3
		)
end

-- 노드를 보간해 촘촘한 경로 점 목록 생성
local function buildPath(nodes: { Vector3 }, samplesPerSegment: number): { Vector3 }
	local path: { Vector3 } = {}
	local n = #nodes
	for i = 1, n do
		local p0 = nodes[(i - 2) % n + 1]
		local p1 = nodes[(i - 1) % n + 1]
		local p2 = nodes[i % n + 1]
		local p3 = nodes[(i + 1) % n + 1]
		for s = 0, samplesPerSegment - 1 do
			local t = s / samplesPerSegment
			path[#path + 1] = catmullRom(p0, p1, p2, p3, t)
		end
	end
	return path
end

local function makeRoadSegment(a: Vector3, b: Vector3, parent: Instance): ()
	local mid = (a + b) / 2
	local dir = b - a
	local length = dir.Magnitude
	if length < 0.05 then
		return
	end
	local look = CFrame.lookAt(mid, b)

	local road = Instance.new("Part")
	road.Anchored = true
	road.Material = Enum.Material.Asphalt
	road.Color = Color3.fromRGB(55, 55, 60)
	road.Size = Vector3.new(ROAD_WIDTH, ROAD_THICKNESS, length + 1)
	road.CFrame = look * CFrame.new(0, -ROAD_THICKNESS / 2, 0)
	road.TopSurface = Enum.SurfaceType.Smooth
	road.BottomSurface = Enum.SurfaceType.Smooth
	road.Parent = parent

	-- 양쪽 벽(가드레일) — 코스 이탈 방지
	for _, side in ipairs({ -1, 1 }) do
		local wall = Instance.new("Part")
		wall.Anchored = true
		wall.Material = Enum.Material.Neon
		wall.Color = side == -1 and Color3.fromRGB(230, 80, 80) or Color3.fromRGB(80, 160, 230)
		wall.Size = Vector3.new(1.5, WALL_HEIGHT, length + 1)
		wall.CFrame = look * CFrame.new(side * (ROAD_WIDTH / 2), WALL_HEIGHT / 2, 0)
		wall.Transparency = 0.35
		wall.Parent = parent
	end
end

-- =====================================================================
-- 공개 API
-- =====================================================================

-- 트랙 메타 정보(미생성). 미리보기/목록 표시에 사용 가능.
function TrackGenerator.getTrackMeta(index: number)
	return {
		index = index,
		seed = 1000 + index * 7919, -- 트랙별 고정 시드 (소수 곱)
		displayName = ("트랙 #%d"):format(index),
	}
end

-- 트랙을 실제로 생성하여 Workspace에 배치하고 정보를 반환
function TrackGenerator.build(index: number, parent: Instance?): TrackInfo
	local meta = TrackGenerator.getTrackMeta(index)
	local rng = makeRandom(meta.seed)

	local model = Instance.new("Model")
	model.Name = ("Track_%d"):format(index)

	local nodes = generateNodes(rng)
	local path = buildPath(nodes, 8)

	-- 도로 생성
	for i = 1, #path do
		local a = path[i]
		local b = path[(i % #path) + 1]
		makeRoadSegment(a, b, model)
	end

	-- 체크포인트 생성 (경로 노드 위치 기반, 순서대로)
	local checkpoints: { BasePart } = {}
	local cpFolder = Instance.new("Folder")
	cpFolder.Name = "Checkpoints"
	cpFolder.Parent = model

	for i = 1, #nodes, CHECKPOINT_EVERY do
		local pos = nodes[i]
		local nextPos = nodes[i % #nodes + 1]
		local look = CFrame.lookAt(pos, nextPos)

		local cp = Instance.new("Part")
		cp.Name = ("Checkpoint_%d"):format(#checkpoints + 1)
		cp.Anchored = true
		cp.CanCollide = false
		cp.Transparency = 1
		cp.Size = Vector3.new(ROAD_WIDTH, WALL_HEIGHT * 2, 4)
		cp.CFrame = look * CFrame.new(0, WALL_HEIGHT, 0)
		cp:SetAttribute("Order", #checkpoints + 1)
		cp.Parent = cpFolder
		checkpoints[#checkpoints + 1] = cp
	end

	-- 결승선(1번 체크포인트) 시각 표시
	local startNode = nodes[1]
	local secondNode = nodes[2]
	local startLook = CFrame.lookAt(startNode, secondNode)

	local finishLine = Instance.new("Part")
	finishLine.Name = "FinishLine"
	finishLine.Anchored = true
	finishLine.CanCollide = false
	finishLine.Material = Enum.Material.SmoothPlastic
	finishLine.Color = Color3.fromRGB(245, 245, 245)
	finishLine.Size = Vector3.new(ROAD_WIDTH, 0.3, 6)
	finishLine.CFrame = startLook * CFrame.new(0, 0.2, 0)
	finishLine.Parent = model

	-- 출발 스폰 위치들 (결승선 뒤쪽, 그리드 배치)
	local spawnCFrames: { CFrame } = {}
	local rows = math.ceil(GameConfig.Race.maxPlayers / 2)
	local idx = 0
	for row = 0, rows - 1 do
		for col = -1, 1, 2 do
			idx += 1
			if idx > GameConfig.Race.maxPlayers then
				break
			end
			local offset = CFrame.new(col * (ROAD_WIDTH / 4), 4, 10 + row * 12)
			spawnCFrames[idx] = startLook * offset
		end
	end

	model.Parent = parent or workspace

	return {
		index = index,
		displayName = meta.displayName,
		model = model,
		startCFrame = startLook,
		spawnCFrames = spawnCFrames,
		checkpoints = checkpoints,
		checkpointCount = #checkpoints,
	}
end

return TrackGenerator
