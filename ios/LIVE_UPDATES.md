# 搜尋與外觀內容更新

先安裝 0.4.2 或更新版本；0.4.1 尚未支援下載設定。

內容來自本專案 main 的 runtime/settings.json。App 開啟時先讀取已驗證的手機快取，再檢查更新，前景預設每五分鐘檢查一次。資料刷新按鈕也會檢查內容。GitHub 的快取可能增加短暫等待，不能保證每次提交立即出現在所有手機。

## 已接上的項目

| 區塊 | 可更新內容 |
| --- | --- |
| copy | 現有介面的固定按鈕、提示與標籤文字；以原文字為鍵 |
| search.aliases | 地點、站牌與路線別名，以及送給 Apple 地圖的正式查詢名稱 |
| search | 搜尋輸入等待時間與結果數量 |
| appearance | 主色、步行路線、水面、公園與建物顏色，現有文字大小、部分間距與圓角比例，以及實色表面 |
| planning | 初次與擴大的上車接駁範圍、純步行範圍、少走路或少等車的偏好、轉乘時間權重 |
| refresh | 現有公車、路線與設定的更新間隔 |
| display | 附近站牌、目的地捷徑、站牌與路線快捷入口的顯示 |
| quickDestinations | 既有目的地捷徑的地名 |

設定只能調整已包含的功能，不能下載程式、新增畫面種類、要求新權限或上傳位置。定位精度與新鮮度、公車訊號可靠性、已通過車輛排除，以及官方到站時間與車牌分離等規則固定在 App 內。開始的行程不會因內容更新而重新選路。

## 一般更新

修改 runtime/settings.json，增加 revision，再執行：

    python ios/live-update.py validate runtime/settings.json

驗證通過後提交該檔案至 main。這只執行內容檢查，不會製作新的 iPhone App。欄位與範圍在 runtime/settings.schema.json；省略選用欄位時採用 App 內預設值。

也可執行 GitHub 的 Quick update content，選 operation=publish，document 填完整內容或局部修改，例如：

    {"copy":{"搜尋目的地":"想去哪裡"},"appearance":{"accentColor":"#005AC6"}}

此入口會先驗證、自動增加版次，再更新同一個檔案。只允許有權限的維護者在 main 執行，普通拉取請求只有讀取權限。

## 別名

同一組必須指同一個地點，不混合場館與捷運站或不同分院：

    {"names":["內湖月台","內湖捷運站","Neihu Station"],"queries":["捷運內湖站"]}

加入 search.aliases 陣列。這不會生成虛構站牌，也不會把實體站牌的不同方向合併。

## 回復與斷線

Quick update content 選 operation=rollback，restore_revision 填舊版次。流程取回舊內容，但使用新的、更大的 revision，手機才能收到回復。

斷線、錯誤格式、過大檔案、超出範圍的數字或需要較新 App 的內容，均不取代最後可用設定。重新開啟也保留手機上最後驗證成功的內容，沒有快取則採 App 內預設值。內容檔不含金鑰或私人資料。

## 驗證

live-settings 原生預覽先拍版次 1，保持同一個 App 程序開啟，再從真正的 GitHub 位址接收版次 2，核對文字、配色和新增別名並拍照。前後的 App 版本與程序編號須一致；完成後恢復正式外觀。
