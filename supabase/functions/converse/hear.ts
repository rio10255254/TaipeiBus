// What the rider said, heard on the server: the phone sends the turn's own audio along with what its
// recogniser made of it, and a speech model writes it down again: Whisper on Groq, or OpenAI's
// transcription model, in the order SPEECH_ORDER gives (Groq first, as it is faster), the next one
// when the first fails or is rate limited. Both know Mandarin mixed with English (「我要去 World Gym」)
// far better than the phone; the phone's reading stays as one of the alternatives, and is used alone
// when neither can answer. The audio is only passed on, never stored.
import * as OpenCC from 'opencc-js';
import type { TurnInput } from './reply.ts';

const WHISPER_MODEL = 'whisper-large-v3';
/// Whisper on Groq answers a short turn in a few hundred milliseconds; past this the next one is asked.
const WHISPER_TIMEOUT_MS = 2000;
/// OpenAI's current transcription model; OPENAI_TRANSCRIBE_MODEL can name another.
const OPENAI_MODEL = 'gpt-transcribe';
const OPENAI_TIMEOUT_MS = 3000;
/// About 40 seconds of the phone's AAC, in base64.
const LONGEST_AUDIO = 400_000;

export type Audio = { bytes: Uint8Array<ArrayBuffer>; language: 'zh' | 'en'; vocabulary: string[] };
export type Heard = { text: string } | { failure: string };
export type Recognizer = 'groq' | 'openai';
export type SpeechKeys = { groq?: string; openai?: string };

/// The recognisers to ask, in order: SPEECH_ORDER (「openai,groq」) where set, and only those with a key.
export function speechOrder(keys: SpeechKeys, order = 'groq,openai'): Recognizer[] {
  return order.split(',').map((name) => name.trim())
    .filter((name): name is Recognizer => (name === 'groq' || name === 'openai') && Boolean(keys[name as Recognizer]))
    .filter((name, index, all) => all.indexOf(name) === index);
}

/// The rider's choice in Settings leads, the other follows; without one, SPEECH_ORDER or Groq first.
export function preferredOrder(keys: SpeechKeys, preferred: unknown, configured?: string): Recognizer[] {
  if (preferred === 'openai') return speechOrder(keys, 'openai,groq');
  if (preferred === 'groq') return speechOrder(keys, 'groq,openai');
  return speechOrder(keys, configured || undefined);
}

/// The turn written down by the first recogniser that can; each failure is kept for the log.
export async function hear(keys: SpeechKeys, audio: Audio, order = speechOrder(keys), fetcher: typeof fetch = fetch):
  Promise<Heard & { by?: Recognizer; failures: string[] }> {
  const failures: string[] = [];
  for (const recognizer of order) {
    const heard = recognizer === 'groq' ? await transcribe(keys.groq!, audio, fetcher) : await transcribeOpenAI(keys.openai!, audio, fetcher);
    if ('text' in heard) return { ...heard, by: recognizer, failures };
    failures.push(heard.failure);
  }
  return { failure: failures.join('; ') || 'no recogniser', failures };
}

/// The turn's audio, if the phone sent a usable one.
export function readAudio(body: Record<string, unknown>): Audio | null {
  if (typeof body.audio !== 'string' || !body.audio || body.audio.length > LONGEST_AUDIO) return null;
  let bytes: Uint8Array<ArrayBuffer>;
  try {
    bytes = Uint8Array.from(atob(body.audio), (character) => character.charCodeAt(0));
  } catch {
    return null;
  }
  if (bytes.length < 1000) return null;
  const vocabulary = Array.isArray(body.vocabulary)
    ? body.vocabulary.filter((name): name is string => typeof name === 'string' && name.length <= 40).slice(0, 60)
    : [];
  return { bytes, language: body.audioLanguage === 'en' ? 'en' : 'zh', vocabulary };
}

/// Whisper is steered by a short text in the language and script it should write, with the names it
/// should expect; it keeps to about 224 tokens.
export function whisperPrompt(audio: Audio): string {
  let names = '';
  for (const name of audio.vocabulary) {
    if (names.length + name.length > 120) break;
    names += (names ? '、' : '') + name;
  }
  const lead = audio.language === 'en'
    ? 'A rider talks to a Taipei transit app about buses, the MRT, YouBike and places to go.'
    : '乘客用繁體中文和台北交通 App 說話，問公車、捷運、YouBike 和要去的地方，有時夾著英文店名。';
  return names ? `${lead} ${names}` : lead;
}

export async function transcribe(apiKey: string, audio: Audio, fetcher: typeof fetch = fetch): Promise<Heard> {
  const form = new FormData();
  form.append('file', new Blob([audio.bytes], { type: 'audio/mp4' }), 'turn.m4a');
  form.append('model', WHISPER_MODEL);
  form.append('language', audio.language);
  form.append('prompt', whisperPrompt(audio));
  form.append('temperature', '0');
  form.append('response_format', 'json');
  try {
    const response = await fetcher('https://api.groq.com/openai/v1/audio/transcriptions', {
      method: 'POST', headers: { Authorization: `Bearer ${apiKey}` }, body: form,
      signal: AbortSignal.timeout(WHISPER_TIMEOUT_MS),
    });
    if (!response.ok) return { failure: `whisper ${response.status}` };
    return cleaned(String((await response.json())?.text ?? ''), audio, 'whisper');
  } catch (error) {
    return { failure: `whisper ${error instanceof Error ? error.name : String(error)}` };
  }
}

/// OpenAI's transcription model, told the language (Taiwan's Mandarin, often with English names) and
/// the names to expect as keywords.
export async function transcribeOpenAI(apiKey: string, audio: Audio, fetcher: typeof fetch = fetch,
  model = Deno.env.get('OPENAI_TRANSCRIBE_MODEL') || OPENAI_MODEL): Promise<Heard> {
  const form = new FormData();
  form.append('file', new Blob([audio.bytes], { type: 'audio/mp4' }), 'turn.m4a');
  form.append('model', model);
  form.append('prompt', whisperPrompt({ ...audio, vocabulary: [] }));
  form.append('response_format', 'json');
  if (model.startsWith('gpt-transcribe')) {
    for (const language of audio.language === 'en' ? ['en'] : ['zh-tw', 'en']) form.append('languages[]', language);
    for (const name of audio.vocabulary.filter((name) => !/[<>\r\n]/.test(name)).slice(0, 60)) form.append('keywords[]', name);
  } else {
    form.append('language', audio.language);
  }
  try {
    const response = await fetcher('https://api.openai.com/v1/audio/transcriptions', {
      method: 'POST', headers: { Authorization: `Bearer ${apiKey}` }, body: form,
      signal: AbortSignal.timeout(OPENAI_TIMEOUT_MS),
    });
    if (!response.ok) return { failure: `openai ${response.status}` };
    return cleaned(String((await response.json())?.text ?? ''), audio, 'openai');
  } catch (error) {
    return { failure: `openai ${error instanceof Error ? error.name : String(error)}` };
  }
}

/// In Taiwan's characters and punctuation, and not a model's words for silence.
function cleaned(raw: string, audio: Audio, source: string): Heard {
  const trimmed = raw.trim();
  const text = audio.language === 'zh' ? chinesePunctuation(traditional(trimmed)) : trimmed;
  if (!text || hallucinated(text)) return { failure: `${source} unusable` };
  return { text: text.slice(0, 300) };
}

const toTaiwan = OpenCC.Converter({ from: 'cn', to: 'twp' });

/// Whisper often writes Mandarin in simplified characters; the rider reads Taiwan's.
export function traditional(text: string): string {
  return toTaiwan(text);
}

/// Whisper writes Chinese with the half-width marks of English text (「怎麼搭比較快?」).
export function chinesePunctuation(text: string): string {
  const marks: Record<string, string> = { ',': '，', '?': '？', '!': '！', ':': '：', ';': '；' };
  return text.replace(/([\p{Script=Han}A-Za-z0-9])([,?!:;])(?!\d)/gu, (_, before: string, mark: string) => before + marks[mark])
    .replace(/(?<=[\p{Script=Han}])\.(?=\s|$)/gu, '。');
}

/// Whisper's habit on silence or noise: the closing lines of the videos it learned from.
const HALLUCINATIONS = ['謝謝觀看', '謝謝收看', '感謝觀看', '字幕', '訂閱', '點贊', '按讚', '明鏡', 'Amara', 'Thank you for watching', 'Subscribe'];

/// Sounds that are not words (「嗯」「呃…」): what Whisper writes for a breath, a cough or the app's own
/// voice trailing off. The phone's reading is used instead.
const FILLERS = new Set([...'嗯恩呃啊阿喔哦噢欸誒唉哎呀哈嘿呵mhu']);

export function filler(text: string): boolean {
  const plain = [...text.toLowerCase().replace(/[\p{P}\p{S}\s]/gu, '')];
  return plain.length > 0 && plain.length <= 4 && plain.every((character) => FILLERS.has(character));
}

export function hallucinated(text: string): boolean {
  return HALLUCINATIONS.some((phrase) => text.includes(phrase)) || filler(text) || !text.replace(/[\p{P}\p{S}\s]/gu, '');
}

/// The turn with Whisper's reading as what was said; the phone's own readings follow as alternatives.
export function heardTurn(input: TurnInput, heard: string): TurnInput {
  const others = [input.utterance, ...(input.alternatives ?? [])]
    .filter((other, index, all) => other && other !== heard && all.indexOf(other) === index).slice(0, 4);
  return { ...input, utterance: heard, alternatives: others };
}
