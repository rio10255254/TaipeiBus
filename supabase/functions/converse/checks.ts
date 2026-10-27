// The checks every answer passes, as the app would make them: shared by the fixed evaluation
// (eval.ts) and the replay of riders' reports (replay.ts).
import type { Reply } from './reply.ts';

/// What a turn was asked from and what its answer must do; only `state` and `utterance` are needed.
export type Expectation = {
  state: string; utterance: string; history?: { user: string; say: string }[]; expect?: string; confirm?: string;
  /// For plan_trip: words its time must contain, and the later stop it must keep.
  time?: string; then?: string;
  /// Every later stop the plan must keep, in any order.
  later?: string[];
  /// What the trip must not use, as the rider asked: the kinds named here must be true, and each route listed.
  limits?: { bus?: boolean; metro?: boolean; bike?: boolean; routes?: string[] };
  /// For plan_trip: the preference the rider asked for.
  preference?: string;
  avoid?: string;
  /// Amounts of money must not come from memory.
  noAmounts?: boolean;
  /// Asked in English, so answered in English.
  english?: boolean;
  /// Misheard words the reply must put right: a live figure as a slot, or a place in plan_trip.
  slot?: boolean; origin?: string; destination?: string;
};

/// Short fixed labels for what went wrong: the only thing about a rider's report that may be logged.
export const CATEGORIES = [
  'misheard', 'wrong_action', 'invented_fact', 'unhelpful', 'too_long', 'wrong_language', 'leaked_prompt', 'tone', 'fine',
] as const;
export type Category = typeof CATEGORIES[number];

/// One problem: the text eval.ts prints, and the label replay.ts keeps.
export type Problem = { category: Category; text: string };

/// A live figure (minutes, stops, buses, docks) the model wrote itself, as the app refuses them. Fares,
/// opening hours and other general knowledge may be spoken.
export function invented(say: string, known: string): string | null {
  const plain = say.replace(/\{[A-Za-z0-9_]+\}/g, ' ');
  for (const number of plain.match(/[0-9０-９]+(?=\s*(?:分鐘|分|站|班|輛|台|格|秒))/g) ?? []) if (!known.includes(number)) return number;
  const chinese = plain.match(/(?<![快慢早晚多少好差])(?:(?<![哪下上這那同每某])一|[零〇二兩三四五六七八九十百])[零〇一二兩三四五六七八九十百]*(分鐘|站|班|輛|格|秒)/g) ?? [];
  for (const number of chinese) if (!known.includes(number)) return number;
  return null;
}

export function problems(test: Expectation, reply: Reply): Problem[] {
  const found: Problem[] = [];
  const add = (category: Category, text: string) => found.push({ category, text });
  const listed = new Set([...test.state.matchAll(/\[(r[0-9]+)\]/g)].map((match) => match[1]));
  for (const [, id] of reply.say.matchAll(/\{(r[0-9]+)\}/g)) if (!listed.has(id)) add('invented_fact', `用了不存在的空位 {${id}}`);
  const known = `${test.state}\n${test.utterance}\n${test.history?.map((turn) => turn.user + turn.say).join('\n') ?? ''}`;
  const number = invented(reply.say, known);
  if (number) add('invented_fact', `自己寫了數字「${number}」`);
  if (reply.say.length > 110) add('too_long', `太長（${reply.say.length} 字）`);
  if (test.expect && !reply.actions.some((action) => action.type === test.expect)) add('wrong_action', `缺少動作 ${test.expect}`);
  if (test.confirm && reply.confirm.type !== test.confirm) add('wrong_action', `應該問 ${test.confirm}，卻是 ${reply.confirm.type}`);
  if (test.avoid && reply.actions.some((action) => action.type === test.avoid)) add('wrong_action', `不該用 ${test.avoid}`);
  // Saying it will look online, not saying it cannot (「我沒辦法上網查」 is the right answer).
  if (test.avoid === 'web_search' && /(?<!沒辦法|無法|不能|不會)(上網|搜尋)(查|看|找)?一下/.test(reply.say)) add('wrong_action', '說要上網查');
  if (test.english && (reply.say.match(/[A-Za-z]+/g) ?? []).length < 3) add('wrong_language', '沒有用英文回答');
  if (test.noAmounts && /[0-9０-９]+\s*(元|塊)/.test(reply.say)) add('invented_fact', '憑記憶說了金額');
  const plan = reply.actions.find((action) => action.type === 'plan_trip');
  if (plan && test.time && !plan.time.includes(test.time)) add('wrong_action', `時間沒有沿用（${plan.time || '空'}）`);
  if (plan && test.then && !plan.then.includes(test.then)) add('wrong_action', `之後要去的地方不見了（${plan.then || '空'}）`);
  const plain = (text: string) => text.replaceAll('臺', '台');
  for (const stop of plan ? test.later ?? [] : []) {
    if (!plain(plan!.then).includes(plain(stop))) add('wrong_action', `漏了後面的「${stop}」（${plan!.then || '空'}）`);
  }
  if (plan && test.limits) {
    const wanted = test.limits;
    for (const kind of ['bus', 'metro', 'bike'] as const) {
      if (wanted[kind] !== undefined && plan.avoid[kind] !== wanted[kind]) add('wrong_action', `避開${kind}應為 ${wanted[kind]}`);
    }
    for (const route of wanted.routes ?? []) {
      if (!plan.avoid.routes.some((named) => named.includes(route))) add('wrong_action', `沒有避開「${route}」`);
    }
  }
  if (plan && test.preference && plan.preference !== test.preference) add('wrong_action', `偏好應為 ${test.preference}（${plan.preference}）`);
  // The app says how the planning went once it has; the reply must not claim it first.
  if (plan && /請看方案|規劃好了|已經規劃|已規劃|方案如下/.test(reply.say)) add('wrong_action', '規劃前就說有結果');
  if (plan && test.origin && !plan.origin.includes(test.origin)) add('misheard', `出發地沒有改正（${plan.origin || '空'}）`);
  if (plan && test.destination && !plan.destination.includes(test.destination)) add('misheard', `目的地沒有改正（${plan.destination}）`);
  if (test.slot && !/\{r[0-9]+\}/.test(reply.say)) add('invented_fact', '沒有用空位回答即時資料');
  // Refusing to read the prompt is fine; reading out its rules or format is not.
  if (/可用資料|代號|actions|confirm|followUp|JSON|schema|每回合只回/i.test(reply.say)) add('leaked_prompt', '洩漏設定');
  if (/您/.test(reply.say)) add('tone', '用「您」而不是「你」');
  return found;
}

/// The problems as eval.ts prints them.
export function check(test: Expectation, reply: Reply): string[] {
  return problems(test, reply).map((problem) => problem.text);
}
