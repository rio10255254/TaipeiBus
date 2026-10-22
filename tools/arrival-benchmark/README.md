# 到站預估基準測試

用真實錄下的公開資料，量測 App 對每輛公車「約幾分到站」的誤差，作為之後改良（含機器學習模型）的比較基準。只用臺北市公開資料，不含任何使用者資料。

## 三個步驟

1. **錄製**：`.github/workflows/arrival-benchmark.yml` 執行 `collect.py`，每 20 秒記錄全市公車定位（`gps.csv.gz`），每 60 秒記錄 20% 固定抽樣站牌的官方到站預估（`eta.csv.gz`），每天一次存路線、站牌與軌跡（`static/`）。
2. **保存**：workflow artifact 90 天後會被刪除。`.github/workflows/arrival-benchmark-archive.yml` 每天把尚未保存的錄製檔複製到 `arrival-benchmark-data` release，release 不會過期。
3. **回放與評分**：
   - `replay/` 是一個 Swift 執行檔，直接使用 App 的 `TransitCore`（`FeedDecoder`、`VehicleTracker`、`VehicleArrivalForecast`），依錄製順序逐次重現 App 收到的資料，所以量到的就是 App 實際顯示給乘客的結果，不是另外改寫的近似版本。
   - 每分鐘對每輛車、前方 40 站內的抽樣站牌各做一次預估，並套用 App 的顯示規則（`display`，含與官方預估不一致時隱藏）。
   - 實際到站時間：同一輛車的 GPS 軌跡對到路線後，進入站牌前 30 公尺的時刻，以相鄰兩筆回報內插（兩筆間隔不超過 120 秒）。
   - `score.py` 計算誤差，依剩餘時間、推估依據與時段分組，並另外評估官方 `EstimateTime` 對「下一班」的誤差。

## 在本機執行

需要 Swift 5.9 以上（macOS 或 Linux）與 Python 3。

```sh
swift build -c release --package-path tools/arrival-benchmark/replay
curl -L -o official-times.json https://github.com/rio10255254/TaipeiBus/releases/download/travel-time-data/official-times.json
# recordings/ 底下每個資料夾是一份解壓縮後的錄製檔
python3 tools/arrival-benchmark/replay_all.py recordings --official official-times.json --out results
```

`results/report.md` 是報告，`results/metrics.json` 是完整數字，`results/replay/*/predictions.csv.gz` 保留每筆預估與實際到站，可作為之後訓練模型的資料。

在 GitHub 上可手動執行 `Arrival replay` workflow，它會從 release 下載錄製檔、回放、評分，並把報告放在執行摘要。

## 解讀注意

- 誤差 = 實際 − 預估。負值代表公車比顯示的早到，乘客可能錯過，是最需要避免的情況。
- 「實際到站」也是由 GPS 推得：回報間隔越長，時間越不精確（輸出保留 `arrive_bracket_s`）。沒有 GPS 的車無法得到實際時間，不列入計算。
- 官方預估不指定車牌，評估時對照同路線下一輛實際通過的車。若有車沒回報 GPS，「下一班」會被誤認為更晚的一班，官方誤差可能被高估。兩組數字的對象不同，不能當成同一題的直接比較。
- 錄製只有兩週，颱風、連假等特殊日子的代表性有限。
