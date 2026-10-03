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
