const std = @import("std");
const builtin = @import("builtin");
const rl = @import("raylib");
const tracks = @import("soundtrack_tracks.zig").paths;
const CutCues = @import("cut_feedback.zig").Cues;

const Status = enum { active, ended, failed };

pub const Soundtrack = Player(if (builtin.os.tag == .emscripten) Browser else Desktop);

fn Player(comptime Backend: type) type {
    return struct {
        const Self = @This();
        backend: Backend,
        next: usize = 0,
        failures: usize = 0,
        active: bool = false,
        paused: bool = false,
        was_enabled: bool = true,

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{ .backend = Backend.init(allocator) };
        }

        /// Returns whether the playlist is unavailable after trying each track.
        pub fn update(self: *Self, enabled: bool, controls_available: bool) bool {
            if (enabled and !self.was_enabled) self.failures = 0;
            self.was_enabled = enabled;
            const should_pause = !enabled or !controls_available;
            if (self.active and self.paused != should_pause) {
                self.backend.setEnabled(!should_pause);
                self.paused = should_pause;
            }
            if (should_pause) return self.failures == tracks.len;

            if (self.active) {
                switch (self.backend.status()) {
                    .active => return false,
                    .ended => self.failures = 0,
                    .failed => self.failures += 1,
                }
                self.backend.closeTrack();
                self.active = false;
            }

            while (self.failures < tracks.len) : (self.failures += 1) {
                const path = tracks[self.next];
                self.next = (self.next + 1) % tracks.len;
                if (self.backend.load(path)) {
                    self.active = true;
                    self.paused = false;
                    return false;
                }
            }
            return true;
        }

        pub fn playCutCues(self: *Self, cues: CutCues) void {
            self.backend.playCutCues(cues);
        }

        pub fn deinit(self: *Self) void {
            self.backend.deinit();
        }
    };
}

const Desktop = struct {
    allocator: std.mem.Allocator,
    stream: ?rl.Music = null,
    snip: CueSound = .{},
    fail: CueSound = .{},

    fn init(allocator: std.mem.Allocator) Desktop {
        return .{ .allocator = allocator };
    }

    fn load(self: *Desktop, path: [:0]const u8) bool {
        if (!rl.isAudioDeviceReady()) rl.initAudioDevice();
        if (!rl.isAudioDeviceReady()) return false;

        const full_path = std.fs.path.joinZ(self.allocator, &.{ rl.getApplicationDirectory(), path }) catch return false;
        defer self.allocator.free(full_path);
        var music = rl.loadMusicStream(full_path) catch return false;
        music.looping = false;
        rl.setMusicVolume(music, 0.35);
        rl.playMusicStream(music);
        rl.updateMusicStream(music);
        self.stream = music;
        return true;
    }

    fn setEnabled(self: *Desktop, enabled: bool) void {
        if (enabled) rl.resumeMusicStream(self.stream.?) else rl.pauseMusicStream(self.stream.?);
    }

    fn status(self: *Desktop) Status {
        const music = self.stream.?;
        rl.updateMusicStream(music);
        return if (rl.isMusicStreamPlaying(music)) .active else .ended;
    }

    fn closeTrack(self: *Desktop) void {
        if (self.stream) |music| rl.unloadMusicStream(music);
        self.stream = null;
    }

    fn playCutCues(self: *Desktop, cues: CutCues) void {
        if (!cues.snip and !cues.fail) return;
        if (!rl.isAudioDeviceReady()) rl.initAudioDevice();
        if (!rl.isAudioDeviceReady()) return;
        if (cues.snip) self.snip.play(@embedFile("cut_audio_assets/snip.wav"), 0.8);
        if (cues.fail) self.fail.play(@embedFile("cut_audio_assets/fail.wav"), 0.25);
    }

    fn deinit(self: *Desktop) void {
        self.closeTrack();
        self.snip.unload();
        self.fail.unload();
        if (rl.isAudioDeviceReady()) rl.closeAudioDevice();
    }
};

const CueSound = struct {
    sound: ?rl.Sound = null,
    attempted: bool = false,

    fn play(self: *CueSound, wav: []const u8, volume: f32) void {
        if (!self.attempted) {
            self.attempted = true;
            const wave = rl.loadWaveFromMemory(".wav", wav) catch return;
            defer rl.unloadWave(wave);
            const sound = rl.loadSoundFromWave(wave);
            if (!rl.isSoundValid(sound)) return;
            rl.setSoundVolume(sound, volume);
            self.sound = sound;
        }
        if (self.sound) |sound| rl.playSound(sound);
    }

    fn unload(self: *CueSound) void {
        if (self.sound) |sound| rl.unloadSound(sound);
    }
};

const Browser = struct {
    extern "c" fn haystack_music_load(path: [*:0]const u8) void;
    extern "c" fn haystack_music_set_enabled(enabled: c_int) void;
    extern "c" fn haystack_music_status() c_int;
    extern "c" fn haystack_music_close() void;

    fn init(_: std.mem.Allocator) Browser {
        return .{};
    }

    fn load(_: *Browser, path: [:0]const u8) bool {
        haystack_music_load(path.ptr);
        return true; // Browser errors arrive asynchronously through status().
    }

    fn setEnabled(_: *Browser, enabled: bool) void {
        haystack_music_set_enabled(@intFromBool(enabled));
    }

    fn status(_: *Browser) Status {
        return switch (haystack_music_status()) {
            1 => .ended,
            2 => .failed,
            else => .active,
        };
    }

    fn closeTrack(_: *Browser) void {
        haystack_music_close();
    }

    // No WebAudio integration yet; visuals and refill notice still run.
    fn playCutCues(_: *Browser, _: CutCues) void {}

    fn deinit(self: *Browser) void {
        self.closeTrack();
    }
};

test "soundtrack waits for controls, pauses, and retries after exhausting the playlist" {
    const Fake = struct {
        loads: usize = 0,
        enabled: bool = false,
        result: Status = .active,
        fn init(_: std.mem.Allocator) @This() {
            return .{};
        }
        fn load(self: *@This(), _: [:0]const u8) bool {
            self.loads += 1;
            self.enabled = true;
            return true;
        }
        fn setEnabled(self: *@This(), enabled: bool) void {
            self.enabled = enabled;
        }
        fn status(self: *@This()) Status {
            return self.result;
        }
        fn closeTrack(self: *@This()) void {
            self.enabled = false;
        }
    };
    var music = Player(Fake).init(std.testing.allocator);
    try std.testing.expect(!music.update(true, false));
    try std.testing.expectEqual(0, music.backend.loads);
    try std.testing.expect(!music.update(true, true));
    try std.testing.expect(!music.update(true, false));
    try std.testing.expect(!music.backend.enabled);
    try std.testing.expect(!music.update(true, true));
    try std.testing.expect(music.backend.enabled);
    try std.testing.expect(!music.update(false, true));
    try std.testing.expect(!music.backend.enabled);
    try std.testing.expect(!music.update(true, true));
    try std.testing.expect(music.backend.enabled);
    try std.testing.expectEqual(1, music.backend.loads);

    music.backend.result = .failed;
    for (1..tracks.len) |_| try std.testing.expect(!music.update(true, true));
    try std.testing.expect(music.update(true, true));
    try std.testing.expect(music.update(true, true));
    try std.testing.expectEqual(tracks.len, music.backend.loads);
    try std.testing.expect(music.update(false, true));
    try std.testing.expect(!music.update(true, true));
    try std.testing.expectEqual(tracks.len + 1, music.backend.loads);
}
