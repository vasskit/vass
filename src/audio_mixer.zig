//! The software mixer behind `audio.zig`: a fixed set of voice slots that read
//! float32 PCM, resample it linearly to the output rate, apply per-voice and master
//! gain and sum into an interleaved stereo float buffer.
//!
//! The mixer knows nothing about threads or devices and never allocates. `Audio`
//! guards one with a lock: the audio thread calls `render`, the UI thread calls the
//! control functions. Voices do not own their samples (the sound table does), so a
//! sound must be `stopSound`ed before its memory goes.
const std = @import("std");

/// Voice slots. More simultaneous sounds than this are refused by `start`.
pub const max_voices = 32;

/// Seconds a gain change (start after a seek, pause, stop, volume) is spread over, so none
/// of them clicks.
pub const ramp_seconds: f32 = 0.006;

/// A reference to one playing sound: a slot and the generation the slot had when the
/// sound started. When the sound ends or is stopped the generation moves on and the
/// handle is stale: every operation on it is a no-op.
pub const Handle = struct {
    slot: u16,
    gen: u16,

    pub const none: Handle = .{ .slot = 0xFFFF, .gen = 0 };

    pub fn isNone(h: Handle) bool {
        return h.slot == 0xFFFF;
    }
};

pub const State = enum {
    /// Audible (or about to be).
    playing,
    paused,
    /// The handle is stale: the sound ended, was stopped, or never existed.
    ended,
};

const Phase = enum { free, playing, paused, pausing, stopping };

const Slot = struct {
    phase: Phase = .free,
    gen: u16 = 1,
    sound_id: u32 = 0,
    samples: []const f32 = &.{},
    channels: u8 = 1,
    rate: u32 = 1,
    /// Position in source frames (fractional).
    pos: f64 = 0,
    volume: f32 = 1,
    /// The gain actually applied; slews towards its target.
    gain: f32 = 0,
    loop: bool = false,

    fn frames(s: *const Slot) usize {
        return s.samples.len / @max(s.channels, 1);
    }
};

pub const Mixer = struct {
    slots: [max_voices]Slot = @splat(.{}),
    master: f32 = 1,
    out_rate: u32 = 48000,

    pub fn init(out_rate: u32) Mixer {
        return .{ .out_rate = out_rate };
    }

    fn slotFor(m: *Mixer, h: Handle) ?*Slot {
        if (h.slot >= max_voices) return null;
        const s = &m.slots[h.slot];
        if (s.gen != h.gen) return null;
        return switch (s.phase) {
            .playing, .paused, .pausing => s,
            .free, .stopping => null,
        };
    }

    fn release(s: *Slot, to: Phase) void {
        s.phase = to;
        s.gen +%= 1;
        if (s.gen == 0) s.gen = 1;
    }

    /// Starts a voice reading `samples` (`channels` 1 or 2, `rate` Hz) from `start_seconds`.
    /// Null if all slots are busy.
    pub fn start(m: *Mixer, sound_id: u32, samples: []const f32, channels: u8, rate: u32, volume: f32, loop: bool, start_seconds: f32) ?Handle {
        for (&m.slots, 0..) |*s, i| {
            if (s.phase != .free) continue;
            const gen = s.gen;
            s.* = .{
                .phase = .playing,
                .gen = gen,
                .sound_id = sound_id,
                .samples = samples,
                .channels = channels,
                .rate = rate,
                .volume = volume,
                .loop = loop,
            };
            s.pos = clampPos(s, @as(f64, @max(start_seconds, 0)) * @as(f64, @floatFromInt(rate)));
            // A sound that begins at its first sample starts at full gain; one that begins
            // part-way in fades up like a seek does.
            s.gain = if (s.pos == 0) volume else 0;
            return .{ .slot = @intCast(i), .gen = gen };
        }
        return null;
    }

    fn clampPos(s: *const Slot, p: f64) f64 {
        const n: f64 = @floatFromInt(s.frames());
        if (!std.math.isFinite(p) or p < 0) return 0;
        if (s.loop) return if (n > 0) @mod(p, n) else 0;
        return @min(p, n);
    }

    pub fn state(m: *Mixer, h: Handle) State {
        const s = m.slotFor(h) orelse return .ended;
        // A voice fading out to a pause already counts as paused.
        return if (s.phase == .playing) .playing else .paused;
    }

    pub fn pause(m: *Mixer, h: Handle) void {
        const s = m.slotFor(h) orelse return;
        if (s.phase == .playing) s.phase = .pausing;
    }

    pub fn resumeVoice(m: *Mixer, h: Handle) void {
        const s = m.slotFor(h) orelse return;
        if (s.phase == .paused or s.phase == .pausing) s.phase = .playing;
    }

    /// Ends the voice: it fades out over a few milliseconds and its slot is then free again.
    /// The handle is stale from this call on.
    pub fn stop(m: *Mixer, h: Handle) void {
        const s = m.slotFor(h) orelse return;
        release(s, .stopping);
    }

    /// Stops every voice playing `sound_id` at once, with no fade, so its samples can be freed.
    pub fn stopSound(m: *Mixer, sound_id: u32) void {
        for (&m.slots) |*s| {
            if (s.phase != .free and s.sound_id == sound_id) {
                s.samples = &.{};
                release(s, .free);
            }
        }
    }

    pub fn stopAll(m: *Mixer) void {
        for (&m.slots) |*s| if (s.phase == .playing or s.phase == .paused or s.phase == .pausing) release(s, .stopping);
    }

    pub fn setVolume(m: *Mixer, h: Handle, v: f32) void {
        const s = m.slotFor(h) orelse return;
        s.volume = if (std.math.isFinite(v)) std.math.clamp(v, 0, 4) else 0;
    }

    pub fn seek(m: *Mixer, h: Handle, seconds: f32) void {
        const s = m.slotFor(h) orelse return;
        s.pos = clampPos(s, @as(f64, @max(seconds, 0)) * @as(f64, @floatFromInt(s.rate)));
        s.gain = 0; // fade up from the cut
    }

    /// Where the voice is, in seconds into the sound; 0 for a stale handle.
    pub fn position(m: *Mixer, h: Handle) f32 {
        const s = m.slotFor(h) orelse return 0;
        return @floatCast(s.pos / @as(f64, @floatFromInt(s.rate)));
    }

    pub fn duration(m: *Mixer, h: Handle) f32 {
        const s = m.slotFor(h) orelse return 0;
        return @floatCast(@as(f64, @floatFromInt(s.frames())) / @as(f64, @floatFromInt(s.rate)));
    }

    /// Number of voices that are playing or paused.
    pub fn activeCount(m: *const Mixer) usize {
        var n: usize = 0;
        for (&m.slots) |*s| switch (s.phase) {
            .playing, .pausing, .paused => n += 1,
            else => {},
        };
        return n;
    }

    /// True while any voice is playing (not paused), or still fading out.
    pub fn anyAudible(m: *const Mixer) bool {
        for (&m.slots) |*s| switch (s.phase) {
            .playing, .pausing, .stopping => return true,
            else => {},
        };
        return false;
    }

    inline fn at(s: *const Slot, frame: usize, ch: usize) f32 {
        return s.samples[frame * s.channels + ch];
    }

    /// Overwrites `out` (interleaved stereo, whole frames) with the mix of all voices.
    pub fn render(m: *Mixer, out: []f32) void {
        @memset(out, 0);
        const n_out = out.len / 2;
        const master = m.master;
        const slew = 1.0 / (ramp_seconds * @as(f32, @floatFromInt(m.out_rate)));
        for (&m.slots) |*s| {
            switch (s.phase) {
                .free, .paused => continue,
                .playing, .pausing, .stopping => {},
            }
            const n_src = s.frames();
            if (n_src == 0) {
                release(s, .free);
                continue;
            }
            const step: f64 = @as(f64, @floatFromInt(s.rate)) / @as(f64, @floatFromInt(m.out_rate));
            const target: f32 = if (s.phase == .playing) s.volume else 0;
            const stereo = s.channels >= 2;
            const n_f: f64 = @floatFromInt(n_src);
            var i: usize = 0;
            while (i < n_out) : (i += 1) {
                const ia: usize = @intFromFloat(s.pos);
                if (ia >= n_src) { // only a one-shot gets here: a loop wraps below
                    release(s, .free);
                    break;
                }
                var ib = ia + 1;
                if (ib >= n_src) ib = if (s.loop) 0 else n_src - 1;
                const f: f32 = @floatCast(s.pos - @as(f64, @floatFromInt(ia)));
                const l = at(s, ia, 0) * (1 - f) + at(s, ib, 0) * f;
                const r = if (stereo) at(s, ia, 1) * (1 - f) + at(s, ib, 1) * f else l;
                // Slew the gain towards its target.
                const d = target - s.gain;
                s.gain += std.math.clamp(d, -slew, slew);
                const g = s.gain * master;
                out[i * 2] += l * g;
                out[i * 2 + 1] += r * g;
                s.pos += step;
                if (s.loop and s.pos >= n_f) s.pos = @mod(s.pos, n_f);
                if (s.phase == .pausing and s.gain <= 0) {
                    s.phase = .paused;
                    break;
                }
                if (s.phase == .stopping and s.gain <= 0) {
                    release(s, .free);
                    break;
                }
            }
        }
        for (out) |*v| v.* = std.math.clamp(v.*, -1, 1);
    }
};

// ---- tests ------------------------------------------------------------------------------

const testing = std.testing;

fn ramp(n: usize, buf: []f32) void {
    for (buf[0..n], 0..) |*v, i| v.* = @as(f32, @floatFromInt(i + 1)) / 10;
}

test "a mono voice plays to the end, then its handle goes stale" {
    var m = Mixer.init(1000);
    const s = [_]f32{ 0.1, 0.2, 0.3, 0.4 };
    const h = m.start(1, &s, 1, 1000, 1, false, 0).?;
    try testing.expectEqual(State.playing, m.state(h));
    try testing.expectEqual(@as(usize, 1), m.activeCount());
    var out: [4]f32 = undefined; // 2 frames
    m.render(&out);
    try testing.expectEqualSlices(f32, &.{ 0.1, 0.1, 0.2, 0.2 }, &out);
    try testing.expectApproxEqAbs(@as(f32, 0.002), m.position(h), 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.004), m.duration(h), 1e-6);
    var out2: [8]f32 = undefined; // 4 frames: two more, then silence
    m.render(&out2);
    try testing.expectEqualSlices(f32, &.{ 0.3, 0.3, 0.4, 0.4, 0, 0, 0, 0 }, &out2);
    try testing.expectEqual(State.ended, m.state(h));
    try testing.expectEqual(@as(usize, 0), m.activeCount());
    try testing.expect(!m.anyAudible());
    // A stale handle is inert, and its slot is reusable with a new generation.
    m.pause(h);
    m.seek(h, 1);
    m.setVolume(h, 0);
    try testing.expectEqual(@as(f32, 0), m.position(h));
    const h2 = m.start(1, &s, 1, 1000, 1, false, 0).?;
    try testing.expectEqual(h.slot, h2.slot);
    try testing.expect(h.gen != h2.gen);
    m.stop(h); // the old handle cannot stop the new voice
    try testing.expectEqual(State.playing, m.state(h2));
}

test "stereo is kept apart, master and voice volume multiply, output is clipped" {
    var m = Mixer.init(1000);
    const s = [_]f32{ 0.5, -0.5, 0.5, -0.5 };
    m.master = 0.5;
    _ = m.start(1, &s, 2, 1000, 0.5, false, 0).?;
    var out: [4]f32 = undefined;
    m.render(&out);
    try testing.expectApproxEqAbs(@as(f32, 0.125), out[0], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, -0.125), out[1], 1e-6);
    // Two loud voices sum past 1 and are clipped.
    var m2 = Mixer.init(1000);
    const loud = [_]f32{ 0.9, 0.9 };
    _ = m2.start(1, &loud, 1, 1000, 1, true, 0).?;
    _ = m2.start(2, &loud, 1, 1000, 1, true, 0).?;
    var o2: [4]f32 = undefined;
    m2.render(&o2);
    try testing.expectEqual(@as(f32, 1), o2[0]);
}

test "overlapping voices sum; the slot table fills and refuses" {
    var m = Mixer.init(1000);
    const a = [_]f32{ 0.25, 0.25, 0.25, 0.25 };
    const b = [_]f32{ 0.125, 0.125, 0.125, 0.125 };
    _ = m.start(1, &a, 1, 1000, 1, false, 0).?;
    _ = m.start(2, &b, 1, 1000, 1, false, 0).?;
    var out: [4]f32 = undefined;
    m.render(&out);
    try testing.expectApproxEqAbs(@as(f32, 0.375), out[0], 1e-6);
    var m2 = Mixer.init(1000);
    for (0..max_voices) |_| try testing.expect(m2.start(1, &a, 1, 1000, 1, true, 0) != null);
    try testing.expect(m2.start(1, &a, 1, 1000, 1, true, 0) == null);
    m2.stopSound(1); // freeing a sound frees all its slots at once
    try testing.expectEqual(@as(usize, 0), m2.activeCount());
    try testing.expect(m2.start(1, &a, 1, 1000, 1, true, 0) != null);
}

test "looping wraps, with the seam interpolated and position kept in range" {
    var m = Mixer.init(1000);
    var s: [10]f32 = undefined;
    ramp(10, &s);
    const h = m.start(1, &s, 1, 1000, 1, true, 0).?;
    var out: [2 * 25]f32 = undefined; // 25 frames from a 10 frame loop
    m.render(&out);
    try testing.expectApproxEqAbs(@as(f32, 1.0), out[2 * 9], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.1), out[2 * 10], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.5), out[2 * 24], 1e-6);
    try testing.expect(m.state(h) == .playing);
    try testing.expectApproxEqAbs(@as(f32, 0.005), m.position(h), 1e-6);
    // Seeking past the end wraps in a loop.
    m.seek(h, 0.023);
    try testing.expectApproxEqAbs(@as(f32, 0.003), m.position(h), 1e-6);
}

test "resampling: a half-rate sound is stretched by linear interpolation" {
    var m = Mixer.init(48000);
    const s = [_]f32{ 0, 1, 0, -1 };
    _ = m.start(1, &s, 1, 24000, 1, false, 0).?;
    var out: [16]f32 = undefined; // 8 output frames
    m.render(&out);
    const want = [_]f32{ 0, 0.5, 1, 0.5, 0, -0.5, -1, -1 };
    for (want, 0..) |w, i| try testing.expectApproxEqAbs(w, out[i * 2], 1e-6);
    // The same sound at the output rate is passed through untouched.
    var m2 = Mixer.init(24000);
    _ = m2.start(1, &s, 1, 24000, 1, false, 0).?;
    var o2: [8]f32 = undefined;
    m2.render(&o2);
    try testing.expectEqualSlices(f32, &.{ 0, 0, 1, 1, 0, 0, -1, -1 }, &o2);
}

test "pause fades out and holds the position; resume continues from there" {
    var m = Mixer.init(10000);
    var s: [1000]f32 = @splat(0.5);
    const h = m.start(1, &s, 1, 10000, 1, false, 0).?;
    var out: [200]f32 = undefined; // 100 frames = 10 ms, more than the 6 ms ramp
    m.render(&out);
    m.pause(h);
    try testing.expectEqual(State.paused, m.state(h)); // already counts, though still fading
    try testing.expect(m.anyAudible());
    m.render(&out);
    try testing.expectEqual(State.paused, m.state(h));
    try testing.expectEqual(@as(f32, 0), out[198]); // silent at the end of the fade
    try testing.expect(out[0] > 0); // but not cut dead at once
    const held = m.position(h);
    try testing.expect(held > 0 and held < 0.03);
    try testing.expect(!m.anyAudible());
    m.render(&out); // paused voices do not advance
    try testing.expectEqual(held, m.position(h));
    m.resumeVoice(h);
    m.render(&out);
    try testing.expect(m.position(h) > held);
    try testing.expectApproxEqAbs(@as(f32, 0.5), out[198], 1e-5); // back at full gain
}

test "stop fades out, frees the slot and invalidates the handle at once" {
    var m = Mixer.init(10000);
    var s: [1000]f32 = @splat(0.5);
    const h = m.start(1, &s, 1, 10000, 1, true, 0).?;
    var out: [200]f32 = undefined;
    m.render(&out);
    m.stop(h);
    try testing.expectEqual(State.ended, m.state(h));
    try testing.expect(m.anyAudible()); // the fade-out tail
    try testing.expectEqual(@as(usize, 0), m.activeCount());
    m.render(&out);
    try testing.expect(!m.anyAudible());
    try testing.expectEqual(@as(f32, 0), out[199]);
    // The slot is free again.
    for (0..max_voices) |_| try testing.expect(m.start(1, &s, 1, 10000, 1, true, 0) != null);
    m.stopAll();
    m.render(&out);
    try testing.expectEqual(@as(usize, 0), m.activeCount());
}

test "seek moves the position, clamps, and starts mid-sound with a fade-in" {
    var m = Mixer.init(1000);
    var s: [1000]f32 = @splat(1);
    const h = m.start(1, &s, 1, 1000, 1, false, 0.25).?;
    try testing.expectApproxEqAbs(@as(f32, 0.25), m.position(h), 1e-6);
    var out: [20]f32 = undefined;
    m.render(&out);
    try testing.expect(out[0] < 0.3); // fading up from silence
    m.seek(h, 0.5);
    try testing.expectApproxEqAbs(@as(f32, 0.5), m.position(h), 1e-6);
    m.seek(h, -3);
    try testing.expectEqual(@as(f32, 0), m.position(h));
    m.seek(h, std.math.nan(f32));
    try testing.expectEqual(@as(f32, 0), m.position(h));
    m.seek(h, 99); // past the end of a one-shot: clamped to the end, which finishes it
    try testing.expectApproxEqAbs(@as(f32, 1), m.position(h), 1e-6);
    m.render(&out);
    try testing.expectEqual(State.ended, m.state(h));
    // Starting past the end is the same.
    const h2 = m.start(1, &s, 1, 1000, 1, false, 50).?;
    m.render(&out);
    try testing.expectEqual(State.ended, m.state(h2));
}

test "volume changes ramp instead of jumping" {
    var m = Mixer.init(10000);
    var s: [1000]f32 = @splat(1);
    const h = m.start(1, &s, 1, 10000, 1, false, 0).?;
    var out: [200]f32 = undefined;
    m.render(&out);
    m.setVolume(h, 0.25);
    m.render(&out);
    try testing.expect(out[0] > 0.9 and out[0] < 1); // first sample barely moved
    try testing.expectApproxEqAbs(@as(f32, 0.25), out[198], 1e-6);
    m.setVolume(h, std.math.nan(f32)); // NaN is mute, not a poisoned mix
    m.render(&out);
    try testing.expectEqual(@as(f32, 0), out[198]);
}

test "an empty sound is dropped rather than looped forever" {
    var m = Mixer.init(1000);
    const h = m.start(1, &.{}, 1, 1000, 1, true, 0).?;
    var out: [8]f32 = undefined;
    m.render(&out);
    try testing.expectEqual(State.ended, m.state(h));
}
