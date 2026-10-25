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
