--!strict
--[[
	GameConfig
	-----------
	게임의 모든 핵심 데이터를 한곳에 모은 설정 모듈입니다.
	차량 목록 / 등급 / 성능 / 가격 / 보상 / 트랙 / 커스터마이징 옵션을
	여기서 관리하면 밸런스 조정이 쉬워집니다.

	이 모듈은 서버와 클라이언트 양쪽에서 require 하여 공유합니다.
]]

local GameConfig = {}

-- =====================================================================
-- 자동차 등급 (Tier)
-- =====================================================================
-- 4등급: 초보(Beginner) / 일반(Normal) / 고급(Advanced) / 전설(Legendary)
export type Tier = "Beginner" | "Normal" | "Advanced" | "Legendary"

GameConfig.Tiers = {
	Beginner = {
		displayName = "초보",
		color = Color3.fromRGB(120, 200, 120), -- 초록
		order = 1,
	},
	Normal = {
		displayName = "일반",
		color = Color3.fromRGB(90, 160, 240), -- 파랑
		order = 2,
	},
	Advanced = {
		displayName = "고급",
		color = Color3.fromRGB(180, 110, 240), -- 보라
		order = 3,
	},
	Legendary = {
		displayName = "전설",
		color = Color3.fromRGB(240, 200, 70), -- 금색
		order = 4,
	},
}

-- =====================================================================
-- 자동차 목록
-- =====================================================================
-- 성능 스탯 (아케이드):
--   topSpeed  : 최고 속도 (studs/sec)
--   accel     : 가속력 (높을수록 빨리 최고속 도달)
--   handling  : 핸들링 (회전 민첩성, 0~1 권장)
--   grip      : 접지력 (코너에서 미끄러짐 저항, 0~1)
--
-- 가격:
--   currency = "Money"  → 게임머니로 구매
--   currency = "Robux"  → 로벅스로 구매 (현재 비활성, 구조만 준비)
--   price    = 0        → 기본 보유(무료)

export type CarStats = {
	topSpeed: number,
	accel: number,
	handling: number,
	grip: number,
}

export type CarDef = {
	id: string,
	displayName: string,
	tier: Tier,
	currency: "Money" | "Robux",
	price: number,
	robuxProductId: number?, -- 로벅스 차량용 DevProduct/GamePass id (출시 전 연결)
	defaultColor: Color3,
	stats: CarStats,
}

GameConfig.Cars = {
	-- ───────── 초보 (무료 기본 차) ─────────
	{
		id = "starter_kart",
		displayName = "스타터 카트",
		tier = "Beginner",
		currency = "Money",
		price = 0,
		defaultColor = Color3.fromRGB(200, 200, 200),
		stats = { topSpeed = 120, accel = 30, handling = 0.65, grip = 0.7 },
	},
	{
		id = "city_hatch",
		displayName = "시티 해치백",
		tier = "Beginner",
		currency = "Money",
		price = 0,
		defaultColor = Color3.fromRGB(230, 180, 90),
		stats = { topSpeed = 130, accel = 32, handling = 0.6, grip = 0.72 },
	},

	-- ───────── 일반 (게임머니, 800~1500) ─────────
	{
		id = "street_coupe",
		displayName = "스트리트 쿠페",
		tier = "Normal",
		currency = "Money",
		price = 800,
		defaultColor = Color3.fromRGB(60, 120, 220),
		stats = { topSpeed = 160, accel = 40, handling = 0.68, grip = 0.75 },
	},
	{
		id = "rally_runner",
		displayName = "랠리 러너",
		tier = "Normal",
		currency = "Money",
		price = 1100,
		defaultColor = Color3.fromRGB(220, 90, 60),
		stats = { topSpeed = 155, accel = 46, handling = 0.74, grip = 0.82 },
	},
	{
		id = "muscle_v8",
		displayName = "머슬 V8",
		tier = "Normal",
		currency = "Money",
		price = 1500,
		defaultColor = Color3.fromRGB(40, 40, 50),
		stats = { topSpeed = 185, accel = 38, handling = 0.6, grip = 0.7 },
	},

	-- ───────── 고급 (게임머니, 3000~6000) ─────────
	{
		id = "turbo_gt",
		displayName = "터보 GT",
		tier = "Advanced",
		currency = "Money",
		price = 3000,
		defaultColor = Color3.fromRGB(230, 70, 130),
		stats = { topSpeed = 210, accel = 52, handling = 0.76, grip = 0.82 },
	},
	{
		id = "aero_spec",
		displayName = "에어로 스펙",
		tier = "Advanced",
		currency = "Money",
		price = 4500,
		defaultColor = Color3.fromRGB(50, 200, 180),
		stats = { topSpeed = 225, accel = 55, handling = 0.8, grip = 0.85 },
	},
	{
		id = "phantom_x",
		displayName = "팬텀 X",
		tier = "Advanced",
		currency = "Money",
		price = 6000,
		defaultColor = Color3.fromRGB(140, 60, 220),
		stats = { topSpeed = 240, accel = 58, handling = 0.82, grip = 0.86 },
	},

	-- ───────── 전설 (로벅스 전용, 현재 비활성) ─────────
	{
		id = "hyper_aurora",
		displayName = "하이퍼 오로라",
		tier = "Legendary",
		currency = "Robux",
		price = 499, -- 로벅스 가격 (참고용, 실제 결제는 비활성)
		robuxProductId = nil, -- 출시 전 GamePass/DevProduct id 연결
		defaultColor = Color3.fromRGB(255, 215, 0),
		stats = { topSpeed = 280, accel = 70, handling = 0.9, grip = 0.92 },
	},
	{
		id = "void_reaper",
		displayName = "보이드 리퍼",
		tier = "Legendary",
		currency = "Robux",
		price = 799,
		robuxProductId = nil,
		defaultColor = Color3.fromRGB(20, 20, 30),
		stats = { topSpeed = 300, accel = 75, handling = 0.92, grip = 0.94 },
	},
}

-- 빠른 조회를 위한 id → CarDef 맵
GameConfig.CarsById = {} :: { [string]: CarDef }
for _, car in ipairs(GameConfig.Cars) do
	GameConfig.CarsById[car.id] = car
end

-- =====================================================================
-- 경제 / 보상
-- =====================================================================
GameConfig.Economy = {
	startingMoney = 0, -- 신규 플레이어 시작 머니
	defaultCarId = "starter_kart", -- 모두가 기본 보유하는 차

	-- 순위별 보상 (게임머니)
	-- 1등 100 / 2등 60 / 3등 40 / 그 외 완주 20
	rewardsByPlace = {
		[1] = 100,
		[2] = 60,
		[3] = 40,
	},
	finishReward = 20, -- 4등 이하 완주 보상
}

-- =====================================================================
-- 커스터마이징 옵션
-- =====================================================================
GameConfig.Customization = {
	timeLimit = 30, -- 커스터마이징 제한 시간 (초)

	-- 차체 색상 팔레트
	bodyColors = {
		Color3.fromRGB(230, 60, 60),
		Color3.fromRGB(240, 140, 40),
		Color3.fromRGB(245, 215, 60),
		Color3.fromRGB(90, 210, 110),
		Color3.fromRGB(60, 150, 240),
		Color3.fromRGB(150, 90, 230),
		Color3.fromRGB(245, 245, 245),
		Color3.fromRGB(35, 35, 40),
	},

	-- 휠 색상 / 네온 색상
	wheelColors = {
		Color3.fromRGB(20, 20, 20),
		Color3.fromRGB(200, 200, 210),
		Color3.fromRGB(230, 190, 50),
	},
	neonColors = {
		Color3.fromRGB(0, 0, 0), -- 꺼짐
		Color3.fromRGB(0, 200, 255),
		Color3.fromRGB(255, 0, 150),
		Color3.fromRGB(120, 255, 0),
		Color3.fromRGB(255, 120, 0),
	},

	-- 스티커/데칼 (Roblox 데칼 에셋 id — 출시 전 실제 id로 교체)
	stickers = {
		{ id = "none", displayName = "없음", assetId = 0 },
		{ id = "flame", displayName = "불꽃", assetId = 0 },
		{ id = "star", displayName = "별", assetId = 0 },
		{ id = "lightning", displayName = "번개", assetId = 0 },
	},
}

-- =====================================================================
-- 트랙 / 경주
-- =====================================================================
GameConfig.Race = {
	trackCount = 10, -- 절차적으로 만들 트랙 종류 수
	maxPlayers = 8, -- 한 경주 최대 인원
	minPlayers = 1, -- 경주 시작 최소 인원
	lobbyCountdown = 15, -- 대기열에서 시작까지 카운트다운 (초)
	laps = 2, -- 완주 랩 수
	raceTimeLimit = 180, -- 경주 제한 시간 (초)
}

return GameConfig
