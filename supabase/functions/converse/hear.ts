// What the rider said, heard on the server: the phone sends the turn's own audio along with what its
// recogniser made of it, and Whisper on Groq writes it down again. Whisper knows Mandarin mixed with
// English (「我要去 World Gym」) far better than the phone; the phone's reading stays as one of the
// alternatives, and is used alone when Whisper fails. The audio is only passed on, never stored.
import * as OpenCC from 'opencc-js';
import type { TurnInput } from './reply.ts';

const WHISPER_MODEL = 'whisper-large-v3';
/// Whisper on Groq answers a short turn in a few hundred milliseconds; past this the phone's reading is used.
const WHISPER_TIMEOUT_MS = 2500;
/// About 40 seconds of the phone's AAC, in base64.
const LONGEST_AUDIO = 400_000;

export type Audio = { bytes: Uint8Array<ArrayBuffer>; language: 'zh' | 'en'; vocabulary: string[] };
export type Heard = { text: string } | { failure: string };

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
    const raw = String((await response.json())?.text ?? '').trim();
    const text = audio.language === 'zh' ? traditional(raw) : raw;
    if (!text || hallucinated(text)) return { failure: 'whisper unusable' };
    return { text: text.slice(0, 300) };
  } catch (error) {
    return { failure: `whisper ${error instanceof Error ? error.name : String(error)}` };
  }
}

const toTaiwan = OpenCC.Converter({ from: 'cn', to: 'twp' });

/// Whisper often writes Mandarin in simplified characters; the rider reads Taiwan's.
export function traditional(text: string): string {
  return toTaiwan(text);
}

/// Whisper's habit on silence or noise: the closing lines of the videos it learned from.
const HALLUCINATIONS = ['謝謝觀看', '謝謝收看', '感謝觀看', '字幕', '訂閱', '點贊', '按讚', '明鏡', 'Amara', 'Thank you for watching', 'Subscribe'];

export function hallucinated(text: string): boolean {
  return HALLUCINATIONS.some((phrase) => text.includes(phrase));
}

/// The turn with Whisper's reading as what was said; the phone's own readings follow as alternatives.
export function heardTurn(input: TurnInput, heard: string): TurnInput {
  const others = [input.utterance, ...(input.alternatives ?? [])]
    .filter((other, index, all) => other && other !== heard && all.indexOf(other) === index).slice(0, 4);
  return { ...input, utterance: heard, alternatives: others };
}
