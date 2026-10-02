# Windows 上建置與推送 TestFlight

## 原生編譯與模擬器

GitHub Actions 的 **iPhone app** workflow 使用 macOS 15、Xcode 26.3。推送 `ios/` 或 workflow 變更後會自動執行；也可在 Actions → iPhone app → Run workflow 手動執行，保留 `sign_ipa = false`。

流程先執行 `TransitCore` 的 Swift 測試，再編譯 SwiftUI／MapLibre Native／Metal 的模擬器 App 與 iPhone Release App，啟動 iPhone 17 模擬器、等待公開即時資料載入並截圖。完成後下載 `iPhone17-simulator` artifact，內含模擬器 App、截圖、32 秒跟車影片與 Debug／Release build log。影片使用真實公車回報；附近站牌截圖的使用者位置為模擬器設定。此產物只供 macOS 模擬器使用。

## 沿用 Apple Developer 帳號

安裝到實機需要有效 Apple Developer Program 資格、Team ID、App 的 Bundle ID，以及對應的簽名憑證與 provisioning profile。Apple ID 本身與既有 App 不代表目前資格仍有效。

沿用既有 Bundle ID 時，請確認它屬於自己的 Team，並接受同 Bundle ID 的測試版會替代手機上原有 App；要並存請註冊新的 Bundle ID。Team ID 可在 [Apple Developer 會員資料](https://developer.apple.com/account/#/membership)查看；App ID、憑證與測試裝置在 [Certificates, Identifiers & Profiles](https://developer.apple.com/account/resources/identifiers/list) 管理。

在 [App Store Connect](https://appstoreconnect.apple.com/) 的 Users and Access → Integrations 準備 Team API key，確認該 key 及角色可以存取憑證、識別碼與描述檔。私鑰 `.p8` 只下載一次，請自行妥善保存。

把以下資料放入私人儲存庫的 **Settings → Secrets and variables → Actions → New repository secret**：

| Secret | 內容 |
| --- | --- |
| `APPLE_TEAM_ID` | Apple Developer Team ID |
| `ASC_KEY_ID` | App Store Connect API key 的 Key ID |
| `ASC_ISSUER_ID` | Team API key 的 Issuer ID |
| `ASC_PRIVATE_KEY` | `.p8` 完整內容，包含開頭、結尾及換行 |

私鑰不用貼進聊天，也不提交到 Git。workflow 只在簽名工作期間寫入暫存檔，結束時移除。

## 取得可安裝的 IPA

1. 若使用 `release-testing`，先在 Apple Developer 登記這支 iPhone 17 的 UDID。可在 Windows 使用 [Apple Devices](https://support.apple.com/guide/devices-windows/welcome/windows) 連接 iPhone 取得裝置資料。
2. 在 Actions → iPhone app → Run workflow 勾選 `sign_ipa`，填入真實 Bundle ID，選擇 `release-testing`。
3. 模擬器建置成功後才進行 archive 及自動簽名。成功後下載 `TaipeiBus-signed-IPA` artifact。
4. 可使用受信任的裝置管理工具安裝 Ad Hoc IPA 到已登記的 iPhone。安裝工具及實機流程需另外驗證。

`debugging` 適用開發測試；未勾選 `publish_testflight` 時，`app-store-connect` 只匯出供上傳的 IPA。直接上傳方式見下一節。

workflow 以 API key 交給 Xcode 自動處理 provisioning。若 Team 政策不允許雲端管理憑證、API key 權限不足或簽名失敗，需依 Xcode 錯誤改用自己的憑證及描述檔；不把未簽名產物描述為可安裝版本。

## 直接推送 TestFlight

本專案的手機安裝流程優先使用 TestFlight，不需要登記 iPhone UDID。

1. 在 Apple Developer 註冊這個 App 的 Bundle ID，例如 `com.rio10255254.TaipeiBus`。在 App Store Connect → My Apps 建立對應 App 記錄；如沿用現有記錄，使用其原本 Bundle ID。
2. 設定上表四個 GitHub Secrets。Team API key 需要上傳 App 與自動簽名所需的角色及權限；可參考 Apple 的[雲端簽名說明](https://developer.apple.com/videos/play/wwdc2021/10204/)。
3. Actions → iPhone app → Run workflow 勾選 `publish_testflight`，填入該 Bundle ID；不必勾選 `sign_ipa`。流程會先完成模擬器測試，再檢查 App 記錄、archive、自動簽名，並由 Xcode 直接上傳 App Store Connect。
4. Xcode 自動管理上傳的 build number。workflow 最多查詢 20 分鐘確認 Apple 處理結果；若 Apple 仍在處理，Actions 摘要會清楚標示尚未完成。
5. 在 App Store Connect 的 TestFlight 加入自己的內部測試群組，在 iPhone 的 TestFlight 安裝。外部測試可能需要 Apple Beta App Review；本流程不提交 App Store 正式上架，也不自動邀請其他測試者。

`publish_testflight` 會覆蓋匯出選項，使用 `app-store-connect` 與 `destination = upload`。自動上傳僅在手動觸發這個選項時執行；一般推送程式碼只編譯模擬器及保存截圖。

## Mac 本機備用方式

在 Xcode 26 開啟 `TaipeiBus.xcodeproj`，選擇 Signing & Capabilities、自己的 Team 和 Bundle ID，選接上的 iPhone 17 執行。`verify-on-mac.sh` 可執行核心測試與未簽名模擬器建置。
