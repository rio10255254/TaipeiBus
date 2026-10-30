# 到站預估基準測試

用真實錄下的公開資料，量測 App 對每輛公車「約幾分到站」的誤差，作為之後改良（含機器學習模型）的比較基準。只用臺北市、新北市公開資料（不使用 TDX 額度），不含任何使用者資料。

## 三個步驟

1. **錄製**：`.github/workflows/arrival-benchmark.yml` 執行 `collect.py`，每 20 秒記錄全市公車定位（`gps.csv.gz`），每 60 秒記錄 20% 固定抽樣站牌的官方到站預估（`eta.csv.gz`），每天一次存路線、站牌與軌跡（`static/`）。2026-10-30 起同時錄新北市（`collect.py --city ntpc`），放在同一份錄製檔的 `ntpc/` 裡，格式相同；10/14–10/28 只有臺北市。
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

`results/report.md` 是報告（2026 年 10 月的基準結果存於 [baseline-2026-10.md](baseline-2026-10.md)，修正與驗證結果存於 [corrections-2026-10.md](corrections-2026-10.md)，完整兩週的結果存於 [fortnight-2026-10.md](fortnight-2026-10.md)，由 `fortnight.py` 依日別與顯示的分鐘分組），`results/metrics.json` 是完整數字，`results/replay/*/predictions.csv.gz` 保留每筆預估與實際到站，可作為之後訓練模型的資料。

- `--city ntpc`：回放各錄製檔的 `ntpc/`（新北市），路線會帶上新北的來源代號，所以套用 `regions.json` 裡新北的車速。
- `--tuning FILE`：用一份候選的 `runtime/tuning.json` 回放，和不加時的結果比較，就能在發布前知道參數改了之後誤差會變多少。

在 GitHub 上可手動執行 `Arrival replay` workflow，它會從 release 下載錄製檔、回放、評分，並把報告放在執行摘要。

## 修正係數

`fit_corrections.py` 從回放結果算出 App 的到站修正（`ForecastTuning`）：

- **每小時倍數**（平日與假日各 24 個）：官方分時段車程與單車車速估算的時間，在尖峰時段明顯偏短。依其他車輛剛通過紀錄估算的時間幾乎沒有偏差，所以不修正。
- **參考範圍倍數**：讓畫面上的「參考範圍」約有 80% 的機會涵蓋實際到站時間。

```sh
python3 tools/arrival-benchmark/fit_corrections.py results/replay/* --test-days 10-21 10-22   # 留兩天驗證
python3 tools/arrival-benchmark/fit_corrections.py results/replay/* --write-swift               # 寫成 App 內建值
python3 tools/arrival-benchmark/fit_corrections.py results/replay/* --base runtime/tuning.json --write-tuning runtime/tuning.json
```

回放時已在使用的倍數要用 `--base` 指定，新的倍數會乘在上面，重複「回放 → 計算」只會逐步收斂，不會重複修正。

## 解讀注意

- 誤差 = 實際 − 預估。負值代表公車比顯示的早到，乘客可能錯過，是最需要避免的情況。
- 「實際到站」也是由 GPS 推得：回報間隔越長，時間越不精確（輸出保留 `arrive_bracket_s`）。沒有 GPS 的車無法得到實際時間，不列入計算。
- 官方預估不指定車牌，評估時對照同路線下一輛實際通過的車。若有車沒回報 GPS，「下一班」會被誤認為更晚的一班，官方誤差可能被高估。兩組數字的對象不同，不能當成同一題的直接比較。
- 錄製只有兩週，颱風、連假等特殊日子的代表性有限。
