# 語音助理研究：從「用一句話規劃」到能說話、能對話、能操作 App

研究日期：2026-10-25。基準為 `ai` 分支 `634d037`。本文件只做研究與設計，不含程式變更；所有數字、價格與 API 狀態以當日查得的官方頁面為準，未能查證的標為「未證實」，列在最後的待驗證清單。

標記說明：**【已查證】** 直接讀過官方或一手頁面；**【推論】** 來自二手來源或由官方資料推得；**【未證實】** 找不到可靠來源，必須實機或另行確認。

---

## 0. 結論先講

1. **主架構建議「裝置端聽與說 + 可替換的大腦 + App 自己的工具」的串接式（cascade）設計**，不以雲端端到端語音模型（speech-to-speech）為主線。理由是本 App 最重要的價值是「數字正確」：到站時間、剩餘站數、YouBike 車位都必須來自官方資料與 App 自己的估計。串接式可以讓 **App 產生要說出口的句子**，模型只負責理解與挑選工具；端到端語音模型則是模型自己開口，無法逐字保證不編造數字。
2. **大腦依裝置分層**：iOS 27 + Apple Intelligence 用 Private Cloud Compute（PCC，32K context、可推理、符合資格者免雲端費用）；iOS 26 用裝置端 Foundation Models（4K context，只放 3–5 個工具）；其餘裝置或使用者同意時，沿用現有 Supabase → Groq（gpt-oss）路徑並加上工具呼叫。iOS 27 的 `LanguageModel` 協定可讓三者共用同一套 `Tool` 程式碼。
3. **先做半雙工（聽→想→說→自動再聽），再做可插話的全雙工**。全雙工需要改用 `.playAndRecord` + 回音消除（voice processing），並重新處理與下車鈴聲、動態島、背景定位的音訊共存，風險較高。
4. **最便宜、最快見效的一步是 App Intents 對話回覆**：新增「307 還要多久」「我的下一站」這類只讀 Intent，以 `IntentDialog` 讓 Siri 直接說出 App 算好的答案，不必開 App。繁中目前沒有 Siri AI（新版 Siri），但經典 App Shortcuts 可用。
5. **雲端端到端語音（Gemini Live、OpenAI Realtime）列為受控實驗**，用 Supabase 只發短效 token、手機直連，並以「所有說出的數字必須出現在工具結果中」的自動檢查把關。

---

## 1. 目標與不做的事

| 能力 | 定義 | 驗收方向 |
| --- | --- | --- |
| 發出聲音 | 以自然的台灣華語說出答案與提示；站名、路線名（307、紅25、南京幹線、內科通勤專車2）念對 | 專有名詞發音正確率、使用者可理解度 |
| 自然對話 | 多回合；可追問、可修改（「改騎車」「晚一點」「那回程呢」）；可插話打斷；能回答問題而不只是規劃 | 任務完成率、回合數、插話誤判率 |
| 操縱 App | 用說的完成查詢、規劃、選方案、開始導航、已上車／已下車、跟車、收藏、提醒開關 | 每個工具的成功率；有副作用的動作 100% 經確認 |

**不做（至少第一版）**：

- 不做背景常駐收音或自訂喚醒詞。第三方 App 不能在背景持續聽；要做必須開 `audio` 背景模式，與 App 審查 2.5.4 衝突的風險高（App 已有背景定位審查紀錄）。入口改用按鈕、Siri、動作按鈕／控制中心。
- 不讓任何模型產生到站時間、路線、座標、車牌或班次。這是 `ai` 分支已建立的邊界（`AssistantIntent.swift` 開頭註解、`AssistantSafetyTests`），語音版必須完整保留。
- 不在導航中鼓勵看手機或長篇對話。語音回答以一句話為原則（審查 1.4.5 安全面）。

---

## 2. `ai` 分支現況盤點

| 元件 | 位置 | 現況 |
| --- | --- | --- |
| 語音輸入 | `ios/TaipeiBus/AssistantInput.swift` `SpeechInput` | `SFSpeechRecognizer` zh-TW／en-US；支援時強制裝置端（`requiresOnDeviceRecognition`），失敗再改用 Apple 伺服器一次。靜音 1.3 秒自動結束、6 秒沒聲音停止。音訊 session 為 `.record` / `.measurement` / `.duckOthers`（第 109 行），**只能收音、不能同時播放**。未設定 `contextualStrings`。 |
| 理解 | `OnDeviceJourneyAssistant.swift` `RuleFirstConversation` | 三層：①使用者同意後線上（Supabase → Groq `gpt-oss-120b`／`20b`，JSON 模式）②規則不確定時用裝置端 Foundation Models（`@Generable GeneratedJourneyReading`）③規則。模型只讀欄位，地點由 `JourneyAssistantContext.resolve` 用 `PlaceSearch` 與常用行程決定，最多三個選項追問。 |
| 線上輔助 | `OnlineJourneyReader.compare`、`rewrite`、`noticeIndices` | 「幫我比較」：模型依畫面上的路線摘要寫最多兩句比較（**模型會在自由文字中引用數字**）；找不到地點時改寫搜尋詞；公告只挑原文段落。 |
| 修改行程 | `AIJourneyViews.swift` `refine(_:)`、`TransitAppModel.applyAssistantChange` | 「改騎車」「晚一點」「不要搭公車」「改去101」。**只在導航開始前有效**（`guard ... !planner.started`）。 |
| Siri | `AssistantInput.swift` `PlanTripIntent`、`TaipeiBusShortcuts` | 只把句子交給 App（`openAppWhenRun = true`），Siri 不會說出結果。 |
| 伺服器 | `supabase/functions/understand/index.ts` | 匿名登入、每機每日 20 句（Pro 100），驗證 App Store 交易決定 Pro；只轉送最多 3 則 system/user 訊息、`max_completion_tokens` ≤ 800、強制 JSON。**不支援工具呼叫、不支援串流。** |
| 介面 | `AIJourneyViews.swift` `VoiceAssistantView`、`VoiceOrb`、`VoiceGlowOverlay` | 邊框光暈／全螢幕兩種樣式，音量動畫、靜音倒數環。 |
| 語音輸出 | — | **沒有**。整個 App 沒有 `AVSpeechSynthesizer`。 |
| 時間解讀 | `TransitCore/SpokenTime.swift` | 規則解讀「明天早上」「三點去台大」等；不信任模型處理日期。可延伸為「說出時間」的格式器。 |
| 基準 | `ios/ai/journey-corpus.json`、`JOURNEY_BENCHMARK.md` | 72 句文字語料，**尚未有真機實測準確率**。 |

**距離目標的缺口**：沒有 TTS；一問一答、不能插話；只會規劃，不能回答「307 還要多久」，也不能在導航中用說的上下車、跟車；伺服器只會一次性 JSON，沒有工具迴圈。

---

## 3. 延續的設計原則

1. **數字只來自 App**。工具回傳結構化資料，同時附上 App 依現有顯示規則（完整分鐘、「約幾分」、過期不顯示）產生的 `spoken` 句子。模型的回答只能引用或串接這些句子；自動檢查：回答中出現的每個數字都必須在本回合的工具結果中出現，否則改念 App 產生的句子。現有「幫我比較」已讓模型在文字中引用時間，這項檢查可以先套用在它身上。
2. **理解可錯，執行要確認**。只讀與純畫面切換可直接執行；改變行程狀態（開始導航、已上車、已下車、結束）、改設定、收藏要先口頭或畫面確認；購買、權限、對外傳送資料不開放給語音。
3. **任何一層失效都能退回**。網路斷→裝置端模型；模型不可用→規則；語音不可用→文字。現有 `RuleFirstConversation` 的分層精神延伸到對話。
4. **同意是逐項的**。現有一次性同意只涵蓋「把打字或辨識後的文字送到 Groq」。**把錄音或位置送到第三方是新的資料類型，需要新的明確同意**（見第 9 節）。

---

## 4. 技術現況（2026-10）

### 4.1 Apple 裝置端與 PCC

- **Foundation Models（iOS 26+）**：`LanguageModelSession`、`@Generable`、`Tool` 協定、串流回應。裝置端模型每個 session **4096 tokens**，涵蓋 instructions、工具定義、工具輸入輸出與回答；中文約一字一 token。Apple 建議每次請求 3–5 個工具、工具描述精簡、處理超出 context 的錯誤。【已查證】[Managing the context window](https://developer.apple.com/tutorials/data/documentation/foundationmodels/managing-the-context-window.md)
- **語言**：Apple Intelligence 支援繁體中文；以 `supportsLocale` 判斷（App 已這樣做）。Apple 建議 instructions 開頭寫明使用者 locale。【已查證】[Supporting languages](https://developer.apple.com/tutorials/data/documentation/foundationmodels/supporting-languages-and-locales-with-foundation-models.md)、[Apple Intelligence 支援](https://support.apple.com/en-us/121115)
- **PCC（iOS 27+）**：`PrivateCloudComputeLanguageModel`，**32K context、可設定推理程度（light／moderate／deep）**，每人每日有額度，可引導升級 iCloud+；工具與 instructions 不必修改，只換建立 session 的一行。需要網路，失敗時應改用裝置端模型。【已查證】[Adding server-side intelligence with PCC](https://developer.apple.com/tutorials/data/documentation/foundationmodels/adding-server-side-intelligence-with-private-cloud-compute.md)
- **PCC 資格**：加入 App Store 小型企業計畫、所有 App 首次下載合計少於 200 萬、申請 PCC entitlement；符合者**沒有雲端 API 費用**。超過門檻須在 6 個月內遷移；Apple 表示未來會有付費擴充。【已查證】[Accessing Private Cloud Compute](https://developer.apple.com/private-cloud-compute/)
- **`LanguageModel` 協定（iOS 27+）**：可自行實作 executor，把伺服器模型接到同一個 `LanguageModelSession`。目前符合的型別為 `SystemLanguageModel` 與 `PrivateCloudComputeLanguageModel`。意義：**iOS 27 起，裝置端、PCC、我們的 Supabase 伺服器可共用同一套 `Tool` 實作**。【已查證】[LanguageModel](https://developer.apple.com/tutorials/data/documentation/foundationmodels/languagemodel.md)
- iOS 27 另有 Dynamic Profiles（session 中切換模型、工具與 instructions）、Evaluations framework。【推論】[WWDC26 iOS guide](https://developer.apple.com/wwdc26/guides/ios/)

### 4.2 語音辨識

- **SpeechAnalyzer / SpeechTranscriber（iOS 26+）**：裝置端，模型以 `AssetInventory` 下載；支援暫定（volatile）結果、`fastResults`、`prepareToAnalyze` 預熱、`AnalysisContext.contextualStrings` 自訂詞彙，以及內建語音偵測 `SpeechDetector`。不支援的語言改用 `DictationTranscriber`。【已查證】[SpeechTranscriber](https://developer.apple.com/tutorials/data/documentation/speech/speechtranscriber.md)、[SpeechDetector](https://developer.apple.com/tutorials/data/documentation/speech/speechdetector.md)、[AnalysisContext](https://developer.apple.com/tutorials/data/documentation/speech/analysiscontext.md)
- **SpeechTranscriber 是否支援 zh-TW：未證實**。二手資料說有「Chinese (Traditional)」，但沒有官方清單；Simulator 回傳空清單，必須在真機印出 `SpeechTranscriber.supportedLocales`。【未證實】
- **SFSpeechRecognizer** zh-TW 可用，App 已實際使用。`SFSpeechRecognitionRequest.contextualStrings` 從 iOS 10 就能加入站名與路線名，**目前沒用到，是低成本改善**。iOS 17 的 `SFCustomLanguageModelData` 可加自訂發音，zh-TW 支援【未證實】。
- **Groq Whisper**：`whisper-large-v3-turbo` 每小時 US$0.04，但**每次請求最少計費 10 秒、不支援串流**，不適合即時對話。【已查證】[Groq STT](https://console.groq.com/docs/speech-to-text)

### 4.3 語音合成

- **AVSpeechSynthesizer**：zh-TW 預設為美佳（Mei-Jia）compact；enhanced／premium 需使用者到設定下載，無 API 列出可下載但未安裝的語音。Siri 語音不開放給第三方。【推論】[Apple 論壇](https://developer.apple.com/forums/thread/758460)、【已查證】[WWDC20 10022](https://developer.apple.com/wwdc20/10022)
- iOS 16 起可用 SSML（`AVSpeechUtterance(ssmlRepresentation:)`）調整停頓與念法。Personal Voice 目前沒有台灣華語。【推論】
- 沒有查到 iOS 27 新的第三方神經 TTS API。【未證實】
- **雲端 TTS**：Azure 有 zh-TW 神經語音（HsiaoChen、YunJhe、HsiaoYu）【已查證】[Azure 語言支援](https://learn.microsoft.com/en-us/azure/ai-services/speech-service/language-support?tabs=tts)；Google Cloud cmn-TW 只有 Standard／WaveNet【已查證】；ElevenLabs Flash v2.5 約 75 ms，華語無台灣變體【已查證】；**Groq TTS 沒有華語**【已查證】[Groq TTS](https://console.groq.com/docs/text-to-speech)。

### 4.4 Siri 與 App Intents

- iOS 26 的 `SnippetIntent` 可提供互動式結果與確認畫面。【已查證】[SnippetIntent](https://developer.apple.com/tutorials/data/documentation/appintents/snippetintent.md)
- iOS 27 的 Siri AI 於 2026-09 以英文 beta 上線，27.2 beta 加入法、日、韓、葡、西文；**中文尚無時程**。Intent schema 的網域示範以訊息、郵件、照片等為主，**沒有交通／導航網域**。【推論】[9to5Mac](https://9to5mac.com/2026/09/16/ios-27-2-expands-siri-ai-to-these-new-languages/)、[WWDC26 240](https://developer.apple.com/videos/play/wwdc2026/240/)
- 結論：繁中使用者目前能用的是**經典 App Shortcuts + `IntentDialog` 回覆**；Siri AI 的螢幕感知與個人情境暫時不能依賴。

### 4.5 雲端端到端語音

| 服務 | 價格（官方） | 特點 | 對本 App 的疑慮 |
| --- | --- | --- | --- |
| OpenAI `gpt-realtime-2.1` | 音訊輸入 $32／輸出 $64 每百萬 token | 推理、函式呼叫、128K、WebRTC／WebSocket、短效 client secret、`semantic_vad` | 價格高；zh-TW 品質沒有公開評測【未證實】 |
| OpenAI `gpt-realtime-2.1-mini` | 音訊輸入 $10／輸出 $20 | 同上，較便宜 | 同上 |
| Google Gemini Live（`gemini-3.8-live`、`3.1-flash-live-preview`） | 音訊輸入 $3（約 $0.005／分）、輸出 $12（約 $0.018／分） | 支援 **zh-Hant**；預設約 800 ms 靜音判定；插話時取消生成；純音訊 session 15 分鐘；只有 WebSocket；短效 token | 3.1 Flash Live 的函式呼叫只能依序執行 |

來源：【已查證】[OpenAI pricing](https://developers.openai.com/api/docs/pricing)、[OpenAI Realtime](https://developers.openai.com/api/docs/guides/realtime)、[Gemini pricing](https://ai.google.dev/gemini-api/docs/pricing)、[Gemini Live guide](https://ai.google.dev/gemini-api/docs/live-guide)、[Gemini ephemeral tokens](https://ai.google.dev/gemini-api/docs/ephemeral-tokens)。OpenAI 另有按分鐘計價的 `gpt-live-1`，把工具交給後端 agent【推論】。

### 4.6 文字大腦（串接式用）

| 模型 | 價格（每百萬 token，輸入／輸出） | 工具呼叫 | 備註 |
| --- | --- | --- | --- |
| Groq `openai/gpt-oss-20b` | $0.075 / $0.30 | 支援，**不支援平行呼叫** | 約 1,000 tok/s；App 已在用 |
| Groq `openai/gpt-oss-120b` | $0.15 / $0.60 | 同上 | 約 500 tok/s |
| Anthropic Claude Haiku 5.5 | $0.10 / $0.50（提示 ≤100K） | 支援，可串流工具輸入 | 只有文字／圖片輸入，沒有語音 API |
| Apple PCC | 符合資格者免費，每人每日額度 | Foundation Models `Tool` | iOS 27+ |
| Apple 裝置端 | 免費、離線 | Foundation Models `Tool` | 4K context |

來源：【已查證】[Groq gpt-oss-20b](https://console.groq.com/docs/model/openai/gpt-oss-20b)、[Groq tool use](https://console.groq.com/docs/tool-use)、[Claude 定價](https://platform.claude.com/docs/en/about-claude/pricing.md)、[Claude 模型總覽](https://platform.claude.com/docs/en/about-claude/models/overview.md)。Groq 經常下架模型（`OnlineJourneyReader.models` 的註解已記錄 2026-08 Llama 下架），應保留多模型退回。

### 4.7 伺服器限制

Supabase Edge Functions 支援 WebSocket，但**牆鐘時間免費版 150 秒、付費版 400 秒，閒置 150 秒逾時**。【已查證】[Limits](https://supabase.com/docs/guides/functions/limits)、[WebSockets](https://supabase.com/docs/guides/functions/websockets)。因此：

- 串接式：每回合一次請求，可用 SSE 串流，符合限制。
- 端到端語音：**不能經由 Edge Function 中繼整段對話**；只能讓函式驗證身分、扣額度後發放短效 token，手機直連供應商。

---

## 5. 架構方案比較

```
A 全裝置端      麥克風 → SpeechAnalyzer/SFSpeech → Foundation Models(4K)+工具 → AVSpeechSynthesizer
B 串接式(建議)  麥克風 → 裝置端辨識 → [PCC | 裝置端 | Supabase→Groq] + App 工具 → App 產生句子 → TTS
C 端到端語音    麥克風 ⇄ WebRTC/WebSocket ⇄ Gemini Live / OpenAI Realtime（工具在手機執行）
```

| 面向 | A 全裝置端 | B 串接式 | C 端到端語音 |
| --- | --- | --- | --- |
| 對話自然度 | 低：4K context 撐不久，回合間要重開 session | 中：半雙工自然，全雙工需自做插話 | **高**：原生插話、語氣自然 |
| 數字正確性 | 高（App 產生句子） | **高**（App 產生句子） | 低到中：模型自己念，只能靠提示與事後檢查 |
| 延遲 | 中（裝置端推論速度待實測） | 中：約 1–2 秒，需要提示音與填充語 | **低**：約 0.5–1 秒【推論】 |
| 成本 | 0 | 極低（見第 6 節） | 較高 |
| 隱私 | **最佳**：不離開手機 | 文字離開手機（PCC 為 Apple 隱私雲） | 錄音與情境送第三方 |
| 裝置涵蓋 | iOS 26 + Apple Intelligence 機型 | **全部**（依裝置選大腦） | 全部（需網路） |
| 離線 | 可 | 部分（退回 A） | 不可 |
| 開發量 | 中 | 中到高 | 中，但驗證與合規成本高 |

**建議**：B 為主線，A 是 B 的離線／無同意退回，C 列為受控實驗。

---

## 6. 成本估算（粗估）

假設一次對話 4 回合：使用者每回合說 4 秒、助理每回合說 6 秒；系統提示加工具定義約 1,500 token。端到端語音每回合都會重讀先前的音訊內容。

| 方案 | 每次對話（美元） | 1,000 名每日使用者 × 每天 5 次 × 30 天 |
| --- | --- | --- |
| Gemini 3.1 Flash Live | 約 0.01–0.02 | 約 1,500–3,000 |
| OpenAI `gpt-realtime-2.1-mini` | 約 0.02–0.03 | 約 3,000–4,500 |
| OpenAI `gpt-realtime-2.1` | 約 0.07–0.10 | 約 10,000–15,000 |
| 串接式 + Groq `gpt-oss-20b` | < 0.001 | < 150 |
| 串接式 + Claude Haiku 5.5 | 約 0.0015 | 約 225 |
| 串接式 + PCC／裝置端 | 0（在額度內） | 0 |

依官方單價、OpenAI 公布的每分鐘約 600 個輸入音訊 token 與 1,200 個輸出音訊 token 推算，沒有計入快取折扣、短效 token 起始計費與雲端 TTS 字元費。**實際成本須以實驗期間的帳單為準。** 現有每機每日 20／100 句的額度機制可直接沿用到語音回合。

---

## 7. 對話與音訊設計

### 7.1 延遲預算（串接式，目標 p50 ≤ 1.2 秒、p90 ≤ 2 秒，從說完到聽見第一個字）

| 階段 | 估計 | 改善手段 |
| --- | --- | --- |
| 判斷說完 | 目前固定 1.3 秒靜音 | 改用暫定結果 + 語意判斷（句子完整、以「嗎／呢」結尾、已有目的地）縮到 0.5–0.8 秒；吵雜時拉長 |
| 最終辨識 | 0.1–0.3 秒【推論】 | `prepareToAnalyze` 預熱；`contextualStrings` |
| 大腦首個 token | 0.3–0.8 秒【推論】 | 提前開始：暫定結果穩定時先送；`prewarm()` 已存在 |
| 工具 | App 資料 < 50 ms；地點搜尋 0.2–0.8 秒 | 搜尋時先說「我找一下」；可平行查的先查 |
| 首段語音 | 0.1–0.2 秒【推論】 | 句子切段播放，第一句先念 |

以上都要在真機用 `JourneyDiagnostics` 記錄各階段時間後再調整。

### 7.2 回合交替與插話

- **半雙工（第一階段）**：播放時不收音；播完自動再聽 6 秒，沒聲音就結束。可沿用現有 `.record` 流程，只需在播放前後切換 session。
- **全雙工（第二階段）**：
  - 改為 `.playAndRecord` + `.voiceChat`，並在 `AVAudioEngine` 啟用 `setVoiceProcessingEnabled(true)`。**只有啟用 voice processing 才有回音消除**，否則手機會聽到自己說的話。【已查證】[voiceChat](https://developer.apple.com/tutorials/data/documentation/avfaudio/avaudiosession/mode-swift.struct/voicechat.md)
  - 偵測到人聲後立即停止播放並取消生成；「嗯」「好」之類的附和不算打斷。
  - `voiceProcessingOtherAudioDuckingConfiguration` 控制壓低其他 App 音樂的程度。【已查證】
  - `.voiceChat` 會開啟藍牙 HFP，AirPods 音質會變差；只播放時應切回 A2DP。
- **與現有聲音共存**：下車鈴聲（`AlightChime.wav`）、動態島通知音（`NavigationQuiet.wav`）、到站震動。下車提醒優先於助理說話，助理說話時收到下車提醒應立即中斷。
- **VoiceOver**：開啟時改用 `UIAccessibility.post(notification: .announcement, ...)` 或協調播放，避免兩個聲音重疊。語音助理對視障乘客特別有價值，應列入驗收。

### 7.3 背景與主動播報

導航中「下一站下車」的語音播報很有用，但在背景播放需要 `audio` 背景模式。App 的審查備註已有一段 GUIDELINE 2.5.4 背景定位說明，再加音訊模式要準備同等強度的說明與錄影。**建議第一版只在前景說話**，背景沿用現有通知、鈴聲與動態島。

### 7.4 台灣華語的辨識

- 站名與路線名加入 `contextualStrings`：目前位置附近的站牌、收藏、最近路線、常用行程名稱，加上 `runtime/settings.json` 的搜尋別名（北車、台大）。
- 中英混用（「去 Taipei 101」「搭 R 線」）、數字念法（「三零七」「三百零七」「307」）、台／臺、台語地名（艋舺、大稻埕）都要放進語音測試語料。
- 吵雜環境（站牌、車上、捷運）：降低 `SpeechDetector` 靈敏度、顯示即時字幕方便更正、保留按住說話。

---

## 8. 操縱 App：統一工具層

### 8.1 構想

新增一個 `AssistantToolbox`（UI 層，`@MainActor`），把 `TransitAppModel`／`JourneyPlannerModel` 既有的公開方法包成具名、具型別的工具。**同一份工具同時供給**：

- Foundation Models 的 `Tool`（iOS 26 裝置端、iOS 27 PCC 與自訂 `LanguageModel`）；
- 線上模型的 JSON schema（Supabase → Groq，或其他文字模型）；
- App Intents（Siri／捷徑），以 `AppEntity` 表示站牌、路線、常用行程。

每個工具回傳 `{ data, spoken, needsConfirmation }`，其中 `spoken` 由 App 產生，模型不得改寫其中的數字。

### 8.2 工具清單草案

| 工具 | 對應程式 | 風險 | 執行方式 |
| --- | --- | --- | --- |
| `find_stop(name)` | `TransitAppModel.findStations(query:limit:)` | 只讀 | 直接 |
| `arrivals(stop, route?)` | 站牌 ETA、`arrivalDisplay(_:stopID:at:onboard:)` | 只讀 | 直接；只念官方預估與 App 估計，過期不念 |
| `find_route(name)` | `routes(query:)` | 只讀 | 直接 |
| `trip_status()` | `planner.stepIndex`、`onboardProgress`、`currentAssistantTrip` | 只讀 | 直接（「還有幾站」「我該在哪下車」） |
| `bike_dock(near?)` | `bikeDock(_:)`、`selectBikeStation` | 只讀 | 直接 |
| `notices(query?)` | `OfficialNotices` | 只讀 | 直接；只念原文摘錄 |
| `show_stop` / `show_route` / `focus_map` | `selectStation`、`selectRoute`、`focusMap` | 畫面 | 直接 |
| `follow_vehicle(plate?)` | `trackApproachingVehicle` | 畫面 | 直接 |
| `plan_trip(...)` | 現有 `JourneyAssistantContext.resolve` + 追問 | 中 | 沿用現有確認流程 |
| `choose_option(n)` | `planner.select(_:)` | 中 | 念出方案摘要後確認 |
| `start_navigation()` | `planner.begin()` | 高 | 必須確認 |
| `boarded()` / `alighted()` / `end_trip()` | `boardCurrentRide`、`confirmBoardedVehicle`、`alight`、`finishJourney` | 高 | 必須確認；已上車沒選車牌時列出附近車牌讓使用者選 |
| `change_trip(...)` | `applyAssistantChange` | 中 | 導航前直接；**導航中需擴充**（現有 guard 會擋），應走 `resolveRemaining` 重新規劃剩餘路段並確認 |
| `toggle_favorite(stop)` | `toggleFavorite` | 低 | 念出結果，可說「取消」復原 |
| `alight_reminder(on)` | `toggleAlightReminder`、`setAlightReminderPreference` | 低 | 屬於 Pro 功能時說明並開啟方案頁，不在語音中購買 |

**不開放**：購買與訂閱、系統權限、清除資料、送出任何外部內容。

### 8.3 4K context 的限制

裝置端模型無法一次載入十幾個工具。做法：

1. 規則或小型分類先判斷意圖（查詢／規劃／導航中操作／修改），每類只給 3–5 個工具；iOS 27 可用 Dynamic Profiles 切換。
2. 對話狀態由 App 保存（目前行程、上一個提到的站牌、待確認動作），每回合只放摘要，不保留完整逐字稿。
3. PCC（32K）與線上模型可放完整工具集，但仍沿用同一路由以維持行為一致。

### 8.4 伺服器需要的變更

`supabase/functions/understand` 目前只接受 system/user 訊息、強制 JSON、最多 3 則訊息。要支援工具迴圈需要新端點（例如 `functions/converse`）：

- 接受 `tools`、`assistant`／`tool` 角色與較長的對話，但仍白名單欄位與限制長度；
- 支援 SSE 串流，讓第一句話提早出來；
- 額度改為「每回合」計算，沿用 `take_assistant_allowance`；
- 句子不保存（維持現有政策）；
- 端到端語音實驗另設 `functions/voice-token`：驗證身分與額度後，向 OpenAI／Google 換取短效 token 並鎖定設定（模型、工具、instructions）。

---

## 9. 隱私、合規與審查

- **5.1.2(i)**：「必須清楚揭露個人資料將與第三方（包括第三方 AI）分享，並在分享前取得明確許可。」【已查證】[App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/)
  - 現有同意（`OnlineJourneyReader.needsConsent`）只涵蓋把文字送到 Groq。`docs/privacy.html` 目前寫明送出的內容「不包含位置、常用行程或帳號」。
  - 對話模式會送出更多內容：目前行程、附近站名，可能還有大略位置。這會讓上述說明失效，**同意畫面與隱私政策都要列出新增送出的欄位**；能只送站名就不要送座標。
  - 端到端語音會送出**錄音**，需要獨立的同意，並說明供應商與資料保存方式（各家零保存條件須另查【未證實】）。
- **2.5.14**：錄音需明確同意與清楚的視覺或聲音提示；現有光暈與球形介面符合方向，全雙工時要持續顯示收音狀態。
- **2.5.4**：背景模式只能用於原本用途，見 7.3。
- **1.4.5**：不能鼓勵以危險方式使用裝置；導航中的回答要短，不要求看螢幕。
- **隱私文件**：`docs/privacy.html`、App 隱私標籤（音訊資料、大略位置是否送出）、審查備註（`ios/release/app-store.zh-Hant.json` 在 `ai` 分支仍寫「No ads, app accounts, UGC, AI service or tracking.」，與現有線上 AI 已不一致，送審前就必須更新）。
- **台灣個資法**：2025-10 修法設立個人資料保護委員會，並可限制跨境傳輸；施行細節與日期【未證實】。實務上應做到目的告知、最小化，並揭露境外處理。

---

## 10. 建議路線圖

每個階段都能單獨發布，前一階段的驗收沒過就不進下一階段。

### 第 0 階段：低成本改善（不需新基礎設施）

1. `SpeechInput` 設定 `contextualStrings`（附近站名、收藏、別名、常用行程名稱）。
2. 新增只讀 App Intents：`NextArrivalIntent(stop, route)`、`TripStatusIntent`，`perform` 回傳 `IntentDialog`（App 產生的句子），**不開 App**；`PlanTripIntent` 維持現狀。
3. 新增 `SpokenAnswer` 格式器（TransitCore，可在 Linux 測試）：把 ETA、站數、時間轉成口語句子，規則與畫面顯示一致（完整分鐘、過期不說）。
4. 規劃完成後可選擇「念出結果」：用 AVSpeechSynthesizer 念第一個方案的摘要。

驗收：Siri 能以繁中念出指定站牌、路線的下一班；`SpokenAnswer` 單元測試涵蓋過期、無資料與跨午夜；站名辨識率比加入 `contextualStrings` 前更好（以第 11 節語料比較）。

### 第 1 階段：半雙工對話與工具層

1. `AssistantToolbox`：第 8.2 節的只讀與畫面工具，加上確認機制。
2. 對話控制器：聽 → 理解（規則／裝置端模型／線上）→ 執行工具 → 說 → 自動再聽；對話狀態由 App 保存。
3. 語音輸出：AVSpeechSynthesizer zh-TW；有 enhanced／premium 語音就用；為路線名與站名建立發音替換表（可經 `runtime/settings.json` 遠端更新）。
4. 導航中操作：已上車、已下車、還有幾站、跟車；`change_trip` 在導航中改走重新規劃剩餘路段。
5. 伺服器：`functions/converse`（工具、SSE、每回合扣額度）。

驗收：任務語料完成率；有副作用的動作 100% 經確認；說出的數字 0 次不在工具結果中；p50 延遲達標。

### 第 2 階段：全雙工與更好的大腦

1. 改用 `.playAndRecord` + voice processing，加入插話、附和過濾與語意判斷說完。
2. iOS 27：以 `PrivateCloudComputeLanguageModel` 作為主要大腦（先申請 entitlement、確認小型企業計畫資格），額度用完退回裝置端或線上。
3. 評估以 `LanguageModel` 協定把 Supabase 伺服器包成自訂模型，讓三種大腦共用同一套 `Tool`。
4. iOS 26 的 SpeechTranscriber 若真機確認支援 zh-TW，評估取代 SFSpeechRecognizer。

驗收：插話反應 < 300 ms；車上與站牌錄音的誤插話率；藍牙耳機與下車鈴聲共存測試。

### 第 3 階段：端到端語音實驗（功能旗標，僅 TestFlight）

1. `functions/voice-token` 發放短效 token；先試 Gemini Live（支援 zh-Hant、單價較低），再比較 `gpt-realtime-2.1-mini`。
2. 工具仍在手機執行、回傳 `spoken`；instructions 要求逐字念出；客戶端比對字幕中的數字，不符就中斷並改念 App 的句子。
3. 與第 2 階段比較自然度、延遲、錯誤數字次數與每次對話成本，再決定是否成為 Pro 功能。

---

## 11. 評估方法

- **語音語料**：把 `ios/ai/journey-corpus.json` 的 72 句擴充為錄音語料，加入問答（「307 還要多久」）、導航中操作與修改句。在安靜室內、站牌、公車上、捷運車廂錄製，男女聲與不同腔調都要有；只用志願者錄音，不收集使用者對話。
- **指標**：
  - 站名與路線名的實體正確率（比整體字錯率重要）；
  - 任務成功率與回合數；
  - 說完到出聲的 p50／p90；
  - 插話誤判與漏判；
  - **說出的數字不在工具結果中的次數（目標 0）**；
  - 每次對話的成本與額度消耗。
- **工具**：延伸 `JourneyBenchmark.swift` 與 App 內「AI 測試」頁，輸出同格式報告；`JourneyDiagnostics` 加入各階段時間戳。
- 現有 72 句仍未有真機結果；**第 1 階段前應先完成文字語料的真機基準**，否則無法區分辨識錯誤與理解錯誤。

---

## 12. 待驗證清單

| 項目 | 方法 |
| --- | --- |
| SpeechTranscriber 是否支援 zh-TW、延遲與準確率 | 真機印出 `supportedLocales`，用第 11 節語料比較 SFSpeechRecognizer |
| zh-TW 的 `SFCustomLanguageModelData` 是否可用 | 真機建立含站名的自訂模型測試 |
| 裝置端 Foundation Models 帶工具時的實際延遲 | 真機基準 |
| PCC 每日額度大小、本帳號是否符合小型企業計畫 | App Store Connect、申請 entitlement |
| Siri AI 中文支援時程 | 追蹤 iOS 27.x 版本說明 |
| 是否有新的第三方神經 TTS API | 查 iOS 27 SDK |
| Gemini Live／OpenAI Realtime 的 zh-TW 辨識與發音品質 | 第 3 階段實驗 |
| 各供應商語音資料保存與零保存條件 | 讀各家資料使用條款 |
| 台灣個資法修正施行日與跨境傳輸規定 | 法規資料庫 |
| Groq 模型下架時程（Llama 下架公告與模型頁不一致） | 定期檢查 Groq deprecations |

---

## 13. 參考資料

- Apple：[Foundation Models](https://developer.apple.com/tutorials/data/documentation/foundationmodels.md)、[Context window](https://developer.apple.com/tutorials/data/documentation/foundationmodels/managing-the-context-window.md)、[Languages](https://developer.apple.com/tutorials/data/documentation/foundationmodels/supporting-languages-and-locales-with-foundation-models.md)、[PCC 文件](https://developer.apple.com/tutorials/data/documentation/foundationmodels/adding-server-side-intelligence-with-private-cloud-compute.md)、[PCC 資格](https://developer.apple.com/private-cloud-compute/)、[LanguageModel](https://developer.apple.com/tutorials/data/documentation/foundationmodels/languagemodel.md)、[SpeechTranscriber](https://developer.apple.com/tutorials/data/documentation/speech/speechtranscriber.md)、[SpeechDetector](https://developer.apple.com/tutorials/data/documentation/speech/speechdetector.md)、[Live audio](https://developer.apple.com/tutorials/data/documentation/speech/recognizing-speech-in-live-audio.md)、[voiceChat mode](https://developer.apple.com/tutorials/data/documentation/avfaudio/avaudiosession/mode-swift.struct/voicechat.md)、[SnippetIntent](https://developer.apple.com/tutorials/data/documentation/appintents/snippetintent.md)、[WWDC26 iOS guide](https://developer.apple.com/wwdc26/guides/ios/)、[Apple Intelligence 支援](https://support.apple.com/en-us/121115)、[App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/)
- OpenAI：[Pricing](https://developers.openai.com/api/docs/pricing)、[Realtime](https://developers.openai.com/api/docs/guides/realtime)、[VAD](https://developers.openai.com/api/docs/guides/realtime-vad)、[Latency & cost](https://developers.openai.com/api/docs/guides/voice-latency-cost)
- Google：[Gemini pricing](https://ai.google.dev/gemini-api/docs/pricing)、[Live guide](https://ai.google.dev/gemini-api/docs/live-guide)、[Ephemeral tokens](https://ai.google.dev/gemini-api/docs/ephemeral-tokens)、[Cloud TTS voices](https://docs.cloud.google.com/text-to-speech/docs/list-voices-and-types)
- Groq：[STT](https://console.groq.com/docs/speech-to-text)、[TTS](https://console.groq.com/docs/text-to-speech)、[Tool use](https://console.groq.com/docs/tool-use)、[Deprecations](https://console.groq.com/docs/deprecations)
- Anthropic：[Models overview](https://platform.claude.com/docs/en/about-claude/models/overview.md)、[Pricing](https://platform.claude.com/docs/en/about-claude/pricing.md)
- 其他：[Azure Speech 語言支援](https://learn.microsoft.com/en-us/azure/ai-services/speech-service/language-support?tabs=tts)、[ElevenLabs models](https://elevenlabs.io/docs/overview/models)、[Supabase limits](https://supabase.com/docs/guides/functions/limits)、[Supabase WebSockets](https://supabase.com/docs/guides/functions/websockets)、[台灣個資法修正（Baker McKenzie）](https://www.bakermckenzie.com/en/insight/publications/alerts/2025/10/taiwan-amendment-to-personal-data-protection-act)
