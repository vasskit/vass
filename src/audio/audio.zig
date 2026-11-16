//! Audio: decoded sounds in memory, mixed playback with several voices, microphone
//! recording, and the helpers around them (peaks for waveforms, WAV encoding).
//! Built on SDL3 audio streams; the format code is in `audio_pcm.zig` and the mixer
//! in `audio_mixer.zig`, both pure and unit-tested without a device.
//!
//!     var audio = vass.audio.Audio.init(gpa, .{});   // opens nothing yet
//!     defer audio.deinit();                            // declare it after the Window
//!     const click = try audio.loadSound(@embedFile("click.wav"));
//!     const v = try audio.play(click, .{ .volume = 0.8 });
//!     audio.pause(v); audio.seek(v, 0.5); audio.resumeVoice(v);
//!
//! **Devices.** Nothing is opened until it is needed: the playback device on the first
//! `play`, the recording device on `startRecording`. An app that never uses audio never
//! touches CoreAudio (and the decoders are dropped by the linker).
//!
//! **Threads.** SDL calls a callback on its own audio thread whenever the device wants
//! more playback data. That callback (and nothing else of ours) runs there: it takes a
//! short spin lock, renders the mixer into a small stack buffer, releases the lock and
//! hands the buffer to SDL. It never allocates, never frees, never calls back into the app.
//! Every public function runs on the caller's (UI) thread and takes the same lock for the
//! few instructions it needs, so a voice operation is never torn and `position()` is
//! consistent. Sounds are owned by the `Audio` (handles, like `Image`s), not by voices;
//! `unloadSound` first stops the sound's voices under the lock, so the audio thread can
//! never read freed memory, and finished voices free their own slot on the audio thread
//! (there is nothing to reap or leak). Recording is polled, not called back: SDL buffers
//! the microphone in a thread-safe queue and the UI thread drains it whenever it calls
//! `level`, `recordingSeconds`, `update` or `stopRecording`, so the audio thread never
//! touches the recording buffer and a stalled UI loses no data.
//!
//! **Latency.** SDL queues about one device buffer (1024 frames, 21 ms at 48 kHz) ahead of the
//! speakers. `position()` is the mixer's read position, so it runs ahead of what you hear
//! by that much plus the hardware latency: fine for a progress bar, not for lip-sync.
const std = @import("std");
const builtin = @import("builtin");
const pcm_mod = @import("audio_pcm.zig");
const mixer_mod = @import("audio_mixer.zig");
const macos = @import("../platform/macos.zig");

pub const Pcm = pcm_mod.Pcm;
pub const DecodeError = pcm_mod.Error;
pub const WavFormat = pcm_mod.WavFormat;
pub const decodeWav = pcm_mod.decodeWav;
pub const decodeOgg = pcm_mod.decodeOgg;
pub const decodeMp3 = pcm_mod.decodeMp3;
pub const decode = pcm_mod.decode;
pub const encodeWav = pcm_mod.encodeWav;
pub const peaks = pcm_mod.peaks;
pub const isAudioName = pcm_mod.isAudioName;
pub const levelStep = pcm_mod.levelStep;
pub const meterScale = pcm_mod.meterScale;
pub const volumeGain = pcm_mod.volumeGain;
pub const max_voices = mixer_mod.max_voices;

const sdl = struct {
    const AudioStream = opaque {};
    const AudioSpec = extern struct { format: u32, channels: c_int, freq: c_int };
    const StreamCallback = *const fn (userdata: ?*anyopaque, stream: *AudioStream, additional: c_int, total: c_int) callconv(.c) void;
    const INIT_AUDIO: u32 = 0x10;
    const AUDIO_F32: u32 = 0x8120;
    const DEVICE_DEFAULT_PLAYBACK: u32 = 0xFFFFFFFF;
    const DEVICE_DEFAULT_RECORDING: u32 = 0xFFFFFFFE;

    extern fn SDL_InitSubSystem(flags: u32) bool;
    extern fn SDL_QuitSubSystem(flags: u32) void;
    extern fn SDL_GetError() [*:0]const u8;
    extern fn SDL_SetHint(name: [*:0]const u8, value: [*:0]const u8) bool;
    extern fn SDL_ResetHint(name: [*:0]const u8) bool;
    extern fn SDL_GetTicks() u64;
    extern fn SDL_Delay(ms: u32) void;
    extern fn SDL_OpenAudioDeviceStream(devid: u32, spec: *const AudioSpec, cb: ?StreamCallback, userdata: ?*anyopaque) ?*AudioStream;
    extern fn SDL_DestroyAudioStream(s: *AudioStream) void;
    extern fn SDL_ResumeAudioStreamDevice(s: *AudioStream) bool;
    extern fn SDL_PauseAudioStreamDevice(s: *AudioStream) bool;
    extern fn SDL_PutAudioStreamData(s: *AudioStream, buf: *const anyopaque, len: c_int) bool;
    extern fn SDL_GetAudioStreamData(s: *AudioStream, buf: *anyopaque, len: c_int) c_int;
    extern fn SDL_GetAudioStreamAvailable(s: *AudioStream) c_int;
    extern fn SDL_GetCurrentAudioDriver() ?[*:0]const u8;
    const PathInfo = extern struct { kind: c_int, size: u64, create_time: i64, modify_time: i64, access_time: i64 };
    const PATHTYPE_FILE: c_int = 1;
    extern fn SDL_GetPathInfo(path: [*:0]const u8, info: *PathInfo) bool;
    extern fn SDL_LoadFile(file: [*:0]const u8, datasize: *usize) ?*anyopaque;
    extern fn SDL_SaveFile(file: [*:0]const u8, data: *const anyopaque, datasize: usize) bool;
    extern fn SDL_free(p: ?*anyopaque) void;
};

/// A sound held by an `Audio`. A small copyable handle; `Audio.unloadSound` frees it and
/// every copy then goes stale (and every operation on a stale one is a harmless no-op).
pub const Sound = struct {
    id: u32 = 0,

    pub const none: Sound = .{};
};

/// One playing instance of a sound; see `Audio.play`. Stale (inert) once it has ended or
/// been stopped.
pub const Voice = mixer_mod.Handle;
pub const VoiceState = mixer_mod.State;

pub const PlayOpts = struct {
    /// Linear gain, 0..1 for the usual range (clamped to 0..4).
    volume: f32 = 1,
    /// Restart from the beginning at the end, until stopped.
    loop: bool = false,
    /// Where to begin, in seconds.
    start: f32 = 0,
};

pub const RecordOpts = struct {
    /// Samples per second asked of the microphone (the device is resampled to it).
    sample_rate: u32 = 44100,
    /// 1 or 2.
    channels: u8 = 1,
    /// Recording stops collecting after this many seconds (`recordingState` then says so).
    max_seconds: f32 = 300,
};

pub const Options = struct {
    /// Force an SDL audio driver by name ("dummy" for no output at all: tests and
    /// screenshots). Default: the platform's (CoreAudio on macOS). The SDL_AUDIO_DRIVER
    /// environment variable also works.
    driver: ?[:0]const u8 = null,
};

pub const PlayError = error{
    /// No usable output device (or SDL audio failed to start).
    NoDevice,
    /// The sound handle is stale or empty.
    InvalidSound,
    /// All `max_voices` voices are busy.
    TooManyVoices,
};

pub const RecordError = error{
    /// No usable input device.
    NoDevice,
    /// macOS says the user denied (or policy forbids) microphone access.
    PermissionDenied,
    AlreadyRecording,
    OutOfMemory,
};

pub const StopRecordError = error{
    NotRecording,
    /// Nothing was captured (the device never delivered a sample).
    EmptyRecording,
    OutOfMemory,
};

pub const LoadError = DecodeError || error{ FileReadFailed, FileTooLarge };
pub const SaveError = DecodeError || error{ InvalidSound, FileWriteFailed };

pub const RecordingState = enum {
    idle,
    recording,
    /// `max_seconds` was reached: no more audio is kept. Call `stopRecording` to take it.
    limit_reached,
};

/// Microphone permission as macOS reports it. `unknown` where it cannot be asked.
pub const MicPermission = enum { unknown, not_determined, denied, granted };

/// State shared with the audio thread. Heap-allocated so its address is stable.
const Shared = struct {
    lock: std.atomic.Mutex = .unlocked,
    mixer: mixer_mod.Mixer,

    fn acquire(s: *Shared) void {
        while (!s.lock.tryLock()) std.atomic.spinLoopHint();
    }

    fn release(s: *Shared) void {
        s.lock.unlock();
    }
};

const out_rate: u32 = 48000;
const out_channels = 2;
/// Frames rendered per lock hold in the audio callback.
const render_chunk = 512;
const idle_pause_ms: u64 = 2000;

fn playbackCallback(userdata: ?*anyopaque, stream: *sdl.AudioStream, additional: c_int, _: c_int) callconv(.c) void {
    const sh: *Shared = @ptrCast(@alignCast(userdata.?));
    var remaining: usize = if (additional > 0) @intCast(additional) else 0;
    var buf: [render_chunk * out_channels]f32 = undefined;
    const frame_bytes = out_channels * @sizeOf(f32);
    while (remaining >= frame_bytes) {
        const frames: usize = @min(remaining / frame_bytes, render_chunk);
        sh.acquire();
        sh.mixer.render(buf[0 .. frames * out_channels]);
        sh.release();
        if (!sdl.SDL_PutAudioStreamData(stream, &buf, @intCast(frames * frame_bytes))) return;
        remaining -= frames * frame_bytes;
    }
}

const Recording = struct {
    stream: *sdl.AudioStream,
    sample_rate: u32,
    channels: u8,
    max_frames: usize,
    samples: std.ArrayList(f32) = .empty,
    /// Peak of the most recent audio, decaying (see `pcm_mod.levelStep`).
    level: f32 = 0,
    /// Largest sample seen at all.
    peak: f32 = 0,
    limit: bool = false,
    last_pump_ms: u64,

    fn frames(r: *const Recording) usize {
        return r.samples.items.len / r.channels;
    }
};

/// Frames a recording may keep: `max_seconds` (at least 0.1; NaN counts as the floor), but
/// never more than a sound may hold. Infinity and absurd values mean "as much as allowed".
fn recordingCapFrames(max_seconds: f32, rate: u32, ch: u8) usize {
    const limit: usize = pcm_mod.max_bytes / @sizeOf(f32) / ch;
    const max_f: f64 = @as(f64, @max(max_seconds, 0.1)) * @as(f64, @floatFromInt(rate));
    if (max_f >= @as(f64, @floatFromInt(limit))) return limit;
    return @intFromFloat(max_f);
}

/// Largest audio file `loadSoundFile` reads.
const max_file_bytes = 256 * 1024 * 1024;

pub const Audio = struct {
    gpa: std.mem.Allocator,
    shared: *Shared,
    sounds: std.AutoHashMapUnmanaged(u32, Pcm) = .empty,
    next_id: u32 = 1,
    driver: ?[:0]const u8,
    sdl_ready: bool = false,
    play_stream: ?*sdl.AudioStream = null,
    play_running: bool = false,
    idle_since_ms: ?u64 = null,
    rec: ?Recording = null,

    /// Creates the audio context. Opens no device and does not start SDL audio yet. If the
    /// allocation fails the context is unusable: calls return `NoDevice`.
    pub fn init(gpa: std.mem.Allocator, opts: Options) Audio {
        const sh = gpa.create(Shared) catch return .{ .gpa = gpa, .shared = undefined, .driver = opts.driver, .next_id = 0 };
        sh.* = .{ .mixer = mixer_mod.Mixer.init(out_rate) };
        return .{ .gpa = gpa, .shared = sh, .driver = opts.driver };
    }

    /// Stops all sound, closes the devices and frees every sound.
    pub fn deinit(a: *Audio) void {
        if (a.next_id == 0) return; // init failed
        if (a.rec) |*r| {
            sdl.SDL_DestroyAudioStream(r.stream);
            r.samples.deinit(a.gpa);
            a.rec = null;
        }
        // Destroying the stream waits for a callback in progress and guarantees there is no
        // later one, so the mixer and the sounds can be freed after it.
        if (a.play_stream) |s| sdl.SDL_DestroyAudioStream(s);
        a.play_stream = null;
        var it = a.sounds.valueIterator();
        while (it.next()) |p| p.deinit(a.gpa);
        a.sounds.deinit(a.gpa);
        if (a.sdl_ready) sdl.SDL_QuitSubSystem(sdl.INIT_AUDIO);
        a.gpa.destroy(a.shared);
        a.* = undefined;
    }

    fn usable(a: *const Audio) bool {
        return a.next_id != 0;
    }

    fn ensureSdl(a: *Audio) error{NoDevice}!void {
        if (!a.usable()) return error.NoDevice;
        if (a.sdl_ready) return;
        if (a.driver) |d| _ = sdl.SDL_SetHint("SDL_AUDIO_DRIVER", d.ptr) else _ = sdl.SDL_ResetHint("SDL_AUDIO_DRIVER");
        // Small device buffers keep `position()` close to what is audible.
        _ = sdl.SDL_SetHint("SDL_AUDIO_DEVICE_SAMPLE_FRAMES", "1024");
        if (!sdl.SDL_InitSubSystem(sdl.INIT_AUDIO)) {
            std.log.warn("SDL audio init failed: {s}", .{sdl.SDL_GetError()});
            return error.NoDevice;
        }
        a.sdl_ready = true;
    }

    /// Name of the SDL audio driver in use ("coreaudio", "dummy", ...), once a device is open.
    pub fn driverName(a: *const Audio) ?[]const u8 {
        if (!a.sdl_ready) return null;
        const n = sdl.SDL_GetCurrentAudioDriver() orelse return null;
        return std.mem.span(n);
    }

    // ---- sounds ------------------------------------------------------------------------

    /// Takes ownership of `pcm` (allocated from this `Audio`'s allocator) as a sound.
    /// On failure the caller still owns it.
    pub fn soundFromPcm(a: *Audio, pcm: Pcm) !Sound {
        if (!a.usable()) return error.OutOfMemory;
        if (pcm.frames() == 0 or pcm.channels == 0 or pcm.channels > 2 or pcm.sample_rate == 0) return error.InvalidAudio;
        const id = a.next_id;
        try a.sounds.put(a.gpa, id, pcm);
        a.next_id +%= 1;
        if (a.next_id == 0) a.next_id = 1;
        return .{ .id = id };
    }

    /// A sound from interleaved float samples (copied).
    pub fn soundFromSamples(a: *Audio, samples: []const f32, sample_rate: u32, channels: u8) (DecodeError)!Sound {
        const copy = try a.gpa.dupe(f32, samples);
        errdefer a.gpa.free(copy);
        return a.soundFromPcm(.{ .samples = copy, .sample_rate = sample_rate, .channels = channels }) catch |e| switch (e) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.InvalidAudio,
        };
    }

    /// Decodes WAV, OGG Vorbis or MP3 bytes (by content) into a sound.
    pub fn loadSound(a: *Audio, bytes: []const u8) DecodeError!Sound {
        const pcm = try decode(a.gpa, bytes);
        errdefer pcm.deinit(a.gpa);
        return a.soundFromPcm(pcm) catch |e| switch (e) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.InvalidAudio,
        };
    }

    /// Reads and decodes an audio file (at most 256 MB).
    pub fn loadSoundFile(a: *Audio, path: []const u8) LoadError!Sound {
        const z = a.gpa.dupeSentinel(u8, path, 0) catch return error.OutOfMemory;
        defer a.gpa.free(z);
        // Ask for the size first: `SDL_LoadFile` reads everything before it returns. Devices
        // and pipes report no size, so only regular files are read.
        var info: sdl.PathInfo = undefined;
        if (!sdl.SDL_GetPathInfo(z.ptr, &info) or info.kind != sdl.PATHTYPE_FILE) return error.FileReadFailed;
        if (info.size > max_file_bytes) return error.FileTooLarge;
        var size: usize = 0;
        const raw = sdl.SDL_LoadFile(z.ptr, &size) orelse return error.FileReadFailed;
        defer sdl.SDL_free(raw);
        if (size > max_file_bytes) return error.FileTooLarge; // it grew since the check
        return a.loadSound(@as([*]const u8, @ptrCast(raw))[0..size]);
    }

    /// Frees a sound; any voices playing it stop at once. A stale handle is ignored.
    pub fn unloadSound(a: *Audio, s: Sound) void {
        if (!a.usable()) return;
        const entry = a.sounds.fetchRemove(s.id) orelse return;
        a.shared.acquire();
        a.shared.mixer.stopSound(s.id);
        a.shared.release();
        entry.value.deinit(a.gpa);
    }

    pub fn hasSound(a: *const Audio, s: Sound) bool {
        return a.usable() and a.sounds.contains(s.id);
    }

    /// The sound's samples, borrowed: valid until it is unloaded.
    pub fn soundPcm(a: *const Audio, s: Sound) ?Pcm {
        if (!a.usable()) return null;
        return a.sounds.get(s.id);
    }

    /// Length in seconds, 0 for a stale handle.
    pub fn soundDuration(a: *const Audio, s: Sound) f32 {
        const p = a.soundPcm(s) orelse return 0;
        return @floatCast(p.duration());
    }

    /// `n` waveform values in 0..1 (see `peaks`); null for a stale handle. Caller frees.
    pub fn soundPeaks(a: *const Audio, gpa: std.mem.Allocator, s: Sound, n: usize) error{OutOfMemory}!?[]f32 {
        const p = a.soundPcm(s) orelse return null;
        return try peaks(gpa, p, n);
    }

    /// The sound as a 16-bit WAV file. Caller frees.
    pub fn soundWav(a: *const Audio, gpa: std.mem.Allocator, s: Sound) SaveError![]u8 {
        const p = a.soundPcm(s) orelse return error.InvalidSound;
        return encodeWav(gpa, p, .pcm16);
    }

    /// Writes the sound to `path` as a 16-bit WAV file.
    pub fn saveWav(a: *const Audio, s: Sound, path: []const u8) SaveError!void {
        const bytes = try a.soundWav(a.gpa, s);
        defer a.gpa.free(bytes);
        const z = a.gpa.dupeSentinel(u8, path, 0) catch return error.OutOfMemory;
        defer a.gpa.free(z);
        if (!sdl.SDL_SaveFile(z.ptr, bytes.ptr, bytes.len)) return error.FileWriteFailed;
    }

    // ---- playback ----------------------------------------------------------------------

    fn ensurePlayback(a: *Audio) error{NoDevice}!void {
        try a.ensureSdl();
        if (a.play_stream == null) {
            const spec: sdl.AudioSpec = .{ .format = sdl.AUDIO_F32, .channels = out_channels, .freq = out_rate };
            const st = sdl.SDL_OpenAudioDeviceStream(sdl.DEVICE_DEFAULT_PLAYBACK, &spec, playbackCallback, a.shared) orelse {
                std.log.warn("opening the playback device failed: {s}", .{sdl.SDL_GetError()});
                return error.NoDevice;
            };
            a.play_stream = st;
            a.play_running = false;
        }
        if (!a.play_running) {
            if (!sdl.SDL_ResumeAudioStreamDevice(a.play_stream.?)) return error.NoDevice;
            a.play_running = true;
        }
        a.idle_since_ms = null;
    }

    /// Starts playing `s`. Several voices play at once (up to `max_voices`); the first call
    /// opens the default output device.
    pub fn play(a: *Audio, s: Sound, opts: PlayOpts) PlayError!Voice {
        const p = a.soundPcm(s) orelse return error.InvalidSound;
        try a.ensurePlayback();
        a.shared.acquire();
        defer a.shared.release();
        return a.shared.mixer.start(s.id, p.samples, p.channels, p.sample_rate, volumeGain(opts.volume), opts.loop, opts.start) orelse error.TooManyVoices;
    }

    fn withVoice(a: *Audio) *mixer_mod.Mixer {
        return &a.shared.mixer;
    }

    pub fn pause(a: *Audio, v: Voice) void {
        if (!a.usable()) return;
        a.shared.acquire();
        defer a.shared.release();
        a.withVoice().pause(v);
    }

    pub fn resumeVoice(a: *Audio, v: Voice) void {
        if (!a.usable()) return;
        a.ensurePlayback() catch return;
        a.shared.acquire();
        defer a.shared.release();
        a.withVoice().resumeVoice(v);
    }

    /// Ends the voice (with a few ms of fade-out); the handle is stale at once.
    pub fn stop(a: *Audio, v: Voice) void {
        if (!a.usable()) return;
        a.shared.acquire();
        defer a.shared.release();
        a.withVoice().stop(v);
    }

    pub fn stopAll(a: *Audio) void {
        if (!a.usable()) return;
        a.shared.acquire();
        defer a.shared.release();
        a.withVoice().stopAll();
    }

    pub fn setVolume(a: *Audio, v: Voice, volume: f32) void {
        if (!a.usable()) return;
        a.shared.acquire();
        defer a.shared.release();
        a.withVoice().setVolume(v, volume);
    }

    /// Jumps to `seconds` into the sound (clamped; wraps for a looping voice).
    pub fn seek(a: *Audio, v: Voice, seconds: f32) void {
        if (!a.usable()) return;
        a.shared.acquire();
        defer a.shared.release();
        a.withVoice().seek(v, seconds);
    }

    /// Seconds into the sound; 0 for a stale handle.
    pub fn position(a: *Audio, v: Voice) f32 {
        if (!a.usable()) return 0;
        a.shared.acquire();
        defer a.shared.release();
        return a.withVoice().position(v);
    }

    /// Length of the voice's sound in seconds; 0 for a stale handle.
    pub fn duration(a: *Audio, v: Voice) f32 {
        if (!a.usable()) return 0;
        a.shared.acquire();
        defer a.shared.release();
        return a.withVoice().duration(v);
    }

    /// `.playing`, `.paused`, or `.ended` (finished, stopped or never valid).
    pub fn voiceState(a: *Audio, v: Voice) VoiceState {
        if (!a.usable()) return .ended;
        a.shared.acquire();
        defer a.shared.release();
        return a.withVoice().state(v);
    }

    pub fn isPlaying(a: *Audio, v: Voice) bool {
        return a.voiceState(v) == .playing;
    }

    /// Master volume applied to everything (default 1).
    pub fn setMasterVolume(a: *Audio, v: f32) void {
        if (!a.usable()) return;
        a.shared.acquire();
        defer a.shared.release();
        a.shared.mixer.master = volumeGain(v);
    }

    pub fn masterVolume(a: *Audio) f32 {
        if (!a.usable()) return 1;
        a.shared.acquire();
        defer a.shared.release();
        return a.shared.mixer.master;
    }

    // ---- housekeeping ------------------------------------------------------------------

    /// True while something changes by itself: a sound is playing (not paused) or the
    /// microphone is recording. An app that redraws only on input should keep drawing
    /// frames (progress bars, meters) while this is true.
    pub fn busy(a: *Audio) bool {
        if (!a.usable()) return false;
        if (a.rec != null) return true;
        a.shared.acquire();
        defer a.shared.release();
        return a.shared.mixer.anyAudible();
    }

    /// Voices that are playing or paused right now.
    pub fn activeVoices(a: *Audio) usize {
        if (!a.usable()) return 0;
        a.shared.acquire();
        defer a.shared.release();
        return a.shared.mixer.activeCount();
    }

    /// Per-frame housekeeping, optional: drains the microphone (so `level` and
    /// `recordingSeconds` are fresh) and pauses the idle output device after two seconds
    /// without sound (it restarts by itself on the next `play`).
    pub fn update(a: *Audio) void {
        if (!a.usable()) return;
        a.pumpRecording();
        if (a.play_stream) |st| {
            if (a.play_running) {
                if (a.busy_playback()) {
                    a.idle_since_ms = null;
                } else {
                    const now = sdl.SDL_GetTicks();
                    const since = a.idle_since_ms orelse blk: {
                        a.idle_since_ms = now;
                        break :blk now;
                    };
                    if (now -| since > idle_pause_ms) {
                        _ = sdl.SDL_PauseAudioStreamDevice(st);
                        a.play_running = false;
                        a.idle_since_ms = null;
                    }
                }
            }
        }
    }

    fn busy_playback(a: *Audio) bool {
        a.shared.acquire();
        defer a.shared.release();
        return a.shared.mixer.anyAudible();
    }

    // ---- recording ---------------------------------------------------------------------

    /// macOS microphone authorisation. A bundled app needs `NSMicrophoneUsageDescription` in
    /// its Info.plist or macOS ends the process the moment it touches the microphone.
    pub fn microphonePermission() MicPermission {
        if (builtin.os.tag != .macos) return .unknown;
        const st = macos.microphoneStatus() orelse return .unknown;
        return switch (st) {
            0 => .not_determined,
            1, 2 => .denied,
            3 => .granted,
            else => .unknown,
        };
    }

    /// Opens the default input device and starts keeping what it hears. The first time on
    /// macOS this makes the OS ask for permission; until the user answers, no samples
    /// arrive. Errors are distinct and non-fatal: no device, permission denied (when macOS
    /// says so up front), already recording.
    pub fn startRecording(a: *Audio, opts: RecordOpts) RecordError!void {
        if (!a.usable()) return error.NoDevice;
        if (a.rec != null) return error.AlreadyRecording;
        const ch: u8 = std.math.clamp(opts.channels, 1, 2);
        const rate: u32 = std.math.clamp(opts.sample_rate, 8000, 96000);
        try a.ensureSdl();
        // Only the real macOS driver is subject to the microphone permission.
        if (std.mem.eql(u8, a.driverName() orelse "", "coreaudio") and microphonePermission() == .denied) return error.PermissionDenied;
        const spec: sdl.AudioSpec = .{ .format = sdl.AUDIO_F32, .channels = ch, .freq = @intCast(rate) };
        const st = sdl.SDL_OpenAudioDeviceStream(sdl.DEVICE_DEFAULT_RECORDING, &spec, null, null) orelse {
            std.log.warn("opening the recording device failed: {s}", .{sdl.SDL_GetError()});
            return error.NoDevice;
        };
        errdefer sdl.SDL_DestroyAudioStream(st);
        var list: std.ArrayList(f32) = .empty;
        // Room for the first second: the common short memo never reallocates.
        try list.ensureTotalCapacity(a.gpa, rate * ch);
        if (!sdl.SDL_ResumeAudioStreamDevice(st)) {
            list.deinit(a.gpa);
            return error.NoDevice;
        }
        const cap_frames = recordingCapFrames(opts.max_seconds, rate, ch);
        a.rec = .{
            .stream = st,
            .sample_rate = rate,
            .channels = ch,
            .max_frames = cap_frames,
            .samples = list,
            .last_pump_ms = sdl.SDL_GetTicks(),
        };
    }

    /// Moves what the microphone delivered since last time into the recording.
    fn pumpRecording(a: *Audio) void {
        const r = &(a.rec orelse return);
        const now = sdl.SDL_GetTicks();
        const dt: f32 = @as(f32, @floatFromInt(now -| r.last_pump_ms)) / 1000.0;
        r.last_pump_ms = now;
        var peak: f32 = 0;
        var buf: [2048]f32 = undefined;
        const ch: usize = r.channels;
        while (true) {
            if (sdl.SDL_GetAudioStreamAvailable(r.stream) <= 0) break;
            const want = (buf.len / ch) * ch * @sizeOf(f32);
            const got = sdl.SDL_GetAudioStreamData(r.stream, &buf, @intCast(want));
            if (got <= 0) break;
            const n = @as(usize, @intCast(got)) / @sizeOf(f32) / ch * ch; // whole frames
            if (n == 0) break;
            const chunk = buf[0..n];
            peak = @max(peak, pcm_mod.peakOf(chunk));
            if (r.limit) continue; // full: drain and drop
            const room = (r.max_frames - r.frames()) * ch;
            const take = @min(room, n);
            r.samples.appendSlice(a.gpa, chunk[0..take]) catch {
                r.limit = true; // out of memory: behave like a full recording
                continue;
            };
            if (take < n or r.frames() >= r.max_frames) r.limit = true;
        }
        r.peak = @max(r.peak, peak);
        r.level = pcm_mod.levelStep(r.level, peak, dt, 0.15);
    }

    pub fn recordingState(a: *Audio) RecordingState {
        a.pumpRecording();
        const r = &(a.rec orelse return .idle);
        return if (r.limit) .limit_reached else .recording;
    }

    /// True from `startRecording` until `stopRecording` or `cancelRecording` (also after the
    /// time limit was reached; check `recordingState`).
    pub fn isRecording(a: *const Audio) bool {
        return a.rec != null;
    }

    /// Seconds recorded so far.
    pub fn recordingSeconds(a: *Audio) f32 {
        a.pumpRecording();
        const r = &(a.rec orelse return 0);
        return @floatCast(@as(f64, @floatFromInt(r.frames())) / @as(f64, @floatFromInt(r.sample_rate)));
    }

    /// Input level for a meter: the recent peak, 0..1 linear, falling away smoothly when it
    /// gets quiet. Feed it through `meterScale` to draw it. 0 when not recording.
    pub fn level(a: *Audio) f32 {
        a.pumpRecording();
        const r = &(a.rec orelse return 0);
        return r.level;
    }

    /// The loudest sample heard since the recording started. Exactly 0 after a couple of
    /// seconds means the device delivers silence (macOS does this for a denied microphone).
    pub fn recordingPeak(a: *Audio) f32 {
        a.pumpRecording();
        const r = &(a.rec orelse return 0);
        return r.peak;
    }

    /// Ends the recording and returns it as a sound.
    pub fn stopRecording(a: *Audio) StopRecordError!Sound {
        a.pumpRecording();
        var r = a.rec orelse return error.NotRecording;
        a.rec = null;
        sdl.SDL_DestroyAudioStream(r.stream);
        if (r.samples.items.len == 0) {
            r.samples.deinit(a.gpa);
            return error.EmptyRecording;
        }
        const data = r.samples.toOwnedSlice(a.gpa) catch {
            r.samples.deinit(a.gpa);
            return error.OutOfMemory;
        };
        return a.soundFromPcm(.{ .samples = data, .sample_rate = r.sample_rate, .channels = r.channels }) catch {
            a.gpa.free(data);
            return error.OutOfMemory;
        };
    }

    /// Throws the recording away.
    pub fn cancelRecording(a: *Audio) void {
        var r = a.rec orelse return;
        a.rec = null;
        sdl.SDL_DestroyAudioStream(r.stream);
        r.samples.deinit(a.gpa);
    }
};

// ---- tests ------------------------------------------------------------------------------
//
// Everything that touches a device uses SDL's dummy audio driver: it consumes playback data
// at real-time speed and records silence, with no hardware and no sound.

const testing = std.testing;

fn tone(gpa: std.mem.Allocator, hz: f32, seconds: f32, rate: u32) ![]f32 {
    const n: usize = @intFromFloat(seconds * @as(f32, @floatFromInt(rate)));
    const out = try gpa.alloc(f32, n);
    for (out, 0..) |*s, i| s.* = 0.5 * @sin(2 * std.math.pi * hz * @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(rate)));
    return out;
}

test "no device is opened until a sound plays" {
    var a = Audio.init(testing.allocator, .{ .driver = "dummy" });
    defer a.deinit();
    const t = try tone(testing.allocator, 440, 0.5, 8000);
    defer testing.allocator.free(t);
    const s = try a.soundFromSamples(t, 8000, 1);
    try testing.expect(a.hasSound(s));
    try testing.expectApproxEqAbs(@as(f32, 0.5), a.soundDuration(s), 1e-4);
    try testing.expect(!a.sdl_ready and a.play_stream == null); // loading needs no device
    try testing.expect(a.driverName() == null);
    try testing.expect(!a.busy());
    a.update();
    a.unloadSound(s);
    try testing.expect(!a.hasSound(s));
    try testing.expect(a.soundDuration(s) == 0);
    a.unloadSound(s); // stale: ignored
    try testing.expectError(error.InvalidSound, a.play(s, .{}));
    try testing.expectError(error.InvalidSound, a.play(Sound.none, .{}));
}

test "playback: voices advance, pause, seek, stop, overlap and stale handles are inert" {
    var a = Audio.init(testing.allocator, .{ .driver = "dummy" });
    defer a.deinit();
    const t = try tone(testing.allocator, 440, 2, 8000);
    defer testing.allocator.free(t);
    const s = try a.soundFromSamples(t, 8000, 1);
    const v = try a.play(s, .{ .volume = 0.0 });
    try testing.expect(a.busy());
    try testing.expectEqualStrings("dummy", a.driverName().?);
    try testing.expect(a.isPlaying(v));
    try testing.expectApproxEqAbs(@as(f32, 2), a.duration(v), 1e-4);
    sdl.SDL_Delay(250);
    const p1 = a.position(v);
    try testing.expect(p1 > 0.05 and p1 < 1.5); // the dummy driver runs in real time
    a.pause(v);
    sdl.SDL_Delay(80); // the fade-out takes a few ms
    try testing.expectEqual(VoiceState.paused, a.voiceState(v));
    const held = a.position(v);
    sdl.SDL_Delay(150);
    try testing.expectEqual(held, a.position(v));
    a.seek(v, 1.5);
    try testing.expectApproxEqAbs(@as(f32, 1.5), a.position(v), 0.02);
    a.resumeVoice(v);
    // Overlapping voices of the same sound are independent.
    const v2 = try a.play(s, .{ .volume = 0.0, .start = 1.0 });
    try testing.expectApproxEqAbs(@as(f32, 1.0), a.position(v2), 0.3);
    a.setVolume(v2, 0.0);
    a.stop(v2);
    try testing.expectEqual(VoiceState.ended, a.voiceState(v2));
    try testing.expectEqual(@as(f32, 0), a.position(v2));
    // Unloading the sound under a playing voice stops it; its handle goes stale.
    a.unloadSound(s);
    try testing.expectEqual(VoiceState.ended, a.voiceState(v));
    a.pause(v);
    a.seek(v, 0);
    a.setMasterVolume(0.25);
    try testing.expectEqual(@as(f32, 0.25), a.masterVolume());
    a.setMasterVolume(-1);
    try testing.expectEqual(@as(f32, 0), a.masterVolume());
}

test "a one-shot ends by itself and frees its slot" {
    var a = Audio.init(testing.allocator, .{ .driver = "dummy" });
    defer a.deinit();
    const t = try tone(testing.allocator, 880, 0.1, 8000);
    defer testing.allocator.free(t);
    const s = try a.soundFromSamples(t, 8000, 1);
    // More plays than slots, one after another: nothing leaks if finished voices free themselves.
    for (0..2 * max_voices) |_| {
        _ = try a.play(s, .{ .volume = 0 });
        sdl.SDL_Delay(15);
    }
    sdl.SDL_Delay(400);
    try testing.expectEqual(@as(usize, 0), a.activeVoices());
}

test "recording on the dummy device: silence, time, cap, stop gives a sound" {
    var a = Audio.init(testing.allocator, .{ .driver = "dummy" });
    defer a.deinit();
    try testing.expect(!a.isRecording());
    try testing.expectError(error.NotRecording, a.stopRecording());
    try testing.expectEqual(RecordingState.idle, a.recordingState());
    try a.startRecording(.{ .sample_rate = 16000, .channels = 1, .max_seconds = 0.25 });
    try testing.expectError(error.AlreadyRecording, a.startRecording(.{}));
    try testing.expect(a.isRecording() and a.busy());
    sdl.SDL_Delay(120);
    try testing.expect(a.recordingSeconds() > 0.02);
    try testing.expectEqual(@as(f32, 0), a.level()); // the dummy microphone hears nothing
    try testing.expectEqual(@as(f32, 0), a.recordingPeak());
    sdl.SDL_Delay(400);
    try testing.expectEqual(RecordingState.limit_reached, a.recordingState());
    try testing.expect(a.recordingSeconds() <= 0.2501);
    const s = try a.stopRecording();
    try testing.expect(!a.isRecording());
    const p = a.soundPcm(s).?;
    try testing.expectEqual(@as(u32, 16000), p.sample_rate);
    try testing.expectEqual(@as(u8, 1), p.channels);
    try testing.expect(p.duration() > 0.2 and p.duration() <= 0.2501);
    // The recording is a normal sound: waveform, WAV.
    const pk = (try a.soundPeaks(testing.allocator, s, 10)).?;
    defer testing.allocator.free(pk);
    try testing.expectEqual(@as(usize, 10), pk.len);
    const wav = try a.soundWav(testing.allocator, s);
    defer testing.allocator.free(wav);
    const back = try decodeWav(testing.allocator, wav);
    defer back.deinit(testing.allocator);
    try testing.expectEqual(p.frames(), back.frames());
    // Cancel discards.
    try a.startRecording(.{});
    a.cancelRecording();
    try testing.expect(!a.isRecording());
    // Stopping at once may legitimately have captured nothing, and says so.
    try a.startRecording(.{});
    if (a.stopRecording()) |s2| a.unloadSound(s2) else |e| try testing.expectEqual(error.EmptyRecording, e);
    // A recording still open at deinit does not leak.
    try a.startRecording(.{});
}

test "sounds load from WAV bytes, files round-trip, bad data is an error" {
    var a = Audio.init(testing.allocator, .{ .driver = "dummy" });
    defer a.deinit();
    const t = try tone(testing.allocator, 440, 0.25, 8000);
    defer testing.allocator.free(t);
    const s = try a.soundFromSamples(t, 8000, 1);
    const wav = try a.soundWav(testing.allocator, s);
    defer testing.allocator.free(wav);
    const s2 = try a.loadSound(wav);
    try testing.expectEqual(a.soundPcm(s).?.frames(), a.soundPcm(s2).?.frames());
    try testing.expectError(error.UnsupportedFormat, a.loadSound("definitely not audio"));
    try testing.expectError(error.InvalidAudio, a.soundFromSamples(&.{}, 8000, 1));
    try testing.expectError(error.InvalidAudio, a.soundFromSamples(t, 8000, 3));
    try testing.expectError(error.FileReadFailed, a.loadSoundFile("/nonexistent/dir/none.wav"));
    try testing.expectError(error.InvalidSound, a.soundWav(testing.allocator, .none));
}

test "opt-in: the real output device opens and takes silent audio (VASS_AUDIO_REAL=1)" {
    if (std.c.getenv("VASS_AUDIO_REAL") == null) return error.SkipZigTest;
    var a = Audio.init(testing.allocator, .{});
    defer a.deinit();
    const t = try tone(testing.allocator, 440, 0.5, 22050);
    defer testing.allocator.free(t);
    const s = try a.soundFromSamples(t, 22050, 1);
    const v = try a.play(s, .{ .volume = 0 }); // silent: gain zero
    sdl.SDL_Delay(300);
    std.debug.print("driver={s} position={d:.3}\n", .{ a.driverName().?, a.position(v) });
    try testing.expect(a.position(v) > 0.05);
    a.stop(v);
}

test "recording: a huge or non-finite time limit is clamped, not converted" {
    try testing.expectEqual(@as(usize, 100 * 8000), recordingCapFrames(100, 8000, 1));
    try testing.expectEqual(@as(usize, 800), recordingCapFrames(0, 8000, 1)); // floor of 0.1 s
    try testing.expectEqual(@as(usize, 800), recordingCapFrames(std.math.nan(f32), 8000, 1));
    const limit = pcm_mod.max_bytes / @sizeOf(f32);
    try testing.expectEqual(limit, recordingCapFrames(std.math.inf(f32), 8000, 1));
    try testing.expectEqual(limit / 2, recordingCapFrames(3.0e38, 96000, 2));
    // And through the real entry point (dummy microphone).
    var a = Audio.init(testing.allocator, .{ .driver = "dummy" });
    defer a.deinit();
    try a.startRecording(.{ .sample_rate = 16000, .channels = 2, .max_seconds = std.math.inf(f32) });
    try testing.expectEqual(limit / 2, a.rec.?.max_frames);
    a.cancelRecording();
}

test "stopping a paused voice while the idle output is paused leaves nothing busy" {
    var a = Audio.init(testing.allocator, .{ .driver = "dummy" });
    defer a.deinit();
    const t = try tone(testing.allocator, 440, 2, 8000);
    defer testing.allocator.free(t);
    const s = try a.soundFromSamples(t, 8000, 1);
    const v = try a.play(s, .{ .volume = 0.5 });
    a.pause(v);
    sdl.SDL_Delay(80); // the fade-out takes a few ms
    try testing.expectEqual(VoiceState.paused, a.voiceState(v));
    try testing.expectEqual(@as(@TypeOf(a.shared.mixer.slots[0].phase), .paused), a.shared.mixer.slots[v.slot].phase);
    // What `update` does after two quiet seconds: the device stops asking for data.
    _ = sdl.SDL_PauseAudioStreamDevice(a.play_stream.?);
    a.play_running = false;
    a.stop(v);
    try testing.expect(!a.busy());
    try testing.expectEqual(@as(usize, 0), a.activeVoices());
    // The same through stopAll.
    const v2 = try a.play(s, .{ .volume = 0.5 });
    a.pause(v2);
    sdl.SDL_Delay(80);
    try testing.expectEqual(@as(@TypeOf(a.shared.mixer.slots[0].phase), .paused), a.shared.mixer.slots[v2.slot].phase);
    _ = sdl.SDL_PauseAudioStreamDevice(a.play_stream.?);
    a.play_running = false;
    a.stopAll();
    try testing.expect(!a.busy());
    try testing.expectEqual(@as(usize, 0), a.activeVoices());
}

test "a file over the size limit is refused before any of it is read" {
    var a = Audio.init(testing.allocator, .{ .driver = "dummy" });
    defer a.deinit();
    var buf: [256]u8 = undefined;
    const dir = std.mem.span(std.c.getenv("TMPDIR") orelse "/tmp");
    const path = try std.fmt.bufPrintSentinel(&buf, "{s}/vass-audio-big-{d}.wav", .{ std.mem.trimEnd(u8, dir, "/"), std.c.getpid() }, 0);
    // A sparse 257 MB file that nobody may read: only a size check can say what is wrong with
    // it (reading it first would report a read failure).
    const fd = std.c.open(path.ptr, .{ .ACCMODE = .RDWR, .CREAT = true, .TRUNC = true }, @as(c_uint, 0));
    try testing.expect(fd >= 0);
    defer _ = std.c.unlink(path.ptr);
    try testing.expectEqual(@as(c_int, 0), std.c.ftruncate(fd, 257 * 1024 * 1024));
    _ = std.c.close(fd);
    try testing.expectError(error.FileTooLarge, a.loadSoundFile(path));
}
