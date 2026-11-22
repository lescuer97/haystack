// Browser-only playback. Zig owns gating and playlist advancement.
mergeInto(LibraryManager.library, {
  $haystackMusic: {
    track: null,
    gestureEvents: ['pointerdown', 'pointerup', 'keydown', 'click'],

    load: function (path) {
      this.close();
      var self = this;
      var track = this.track = {audio: null, enabled: true, status: 0, attempt: 0, gesture: null};
      try {
        var audio = track.audio = new Audio();
        audio.volume = 0.35;
        audio.onended = function () { self.finish(track, 1); };
        audio.onerror = function () { self.finish(track, 2); };
        audio.src = path;
        this.play(track);
      } catch (_) {
        this.finish(track, 2);
      }
    },

    setEnabled: function (enabled) {
      var track = this.track;
      if (!track || track.enabled === enabled || track.status !== 0) return;
      track.enabled = enabled;
      if (enabled) {
        this.play(track);
      } else {
        // A pending play() may reject after pause(), even after a later resume.
        ++track.attempt;
        this.stopGestureRetry(track);
        track.audio.pause();
      }
    },

    play: function (track) {
      if (this.track !== track || !track.enabled || track.status !== 0) return;
      this.stopGestureRetry(track);
      var self = this;
      var attempt = ++track.attempt;
      function rejected(error) {
        if (self.track !== track || !track.enabled || track.status !== 0 || track.attempt !== attempt) return;
        if (error && error.name === 'NotAllowedError') self.waitForGesture(track);
        else self.finish(track, 2);
      }
      try {
        var pending = track.audio.play();
        if (pending) pending.catch(rejected);
      } catch (error) {
        rejected(error);
      }
    },

    waitForGesture: function (track) {
      var self = this;
      var retry = track.gesture = function (event) {
        if (!event.isTrusted || track.gesture !== retry) return;
        // Mouse activates on pointerdown; touch and pen activate on pointerup.
        if (event.type === 'pointerdown' && event.pointerType !== 'mouse') return;
        if (event.type === 'pointerup' && event.pointerType === 'mouse') return;
        self.play(track);
      };
      for (var type of this.gestureEvents) window.addEventListener(type, retry, true);
    },

    stopGestureRetry: function (track) {
      if (!track.gesture) return;
      for (var type of this.gestureEvents) window.removeEventListener(type, track.gesture, true);
      track.gesture = null;
    },

    finish: function (track, status) {
      if (this.track !== track || track.status !== 0) return;
      track.status = status;
      this.stopGestureRetry(track);
    },

    close: function () {
      var track = this.track;
      if (!track) return;
      this.track = null;
      this.stopGestureRetry(track);
      var audio = track.audio;
      if (!audio) return;
      audio.onended = audio.onerror = null;
      audio.pause();
      audio.removeAttribute('src');
      // Reset the element and abort any in-flight fetch without selecting a URL.
      audio.load();
    },
  },

  haystack_music_load__deps: ['$haystackMusic', '$UTF8ToString'],
  haystack_music_load__sig: 'vi',
  haystack_music_load: function (path) { haystackMusic.load(UTF8ToString(path)); },
  haystack_music_set_enabled__deps: ['$haystackMusic'],
  haystack_music_set_enabled__sig: 'vi',
  haystack_music_set_enabled: function (enabled) { haystackMusic.setEnabled(enabled !== 0); },
  haystack_music_status__deps: ['$haystackMusic'],
  haystack_music_status__sig: 'i',
  haystack_music_status: function () { return haystackMusic.track ? haystackMusic.track.status : 0; },
  haystack_music_close__deps: ['$haystackMusic'],
  haystack_music_close__sig: 'v',
  haystack_music_close: function () { haystackMusic.close(); },
});
