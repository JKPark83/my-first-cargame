# 🏎️ My First Car Game (자동차 경주 게임)

로블록스(Roblox) 멀티플레이 자동차 경주 게임입니다.
라운지에서 차를 고르고, 30초 안에 꾸미고, 랜덤 트랙에서 최대 8명이 경주합니다.
순위에 따라 게임머니를 받아 더 좋은 차를 사는 성장형 레이싱 게임입니다.

## ✨ 핵심 기능

| 기능 | 설명 |
|------|------|
| 🏠 3D 라운지 | 입장 시 로비 공간. 경주 참가 패드 / 차고 버튼 |
| 🚗 4등급 차량 | 초보(무료) · 일반 · 고급(게임머니) · 전설(로벅스, 현재 비활성) |
| 🎨 커스터마이징 | 차체 색상 · 휠 · 네온 · 스티커 · 번호판 (30초 제한 타이머) |
| 🏁 멀티플레이 경주 | 대기열 → 카운트다운 → 랜덤 트랙 → 최대 8명 경주 |
| 🛣️ 절차적 트랙 | 코드로 생성되는 10종 루프 트랙 (시드 기반 재현) |
| 💰 보상 경제 | 1등 100 / 2등 60 / 3등 40 / 완주 20 게임머니 |
| 💾 영구 저장 | DataStore로 머니 · 보유차 · 커스텀 · 최고기록 영구 저장 |
| 🗺️ 미니맵 + 실시간 순위 | 경주 중 트랙 미니맵·차량 위치·실시간 등수·랩 표시 |
| 🚀 부스트 / 장애물 | 부스트 패드(가속) · 오일 슬릭(감속) · 라바콘 |
| 🏆 글로벌 리더보드 | 최고 완주 기록 순위 (라운지 전광판 + UI 패널) |

## 🎮 조작

- **W / S** : 가속 / 후진
- **A / D** : 좌 / 우 조향
- 🚀 **부스트 패드**(파란 발판)를 밟으면 일시 가속, 🛢️ **오일 슬릭**(검은 웅덩이)을 밟으면 감속
- (VehicleSeat 기본 입력을 아케이드 물리로 변환)

## 🗂️ 프로젝트 구조

```
default.project.json          # Rojo 프로젝트 설정
src/
├─ ReplicatedStorage/
│  ├─ GameConfig.luau         # 차량·트랙·보상·가격·커스텀 데이터 (밸런스 중심)
│  └─ Remotes.luau            # 클라↔서버 RemoteEvent/Function 정의
├─ ServerScriptService/
│  ├─ Main.server.luau        # 서버 진입점 (모든 시스템 초기화)
│  ├─ DataManager.luau        # DataStore 저장/로드
│  ├─ LoungeBuilder.luau      # 3D 라운지 생성
│  ├─ TrackGenerator.luau     # 절차적 트랙 생성
│  ├─ CarSpawner.luau         # 차량 조립·성능·커스텀 적용
│  ├─ ShopService.luau        # 구매·선택·커스터마이징 검증
│  ├─ LeaderboardService.luau # 글로벌 최고기록 (OrderedDataStore)
│  └─ RaceManager.luau        # 대기열·경주·순위·보상·미니맵·부스트 (핵심 루프)
└─ StarterPlayer/StarterPlayerScripts/
   ├─ CarController.client.luau  # 아케이드 주행 물리
   └─ UIController.client.luau   # 차고·커스텀·HUD·결과 UI
```

## 🚀 Roblox Studio에서 실행하기 (Rojo)

이 프로젝트는 [Rojo](https://rojo.space)로 파일시스템 ↔ Roblox Studio를 동기화합니다.

1. **Rojo 설치** (택1)
   - [Aftman](https://github.com/LPGhatguy/aftman) / [Rokit](https://github.com/rojo-rbx/rokit) 사용, 또는
   - `cargo install rojo`, 또는
   - VS Code 확장 **"Rojo"** 설치
2. **Studio 플러그인 설치**: VS Code 확장 또는 `rojo plugin install`
3. 저장소 루트에서 서버 실행:
   ```bash
   rojo serve
   ```
4. Roblox Studio에서 빈 baseplate 열기 → Rojo 플러그인에서 **Connect**
5. ▶️ **Play** 로 테스트

> 또는 한 번에 빌드: `rojo build -o game.rbxlx` 후 Studio에서 열기.

### ⚙️ 실행 전 설정

- **DataStore**: Studio 테스트 시 `Game Settings → Security → Enable Studio Access to API Services` 켜기.
  (꺼져 있으면 자동으로 세션 임시 저장으로 동작합니다.)
- **혼자 테스트**: `GameConfig.Race.minPlayers = 1` 로 되어 있어 1인 경주가 가능합니다.
  멀티플레이 테스트는 Studio의 **Test → Clients and Servers** 로 여러 클라이언트를 띄우세요.

## 🔧 밸런스 / 콘텐츠 조정

대부분의 수치는 **`src/ReplicatedStorage/GameConfig.luau`** 한 곳에서 조정합니다.

- 차량 추가/성능/가격 → `GameConfig.Cars`
- 보상 금액 → `GameConfig.Economy.rewardsByPlace`, `finishReward`
- 트랙 수 / 인원 / 랩 / 카운트다운 → `GameConfig.Race`
- 커스터마이징 색상/스티커/제한시간 → `GameConfig.Customization`
- 부스트 세기/지속시간/개수 → `GameConfig.Boost`
- 오일 슬릭 감속/개수, 콘 개수 → `GameConfig.Obstacles`
- 리더보드 표시 인원/캐시 주기 → `GameConfig.Leaderboard`

## 💎 로벅스(수익화) 연결 — 출시 전 TODO

현재 전설 등급 차량은 **구조만 준비되고 결제는 비활성** 상태입니다. 출시 시:

1. Roblox에서 GamePass 또는 DevProduct 생성
2. `GameConfig.Cars`의 전설 차량 `robuxProductId`에 id 입력
3. `ShopService.handleBuy`의 로벅스 분기에 `MarketplaceService:PromptProductPurchase` 연결
4. `ProcessReceipt`에서 `DataManager.grantCar` 호출

## 📝 참고

- 스티커 데칼은 `assetId = 0`(플레이스홀더)입니다. 실제 데칼 에셋 id로 교체하세요.
- 트랙/차량은 모두 코드로 생성되어 별도 3D 에셋 없이 동작합니다.
- 향후 개선 아이디어: 부스트 아이템, 미니맵, 리더보드, 시즌 패스 등.
