# 遠端更新操作手冊

這個資料夾裡的檔案會被所有已安裝的 App 直接下載，**改完存檔就生效，不用改版、不用送審**。
用手機或電腦的 GitHub 都可以改：打開檔案 → 右上角鉛筆 ✏️ → 修改 → **Commit changes**（直接存到 `main`）。

存檔後 GitHub 會自動檢查（Actions 裡的「Quick update content」）。
- ✅ 綠色：內容正確，手機會照下表的時間更新。
- ❌ 紅色：內容有錯，GitHub 會寄信通知你。**手機會忽略有錯的檔案、繼續用上一份正確內容**，所以不會把 App 弄壞；照錯誤訊息修正後再存一次即可。

| 檔案 | 用途 | 手機多久會套用 |
|---|---|---|
| `app-update.json` | 強制更新／建議更新 | App 打開或回到前景時（最多 30 分鐘檢查一次） |
| `tuning.json` | 到站時間與車程的校正參數 | 同上；轉乘規劃的預設車速在下次開啟 App 時套用 |
| `settings.json` | 文字、顏色、搜尋別名、步行距離、更新頻率等 | 約 5–10 分鐘 |

GitHub 連不上時，手機會改從 jsDelivr CDN 讀同一份檔案（最多晚 12 小時，存檔時會自動清除 CDN 快取）。

---

## 1. 強制更新 `app-update.json`

```json
{
  "schemaVersion": 1,
  "minimumVersion": "1.7.0",
  "recommendedVersion": "1.7.1",
  "message": "這個版本修正了到站時間，請更新後繼續使用。",
  "englishMessage": "Please update to keep using the app."
}
```

- `minimumVersion`：低於這個版本的 App **無法使用**，只會看到「前往 App Store」。
- `recommendedVersion`（可省略）：低於這個版本會跳出一次「有新版本」提醒，可以按「稍後」。
- `message` / `englishMessage`（可省略）：自訂說明文字，最多 300 字。
- **安全機制**：只有 App Store **已經上架**的版本號才會生效。新版還在審核時先寫好也沒關係，上架後才會開始要求更新；打錯成不存在的版本號也不會把人鎖住。
- 取消強制更新：把 `minimumVersion` 改回 `"1.0.0"`。
- ⚠️ 只對內建這個功能的版本有效（1.2.0 等舊版看不懂這個檔案）。

## 2. 到站時間校正 `tuning.json`

**只寫要改的項目**，沒寫的都用 App 內建值。例如把一般車速調快、範圍調窄：

```json
{
  "schemaVersion": 1,
  "note": "2026-10-29 依兩週實測校正",
  "typicalSpeed": 5.2,
  "officialProfileSpread": 0.12
}
```

| 名稱 | 意思 | 內建值 | 可設定範圍 |
|---|---|---|---|
| `typicalSpeed` | 沒有資料時假設的公車車速（公尺／秒） | 4.5 | 2–10 |
| `stopSeconds` | 沒有資料時每站加上的停靠秒數 | 20 | 0–90 |
| `officialProfileWeight` | 官方車程相當於幾輛實際車輛的紀錄（越大越相信官方） | 2 | 0–10 |
| `officialSegmentMargin` | 官方車程每一段的誤差比例（下一班車的到站範圍） | 0.25 | 0.05–0.8 |
| `minimumUncertainty` | 到站範圍至少佔剩餘時間的比例 | 0.12 | 0.03–0.5 |
| `limitedUncertainty` | 資料不足時到站範圍至少佔剩餘時間的比例 | 0.3 | 0.05–0.8 |
| `railSpread` | 捷運車程的誤差比例 | 0.05 | 0.01–0.5 |
| `stationHistorySpread` | 依近期站間紀錄估算時的誤差比例 | 0.10 | 0.02–0.6 |
| `officialProfileSpread` | 依官方分時段車程估算時的誤差比例 | 0.15 | 0.02–0.6 |
| `recentTrafficSpread` | 依目前路線車流估算時的誤差比例 | 0.15 | 0.02–0.6 |
| `typicalSpread` | 只能用一般車速估算時的誤差比例 | 0.25 | 0.02–0.8 |

「誤差比例」0.15 代表 20 分鐘的車程顯示為大約 ±3 分鐘的範圍。
**名稱打錯或數字超出範圍，整份檔案都會被忽略**（檢查會變紅色並寄信），手機繼續使用上一份正確的值。
恢復內建值：刪掉那一行，或整份改回只有 `"schemaVersion": 1`。

## 3. 一般設定 `settings.json`

直接改要改的值即可；**`revision` 不用自己加**，存檔後 GitHub 會自動加 1（手機只接受 revision 比較大的內容）。
各欄位的允許範圍寫在 `settings.schema.json`。常用項目：

- `refresh.vehicleSeconds`：一般車輛位置更新間隔（秒）
- `refresh.trackingSeconds`：跟車／規劃路線時的更新間隔（5–10 秒）
- `planning.firstWalkMeters`、`planning.expandedWalkMeters`：轉乘規劃的步行距離
- `search.aliases`：搜尋別名（例如「內湖捷運站」→「捷運內湖站」）
- `copy`：替換 App 上的文字，`{"原文字": "新文字"}`
- `quickDestinations`：首頁快捷目的地

不想手動改檔案時，也可以到 Actions →「Quick update content」→ **Run workflow**，
`operation` 選 `publish` 並貼上只含要修改部分的 JSON；要退回舊內容選 `rollback` 並填舊的 revision。

## 改壞了怎麼辦

1. 手機一律忽略有錯的檔案，所以 App 不會因此壞掉。
2. 在 GitHub 打開檔案 → **History** → 找到上一個版本 → 複製內容貼回去存檔。
3. `settings.json` 也可以用上面的 `rollback`。
