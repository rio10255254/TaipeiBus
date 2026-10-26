// Sends a few recorded sentences to each speech recogniser with a key (Whisper on Groq, OpenAI) the
// way the server does for a turn, and checks each comes back with the words that matter; the first is
// then answered by Claude from what was heard. The recordings are synthesized voices in the phone's format (16 kHz mono AAC).
// deno run --allow-env --allow-net --allow-read --config supabase/functions/converse/deno.json supabase/functions/converse/hear_check.ts
import { askClaude } from './brain.ts';
import { type Audio, type Heard, heardTurn, transcribe, transcribeOpenAI } from './hear.ts';
import { userMessage } from './reply.ts';

const groqKey = Deno.env.get('GROQ_API_KEY');
const openaiKey = Deno.env.get('OPENAI_API_KEY');
const anthropicKey = Deno.env.get('ANTHROPIC_API_KEY');
if (!groqKey && !openaiKey) {
  console.log('No GROQ_API_KEY or OPENAI_API_KEY: server recognition not checked.');
  Deno.exit(0);
}

const vocabulary = ['忠孝復興', '圓山', '台北101', 'World Gym', 'YouBike', '捷運'];
const recordings: { file: string; language: Audio['language']; expect: string[]; phone: string }[] = [
  { file: 'wg.m4a', language: 'zh', expect: ['World Gym'], phone: '我要去word jim怎麼搭比較快' },
  { file: 'yuanshan.m4a', language: 'zh', expect: ['圓山', '酒吧', '推薦'], phone: '想去遠山的酒吧' },
  { file: 'r307.m4a', language: 'zh', expect: ['307|三零七|三〇七'], phone: '三零七還要多酒' },
  { file: 'english.m4a', language: 'en', expect: ['307', 'how long'], phone: 'how long until the 307 comes' },
];

const map = '現在：2026-10-25 19:40 星期日（台北）\n畫面：地圖\n附近站牌：忠孝復興站、大安路口';
let failures = 0;
// The account's own Whisper limits, as Groq reports them with each answer.
let limits = '';
const counting: typeof fetch = async (input, init) => {
  const response = await fetch(input, init);
  const header = (name: string) => response.headers.get(name) ?? '?';
  limits = `每日請求 剩 ${header('x-ratelimit-remaining-requests')}/${header('x-ratelimit-limit-requests')}` +
    `｜音訊秒數 剩 ${header('x-ratelimit-remaining-audio-seconds')}/${header('x-ratelimit-limit-audio-seconds')}`;
  return response;
};
// Each recogniser with a key hears every recording, so they can be compared side by side.
const recognizers: { name: string; ask: (audio: Audio) => Promise<Heard> }[] = [
  ...(groqKey ? [{ name: 'Groq Whisper', ask: (audio: Audio) => transcribe(groqKey, audio, counting) }] : []),
  ...(openaiKey ? [{ name: 'OpenAI', ask: (audio: Audio) => transcribeOpenAI(openaiKey, audio) }] : []),
];
for (const recognizer of recognizers) {
  console.log(`## ${recognizer.name}`);
  for (const recording of recordings) {
    const bytes = await Deno.readFile(new URL(`./fixtures/${recording.file}`, import.meta.url));
    const started = performance.now();
    const heard = await recognizer.ask({ bytes, language: recording.language, vocabulary });
    const ms = Math.round(performance.now() - started);
    if (!('text' in heard)) {
      failures++;
      console.log(`✗ ${recording.file}｜${heard.failure}｜${ms} ms`);
      continue;
    }
    const lower = heard.text.toLowerCase();
    const missing = recording.expect.filter((words) => !words.split('|').some((word) => lower.includes(word.toLowerCase())));
    if (missing.length) failures++;
    console.log(`${missing.length ? '✗' : '✓'} ${recording.file}｜聽到：${heard.text}｜${ms} ms${missing.length ? `｜缺少：${missing.join('、')}` : ''}`);

    // What the model makes of it, from Whisper's reading with the phone's own as an alternative.
    if (recording.file === 'wg.m4a' && anthropicKey) {
      const turn = heardTurn({ utterance: recording.phone, state: map, history: [] }, heard.text);
      const answer = await askClaude(anthropicKey, userMessage(turn));
      const plan = 'reply' in answer ? answer.reply.actions.find((action) => action.type === 'plan_trip') : undefined;
      const fine = Boolean(plan?.destination.includes('World Gym'));
      if (!fine) failures++;
      console.log(`${fine ? '✓' : '✗'} Claude｜${'reply' in answer ? `${answer.reply.say}｜${answer.reply.actions.map((action) => `${action.type}(${action.destination})`).join(' ')}` : answer.failure}`);
    }
  }
}
if (groqKey) console.log(`Groq Whisper 額度：${limits}`);
if (failures) {
  console.log(`${failures} 項沒有通過。`);
  Deno.exit(1);
}
console.log('伺服器語音辨識正常。');
