//! Decoded audio held in memory (`Pcm`), and the pure parts around it: WAV
//! parsing and encoding, OGG Vorbis and MP3 decoding (through stb_vorbis and
//! dr_mp3, both C single-file libraries), waveform peaks and level metering.
//! No platform dependency and no device: everything here is plain data in,
//! plain data out, so it is unit-tested without any audio hardware.
const std = @import("std");

extern fn stb_vorbis_open_memory(data: [*]const u8, len: c_int, err: *c_int, alloc: ?*anyopaque) ?*anyopaque;
extern fn stb_vorbis_close(f: *anyopaque) void;
extern fn stb_vorbis_get_info(f: *anyopaque) VorbisInfo;
extern fn stb_vorbis_stream_length_in_samples(f: *anyopaque) c_uint;
extern fn stb_vorbis_get_samples_float_interleaved(f: *anyopaque, channels: c_int, buffer: [*]f32, num_floats: c_int) c_int;
const VorbisInfo = extern struct {
    sample_rate: c_uint,
    channels: c_int,
    setup_memory_required: c_uint,
    setup_temp_memory_required: c_uint,
    temp_memory_required: c_uint,
    max_frame_size: c_int,
};

// dr_mp3 is reached through three small wrappers in src/audio/audio_impl.c, so Zig never
// has to know the layout of its decoder struct.
extern fn vass_mp3_open(data: [*]const u8, len: usize) ?*anyopaque;
extern fn vass_mp3_info(m: *anyopaque, channels: *c_uint, sample_rate: *c_uint) void;
extern fn vass_mp3_read(m: *anyopaque, frames: u64, out: [*]f32) u64;
extern fn vass_mp3_close(m: *anyopaque) void;

pub const Error = error{
    /// The bytes are not (valid) audio of the format they claim.
    InvalidAudio,
    /// A valid file this library does not decode (a 5.1 WAV, A-law, ...).
    UnsupportedFormat,
    /// More samples than `max_bytes` allows.
    TooLong,
    OutOfMemory,
};

/// Largest decoded sound accepted, in bytes of float32 samples (about 23
/// minutes of 48 kHz stereo).
pub const max_bytes: usize = 256 * 1024 * 1024;
/// Largest sample rate accepted.
pub const max_rate: u32 = 768000;

/// Interleaved float32 samples (nominally -1..1), 1 or 2 channels.
pub const Pcm = struct {
    samples: []f32,
    sample_rate: u32,
    channels: u8,

    pub fn frames(p: Pcm) usize {
        return p.samples.len / @max(p.channels, 1);
    }

    /// Length in seconds.
    pub fn duration(p: Pcm) f64 {
        if (p.sample_rate == 0) return 0;
        return @as(f64, @floatFromInt(p.frames())) / @as(f64, @floatFromInt(p.sample_rate));
    }

    pub fn deinit(p: Pcm, gpa: std.mem.Allocator) void {
        gpa.free(p.samples);
    }

    pub fn clone(p: Pcm, gpa: std.mem.Allocator) error{OutOfMemory}!Pcm {
        return .{ .samples = try gpa.dupe(f32, p.samples), .sample_rate = p.sample_rate, .channels = p.channels };
    }
};

fn checkFormat(channels: u32, rate: u32) Error!void {
    if (channels == 0 or rate == 0 or rate > max_rate) return error.InvalidAudio;
    if (channels > 2) return error.UnsupportedFormat;
}

fn sampleCountOk(n: u64) bool {
    return n <= max_bytes / @sizeOf(f32);
}

// ---- WAV --------------------------------------------------------------------------------

fn rd16(b: []const u8, off: usize) u16 {
    return std.mem.readInt(u16, b[off..][0..2], .little);
}

fn rd32(b: []const u8, off: usize) u32 {
    return std.mem.readInt(u32, b[off..][0..4], .little);
}

fn clean(x: f32) f32 {
    return if (std.math.isFinite(x)) x else 0;
}

/// Parses a RIFF/WAVE file: integer PCM at 8 (unsigned), 16, 24 and 32 bits, IEEE float at
/// 32 and 64 bits, mono or stereo, also inside WAVE_FORMAT_EXTENSIBLE. Tolerant of what
/// real files do: unknown chunks, odd-sized chunks, a `data` size that is zero, too big or
/// 0xFFFFFFFF (streamed files: the rest of the file is taken), a final partial frame
/// (dropped), a wrong RIFF size. Anything else malformed is `InvalidAudio`.
pub fn decodeWav(gpa: std.mem.Allocator, bytes: []const u8) Error!Pcm {
    if (bytes.len < 12 or !std.mem.eql(u8, bytes[0..4], "RIFF") or !std.mem.eql(u8, bytes[8..12], "WAVE")) return error.InvalidAudio;
    var tag: u16 = 0;
    var channels: u32 = 0;
    var rate: u32 = 0;
    var bits: u32 = 0;
    var have_fmt = false;
    var data: ?[]const u8 = null;

    var pos: usize = 12;
    while (pos + 8 <= bytes.len) {
        const id = bytes[pos..][0..4];
        const size: usize = rd32(bytes, pos + 4);
        const body = pos + 8;
        const avail = bytes.len - body;
        if (std.mem.eql(u8, id, "fmt ")) {
            if (size < 16 or avail < 16) return error.InvalidAudio;
            tag = rd16(bytes, body);
            channels = rd16(bytes, body + 2);
            rate = rd32(bytes, body + 4);
            bits = rd16(bytes, body + 14);
            if (tag == 0xFFFE) {
                // Extensible: the real format is the first two bytes of the sub-format GUID.
                if (size < 26 or avail < 26) return error.InvalidAudio;
                tag = rd16(bytes, body + 24);
            }
            have_fmt = true;
        } else if (std.mem.eql(u8, id, "data")) {
            // A size of 0 or 0xFFFFFFFF (or one past the end) comes from streaming writers.
            const n = if (size == 0 or size > avail) avail else size;
            data = bytes[body..][0..n];
            if (have_fmt) break;
        }
        const next = body +| size +| (size & 1);
        if (next <= pos) break;
        pos = next;
    }
    if (!have_fmt) return error.InvalidAudio;
    const d = data orelse return error.InvalidAudio;

    const is_float = switch (tag) {
        1 => false,
        3 => true,
        else => return error.UnsupportedFormat,
    };
    try checkFormat(channels, rate);
    switch (bits) {
        8, 16, 24, 32 => {},
        64 => if (!is_float) return error.UnsupportedFormat,
        else => return error.UnsupportedFormat,
    }
    if (is_float and bits != 32 and bits != 64) return error.UnsupportedFormat;
    if (!is_float and bits == 64) return error.UnsupportedFormat;

    const bps: usize = bits / 8;
    const frame_bytes = bps * channels;
    const n_frames = d.len / frame_bytes;
    const n_samples = n_frames * channels;
    if (!sampleCountOk(n_samples)) return error.TooLong;
    const out = try gpa.alloc(f32, n_samples);
    errdefer gpa.free(out);
    for (out, 0..) |*o, i| {
        const p = d[i * bps ..];
        o.* = if (is_float) switch (bits) {
            32 => clean(@bitCast(rd32(p, 0))),
            else => clean(@floatCast(@as(f64, @bitCast(std.mem.readInt(u64, p[0..8], .little))))),
        } else switch (bits) {
            8 => (@as(f32, @floatFromInt(p[0])) - 128) / 128,
            16 => @as(f32, @floatFromInt(@as(i16, @bitCast(rd16(p, 0))))) / 32768,
            24 => blk: {
                const u: u32 = @as(u32, p[0]) | @as(u32, p[1]) << 8 | @as(u32, p[2]) << 16;
                const s: i32 = @bitCast(u << 8);
                break :blk @as(f32, @floatFromInt(s >> 8)) / 8388608;
            },
            else => @as(f32, @floatCast(@as(f64, @floatFromInt(@as(i32, @bitCast(rd32(p, 0))))) / 2147483648)),
        };
    }
    return .{ .samples = out, .sample_rate = rate, .channels = @intCast(channels) };
}

pub const WavFormat = enum { pcm16, float32 };

/// Encodes `pcm` as a canonical WAV file: 44-byte header and the samples, either 16-bit
/// integers (clipped to -1..1; the default, readable everywhere) or 32-bit floats.
/// Caller frees.
pub fn encodeWav(gpa: std.mem.Allocator, pcm: Pcm, format: WavFormat) Error![]u8 {
    try checkFormat(pcm.channels, pcm.sample_rate);
    const bps: usize = if (format == .pcm16) 2 else 4;
    const data_len = pcm.samples.len * bps;
    if (data_len > std.math.maxInt(u32) - 36) return error.TooLong;
    const out = try gpa.alloc(u8, 44 + data_len);
    errdefer gpa.free(out);
    const ch: u32 = pcm.channels;
    @memcpy(out[0..4], "RIFF");
    std.mem.writeInt(u32, out[4..8], @intCast(36 + data_len), .little);
    @memcpy(out[8..16], "WAVEfmt ");
    std.mem.writeInt(u32, out[16..20], 16, .little);
    std.mem.writeInt(u16, out[20..22], if (format == .pcm16) 1 else 3, .little);
    std.mem.writeInt(u16, out[22..24], @intCast(ch), .little);
    std.mem.writeInt(u32, out[24..28], pcm.sample_rate, .little);
    std.mem.writeInt(u32, out[28..32], pcm.sample_rate * ch * @as(u32, @intCast(bps)), .little);
    std.mem.writeInt(u16, out[32..34], @intCast(ch * bps), .little);
    std.mem.writeInt(u16, out[34..36], @intCast(bps * 8), .little);
    @memcpy(out[36..40], "data");
    std.mem.writeInt(u32, out[40..44], @intCast(data_len), .little);
    for (pcm.samples, 0..) |s, i| {
        const o = out[44 + i * bps ..];
        if (format == .pcm16) {
            std.mem.writeInt(i16, o[0..2], toI16(s), .little);
        } else {
            std.mem.writeInt(u32, o[0..4], @bitCast(clean(s)), .little);
        }
    }
    return out;
}

/// float sample -> 16-bit integer, rounded and clipped; NaN is silence.
pub fn toI16(s: f32) i16 {
    const v = std.math.clamp(clean(s), -1, 1) * 32767;
    return @intFromFloat(@round(v));
}

// ---- OGG Vorbis and MP3 -----------------------------------------------------------------

/// Decodes an Ogg Vorbis file (stb_vorbis). Mono and stereo; files with 3 to 6 channels
/// are mixed down to stereo by the decoder.
pub fn decodeOgg(gpa: std.mem.Allocator, bytes: []const u8) Error!Pcm {
    if (bytes.len < 4 or bytes.len > std.math.maxInt(c_int)) return error.InvalidAudio;
    var err: c_int = 0;
    const f = stb_vorbis_open_memory(bytes.ptr, @intCast(bytes.len), &err, null) orelse return error.InvalidAudio;
    defer stb_vorbis_close(f);
    const info = stb_vorbis_get_info(f);
    if (info.channels < 1 or info.channels > 6 or info.sample_rate == 0 or info.sample_rate > max_rate) return error.InvalidAudio;
    const ch: u32 = @min(@as(u32, @intCast(info.channels)), 2);
    const total: u64 = stb_vorbis_stream_length_in_samples(f);
    if (total == 0) return error.InvalidAudio;
    if (!sampleCountOk(total * ch)) return error.TooLong;
    const out = try gpa.alloc(f32, @intCast(total * ch));
    errdefer gpa.free(out);
    // Read until the decoder runs dry or the (header-declared) length is filled.
    var got: usize = 0;
    while (got < total) {
        const want = @min(total - got, 4096);
        const n = stb_vorbis_get_samples_float_interleaved(f, @intCast(ch), out[got * ch ..].ptr, @intCast(want * ch));
        if (n <= 0) break;
        got += @intCast(n);
    }
    if (got == 0) return error.InvalidAudio;
    const trimmed = gpa.realloc(out, got * ch) catch out[0 .. got * ch];
    for (trimmed) |*s| s.* = clean(s.*);
    return .{ .samples = trimmed, .sample_rate = info.sample_rate, .channels = @intCast(ch) };
}

/// Decodes an MP3 file (dr_mp3), mono or stereo.
pub fn decodeMp3(gpa: std.mem.Allocator, bytes: []const u8) Error!Pcm {
    if (bytes.len < 4) return error.InvalidAudio;
    const m = vass_mp3_open(bytes.ptr, bytes.len) orelse return error.InvalidAudio;
    defer vass_mp3_close(m);
    var ch: c_uint = 0;
    var rate: c_uint = 0;
    vass_mp3_info(m, &ch, &rate);
    try checkFormat(ch, rate);
    var list: std.ArrayList(f32) = .empty;
    errdefer list.deinit(gpa);
    const chunk_frames = 4096;
    var buf: [chunk_frames * 2]f32 = undefined;
    while (true) {
        const n = vass_mp3_read(m, chunk_frames, &buf);
        if (n == 0) break;
        if (!sampleCountOk(list.items.len + n * ch)) return error.TooLong;
        try list.appendSlice(gpa, buf[0 .. n * ch]);
    }
    if (list.items.len == 0) return error.InvalidAudio;
    for (list.items) |*s| s.* = clean(s.*);
    return .{ .samples = try list.toOwnedSlice(gpa), .sample_rate = rate, .channels = @intCast(ch) };
}

pub const Format = enum { wav, ogg, mp3 };

/// Recognises a format from the first bytes (RIFF/WAVE, OggS, ID3 or an MPEG frame sync).
pub fn sniff(bytes: []const u8) ?Format {
    if (bytes.len >= 12 and std.mem.eql(u8, bytes[0..4], "RIFF") and std.mem.eql(u8, bytes[8..12], "WAVE")) return .wav;
    if (bytes.len >= 4 and std.mem.eql(u8, bytes[0..4], "OggS")) return .ogg;
    if (bytes.len >= 3 and std.mem.eql(u8, bytes[0..3], "ID3")) return .mp3;
    if (bytes.len >= 2 and bytes[0] == 0xFF and bytes[1] & 0xE0 == 0xE0) return .mp3;
    return null;
}

/// Decodes WAV, OGG Vorbis or MP3, chosen by content, not by file name.
pub fn decode(gpa: std.mem.Allocator, bytes: []const u8) Error!Pcm {
    return switch (sniff(bytes) orelse return error.UnsupportedFormat) {
        .wav => decodeWav(gpa, bytes),
        .ogg => decodeOgg(gpa, bytes),
        .mp3 => decodeMp3(gpa, bytes),
    };
}

/// True for file names `decode` should be tried on (by extension, case-insensitive).
pub fn isAudioName(name: []const u8) bool {
    const ext = std.fs.path.extension(name);
    inline for (.{ ".wav", ".ogg", ".mp3" }) |e| if (std.ascii.eqlIgnoreCase(ext, e)) return true;
    return false;
}

// ---- peaks and levels -------------------------------------------------------------------

/// `n` values in 0..1 for drawing a waveform: the absolute peak (over all channels) of each
/// of `n` equal slices of the sound. A sound shorter than `n` frames repeats its frames.
/// Caller frees.
pub fn peaks(gpa: std.mem.Allocator, pcm: Pcm, n: usize) error{OutOfMemory}![]f32 {
    const out = try gpa.alloc(f32, n);
    const frames_n = pcm.frames();
    const ch: usize = @max(pcm.channels, 1);
    for (out, 0..) |*o, i| {
        if (frames_n == 0) {
            o.* = 0;
            continue;
        }
        const a = i * frames_n / n;
        const b = @min(frames_n, @max(a + 1, (i + 1) * frames_n / n));
        var m: f32 = 0;
        for (pcm.samples[a * ch .. b * ch]) |s| m = @max(m, @abs(clean(s)));
        o.* = @min(m, 1);
    }
    return out;
}

/// Largest absolute sample in `samples` (0..1, clipped).
pub fn peakOf(samples: []const f32) f32 {
    var m: f32 = 0;
    for (samples) |s| m = @max(m, @abs(clean(s)));
    return @min(m, 1);
}

/// Root-mean-square of `samples` (0..1).
pub fn rmsOf(samples: []const f32) f32 {
    if (samples.len == 0) return 0;
    var acc: f64 = 0;
    for (samples) |s| acc += @as(f64, clean(s)) * clean(s);
    return @min(1, @as(f32, @floatCast(@sqrt(acc / @as(f64, @floatFromInt(samples.len))))));
}

/// Level meter ballistics: jumps up to a new `peak` at once and falls back with a time
/// constant of `release` seconds, so a meter drawn each frame neither flickers nor sticks.
/// `seconds` is the time since the previous step.
pub fn levelStep(level: f32, peak: f32, seconds: f32, release: f32) f32 {
    const k = @exp(-@max(seconds, 0) / @max(release, 1e-4));
    return @max(peak, level * k);
}

/// Maps a linear level (0..1) to 0..1 on a decibel scale from `floor_db` (default -50) to 0,
/// which is how loud things look on a meter: speech peaks at 0.1 to 0.3 linear, which is
/// 0.6 to 0.8 here.
pub fn meterScale(level: f32, floor_db: f32) f32 {
    if (level <= 0) return 0;
    const db = 20 * std.math.log10(level);
    return std.math.clamp((db - floor_db) / -floor_db, 0, 1);
}

/// Linear gain for a volume setting: clamped to 0..4 (a slider at 1 is unity).
pub fn volumeGain(v: f32) f32 {
    if (!std.math.isFinite(v)) return 0;
    return std.math.clamp(v, 0, 4);
}

// ---- tests ------------------------------------------------------------------------------

const testing = std.testing;

fn testWav(comptime bits: u16, tag: u16, channels: u16, rate: u32, payload: []const u8) ![]u8 {
    var l: std.ArrayList(u8) = .empty;
    const a = testing.allocator;
    errdefer l.deinit(a);
    try l.appendSlice(a, "RIFF\x00\x00\x00\x00WAVEfmt ");
    try l.appendSlice(a, &std.mem.toBytes(@as(u32, 16)));
    try l.appendSlice(a, &std.mem.toBytes(tag));
    try l.appendSlice(a, &std.mem.toBytes(channels));
    try l.appendSlice(a, &std.mem.toBytes(rate));
    try l.appendSlice(a, &std.mem.toBytes(rate * @as(u32, channels) * bits / 8));
    try l.appendSlice(a, &std.mem.toBytes(@as(u16, channels * bits / 8)));
    try l.appendSlice(a, &std.mem.toBytes(bits));
    try l.appendSlice(a, "data");
    try l.appendSlice(a, &std.mem.toBytes(@as(u32, @intCast(payload.len))));
    try l.appendSlice(a, payload);
    return l.toOwnedSlice(a);
}

test "WAV: every supported sample format decodes to the same floats" {
    const a = testing.allocator;
    {
        const w = try testWav(8, 1, 1, 8000, &.{ 128, 255, 0 });
        defer a.free(w);
        const p = try decodeWav(a, w);
        defer p.deinit(a);
        try testing.expectEqual(@as(u32, 8000), p.sample_rate);
        try testing.expectEqual(@as(usize, 3), p.frames());
        try testing.expectApproxEqAbs(@as(f32, 0), p.samples[0], 1e-6);
        try testing.expectApproxEqAbs(@as(f32, 0.9921875), p.samples[1], 1e-6);
        try testing.expectApproxEqAbs(@as(f32, -1), p.samples[2], 1e-6);
    }
    {
        const w = try testWav(16, 1, 2, 44100, &std.mem.toBytes([4]i16{ 16384, -16384, 32767, -32768 }));
        defer a.free(w);
        const p = try decodeWav(a, w);
        defer p.deinit(a);
        try testing.expectEqual(@as(u8, 2), p.channels);
        try testing.expectEqual(@as(usize, 2), p.frames());
        try testing.expectApproxEqAbs(@as(f32, 0.5), p.samples[0], 1e-6);
        try testing.expectApproxEqAbs(@as(f32, -0.5), p.samples[1], 1e-6);
        try testing.expectApproxEqAbs(@as(f32, -1), p.samples[3], 1e-6);
    }
    {
        // 24-bit: +0.5 (0x400000), -0.5 (0xC00000), -1 (0x800000)
        const w = try testWav(24, 1, 1, 48000, &.{ 0, 0, 0x40, 0, 0, 0xC0, 0, 0, 0x80 });
        defer a.free(w);
        const p = try decodeWav(a, w);
        defer p.deinit(a);
        try testing.expectApproxEqAbs(@as(f32, 0.5), p.samples[0], 1e-6);
        try testing.expectApproxEqAbs(@as(f32, -0.5), p.samples[1], 1e-6);
        try testing.expectApproxEqAbs(@as(f32, -1), p.samples[2], 1e-6);
    }
    {
        const w = try testWav(32, 1, 1, 48000, &std.mem.toBytes([2]i32{ 1 << 30, std.math.minInt(i32) }));
        defer a.free(w);
        const p = try decodeWav(a, w);
        defer p.deinit(a);
        try testing.expectApproxEqAbs(@as(f32, 0.5), p.samples[0], 1e-6);
        try testing.expectApproxEqAbs(@as(f32, -1), p.samples[1], 1e-6);
    }
    {
        const w = try testWav(32, 3, 1, 22050, &std.mem.toBytes([3]f32{ 0.25, -2, std.math.nan(f32) }));
        defer a.free(w);
        const p = try decodeWav(a, w);
        defer p.deinit(a);
        try testing.expectEqual(@as(f32, 0.25), p.samples[0]);
        try testing.expectEqual(@as(f32, -2), p.samples[1]); // out of range floats are kept
        try testing.expectEqual(@as(f32, 0), p.samples[2]); // NaN is silence
    }
    {
        const w = try testWav(64, 3, 1, 22050, &std.mem.toBytes([2]f64{ 0.125, -0.5 }));
        defer a.free(w);
        const p = try decodeWav(a, w);
        defer p.deinit(a);
        try testing.expectEqual(@as(f32, 0.125), p.samples[0]);
        try testing.expectEqual(@as(f32, -0.5), p.samples[1]);
    }
}

test "WAV: tolerates streaming sizes, odd chunks, extensible, a partial frame" {
    const a = testing.allocator;
    const pay = std.mem.toBytes([2]i16{ 1000, 2000 });
    // data size 0xFFFFFFFF: take the rest of the file. A trailing odd byte is dropped.
    var w = try testWav(16, 1, 1, 8000, &(pay ++ [1]u8{7}));
    defer a.free(w);
    std.mem.writeInt(u32, w[40..44], 0xFFFFFFFF, .little);
    var p = try decodeWav(a, w);
    try testing.expectEqual(@as(usize, 2), p.frames());
    p.deinit(a);
    // data size 0 (a writer that never came back to patch the header)
    std.mem.writeInt(u32, w[40..44], 0, .little);
    p = try decodeWav(a, w);
    try testing.expectEqual(@as(usize, 2), p.frames());
    p.deinit(a);

    // An unknown odd-sized chunk before `fmt ` and a LIST chunk before `data`.
    var l: std.ArrayList(u8) = .empty;
    defer l.deinit(a);
    try l.appendSlice(a, "RIFF\x00\x00\x00\x00WAVEjunk\x03\x00\x00\x00abc\x00");
    try l.appendSlice(a, "fmt \x10\x00\x00\x00\x01\x00\x01\x00\x40\x1f\x00\x00\x80\x3e\x00\x00\x02\x00\x10\x00");
    try l.appendSlice(a, "LIST\x04\x00\x00\x00INFO");
    try l.appendSlice(a, "data\x04\x00\x00\x00");
    try l.appendSlice(a, &pay);
    p = try decodeWav(a, l.items);
    try testing.expectEqual(@as(u32, 8000), p.sample_rate);
    try testing.expectEqual(@as(usize, 2), p.frames());
    p.deinit(a);

    // WAVE_FORMAT_EXTENSIBLE carrying float32 stereo.
    var e: std.ArrayList(u8) = .empty;
    defer e.deinit(a);
    try e.appendSlice(a, "RIFF\x00\x00\x00\x00WAVEfmt \x28\x00\x00\x00\xfe\xff\x02\x00\x80\xbb\x00\x00\x00\xdc\x05\x00\x08\x00\x20\x00");
    try e.appendSlice(a, "\x16\x00\x20\x00\x03\x00\x00\x00\x03\x00\x00\x00\x00\x00\x10\x00\x80\x00\x00\xaa\x00\x38\x9b\x71");
    try e.appendSlice(a, "data\x08\x00\x00\x00");
    try e.appendSlice(a, &std.mem.toBytes([2]f32{ 0.5, -0.5 }));
    p = try decodeWav(a, e.items);
    try testing.expectEqual(@as(u8, 2), p.channels);
    try testing.expectEqual(@as(u32, 48000), p.sample_rate);
    try testing.expectEqual(@as(f32, -0.5), p.samples[1]);
    p.deinit(a);
}

test "WAV: malformed and unsupported input is an error, never a crash" {
    const a = testing.allocator;
    try testing.expectError(error.InvalidAudio, decodeWav(a, ""));
    try testing.expectError(error.InvalidAudio, decodeWav(a, "RIFF"));
    try testing.expectError(error.InvalidAudio, decodeWav(a, "RIFF\x00\x00\x00\x00WAVE")); // no chunks
    try testing.expectError(error.InvalidAudio, decodeWav(a, "not a wav file at all, really"));
    const good = try testWav(16, 1, 1, 8000, &.{ 1, 0, 2, 0 });
    defer a.free(good);
    // Every truncation either decodes (shorter) or errors; none may crash.
    for (0..good.len) |n| {
        if (decodeWav(a, good[0..n])) |p| p.deinit(a) else |_| {}
    }
    // Header lies: zero channels, zero rate, 12-bit, A-law, 6 channels, fmt chunk too short.
    for ([_]struct { off: usize, val: u16, want: anyerror }{
        .{ .off = 22, .val = 0, .want = error.InvalidAudio },
        .{ .off = 34, .val = 12, .want = error.UnsupportedFormat },
        .{ .off = 20, .val = 6, .want = error.UnsupportedFormat },
        .{ .off = 22, .val = 6, .want = error.UnsupportedFormat },
    }) |c| {
        const bad = try a.dupe(u8, good);
        defer a.free(bad);
        std.mem.writeInt(u16, bad[c.off..][0..2], c.val, .little);
        try testing.expectError(c.want, decodeWav(a, bad));
    }
    const norate = try a.dupe(u8, good);
    defer a.free(norate);
    std.mem.writeInt(u32, norate[24..28], 0, .little);
    try testing.expectError(error.InvalidAudio, decodeWav(a, norate));
    const short_fmt = try a.dupe(u8, good);
    defer a.free(short_fmt);
    std.mem.writeInt(u32, short_fmt[16..20], 8, .little);
    try testing.expectError(error.InvalidAudio, decodeWav(a, short_fmt));
    // A chunk size that overflows pointer arithmetic does not loop or overflow.
    const huge = try a.dupe(u8, good);
    defer a.free(huge);
    std.mem.writeInt(u32, huge[16..20], 0xFFFFFFFF, .little);
    try testing.expectError(error.InvalidAudio, decodeWav(a, huge));
    // Pseudo-random garbage behind a valid RIFF/WAVE header.
    var prng = std.Random.DefaultPrng.init(42);
    var junk: [256]u8 = undefined;
    for (0..200) |_| {
        prng.random().bytes(&junk);
        @memcpy(junk[0..4], "RIFF");
        @memcpy(junk[8..12], "WAVE");
        if (decodeWav(a, &junk)) |p| p.deinit(a) else |_| {}
    }
}

test "WAV: encode then decode round-trips; float32 is exact, pcm16 is within one step" {
    const a = testing.allocator;
    var s: [200]f32 = undefined;
    for (&s, 0..) |*v, i| v.* = 0.9 * @sin(@as(f32, @floatFromInt(i)) * 0.1);
    const pcm: Pcm = .{ .samples = &s, .sample_rate = 16000, .channels = 2 };
    const w16 = try encodeWav(a, pcm, .pcm16);
    defer a.free(w16);
    try testing.expectEqual(@as(usize, 44 + 400), w16.len);
    try testing.expectEqual(@as(u32, 436), rd32(w16, 4));
    const back = try decodeWav(a, w16);
    defer back.deinit(a);
    try testing.expectEqual(@as(u8, 2), back.channels);
    try testing.expectEqual(@as(u32, 16000), back.sample_rate);
    for (s, back.samples) |x, y| try testing.expectApproxEqAbs(x, y, 6e-5);
    const wf = try encodeWav(a, pcm, .float32);
    defer a.free(wf);
    const backf = try decodeWav(a, wf);
    defer backf.deinit(a);
    try testing.expectEqualSlices(f32, &s, backf.samples);
    // Clipping and NaN on the way out.
    const wild: Pcm = .{ .samples = @constCast(&[_]f32{ 3, -3, std.math.nan(f32) }), .sample_rate = 8000, .channels = 1 };
    const ww = try encodeWav(a, wild, .pcm16);
    defer a.free(ww);
    const wb = try decodeWav(a, ww);
    defer wb.deinit(a);
    try testing.expectApproxEqAbs(@as(f32, 1), wb.samples[0], 1e-4);
    try testing.expectApproxEqAbs(@as(f32, -1), wb.samples[1], 1e-4);
    try testing.expectEqual(@as(f32, 0), wb.samples[2]);
    try testing.expectError(error.UnsupportedFormat, encodeWav(a, .{ .samples = &s, .sample_rate = 8000, .channels = 3 }, .pcm16));
    try testing.expectError(error.InvalidAudio, encodeWav(a, .{ .samples = &s, .sample_rate = 0, .channels = 1 }, .pcm16));
}

test "sniff and isAudioName" {
    try testing.expectEqual(Format.wav, sniff("RIFF\x00\x00\x00\x00WAVEfmt ").?);
    try testing.expectEqual(Format.ogg, sniff("OggS\x00\x02").?);
    try testing.expectEqual(Format.mp3, sniff("ID3\x04").?);
    try testing.expectEqual(Format.mp3, sniff("\xff\xfb\x90\x00").?);
    try testing.expect(sniff("hello") == null);
    try testing.expect(sniff("") == null);
    try testing.expectError(error.UnsupportedFormat, decode(testing.allocator, "hello world"));
    try testing.expect(isAudioName("/a/b/Memo.WAV"));
    try testing.expect(isAudioName("x.ogg") and isAudioName("x.mp3"));
    try testing.expect(!isAudioName("x.png") and !isAudioName("wav"));
}

test "peaks: abs-peak per bucket, over all channels" {
    const a = testing.allocator;
    // 8 stereo frames; the loud sample is on the right channel of frame 5.
    const s = [_]f32{ 0.1, 0, 0, -0.2, 0.3, 0, 0, 0, 0, 0, 0, -0.9, 0.5, 0, 0, 0 };
    const pcm: Pcm = .{ .samples = @constCast(&s), .sample_rate = 8000, .channels = 2 };
    const p = try peaks(a, pcm, 4);
    defer a.free(p);
    try testing.expectEqualSlices(f32, &.{ 0.2, 0.3, 0.9, 0.5 }, p);
    // More buckets than frames: every bucket still sees a frame.
    const many = try peaks(a, pcm, 16);
    defer a.free(many);
    try testing.expectEqual(@as(usize, 16), many.len);
    try testing.expectEqual(@as(f32, 0.9), many[10]);
    // Fewer: one bucket is the global peak. Empty sound and n = 0 are fine.
    const one = try peaks(a, pcm, 1);
    defer a.free(one);
    try testing.expectEqual(@as(f32, 0.9), one[0]);
    const none = try peaks(a, .{ .samples = &.{}, .sample_rate = 8000, .channels = 1 }, 3);
    defer a.free(none);
    try testing.expectEqualSlices(f32, &.{ 0, 0, 0 }, none);
    const zero = try peaks(a, pcm, 0);
    defer a.free(zero);
    try testing.expectEqual(@as(usize, 0), zero.len);
    // Values above 1 are clipped to 1.
    const loud = try peaks(a, .{ .samples = @constCast(&[_]f32{ 2, 0.5 }), .sample_rate = 8000, .channels = 1 }, 2);
    defer a.free(loud);
    try testing.expectEqualSlices(f32, &.{ 1, 0.5 }, loud);
}

test "levels: peak, rms, meter ballistics and scale" {
    try testing.expectEqual(@as(f32, 0.5), peakOf(&.{ 0.1, -0.5, 0.25 }));
    try testing.expectEqual(@as(f32, 0), peakOf(&.{}));
    try testing.expectApproxEqAbs(@as(f32, 0.5), rmsOf(&.{ 0.5, -0.5, 0.5, -0.5 }), 1e-6);
    try testing.expectEqual(@as(f32, 0), rmsOf(&.{}));
    // A louder peak is taken at once; silence decays by exp(-t/release).
    try testing.expectEqual(@as(f32, 0.8), levelStep(0.2, 0.8, 0.016, 0.2));
    try testing.expectApproxEqAbs(@as(f32, 0.8 * @exp(@as(f32, -0.5))), levelStep(0.8, 0, 0.1, 0.2), 1e-5);
    // The meter scale: full scale is 1, -50 dB is 0, -20 dB (0.1) is 0.6.
    try testing.expectApproxEqAbs(@as(f32, 1), meterScale(1, -50), 1e-6);
    try testing.expectEqual(@as(f32, 0), meterScale(0, -50));
    try testing.expectEqual(@as(f32, 0), meterScale(0.001, -50));
    try testing.expectApproxEqAbs(@as(f32, 0.6), meterScale(0.1, -50), 1e-5);
    try testing.expectEqual(@as(f32, 1), meterScale(5, -50));
    // Volume settings are clamped and NaN is mute.
    try testing.expectEqual(@as(f32, 0), volumeGain(-1));
    try testing.expectEqual(@as(f32, 4), volumeGain(100));
    try testing.expectEqual(@as(f32, 0), volumeGain(std.math.nan(f32)));
    try testing.expectEqual(@as(f32, 0.3), volumeGain(0.3));
}

test "ogg and mp3: garbage and empty input are errors" {
    const a = testing.allocator;
    try testing.expectError(error.InvalidAudio, decodeOgg(a, ""));
    try testing.expectError(error.InvalidAudio, decodeOgg(a, "OggS this is not vorbis data, not at all......"));
    try testing.expectError(error.InvalidAudio, decodeMp3(a, ""));
    try testing.expectError(error.InvalidAudio, decodeMp3(a, "ID3 and then nothing that looks like a frame......"));
    var prng = std.Random.DefaultPrng.init(7);
    var junk: [512]u8 = undefined;
    for (0..50) |_| {
        prng.random().bytes(&junk);
        @memcpy(junk[0..4], "OggS");
        if (decodeOgg(a, &junk)) |p| p.deinit(a) else |_| {}
        junk[0] = 0xFF;
        junk[1] = 0xFB;
        if (decodeMp3(a, &junk)) |p| p.deinit(a) else |_| {}
    }
}

fn crossings(p: Pcm) usize {
    var n: usize = 0;
    var i: usize = 1;
    while (i < p.frames()) : (i += 1) {
        if ((p.samples[i - 1] < 0) != (p.samples[i] < 0)) n += 1;
    }
    return n;
}

test "ogg vorbis: a 440 Hz tone decodes to the right rate, length and pitch" {
    const a = testing.allocator;
    const bytes = @embedFile("testdata/tone.ogg");
    try testing.expectEqual(Format.ogg, sniff(bytes).?);
    const p = try decode(a, bytes);
    defer p.deinit(a);
    try testing.expectEqual(@as(u32, 22050), p.sample_rate);
    try testing.expectEqual(@as(u8, 1), p.channels);
    try testing.expectApproxEqAbs(@as(f64, 0.25), p.duration(), 0.01);
    try testing.expectApproxEqAbs(@as(f32, 0.5), peakOf(p.samples), 0.08);
    // 440 Hz for 0.25 s is 110 cycles, 220 zero crossings.
    try testing.expectApproxEqAbs(@as(f32, 220), @as(f32, @floatFromInt(crossings(p))), 6);
    // A truncated file decodes what it has, or fails cleanly.
    for ([_]usize{ 40, 400, 2000, bytes.len - 5 }) |n| {
        if (decodeOgg(a, bytes[0..n])) |q| q.deinit(a) else |_| {}
    }
}

test "mp3: a 440 Hz tone decodes to the right rate and pitch" {
    const a = testing.allocator;
    const bytes = @embedFile("testdata/tone.mp3");
    try testing.expectEqual(Format.mp3, sniff(bytes).?);
    const p = try decode(a, bytes);
    defer p.deinit(a);
    try testing.expectEqual(@as(u32, 22050), p.sample_rate);
    try testing.expectEqual(@as(u8, 1), p.channels);
    // The encoder pads the start and end, so a little longer than 0.25 s.
    try testing.expect(p.duration() >= 0.25 and p.duration() < 0.6);
    try testing.expect(peakOf(p.samples) > 0.3 and peakOf(p.samples) < 0.8);
    const c: f32 = @floatFromInt(crossings(p));
    try testing.expect(c > 200 and c < 400); // the padding adds a few
    for ([_]usize{ 10, 300, bytes.len - 3 }) |n| {
        if (decodeMp3(a, bytes[0..n])) |q| q.deinit(a) else |_| {}
    }
}
