// Node-only harness: node --test browser/game-music-test.mjs
import {strict as assert} from 'node:assert';
import {readFile} from 'node:fs/promises';
import {test} from 'node:test';
import {setImmediate} from 'node:timers/promises';
import vm from 'node:vm';

const source = await readFile(new URL('./game-music.js', import.meta.url), 'utf8');
const rewardWav = await readFile(new URL('../assets/sfx/reward.wav', import.meta.url));
const paths = new Map([[1, 'assets/music/media/cozy-1.ogg'], [2, 'assets/music/media/cozy-2.ogg']]);

function setup(AudioContext) {
  const tracks = [];
  const requests = [];
  const listeners = new Map();
  const window = {
    AudioContext,
    addEventListener(type, listener, capture) {
      assert.equal(capture, true);
      assert.ok(!listeners.has(type));
      listeners.set(type, listener);
    },
    removeEventListener(type, listener, capture) {
      assert.equal(capture, true);
      assert.equal(listeners.get(type), listener);
      listeners.delete(type);
    },
  };
  class Audio {
    constructor() {
      assert.equal(arguments.length, 0);
      this.paused = true;
      this.src = null;
      this.plays = [];
      this.pauses = 0;
      this.resets = 0;
      tracks.push(this);
    }
    set src(path) {
      if (path !== null) {
        assert.ok(tracks.every(track => track === this || (track.src === null && track.paused)));
        requests.push(path);
      }
      this.path = path;
    }
    get src() { return this.path; }
    play() {
      this.paused = false;
      return new Promise((resolve, reject) => this.plays.push({resolve, reject}));
    }
    async rejectPlay(name, index = this.plays.length - 1) {
      if (index === this.plays.length - 1) this.paused = true;
      this.plays[index].reject({name});
    }
    pause() {
      this.pauses++;
      this.paused = true;
    }
    removeAttribute(name) {
      assert.equal(name, 'src');
      this.src = null;
    }
    load() {
      assert.equal(this.src, null);
      this.resets++;
    }
  }

  const library = {};
  const HEAPU8 = new Uint8Array(1 + rewardWav.length);
  HEAPU8.set(rewardWav, 1);
  const context = vm.createContext({LibraryManager: {library}, mergeInto: Object.assign,
    UTF8ToString: ptr => paths.get(ptr), Audio, window, HEAPU8});
  vm.runInContext(source, context);
  context.haystackMusic = library.$haystackMusic;
  context.haystackRewardAudio = library.$haystackRewardAudio;
  return {
    tracks, requests, listeners,
    load: library.haystack_music_load,
    enable: library.haystack_music_set_enabled,
    status: library.haystack_music_status,
    close: library.haystack_music_close,
    reward: library.haystack_reward_audio,
    gesture(type, properties = {}) { listeners.get(type)?.({type, isTrusted: true, ...properties}); },
  };
}

test('register sound unlocks on a trusted gesture and plays the same WAV at two volumes', async () => {
  const plays = [];
  const decoded = {};
  let opened = 0, closed = 0, decodes = 0;
  class Context {
    state = 'suspended';
    constructor() { opened++; }
    async resume() { this.state = 'running'; }
    async close() { closed++; }
    async decodeAudioData(data) {
      assert.deepEqual(Buffer.from(data), rewardWav);
      decodes++;
      return decoded;
    }
    createGain() { return {gain: {}, connect() {}}; }
    createBufferSource() {
      return {connect(node) { this.node = node; }, start() { plays.push([this.buffer, this.node.gain.value]); }};
    }
  }
  const h = setup(Context);
  h.reward(1, 1, rewardWav.length);
  h.gesture('click', {isTrusted: false});
  h.reward(2);
  assert.equal(opened, 0);
  h.gesture('click');
  h.gesture('keydown');
  assert.equal(decodes, 1);
  assert.deepEqual(plays, []);
  h.reward(2, 0, 0, 1);
  h.reward(2, 0, 0, 0.35);
  await setImmediate();
  assert.deepEqual(plays, [[decoded, 1], [decoded, 0.35]]);
  h.reward(2);
  h.reward(0);
  await setImmediate();
  assert.equal(plays.length, 2);
  assert.equal(closed, 1);
  assert.equal(h.listeners.size, 0);
});

function assertReleased(audio) {
  assert.equal(audio.paused, true);
  assert.equal(audio.src, null);
  assert.equal(audio.onended, null);
  assert.equal(audio.onerror, null);
  assert.equal(audio.resets, 1);
}

test('lazy loading, idempotent gating, and cleanup', () => {
  const h = setup();
  h.enable(1);
  h.enable(0);
  h.close();
  assert.equal(h.status(), 0);
  assert.equal(h.tracks.length, 0);
  assert.deepEqual(h.requests, []);
  assert.equal(h.listeners.size, 0);

  h.load(1);
  const [audio] = h.tracks;
  assert.equal(audio.volume, 0.0875);
  assert.equal(audio.plays.length, 1);
  h.enable(1);
  h.enable(0);
  h.enable(0);
  assert.equal(audio.pauses, 1);
  assert.equal(audio.paused, true);
  h.enable(-1);
  h.enable(1);
  assert.equal(audio.plays.length, 2);
  assert.equal(audio.paused, false);
  assert.equal(h.tracks.length, 1);
  assert.deepEqual(h.requests, [paths.get(1)]);

  h.close();
  h.close();
  assertReleased(audio);
  assert.equal(h.status(), 0);
});

test('ended, media error, and fatal play rejection reach Zig without advancing', async () => {
  const h = setup();
  h.load(1);
  const [first] = h.tracks;
  first.plays[0].resolve();
  assert.equal(h.status(), 0);
  first.onended();
  assert.equal(h.status(), 1);
  h.enable(0);
  h.enable(1);
  assert.equal(first.plays.length, 1);
  assert.deepEqual(h.requests, [paths.get(1)]);

  h.load(2);
  const second = h.tracks[1];
  assertReleased(first);
  assert.equal(h.status(), 0);
  second.onerror();
  assert.equal(h.status(), 2);
  second.onended();
  assert.equal(h.status(), 2);

  h.load(1);
  await h.tracks[2].rejectPlay('NotSupportedError');
  assert.equal(h.status(), 2);
  assert.equal(h.listeners.size, 0);
  assert.deepEqual(h.requests, [paths.get(1), paths.get(2), paths.get(1)]);
  h.close();
});

test('autoplay denial retries on trusted activation, never on frames or while paused', async () => {
  const h = setup();
  h.load(1);
  const [audio] = h.tracks;
  await audio.rejectPlay('NotAllowedError');
  assert.equal(h.status(), 0);
  h.enable(1);
  h.gesture('click', {isTrusted: false});
  h.gesture('pointerdown', {pointerType: 'touch'});
  assert.equal(audio.plays.length, 1);
  h.gesture('pointerup', {pointerType: 'touch'});
  assert.equal(audio.plays.length, 2);
  assert.equal(h.listeners.size, 0);

  await audio.rejectPlay('NotAllowedError');
  const staleGesture = h.listeners.get('keydown');
  h.enable(0);
  assert.equal(h.listeners.size, 0);
  staleGesture({type: 'keydown', isTrusted: true});
  assert.equal(audio.plays.length, 2);
  h.enable(1);
  await audio.rejectPlay('NotAllowedError');
  staleGesture({type: 'keydown', isTrusted: true});
  assert.equal(audio.plays.length, 3);
  h.gesture('pointerdown', {pointerType: 'mouse'});
  assert.equal(audio.plays.length, 4);
  audio.plays[3].resolve();
  assert.equal(h.status(), 0);
  assert.equal(h.listeners.size, 0);
  assert.deepEqual(h.requests, [paths.get(1)]);

  h.enable(0);
  h.enable(1);
  await audio.rejectPlay('NotAllowedError');
  assert.ok(h.listeners.size > 0);
  h.close();
  assert.equal(h.listeners.size, 0);
  assertReleased(audio);
});

test('late rejections and media callbacks cannot affect newer playback', async () => {
  const h = setup();
  h.load(1);
  const [first] = h.tracks;
  h.enable(0);
  h.enable(1);
  await first.rejectPlay('NotAllowedError', 0);
  assert.equal(h.listeners.size, 0);
  assert.equal(h.status(), 0);
  assert.equal(first.paused, false);

  const staleError = first.onerror;
  const staleEnd = first.onended;
  h.load(2);
  const second = h.tracks[1];
  staleError();
  staleEnd();
  await first.rejectPlay('AbortError');
  assert.equal(h.status(), 0);
  assert.equal(second.paused, false);
  assert.equal(second.plays.length, 1);
  h.close();
  await second.rejectPlay('NotAllowedError');
  assert.equal(h.status(), 0);
  assert.equal(h.listeners.size, 0);
});
