# 台北公車 · iPhone

以地圖為主的台北公車 App，優先適配 iPhone 17。SwiftUI 介面、CoreLocation 定位、URLSession 資料更新，搭配 MapLibre Native 與 Metal，把簡單的灰色公車模型畫入地圖道路的 3D 場景。

底圖使用免金鑰的 OpenFreeMap，配色接近 Apple Maps；**目前不是 Apple Maps 底圖**。原生版直接連接臺北市公開 HTTPS 資料，使用時不需要電腦、Node 伺服器或 TDX 金鑰。

## 手機操作

- 開啟即看到地圖、站牌與近期回報的公車。沒有常駐資訊面板；資訊跟隨選中的站牌或車輛。
- 點定位按鈕，才請求使用期間定位權限。可搜尋附近站牌，也可手動選站；不需要背景定位。
- 點站牌查看官方路線到站時間，詳細頁可收藏站牌，或開啟 Apple Maps 步行導航。
- 搜尋路線、切換行駛方向、選車牌，查看指定公車。跟車時鏡頭隨車移動，手動拖曳地圖會停止跟車。
- 車輛資訊包含車牌、路線方向、業者、低底盤資訊、GPS 回報速度與定位時間。
- 選車時淡化建築、強化灰色車身及藍色輪廓；可關閉凸顯，恢復正常建築遮擋。
- 搜尋、詳情與來源說明僅在需要時開啟原生 sheet，支援 Dynamic Type、VoiceOver 與觸覺回饋。

## 即時資料的意義

App 在前景每 15 秒查詢公車與到站資料；這不代表每輛公車的 GPS 都每 15 秒更新。定位超過 2 分鐘會顯示延遲、停止動畫。取得失敗保留最後資料的原始時間；到站預估過期或取得失敗時不顯示舊預估。背景暫停查詢和繪圖，返回 App 立即更新。公車來源由臺北市持續更新，不依賴觀看者開啟 App。

官方 `EstimateTime` 只提供路線／站牌預估，**沒有車牌綁定**。站牌顯示的「附近車牌」依同方向、同路線、近期 GPS 及支線停靠站資料篩選，與路線 ETA 分開呈現；不能把最近車牌直接視為下一班。

GPS 在官方路線軌跡 40 公尺內時匹配軌跡。相鄰回報屬於同車、同路線、同方向且間距合理，才沿路線轉彎平滑移動；無匹配時顯示原始 GPS，不推算尚未收到的未來位置。不提供車道級或高架高度定位。

## 原生地圖與效能

`ios/TaipeiBus/NativeBusLayer.swift` 是 MapLibre Native 的 Metal custom style layer。約 2.55 × 11.8 × 3.5 公尺的公車網格共用地圖相機與 3D depth buffer，遵循地圖透視與建築遮擋。凸顯模式讓選中的車輛略過遮擋，保持原本世界座標。車輛以 instancing 繪製，每幀最多 240 輛可見車；使用三組 GPU instance buffer 避免改寫仍在使用的資料。

公車動畫最高 60 fps，低耗電或較高溫時降為 30 fps；沒有移動時不要求連續重畫。原生 UI 由系統管理更新率。實際 GPU、耗電與流暢度仍需在 iPhone 17 實機測量。

## 建置

最低 iOS 17；iPhone 17 模擬器使用 Xcode 26。在 Mac 開啟 `ios/TaipeiBus.xcodeproj`，選 TaipeiBus scheme 與 iPhone 模擬器，即可編譯。安裝到實機需自己的 Bundle ID 與 Apple Signing Team。

Windows 使用本專案的 GitHub Actions：提交 `ios/` 變更後，macOS runner 執行 Swift 核心測試、編譯原生 App、啟動 iPhone 17 模擬器並保存截圖。下載 Actions 的 `iPhone17-simulator` artifact 可取得 `.app`、截圖與編譯紀錄；模擬器 `.app` 不能直接安裝到 iPhone。

[雲端建置及 TestFlight 步驟](ios/CLOUD_BUILD.md)說明如何使用既有 Apple Developer 帳號，簽名後直接上傳 TestFlight；也保留單獨匯出 IPA 的入口。簽名金鑰放在 GitHub Actions secrets，不寫入原始碼或聊天。

## 資料與授權

使用[臺北市公共運輸處公開 API](https://pto.gov.taipei/News_Content.aspx?n=A1DF07A86105B6BB&s=55E8ADD164E4F579&sms=2479B630A6BD8079)：`GetBusData`、`GetEstimateTime`、`GetRoute`、`GetStop`、`GetPathDetail`、`GetProvider`、`GetBusShape`。全部為公開 gzip JSON，來源為 `https://tcgbusfs.blob.core.windows.net/blobbus/`。

車輛範圍先限制台北市區周邊（121.40–121.72°E、24.94–25.23°N），包含經過此範圍的跨市路線。底圖為 OpenStreetMap／OpenMapTiles、OpenFreeMap；地圖保留來源 attribution。MapLibre Native 固定為 6.31.0。SDK 及修改後 Liberty 樣式授權收錄於 `ios/TaipeiBus/Licenses.txt`。

## 本機驗證與手機預覽

`ios/TransitCore` 是可獨立測試的 Swift package。7 項測試已在 Swift 6.2 上通過，涵蓋台北時區、異常及過期回報、同名站牌方向、支線停靠站、轉彎及反向路徑、重複 snapshot、ETA 與車牌分離。gzip 解壓縮已測試正常資料、截斷資料與大小限制。UIKit／Metal App 的編譯與截圖由 macOS Actions 驗證；實機簽名另行處理。

原有 `src/`、`server/` 保留為手機尺寸的互動預覽，可在 Windows 查看設計：

```sh
npm install
npm run build
npm start
```

開啟 `http://localhost:4173/`。手機預覽已用 iPhone 17 的 402 × 874 pt 尺寸驗證站牌、路線、車牌、跟車與定位流程；瀏覽器畫面不代表原生 iOS 的實機驗證。`work/` 包含可重建的本機測試資料，不提交到 GitHub。
