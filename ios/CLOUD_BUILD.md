# TestFlight 發布手冊（Windows → GitHub macOS → iPhone）

更新：2026-10-04。此專案不需要你先取得 Mac；Xcode 建置和發行簽名由 GitHub 的標準 macOS runner 執行。第一次安裝優先採用 **TestFlight 內部測試**。目前已改為公開儲存庫，標準製作電腦適用公開專案的免費規則；製作紀錄與預覽檔案仍依需要保存，避免重複執行。GitHub Actions 與 GitHub Releases 的成品存放空間適用不同規則。[GitHub Actions 帳務說明](https://docs.github.com/en/billing/concepts/product-billing/github-actions)

## 公開 App Store 發佈

正式版 `1.0.0 (23.1.0)` 已簽名上傳並完成 Apple 處理，加入既有 TestFlight 內部群組，且上架資料已指定此版本；已於 2026-10-04 00:59（台灣時間）提交 App Review，目前等待 Apple 審查；尚未公開下載。已設定免費、僅台灣、審核後自動發佈。公開支援及隱私頁由 GitHub Pages 的 `docs` 目錄提供：

- [支援與聯絡](https://rio10255254.github.io/TaipeiBus/support.html)
- [隱私政策](https://rio10255254.github.io/TaipeiBus/privacy.html)
- [1.0.0 發佈回條](https://github.com/rio10255254/TaipeiBus/actions/runs/37136630816)
- [首次原生操作與商店截圖檢查](https://github.com/rio10255254/TaipeiBus/actions/runs/37133870399)
- [3D 跟車及詳情切換檢查](https://github.com/rio10255254/TaipeiBus/actions/runs/37137711570)
- [七張截圖及台灣免費設定核對](https://github.com/rio10255254/TaipeiBus/actions/runs/37138719534)
- [Apple 審查紀錄](https://appstoreconnect.apple.com/apps/6818475740/distribution/reviewsubmissions/details/c422d760-5efa-4bd4-a7ba-2bb4adbdb6d7)

`TestFlight` 工作流程支援 `store-audit`（唯讀）、`store-prepare`（將文案及指定有效 build 寫入可編輯版本）、`store-verify`（驗證台灣零元供應及完成處理的截圖）。`store-prepare` 必須提供 `resume_build`，審查聯絡資料來自 `APP_STORE_REVIEW_CONTACT` Secret；回條及製作紀錄不輸出私人聯絡內容。Apple 的 App 隱私權問卷仍需網站操作。

商店前三張依序為 3D 跟車、公車導航、沿途逐站時間，總共七張圖片均已完成 Apple 處理。商店圖片以 iPhone 17 Pro Max 真正執行 App 拍攝，1320 × 2868 RGB；公車位置和時間使用官方即時資料，僅乘客定位由模擬器提供。`app-store-features` 拍攝實際公車的 3D 跟車、搭車引導及沿途到站預估；不使用測試公車或編造到站資料。沒有即時營運車輛時應等待有效資料，不以測試資料替代。Apple API 的 `APP_IPHONE_67` 對應目前網站的 6.9 吋截圖欄位。

## TestFlight 1.1.4：五秒定位更新與連續真實軌跡

`1.1.4 (35.1.0)` 已完成簽名、上傳與 Apple 處理，加入既有內部群組；來源 `ce3892b8cb9b7deccf5fb6fd1de46eea231087ba`。[發布回條](https://github.com/rio10255254/TaipeiBus/actions/runs/37181688948)確認 `upload_confirmed=true`、`status=internal_group_assigned`。僅供 TestFlight，分支仍為草稿，正式版、公開網站與共享設定文件未改動。

實際連續請求顯示官方 GetBusData 檔案於 2026-10-04 13:17:30–13:18:00 每五秒更新一批車，每批改變 357–509 筆回報；不代表每輛車都每五秒回報。即時條件請求也確認 HTTP 304，避免重複下載 34,418 bytes 並保留原定位時間。App 前景改約五秒檢查定位，從請求開始計時，背景取消更新；較舊的共享設定不包含新增欄位時沿用此原生預設。

原三秒快速銜接改為依定位回報間隔播放真實已接收軌跡。新點提早到來時排入下一段，不重新拉快正在播放的轉彎；積壓總緩衝限制二十秒，維持位置、方向、輪胎行程連續。相同終點的停車新點不會把正在行駛的動畫瞬移到終點；缺少道路軌跡時，只平順銜接可靠的原始定位點。未收到新點就停在最後確定位置，不推演未來 GPS。減少動態效果直接顯示最新確認位置。跟車標籤縮小並移開公車本體；定位動畫保留短暫延遲，官方到站仍使用來源最新資料。

[完整驗證](https://github.com/rio10255254/TaipeiBus/actions/runs/37180642946)通過 111 個核心測試（一般階段略過的五個即時案例另於官方資料階段執行）、Debug／Release 及全部 1,214 個方向／走法、441 個共營站序、1,531 個預期車輛關聯。七份五秒間隔的真實 630 定位重播，通過 15 次連續接點及 2,848 個移動畫面檢查；另涵蓋五秒等速、提前資料、停止資料、來源積壓、道路未確認、重複／失敗 HTTP、2,500 輛車與不超出來源終點的測試。資料保存在 `TransitCoreTests/Fixtures/ContinuousGPS.json`，不含乘客定位。

原生 iPhone 17 模擬器淺色四項、深色三項操作通過，包含真正營運車的來源更新與同車跟隨、2,500 輛持續車流、共營車追蹤與上車後站牌。持續車流每種外觀取 14 次位置樣本，至少七成量測區間仍在移動，沒有超過已收到的位置或快速衝刺；全部車模型保留。前後截圖附帶的定位紀錄量得淺色 27.04 秒平均 1.079 m/s、深色 13.09 秒平均 1.058 m/s，CPU 編碼 P95 分別 22.92、20.97 ms。模擬器繪製回呼中位數 22.14、24.21 ms，P95 43.70、65.98 ms；這些不等於實機顯示幀率或效能保證。已檢視原生實車／車流／跟車畫面；系統淺色／深色／淺色仍維持同一程序、車牌及視野。

原生斷言已檢查每次取樣的移動；此次成品只保留截圖的前後定位紀錄，獨立取樣附件被原匯出篩選器排除。後續匯出已修正為保留所有 `continuous-` 附件並檢查篩選規則。此修正僅影響驗證附件保存，不改動已發布的 App。

## TestFlight 1.1.3：官方下一班優先與車輛時間可信度

`1.1.3 (34.1.0)` 已完成簽名、上傳與 Apple 處理，加入既有內部群組；來源 `381d9b3c7408b1faddea92651476dffdec7388e5`。[發布回條](https://github.com/rio10255254/TaipeiBus/actions/runs/37178287459)確認 `upload_confirmed=true`、`status=internal_group_assigned`。僅供 TestFlight，分支保持草稿；正式版的安裝檔、商店資料、網站與共享即時設定未變更。

候車主畫面明確顯示「官方下一班」。官方資料只有路線、站牌、方向與剩餘秒數，沒有車牌；不把此時間指定給特定車。單車時間需有至少三筆、45 秒、80 公尺的連續行駛紀錄，或至少三輛不同實體車通過對應路段的紀錄；超出近期觀測範圍、不確定度過大或方向不符時不顯示分鐘數。相容共營車可共用幾何相符的路段紀錄，不同繞行路段不混用。官方未營運或單車時間明顯早於官方時，以官方資訊為主，保留定位／站數；GPS 超過 30 秒會標示位置更新中。停車不因舊定位倒數成為即將抵達，回報間隔超過 90 秒重新累積紀錄。

大湖西向 630 的公開資料錄於 2026-10-04 11:57–12:01，晚於使用者 11:54 截圖，不能重建截圖當下的每筆資料。錄製的 388-U8 已通過大湖 651–1,255 公尺，驗證不列為候車車輛；KKA-0363 的稀疏資料曾使舊估計跳成約 8、12、7 分，現在顯示剩餘 9、7、6、6 站，候車以官方倒數為主。資料保存於 `TransitCoreTests/Fixtures/DahuConflict.json`，不包含乘客定位。

[完整驗證](https://github.com/rio10255254/TaipeiBus/actions/runs/37177420952)通過：101 項核心測試（五項即時資料測試在一般階段略過，隨後在完整官方資料階段執行）、Debug／Release、1,214 個方向／走法組合及 441 個共營站序，覆蓋 1,510 個預期車輛關聯。另對 1,061 筆官方車輛回報檢查 12,544 個有序／到期的原始預測；此為健全性檢查，不代表全部預測會呈現分鐘數，也不是實際到站精度證明。

淺色、深色各三項 iPhone 17 原生模擬器操作通過，已檢視候車、全部車輛、追蹤與上車後逐站畫面。衝突場景保留官方 12 分，缺乏紀錄的車顯示時間待確認，足夠連續紀錄的車顯示約 11–14 分；點清單車牌、回到地圖跟車、確認上車及沿途站牌都維持同一車。測試車明確標示且僅存在 Debug 環境。實際系統淺色／深色／淺色切換保持同一程序、車牌、地圖中心與縮放。

地圖收到新位置後，最長三秒內平順抵達已收到的定位，避免額外等待完整的上游回報週期；2,500 輛車測試通過，保留轉彎、車牌、方向及輪胎行程連續性，不越過已收到的終點。不表示上游定位變快，也未宣稱實機幀率或絕對到站精度。保留先前灰色車流與系統深色模式。

## TestFlight 1.1.2：全路線車輛匹配與系統深色模式

`1.1.2 (33.1.0)` 已完成簽名、上傳及 Apple 處理，加入既有內部群組；來源 `c4200e851b9906780d6b11badc1eb609430b98e6`。[發佈回條](https://github.com/rio10255254/TaipeiBus/actions/runs/37175022141)確認 `upload_confirmed=true`、`status=internal_group_assigned`。保持 TestFlight-only，正式版原安裝檔、共享內容更新、商店文案與公開網站不變。

導航不再只比對選中業者的路線代碼。同方向、上車至下車之間停靠站序相同的共營車輛會一同顯示；不同走法、相反方向及已過站車輛仍會排除。選擇其他相容業者的車牌後，跟車、上車確認與沿途預估都使用該實際車輛。缺少 GPS 時，候車區分官方倒數仍可用及前車已過站等情況。

[完整驗證](https://github.com/rio10255254/TaipeiBus/actions/runs/37174224357)通過 Debug／Release、核心測試及官方網路核對：416 條路線、722 種走法、1,214 個方向／走法組合、441 個共營站序，以及全部 1,601 個預期車輛關聯；關聯數包含不同相容走法下的重複檢查，不等於車輛數。630 的固定官方資料重現已另驗證漏車、已過站、反方向及改動站序排除。

外觀跟隨 iPhone 系統：地圖、站名、標記、路線／步行線、搜尋、候車、上車後畫面與 3D 選取都適配深色。已檢視原生截圖，淺色與深色各兩項操作測試通過；實際系統淺色 → 深色 → 淺色切換保持同一程序、車牌、縮放與地圖中心。測試公車明確標示，僅存在 Debug 驗證環境。

## TestFlight 1.1.1：柔和灰色車流

`1.1.1 (32.1.0)` 已完成簽名、上傳與 Apple 處理，加入既有內部測試群組；來源 `b79df78a1e807ddaaf74d3df49d2b322fbc41e47`。[發佈回條](https://github.com/rio10255254/TaipeiBus/actions/runs/37170555367)確認 `upload_confirmed=true`、`status=internal_group_assigned`。此版本僅供 TestFlight，分支仍未合併，正式上架準備入口維持停用。

縮遠不再換成深色方向箭頭。車輛沿用灰色公車形狀，隨縮放平順淡化輪廓、車窗明暗及不透明度，形成柔和車流；靠近後恢復原本的車頂、車窗與輪胎。畫面保留每一輛可見車輛，點車跟隨與返回原地圖範圍的操作不變。

[原生驗證](https://github.com/rio10255254/TaipeiBus/actions/runs/37170017888)通過 Debug／Release 建置、核心測試、四項官方資料檢查與三項全城操作測試，已檢視官方車流、縮放、平移及 3D 跟車截圖。2,500 輛壓力測試車沿測試道路持續行進，全部保留為公車模型；記錄 219 次繪製，CPU 準備 P95 為 8.24 ms、繪製回呼間隔中位數 16.72 ms、P95 33.24 ms。這些是模擬器診斷值，並非實機顯示幀率或耗電保證；測試公車與診斷入口不包含於發布版。

固定道路長度、方向與短路徑方向已快取，車牌位置更新只刷新相應子畫面，避免整個主畫面反覆刷新。位置仍只在已收到的道路資料之間銜接，沒有未來位置外推。本次未改共享內容更新、商店文案或公開網站，正式版仍沿用原送審安裝檔。

## TestFlight 1.1.0：全城公車實驗

目前創新功能先走 TestFlight，保留正式 `1.0.0 (23.1.0)` 的審查。`codex/city-bus-flow` 分支的 `1.1.0 (29.1.0)` 已完成簽名、上傳及 Apple 處理，加入既有內部測試群組；來源為 `096a5c7b2ba6ce43abf2f0be8b3a46fc0dd5d846`。這個分支尚未合併，發布設定標記為 `testflight-only`，正式上架準備入口會拒絕操作。

首頁點「全城」會縮放到目前收到的有效公車位置；縮遠時以小型方向符號呈現，放大後切換到 3D 公車。點選一輛車可跟車，關閉選取回到先前全城範圍，再點「全城」離開時回到原本的附近地圖。

- [1.1.0 發佈回條](https://github.com/rio10255254/TaipeiBus/actions/runs/37145716776)：`upload_confirmed=true`、`status=internal_group_assigned`。
- [原生操作及截圖檢查](https://github.com/rio10255254/TaipeiBus/actions/runs/37142346610)：Debug／Release 編譯、核心測試、四項官方資料檢查及兩項全城操作測試通過。官方即時資料畫面與 2,500 輛壓力測試畫面分別驗證；全城保留全部 2,500 個符號，點車切入 3D、關閉與離開後的地圖位置亦通過檢查。
- 2,500 輛為明確標示的 Debug 測試資料，不包含在發布版；發布版只使用官方資料。動作只在已收到的位置之間銜接，資料過期時停止延伸。
- [上傳後的正式版唯讀核對](https://github.com/rio10255254/TaipeiBus/actions/runs/37146019300)：`1.0.0` 仍是 `WAITING_FOR_REVIEW`，維持原本 `23.1.0` 及原審查紀錄；本分支未改動共享內容更新、商店資料或公開網站。

內部群組已可取得此版本；使用者手機的安裝結果及長時間耗電、溫度仍需實機確認，模擬器壓力測試不能代替這部分。

## 先前 TestFlight 0.4.4 驗證紀錄

| 項目 | 狀態／處理方式 |
| --- | --- |
| 原生 iPhone App | SwiftUI、CoreLocation、MapLibre Native／Metal；優先適配 iPhone 17，最低 iOS 17 |
| 版本 | `0.4.4 (13.1.0)` 已完成正式簽名、上傳及 Apple 處理，並加入既有內部測試群組 |
| 建置工具 | 固定 Xcode 26.3；符合 2026-04-28 起 iOS 26 SDK 以上的上傳要求 |
| App 圖示 | 已有 1024 × 1024 RGB 圖示，無透明背景 |
| 定位／隱私 | 已有使用期間定位說明、Privacy Manifest、App 內隱私說明及政策 HTML 草稿 |
| 網路與加密 | 使用 HTTPS；現有 Info.plist 宣告 `ITSAppUsesNonExemptEncryption=false`，若新增自訂加密須重新評估 |
| 測試 | 78 項離線公車核心測試、3 項官方資料測試，以及 10 項原生操作測試已通過；已檢視實際截圖及桌面圖標；發布腳本另有無網路測試，CI 編譯 Simulator Debug 與 iPhone Release |
| GitHub 儲存庫 | 公開 [rio10255254/TaipeiBus](https://github.com/rio10255254/TaipeiBus)；公開前已檢查完整修改歷史、可取得的製作紀錄與歷史上傳項目，沒有發現私鑰外洩；發布流程已獨立 |
| Apple 帳號授權 | 已設定 API 授權與發行憑證、描述檔；最近成功發佈已完成正式簽名及上傳 |
| App 身分 | `com.rio10255254.TaipeiBus`；已建立 App Store Connect App 記錄並完成過發佈 |
| 真機／TestFlight | `0.4.4 (13.1.0)` 的發佈回條確認已加入內部測試群組；實機安裝結果需由測試者確認 |
| 最新發佈工作 | `0.4.4` [發佈工作](https://github.com/rio10255254/TaipeiBus/actions/runs/37113621917)成功；已核對版本、build、來源 commit、上傳確認及既有內部測試群組狀態 |

0.4.4 加入站牌與地圖聯動、最近站牌重新定位、手機方向切換、路線專用按鍵及紀錄、完整行程切換修正與霧白／藍灰色新圖標。推薦綜合步行、車程、等待及轉乘，納入首班時間，排除普通通勤不適合的特殊服務並保留直達備選。[十項原生操作測試](https://github.com/rio10255254/TaipeiBus/actions/runs/37111958479)全部通過，已檢視實際畫面；發佈來源為 `9db9b12c9828c203ea4efb89b571b2313dc837c2`，回條確認 `upload_confirmed=true`、`status=internal_group_assigned`。

上一版 `0.4.3 (12.1.0)` 的[發佈工作](https://github.com/rio10255254/TaipeiBus/actions/runs/37104010069)成功。

0.4.3 縮短候車資訊、讓三個路線選項同屏顯示，步行留在同一張地圖，並補齊上下車、轉乘及抵達操作。[五項原生操作測試與截圖](https://github.com/rio10255254/TaipeiBus/actions/runs/37099237594)均已通過；發佈來源為 `535556d7eca01bd17e18822fa449b429f2be21d1`，回條確認 `upload_confirmed=true`、`status=internal_group_assigned`。

上一版 `0.4.2 (11.1.0)` 的[發佈工作](https://github.com/rio10255254/TaipeiBus/actions/runs/37089884155)亦成功，包含快速定位、搜尋及內容更新。

SDK 要求見 [Apple 2026 上傳公告](https://developer.apple.com/news/?id=ueeok6yw)。模擬器 `.app` 和原始碼 ZIP 都不能直接安裝到 iPhone。

## 日常小改動

0.4.2 已包含搜尋與外觀內容更新。[內容更新手冊](LIVE_UPDATES.md)列出支援的文字、別名、配色及搭車偏好與回復方式；這些修改不需重新製作 App。新功能、定位程式與計算方法仍走 TestFlight 新版。已實測同一個 App 程序收到真正的 GitHub 更新，發布與回復入口亦均成功。

## 第一次上傳：你需完成的帳號設定

### 1. 確認 Apple Developer 會員與 App 身分

登入 [Apple Developer Account](https://developer.apple.com/account/) 與 [App Store Connect](https://appstoreconnect.apple.com/)。確認付費 Apple Developer Program 會員有效，帳號可管理正確 Team；若 Apple 顯示新版合約，需由 Account Holder 接受。

新 App 建議使用獨立 Bundle ID `com.rio10255254.TaipeiBus`。如果要沿用舊 App，必須改成其已註冊 Bundle ID，並核對既有版本及用途。Team ID 是 Developer 會員頁面的 10 位識別碼，**不是** Issuer ID。App Store Connect App 記錄在上傳後不能更換 Bundle ID；請先確定身分。

[Apple：建立 App 記錄及角色要求](https://developer.apple.com/help/app-store-connect/create-an-app-record/add-a-new-app/)。

### 2. 產生 Team API Key

App Store Connect → Users and Access → Integrations → App Store Connect API → **Team Keys**。若尚未取得 API 存取，先由 Account Holder 申請啟用。為 GitHub CI 建立 Team Key，建議由 Account Holder／Admin 配置 Admin 角色，讓 CI 可管理 App ID、自動簽名與內部測試群組。

記下 Key ID（10 位）和 Issuer ID（UUID），下載 `.p8` 私鑰並妥善保存；Apple 只允許下載一次。這個 key 是 App Store Connect API 授權，不是 `.p12` Distribution Certificate。**Individual API Key 不能完成這裡所需的自動 provisioning**。Team Key 權限可能涵蓋團隊多個 App，請確認使用專門給此 CI 的 key。

[Apple：建立 API Key](https://developer.apple.com/documentation/appstoreconnectapi/creating-api-keys-for-app-store-connect-api)、[API 存取與角色](https://developer.apple.com/help/app-store-connect/get-started/app-store-connect-api)、[雲端簽名憑證權限](https://developer.apple.com/help/account/certificates/cloud-managed-certificates/)。

### 3. 將四個值存入 GitHub Secrets

儲存庫 Settings → Secrets and variables → Actions → New repository secret：

| Secret | 值 |
| --- | --- |
| `APPLE_TEAM_ID` | Developer 會員頁的 Team ID |
| `ASC_KEY_ID` | Team API Key 的 Key ID |
| `ASC_ISSUER_ID` | 該 Team API Key 的 Issuer ID |
| `ASC_PRIVATE_KEY` | `.p8` 完整內容，包含 BEGIN／END PRIVATE KEY 與換行 |

不要把私鑰貼進聊天、提交到 Git 或加入公開網址。Windows 已登入 GitHub CLI 時，可用本專案的腳本一次設定，不會印出私鑰或將其放入命令列參數：

```powershell
.\ios\Configure-TestFlight.ps1 `
  -TeamId '你的10位TEAMID' `
  -KeyId '你的10位KEYID' `
  -IssuerId '你的Issuer-UUID' `
  -PrivateKeyPath 'C:\你的資料夾\AuthKey_XXXXXXXXXX.p8' `
  -BundleId 'com.rio10255254.TaipeiBus'
```

範例中的中文值必須換成實際值。原始 `.p8` 仍由你保管，腳本不會刪除。Secrets 只能寫入／覆蓋，後續只能查名稱，無法從 GitHub 取回私鑰。

Repository Variables（不是 Secrets）可配置：

| Variable | 用途 |
| --- | --- |
| `BUS_BUNDLE_ID` | 已確定的 App Bundle ID；腳本會設定 |
| `BUS_FEEDBACK_EMAIL` | 真實、可收到測試回饋的信箱；外部測試前補齊 |
| `BUS_PRIVACY_POLICY_URL` | 發布後的公開 HTTPS 隱私政策；外部審查／正式發布前補齊 |

腳本接受 `-FeedbackEmail` 與 `-PrivacyPolicyUrl` 選用參數。沒有提供時會保留 GitHub／Apple 既有值，不填假的資料。

### 4. 註冊 App ID，建立 App Store Connect App 記錄

開啟 [GitHub Actions → TestFlight](https://github.com/rio10255254/TaipeiBus/actions/workflows/testflight.yml) → Run workflow → branch `main`：

1. `operation=register-app-id`：由 API 註冊 Bundle ID；已存在則沿用。如果你在 Developer 網站已註冊同一 ID，可跳過此步。
2. 在 App Store Connect → My Apps → `+` → New App 建立記錄。此步需要網站操作；Apple 的 Apps API 沒有新增 App 記錄端點。

填寫：

| 欄位 | 建議 |
| --- | --- |
| Platforms | iOS |
| Name | 台北公車；若名稱不可用，需選擇可用名稱 |
| Primary Language | Chinese (Traditional)／繁體中文 |
| Bundle ID | 與 CI 完全相同的已註冊 ID |
| SKU | `TaipeiBus-iOS`，或你自己可唯一辨識的代碼 |
| User Access | 按團隊實際需求設定 |

App 記錄建立完成後，執行 `operation=check-only`。這只讀取帳號、App 記錄與現有 build，產生預檢回條，不上傳或修改測試群組。成功後再選 `operation=upload`。

## 自動上傳做什麼

`TestFlight` workflow 只有手動明確選 `upload` 才發布；`main` 提交和 PR 只做測試／編譯。修改分支的普通提交不另開重複工作，未建立 PR 時可手動驗證。一般檢查只保存紀錄，只有手動要求預覽才打包模擬器 App。不同發布依序排隊，不會因新提交而中斷已開始的上傳。

1. 檢查圖示、隱私 Manifest、定位文案、版本、平台與測試說明。
2. 驗證 App ID／App 記錄，查現有 build，選出唯一 `major.attempt.0` build number。
3. 執行發布腳本測試與 64 項離線 Swift 核心測試。
4. 使用 Release、iPhoneOS SDK、正確 Team／Bundle ID／版本與發行簽名 archive。
5. 驗證實際 archive 的簽名、SDK、圖示、Manifest、dSYM 與版本，確認沒有 Debug 預覽入口。
6. 使用 Xcode 直接上傳 App Store Connect。禁止 Xcode 自動改寫 build number，以便可靠核對。
7. 只追蹤這次指定的 App、marketing version 和 build number。等待 Apple processing；確認可內部測試後，建立／沿用 `TaipeiBus Internal` 群組並加入該 build。
8. 寫入繁體中文 Beta 描述與 What to Test；設定了信箱／政策網址才更新相應欄位。
9. 保存無私鑰的回條、建置／上傳紀錄與 crash symbols 14 天；工作結束移除暫存 `.p8`。

群組以 App 範圍及名稱比對，不會把 build 加入同名外部群組。流程不新增測試者、不寄邀請、不開公開連結，也不代填審查聯絡人或自動送外部審查。

App Store Connect 仍可能因權限、憑證、合約或 export compliance 要求額外操作；這些狀態會明確回報。**job 成功但回條為 `processing_pending` 時，仍不能宣稱已可安裝。**

## 在 iPhone 安裝：最快內部測試

在 App Store Connect → 此 App → TestFlight → Internal Testing → `TaipeiBus Internal`，把你自己的符合資格 App Store Connect 使用者加入群組；若你本來已在這個群組中，核對最新 build 是否顯示可測試。帳號持有人或管理員亦需確認該使用者的角色與 App 存取權。

iPhone 安裝 Apple 的 TestFlight，使用對應測試者 Apple 帳號，接受 App Store Connect 提供的測試邀請／入口並安裝。此處不需要實機 UDID，也不用將 iPhone 接到 Mac。

內部測試最多 100 名符合資格的 App Store Connect 使用者，最快開始；外部測試最多 10,000 人，第一個外部 build 必須經 Beta App Review。build 最多可測試 90 天，之後需新 build。Apple 處理或審查時間無法保證。

[Apple：TestFlight 概覽](https://developer.apple.com/help/app-store-connect/test-a-beta-version/testflight-overview/)、[新增內部測試者](https://developer.apple.com/help/app-store-connect/test-a-beta-version/add-internal-testers/)。

## Apple 處理延遲、失敗與接續

每次 run 的 Summary 與 `TestFlight-<run>-<attempt>` artifact 有 `testflight-receipt.json`，包含 App、Bundle ID、版本、build、commit 與狀態。先核對回條與 Apple 網站同一 build。

| 狀態／錯誤 | 做法 |
| --- | --- |
| `account_verified` | 帳號預檢通過，尚未上傳 |
| `uploaded_processing_pending` | Xcode 上傳命令成功，Apple 處理／可測試狀態待確認 |
| `processing_pending` | 20 分鐘內尚未確認可測試；稍後用下述 `finish-processing` 接續，不重傳相同 build |
| `internal_group_assigned` | Apple 已處理、build 已掛到內部群組；還要核對自身測試者資格／安裝 |
| `apple_action_required` | 在 Apple 網站處理 export compliance 等顯示問題，再接續 |
| HTTP 401 | 核對 Issuer ID、Key ID、完整 `.p8` 是否相配／已撤銷 |
| HTTP 403 | 核對 Team Key 角色、App 權限、最新合約及 Developer 會員 |
| No app record／Bundle ID mismatch | 先註冊相同 Bundle ID，建立該 App 記錄，勿上傳到其他 App |
| Automatic signing／cloud certificate 失敗 | Account Holder／Admin 核對雲端簽名權限與可用 Distribution 憑證；必要時改成另行配置 `.p12` 與 provisioning profile，不要當作已有簽名 |
| FAILED／INVALID／已過期 | 查看 Apple 的實際原因；修正後發布新 build |
| 重複 build number | 核對其他 CI 是否同時發布；本流程會依 Apple 已有 build 遞增，仍需避免另一條發布管線競爭 |

接續操作：Run workflow → `operation=finish-processing` → 填回條中的同一 `bundle_id`、`version`、`resume_build`。這只查詢該 build、更新測試文案並掛群組，不會再次 archive／上傳。重跑群組掛載會跳過已存在的關聯。

### GitHub 在幾秒內失敗，沒有開始製作

先看執行頁面的錯誤註記，而非只看紅色 `Run failed`。若註記提到付款失敗或 spending limit，且工作沒有任何步驟，代表 GitHub 尚未分配製作電腦；沒有執行 App 編譯，也沒有上傳到 Apple。重跑、修改 App 或移動成品到 Releases 都不能解除帳號限制。

在 [GitHub 帳務總覽](https://github.com/settings/billing/summary)核對 Actions 用量、Budgets 的停止使用設定及付款狀態。私人儲存庫有依帳號方案計算的免費製作時間與檔案額度；標準電腦在公開儲存庫的規則不同。不要只憑這則共用錯誤訊息斷定是哪一項超額，也不要把現有檔案大小視為完整帳務用量。[GitHub Actions 帳務說明](https://docs.github.com/en/billing/concepts/product-billing/github-actions)

[GitHub Releases](https://docs.github.com/en/repositories/releasing-projects-on-github/about-releases)的成品存放及下載限制是另一套規則。調高支出上限、更改付款資料或公開儲存庫需由帳號持有人決定；本專案的製作流程不會自動變更這些設定。解除帳號限制後，再執行一次 `operation=upload`；若之前已上傳成功，應依回條使用 `finish-processing`，避免重傳。

## 外部測試：額外需求

確定內部實機測試可用後，在 App Store Connect 建立外部測試群組、選同一 build，依 Apple 介面補齊：

- Beta App Description、Feedback Email、What to Test；本專案已準備描述與測試文字。
- 真實審查聯絡人姓名、電話、信箱。
- 若 App 有登入才需要審查帳密；目前無帳號，可註明不需登入。
- 完整且可公開存取的隱私政策網址；不能填本機路徑、私人 GitHub 文件或未發布草稿。
- 核對加密／export compliance 狀態，再提交 Beta App Review。
- 審查通過後由你選擇邀請對象或開啟有名額上限的公開連結。

[Apple：提供測試資料](https://developer.apple.com/help/app-store-connect/test-a-beta-version/provide-test-information/)。一般使用者應採外部測試，無須加入你的 App Store Connect 團隊。

## 隱私政策與 App Privacy

`ios/release/privacy-policy.html` 已準備與目前實作一致的繁體中文草稿。發布前補入營運者名稱、可聯絡信箱、生效日期；放在你的 HTTPS 網站，再設定 `BUS_PRIVACY_POLICY_URL`。尚未有公開網站／聯絡資料，因此未假裝已部署。

目前使用者定位在裝置上找站牌，公車查詢為固定公開檔案；收藏／近期選擇保存在手機，沒有 App 帳號、廣告、分析 SDK 或自建個資後端。**地圖圖磚請求會向 OpenFreeMap／其服務商揭露地圖範圍和連線資訊**，不能只因 App manifest 的 collected-types 為空就一律填「不收集資料」。發布時仍須按 Apple 定義確認第三方是否留存／使用相關資料，以及是否形成粗略位置等需揭露的資料。

Apple 對僅在裝置處理、暫時服務請求及送出後留存的資料有不同定義；請核對 App 及第三方實際行為再完成 App Privacy。新增 SDK、分析、廣告、帳號或後端時重新檢查 Manifest、政策及隱私問卷。

[Apple：管理 App Privacy](https://developer.apple.com/help/app-store-connect/manage-app-information/manage-app-privacy)、[App 隱私資料定義](https://developer.apple.com/go/?id=info-1)、[OpenFreeMap 隱私政策](https://openfreemap.org/privacy/)。

## 正式 App Store 上線：與 TestFlight 分開

TestFlight 可供 Beta 安裝，不等於已在 App Store 公開上架。正式上架還需：可用的 App 名稱／副標題、說明／關鍵字、類別、年齡分級、Support URL、Privacy Policy URL、App Privacy、內容／版權聲明、售價與發行地區、對應 Apple 顯示尺寸的實際截圖，以及 App Review 聯絡資料。建立 App Store 版本，選擇已處理的同一 build，通過 App Review 後依你選的方式發行。

目前優先台北公車；發布文案必須如實標示 MapLibre／OpenFreeMap，不能宣稱使用 Apple Maps 底圖、車道級定位或特定車牌專屬官方 ETA。第三方資料／地圖的 attribution 已在 App 提供。

## 已備妥的檔案與日常驗證

| 檔案 | 用途 |
| --- | --- |
| `.github/workflows/testflight.yml` | 帳號預檢、註冊 App ID、Release 上傳、處理接續 |
| `.github/workflows/ios.yml` | `main` 提交／PR／手動驗證的核心及發布腳本測試與 Debug／Release 編譯 |
| `ios/Configure-TestFlight.ps1` | Windows 一次設定四個 Secrets 及選用 Variables |
| `ios/release/testflight.json` | 預設 App 身分、版本、語言與內部群組名稱 |
| `ios/release/beta-description.zh-Hant.txt` | Beta App Description |
| `ios/release/what-to-test.zh-Hant.txt` | What to Test |
| `ios/release/review-notes.txt` | 審查員手動搜尋台北站牌／路線操作說明 |
| `ios/release/privacy-policy.html` | 待聯絡資料及部署的政策草稿 |
| `ios/release-check.py` | 不讀 Apple 私鑰的 source／實際 archive 預檢 |
| `ios/apple-connect.rb`、`ios/release/apple_client.rb` | JWT／官方 API、精確 build 查詢與內部群組配置 |

本機可先跑 `python ios/release-check.py`；發布腳本測試使用 `ruby ios/release/apple_client_test.rb`。Mac 可執行 `swift test --package-path ios/TransitCore` 或 `ios/verify-on-mac.sh`。

需要新原生照片時，執行 `iPhone app` workflow，勾選 `capture_preview=true` 並選擇所需畫面；選用影片只在可驗證有效時保留。普通提交不啟動模擬器、不打包預覽 App，TestFlight 上傳也不等待截圖／影片。單純檢查不需在自動檢查之後再手動重跑。
