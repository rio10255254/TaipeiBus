# AI 分支開發

`ai` 用於隔離開發與驗證。完成下列驗收前維持獨立分支；此分支的 CI 不簽署、不上傳 TestFlight、不合併或發布。

## 功能與資料邊界

- **自然語言行程**：在目的地搜尋開啟「用一句話規劃」。Foundation Models 盡量理解目的地、出發地、偏好與抵達期限，逐欄標示「確定／需確認」，不以地名逐字比對、時間關鍵字或歧義拒絕整句。模型可呼叫既有 PlaceSearch 取得前三個真實名稱／地址，以及常用行程工具解析回家／公司；有歧義時在同一 session 提供最多三個選項，點選後接續，也可直接修改條件。使用者選取地圖搜尋或常用行程中的實際地點並明確確認所有條件後才規劃；模型不能輸出座標、路線、班次或預測到站時間。無效日期保留說明並標示需確認。提示只保留於當次對話記憶體、不寫入持久儲存；地點搜尋關鍵字會交給 Apple 地圖。既有 Pro 路線偏好權限繼續適用。
- **未來行程參考**：沿用 `MultimodalPlanner`、官方班表／班距及既有車程資料，透過既有步行驗證與 `TripRanking` 比較。最多查詢 90 天內、同一台北曆日的行程，以分鐘為單位向前搜尋最多六小時，預留至少十分鐘。只驗證有限候選，不能保證找出所有方案；缺少服務時間或步行資料時不顯示出發時刻。顯示的是推估範圍，出發當天仍須重新規劃；不使用今日車輛位置或未來 YouBike 庫存。
- **車牌掃描**：在搭乘車牌選擇器開啟相機，使用 VisionKit 的裝置端文字辨識。僅比對能服務該行程、方向相符、位置可靠且 300 公尺內的近期車輛；不猜測 O/0，不自動確認上車。使用者核對車牌後才選車；權限拒絕或硬體不支援時保留手動選擇。影像不保存、不上傳。
- **通勤提示**：設定中自行開啟，僅記錄已儲存行程 ID 與實際開始時間。至少三個不同日期、相近時段才推薦；最多保留 42 天、240 筆，使用時清理。關閉或清除即可刪除紀錄，不刪除已儲存行程。
- **交通公告**：資訊與設定內開啟公運處新聞稿、搜尋與全文。模型僅選取原文段落，無權輸出改寫的日期、站名或路線；完整內容、發布時間與官網附件入口持續保留。公告不會直接修改路線或到站時間。更新失敗明示；沒有公告不代表沒有交通異動。

## 官方依據

- [Foundation Models 語言支援與執行期檢查](https://developer.apple.com/documentation/foundationmodels/supporting-languages-and-locales-with-foundation-models)
- [Apple Intelligence 裝置與語言條件](https://support.apple.com/en-us/121115)：目前列出繁體中文，但不同 OS／模型版本的支援有差異。程式使用 `SystemLanguageModel.availability` 與 `supportsLocale`，不以機型名稱推斷可用性。
- [公運處新聞稿](https://pto.gov.taipei/News.aspx?n=D065CCB1467288C8&sms=72544237BBE4C5F6) 官網標示的 [RSS](https://pto.gov.taipei/OpenData.aspx?SN=EB6F7CBE2BCF295F)。2026-10-22 已下載實際 feed，使用正式 parser 成功解析 50 則公告。以官方 HTTPS 網域限制來源與轉址，拒絕 DTD／外部實體及過大的 XML，HTML 僅轉成純文字。

App 最低版本仍為 iOS 17。Foundation Models 入口要求 iOS 26 與裝置當下可用的 Apple Intelligence；相機掃描另以 VisionKit 的硬體與權限狀態判斷。模型不可用時隱藏自然語言行程入口，仍可手動搜尋、選車與閱讀公告。App 的 Debug／Release 均明確 weak link FoundationModels，CI 另檢查建置產物的 Mach-O load command。

## 驗證

`.github/workflows/ai.yml` 在 `ai` 的原生程式碼變更時執行：

1. Xcode 26.3／macOS 15 的完整 TransitCore 測試、語系與發行中繼資料檢查。
2. iPhone Simulator 原生編譯、啟動與截圖。
3. 本機紀錄的同意／刪除測試、模型不可用與相機不可用的實際 UI 操作。
4. 未簽署的 iPhone Release 建置與 FoundationModels weak-link 檢查。

日誌、截圖及 XCTest 結果會附在 Actions artifact，保留十四天。`ios/ai/setup.rb` 只在測試時建立兩個測試 target；不用修改正式專案來保存測試 target。

UI 測試以 Debug 專用的 `--test-ai-ui` 使用內建官方路線目錄及既有、明示非即時的上車情境；建立候選行程時固定服務時間，車輛回報則保持當次測試的時間。搜尋測試實際點擊首頁入口。另以 `--test-ai-review` 的明確 Debug fixture 驗證選項接續與使用者確認守門；不執行模型推論，也不列入模型準確率。這些退回操作測試不依賴首次公車資料下載，也不代表真實模型或相機辨識已驗收。

Linux 已執行新增的 20 項核心測試：參數與日期驗證、車牌比對、通勤統計、未來服務時段與固定班次、RSS 解析及原文摘錄。這是排除不相干 CoreGraphics 地圖標籤檔案後、原始碼逐位元複製的獨立驗證包；不能取代完整原生測試。執行期模擬器及裝置驗證以對應提交的 Actions 結果為準。

## 合併發布前尚須驗收

- 最終提交的完整 CI 必須通過；不能沿用較早提交的成功結果。
- 支援 Apple Intelligence 的真機：繁體中文／英文、尚未下載模型、關閉模型、模糊日期、跨午夜、取消、錯誤與重試；確認真實模型欄位正確、需確認提示與追問合理，未將使用者期限改成模型預測。
- 真機相機：拒絕／撤回權限、逆光與模糊車牌、同路線多車、方向不同、資料過期、切換背景與確認前資料變更。
- 實際通勤路線的未來規劃、班表更新與公告附件人工核對；確認提示範圍符合資料品質。
- 大字體、VoiceOver、繁體中文與英文的四項完整操作，以及隱私政策／商店申報檢查。

GitHub 的 iOS Simulator 可以執行原生 App 與 UI 測試；模型推論與真實相機畫面仍須以實際支援能力及真機結果驗證。上述真機項目尚未完成，不能把分支視為可直接發布。

## 自然語言行程理解基準

已建立 72 句日常語料及獨立 `TaipeiBusAIBenchmarkTests` 真機 scheme。涵蓋「快一點」「臺／台」「北車」「回家」「明天 9 點前」「從公司到…」、多義常用行程與跨午夜。每句保存四個欄位得分、原始條件、問題／選項、工具呼叫、接續後輸出、耗時及錯誤，附 OS、機型、提示版本及來源指紋；錯誤列不排除於分母。執行與 CSV 匯出方式見 [真機基準說明](ios/ai/JOURNEY_BENCHMARK.md)。

這次環境沒有 Xcode 或連線真機，**72 句尚未實測，不能聲稱已有模型準確率**。本次可執行的 11 項 AssistantSafetyTests 使用逐位元複製的核心來源於 Linux 通過；Swift 語法解析、語料結構、語系與離線發行檢查通過。完整 Apple SDK 編譯、新增原生工具／UI 測試與 Mach-O 檢查仍須在 Xcode 執行。

## 延伸研究

語音輸出、多回合對話與用說的操作 App 的研究與路線圖見 [VOICE_ASSISTANT_RESEARCH.md](VOICE_ASSISTANT_RESEARCH.md)。
