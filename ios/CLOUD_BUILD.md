# Windows 上建置 iPhone App

## 原生編譯與模擬器

GitHub Actions 的 **iPhone app** workflow 使用 macOS 15、Xcode 26.3。推送 `ios/` 或 workflow 變更後會自動執行；也可在 Actions → iPhone app → Run workflow 手動執行，保留 `sign_ipa = false`。

流程先執行 `TransitCore` 的 Swift 測試，再編譯 SwiftUI／MapLibre Native／Metal App，啟動 iPhone 17 模擬器、等待公開即時資料載入並截圖。完成後下載 `iPhone17-simulator` artifact，內含 App、截圖與 build log。模擬器產物只供 macOS 模擬器使用。

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

`debugging` 適用開發測試；`app-store-connect` 只匯出供上傳的 IPA，**目前 workflow 不會自動上傳 TestFlight 或 App Store**。要用 TestFlight，還需 App Store Connect 的 App 記錄、上傳、處理與測試人員設定。

workflow 以 API key 交給 Xcode 自動處理 provisioning。若 Team 政策不允許雲端管理憑證、API key 權限不足或簽名失敗，需依 Xcode 錯誤改用自己的憑證及描述檔；不把未簽名產物描述為可安裝版本。

## Mac 本機備用方式

在 Xcode 26 開啟 `TaipeiBus.xcodeproj`，選擇 Signing & Capabilities、自己的 Team 和 Bundle ID，選接上的 iPhone 17 執行。`verify-on-mac.sh` 可執行核心測試與未簽名模擬器建置。
