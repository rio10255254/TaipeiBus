// The spoken sentence while the reply is still being written. The reply is one JSON object whose
// first field is `say`, so the words to speak arrive before the actions; this reads them out of the
// unfinished JSON so the phone can start speaking at the first full stop.

export class SayReader {
  private text = '';
  /// Where the value of `say` starts in `text`, once its opening quote has arrived.
  private start = -1;
  /// How far into the value has been decoded.
  private at = 0;
  private done = false;

  /// The closing quote of `say` has arrived: nothing more will be spoken.
  get complete(): boolean {
    return this.done;
  }

  /// The new characters of `say` in this chunk of the reply; empty until there are some.
  push(chunk: string): string {
    if (this.done) return '';
    this.text += chunk;
    if (this.start < 0) {
      const opening = /"say"\s*:\s*"/.exec(this.text);
      if (!opening) return '';
      this.start = opening.index + opening[0].length;
      this.at = this.start;
    }
    let decoded = '';
    while (this.at < this.text.length) {
      const character = this.text[this.at];
      if (character === '"') {
        this.done = true;
        break;
      }
      if (character !== '\\') {
        decoded += character;
        this.at += 1;
        continue;
      }
      // An escape is decoded only once it has fully arrived.
      const next = this.text[this.at + 1];
      if (next === undefined) break;
      if (next === 'u') {
        const hex = this.text.slice(this.at + 2, this.at + 6);
        if (hex.length < 4) break;
        decoded += /^[0-9a-fA-F]{4}$/.test(hex) ? String.fromCharCode(parseInt(hex, 16)) : '';
        this.at += 6;
        continue;
      }
      decoded += ({ n: '\n', t: '\t', r: '', b: '', f: '' } as Record<string, string>)[next] ?? next;
      this.at += 2;
    }
    return decoded;
  }
}

/// The places of the reply's first action, read out of the unfinished JSON as soon as each name is
/// whole: a trip's destination and origin, or what find_place looks for. The phone starts looking them
/// up on the map while the rest of the reply is still being written.
export class PlacePeek {
  private text = '';
  private done = false;

  /// The names, once, the first time they are all there; empty before and after.
  push(chunk: string): string[] {
    if (this.done) return [];
    this.text += chunk;
    const actions = this.text.indexOf('"actions"');
    if (actions < 0) return [];
    // No action at all: what follows is `confirm`, which is only asked.
    if (/^"actions"\s*:\s*\[\s*\]/.test(this.text.slice(actions))) {
      this.done = true;
      return [];
    }
    const type = /"type"\s*:\s*"([a-z_]+)"/.exec(this.text.slice(actions));
    if (!type) return [];
    const rest = this.text.slice(actions + type.index);
    if (type[1] === 'find_place') {
      const query = PlacePeek.value(rest, 'query');
      if (query === undefined) return [];
      this.done = true;
      return query.split('、').map((name) => name.trim()).filter(Boolean).slice(0, 3);
    }
    if (type[1] !== 'plan_trip') {
      this.done = true;
      return [];
    }
    const destination = PlacePeek.value(rest, 'destination'), origin = PlacePeek.value(rest, 'origin');
    if (destination === undefined || origin === undefined) return [];
    this.done = true;
    return [destination, origin].map((name) => name.trim()).filter(Boolean);
  }

  /// The string value of `key` once its closing quote has arrived.
  private static value(text: string, key: string): string | undefined {
    const match = new RegExp(`"${key}"\\s*:\\s*"((?:[^"\\\\]|\\\\.)*)"`).exec(text);
    if (!match) return undefined;
    try {
      return JSON.parse(`"${match[1]}"`);
    } catch {
      return undefined;
    }
  }
}
