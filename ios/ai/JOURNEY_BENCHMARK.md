# 自然語言行程真機基準

狀態：**尚未執行真機推論，沒有實測準確率**。本次工作環境為 Linux，未連線支援 Apple Intelligence 的 iPhone。核心測試、模擬 UI fixture 或 Simulator 建置都不能算作這份基準的模型結果。

`journey-corpus.json` 收錄 72 句人工整理的日常說法，不是擷取使用者私人對話。包含「快一點」、臺／台、北車、回家、去公司、從公司到其他地點、明天 9 點前、跨午夜、過去時間、指定出發時間、多目的地、沒有儲存地點與重複的家／公司。正常情境使用固定的虛構常用行程；「家」位於古亭、「公司」位於市政府，只是測試資料。地點搜尋仍呼叫真正的 `PlaceSearch`／Apple 地圖，未以假資料替代模型或搜尋結果。

## 在 iPhone 上直接執行（不需要 Mac）

測試版（Debug、Xcode 安裝或 TestFlight）的「資訊與設定」最下方有「AI 測試」。App Store 版不會顯示：入口只在 `AppTransaction` 為 sandbox／xcode 環境時出現。

1. 在已開啟 Apple Intelligence 的 iPhone 安裝 TestFlight 版，打開「資訊與設定 → AI 測試 → 開始測試」。
2. 72 句會逐句在手機上的模型執行，期間保持 App 在前景（測試中不會自動鎖定螢幕）。使用的是固定的虛構常用行程，不讀取或修改自己的常用行程；地點搜尋仍連 Apple 地圖。
3. 完成（或按「停止」）後用「分享測試報告」把 JSON 存到檔案或傳到電腦，再執行下方的 `journey-report.py`。中途停止的報告會標示為不完整。

測試頁與下方的 XCTest 共用 `ios/TaipeiBus/JourneyBenchmark.swift`，產生相同格式的報告；App 內的報告以版本號與 build 號、語料 SHA-256 標示來源。

## 在 iPhone 執行（Mac + Xcode）

1. 使用 Xcode 26.3 或更新版本，連接已啟用 Apple Intelligence 且繁體中文模型可用的 iPhone。開啟 Developer Mode，確認開發簽署、App 與測試 bundle 的簽署權限；本流程不發布或上傳 TestFlight。
2. 安裝 `xcodeproj` Ruby gem，執行 `ruby ios/ai/setup.rb`。會生成獨立的 `TaipeiBusAIBenchmarkTests` scheme、加入語料資源，並寫出忽略版本控制的 `journey-build.json`（commit、dirty 狀態、來源與語料 SHA-256）。修改來源後須重新執行 setup。
3. 在 Xcode 選擇該 scheme 與實體 iPhone，設定 Development Team 後執行測試。或使用以下命令，替換實際裝置 ID 與 Team ID：

```sh
xcodebuild -project ios/TaipeiBus.xcodeproj -scheme TaipeiBusAIBenchmarkTests \
  -configuration Debug -destination 'platform=iOS,id=DEVICE_UDID' \
  -resultBundlePath /tmp/JourneyDevice.xcresult \
  -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=YES DEVELOPMENT_TEAM=TEAM_ID test
xcrun xcresulttool export attachments --path /tmp/JourneyDevice.xcresult \
  --output-path /tmp/journey-device-attachments
```

測試要求真機，模型不可用時明確 skip，不產生準確率。請勿加入 `--test-ai-review`；那是另一個 scheme 使用的 UI fixture。每句建立新的 session；有追問的案例在原 session 選擇語料指定的語意選項，再記錄後續輸出。找不到合適選項時記為錯誤，保留原始選項供人工檢查，不任選第一項。每句完成即保存 JSON attachment，避免整批中斷時遺失已完成資料。測試會暫時選擇繁體中文，結束後還原原有語言設定，不改動使用者常用行程。

## 報表與判分

從附件清單找出 `journey-device-report` JSON（實際匯出檔名由 Xcode 決定），執行：

```sh
python3 ios/ai/journey-report.py /tmp/journey-device-attachments/REPORT.json \
  --csv /tmp/journey-device-results.csv
```

每句分別記錄目的地、出發地、偏好、時間的正確與否，以及四欄正確率；整批另計各欄平均與四欄皆正確的句子比例。錯誤／拒答仍納入分母，不只統計成功句子。是否適當追問、是否呼叫常用行程工具、選項接續後的四欄得分分開保留。這是測量基準，XCTest 完成不等於準確率達標。

地名採預先列好的可接受名稱，判分時統一臺／台、空白與字寬；App 本身不做逐字拒絕。`time: none` 要求沒有日期與殘留時間條件；`confirm` 或空的地名選項陣列要求該欄標示需確認。模型輸出的欄位、信心、問題／選項、真實候選名稱／地址、工具呼叫、耗時、錯誤，以及固定參考時間都可由語料與報表核對。

請人工檢查錯誤句及 Apple 地圖的名稱變化，區分模型理解錯誤、搜尋資料差異與標註錯誤。若修訂可接受答案，保留原報表與語料版本，不能回頭覆寫舊得分。基準目前沒有聲稱可接受的準確率門檻；累積至少一次完整真機結果後，再依錯誤類型調整 `OnDeviceJourneyAssistant.promptVersion` 與提示。Apple 未提供的模型版本不得填寫猜測值；報表記錄 iPhone 型號、OS build、語言、提示版本與來源指紋。

## 其他回歸驗證

- `AssistantSafetyTests`：欄位保留、無效日期、選項範圍與輸入限制。
- `JourneyAssistantToolTests`：只回傳工具取得的候選、已存起終點與偏好、搜尋失敗／取消及次數上限。裝置端模型的上下文約 4,096 tokens，工具輸出因此受限：`listSavedJourneys` 依關鍵字只回傳最相關的 3 筆，且不含地址（50 筆常用行程時「回家」仍取得正確的一筆，輸出在 600 bytes 內）；`searchPlaces` 每次對話最多 3 次、每次 3 筆，地址截為 20 字。超過上下文時以新的 session 重試一次，再失敗就回到手動填寫。
- `AIUITests`：不可用時入口隱藏；以明確的 Debug fixture 檢查點選後不需重打、選地點後仍需明確確認、更換地點取消確認。這不是模型準確率測試。
- CI 裝置 Release 建置後以 Mach-O load commands 確認 FoundationModels 使用 `LC_LOAD_WEAK_DYLIB`。
