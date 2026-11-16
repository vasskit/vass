//! Audio: generated tones (overlapping voices), embedded WAV and OGG sounds, a looped
//! sound with pause/resume, a master-volume slider, recording from the microphone with a
//! live level meter, and a waveform of the recording with playback, click-to-seek and
//! save-to-WAV.
//!
//!     zig build audio                      run it (plays sound; Record asks for the microphone)
//!     zig build audio -- --snapshot DIR    synthetic data on SDL's silent "dummy" driver,
//!                                          draw a few frames, save DIR/audio.bmp, exit
const std = @import("std");
const vass = @import("vass");

const Rect = vass.Rect;
const Color = vass.Color;
const Ui = vass.Ui;
const ui_mod = vass.ui;
const audio_mod = vass.audio;
const Sound = audio_mod.Sound;
const Voice = audio_mod.Voice;

const win_w = 760;
const win_h = 600;
const margin: f32 = 24;

const chime_wav = @embedFile("assets/chime.wav");
const arp_ogg = @embedFile("assets/arp.ogg");

const note_names = [_][]const u8{ "C4", "E4", "G4", "C5" };
const note_hz = [_]f32{ 261.63, 329.63, 392.0, 523.25 };

const App = struct {
    state: ui_mod.State = .{},
    audio: audio_mod.Audio,
    icons: struct { mic: vass.SvgIcon = .none, play: vass.SvgIcon = .none, pause: vass.SvgIcon = .none, stop: vass.SvgIcon = .none } = .{},
    notes: [4]Sound = @splat(.none),
    chime: Sound = .none,
    arp: Sound = .none,
    pad: Sound = .none,
    pad_voice: Voice = .none,
    pad_volume: f32 = 0.5,
    master: f32 = 0.8,
    clip: Sound = .none,
    clip_peaks: []f32 = &.{},
    clip_voice: Voice = .none,
    status: [200]u8 = undefined,
    status_len: usize = 0,
    /// Shown in snapshot mode in place of the live microphone level.
    synthetic: bool = false,

    fn setStatus(app: *App, comptime fmt: []const u8, args: anytype) void {
        app.status_len = if (std.fmt.bufPrint(&app.status, fmt, args)) |s| s.len else |_| 0;
    }
};

fn makeTone(gpa: std.mem.Allocator, hz: f32, seconds: f32, rate: u32, decay: f32) ![]f32 {
    const n: usize = @intFromFloat(seconds * @as(f32, @floatFromInt(rate)));
    const out = try gpa.alloc(f32, n);
    const r: f32 = @floatFromInt(rate);
    for (out, 0..) |*s, i| {
        const t = @as(f32, @floatFromInt(i)) / r;
        const env = @min(1, t / 0.006) * @exp(-decay * t);
        s.* = 0.4 * env * (@sin(2 * std.math.pi * hz * t) + 0.3 * @sin(4 * std.math.pi * hz * t));
    }
    return out;
}

/// Two seconds of a soft chord whose partials all fit a whole number of cycles in the
/// loop, so it repeats without a click.
fn makePad(gpa: std.mem.Allocator) ![]f32 {
    const rate: u32 = 22050;
    const out = try gpa.alloc(f32, rate * 2);
    const r: f32 = @floatFromInt(rate);
    for (out, 0..) |*s, i| {
        const t = @as(f32, @floatFromInt(i)) / r;
        const tr = 0.75 + 0.25 * @sin(2 * std.math.pi * t / 2); // one slow swell per loop
        s.* = 0.18 * tr * (@sin(2 * std.math.pi * 220 * t) + @sin(2 * std.math.pi * 277.5 * t) + @sin(2 * std.math.pi * 330 * t));
    }
    return out;
}

/// A stand-in for a voice memo: bursts of a few harmonics under a syllable-like envelope.
fn makeSpeechish(gpa: std.mem.Allocator, seconds: f32, rate: u32) ![]f32 {
    const n: usize = @intFromFloat(seconds * @as(f32, @floatFromInt(rate)));
    const out = try gpa.alloc(f32, n);
    var prng = std.Random.DefaultPrng.init(11);
    const rnd = prng.random();
    const r: f32 = @floatFromInt(rate);
    var amp: f32 = 0;
    var target: f32 = 0;
    var f0: f32 = 140;
    for (out, 0..) |*s, i| {
        const t = @as(f32, @floatFromInt(i)) / r;
        if (i % (rate / 7) == 0) { // a new "syllable" every ~140 ms; a pause now and then
            target = if (rnd.float(f32) < 0.18) 0.02 else 0.25 + 0.7 * rnd.float(f32);
            f0 = 110 + 90 * rnd.float(f32);
        }
        amp += (target - amp) * 0.0012;
        const v = @sin(2 * std.math.pi * f0 * t) + 0.5 * @sin(4 * std.math.pi * f0 * t) + 0.3 * @sin(6 * std.math.pi * f0 * t);
        s.* = 0.5 * amp * v + 0.01 * (rnd.float(f32) - 0.5);
    }
    return out;
}

fn loadSounds(app: *App, win: *vass.platform.Window, gpa: std.mem.Allocator) !void {
    app.icons = .{
        .mic = try win.loadSvg(@embedFile("assets/icons/lucide-mic.svg")),
        .play = try win.loadSvg(@embedFile("assets/icons/lucide-play.svg")),
        .pause = try win.loadSvg(@embedFile("assets/icons/lucide-pause.svg")),
        .stop = try win.loadSvg(@embedFile("assets/icons/lucide-square.svg")),
    };
    for (&app.notes, note_hz) |*s, hz| {
        const t = try makeTone(gpa, hz, 1.2, 22050, 3.5);
        defer gpa.free(t);
        s.* = try app.audio.soundFromSamples(t, 22050, 1);
    }
    app.chime = try app.audio.loadSound(chime_wav);
    app.arp = try app.audio.loadSound(arp_ogg);
    const pad = try makePad(gpa);
    defer gpa.free(pad);
    app.pad = try app.audio.soundFromSamples(pad, 22050, 1);
}

fn setClip(app: *App, gpa: std.mem.Allocator, clip: Sound) !void {
    if (app.clip.id != 0) {
        app.audio.unloadSound(app.clip); // stops its voice too
        gpa.free(app.clip_peaks);
    }
    app.clip = clip;
    app.clip_voice = .none;
    app.clip_peaks = (try app.audio.soundPeaks(gpa, clip, 240)) orelse &.{};
}

fn fmtTime(buf: []u8, seconds: f32) []const u8 {
    const total: u32 = @intFromFloat(@max(0, seconds));
    return std.fmt.bufPrint(buf, "{d}:{d:0>2}", .{ total / 60, total % 60 }) catch "";
}

fn heading(ui: *Ui, x: f32, y: f32, str: []const u8) void {
    ui.labelAt(x, y, str, .{ .size = 11, .color = ui.theme.dim, .weight = .semibold });
}

/// A button that stands out from the card it sits on.
fn cardButton(ui: *Ui, r: Rect, str: []const u8) bool {
    const t = ui.theme;
    return ui.chip(r, str, .{ .fill = t.track, .hover_fill = t.button_on, .size = 12, .radius = 8, .weight = .medium }).clicked;
}

fn playNote(app: *App, s: Sound) void {
    _ = app.audio.play(s, .{ .volume = 0.9 }) catch |e| app.setStatus("Could not play: {s}", .{@errorName(e)});
}

fn frame(app: *App, ui: *Ui, gpa: std.mem.Allocator) void {
    const t = ui.theme;
    const audio = &app.audio;
    audio.update();
    var y: f32 = 20;
    ui.labelAt(margin, y, "Audio", .{ .size = 24 });
    y += 46;

    // Master volume.
    ui.labelAt(margin, y + 5, "Master volume", .{ .color = t.dim });
    if (ui.slider(.{ .x = margin + 130, .y = y, .w = 260, .h = 26 }, &app.master, .{ .min = 0, .max = 1 }).changed) {
        audio.setMasterVolume(app.master);
    }
    var nb: [16]u8 = undefined;
    ui.labelAt(margin + 404, y + 5, std.fmt.bufPrint(&nb, "{d}%", .{@as(u32, @intFromFloat(@round(app.master * 100)))}) catch "", .{});
    y += 48;

    // One-shot sounds: voices overlap, so press several quickly.
    heading(ui, margin, y, "ONE-SHOTS (PRESS SEVERAL: THEY OVERLAP)");
    y += 20;
    const card1: Rect = .{ .x = margin, .y = y, .w = win_w - 2 * margin, .h = 80 };
    ui.list.rrect(card1, 12, t.card);
    var x = card1.x + 16;
    for (note_names, 0..) |name, i| {
        if (cardButton(ui, .{ .x = x, .y = y + 16, .w = 64, .h = 30 }, name)) playNote(app, app.notes[i]);
        x += 72;
    }
    if (cardButton(ui, .{ .x = x + 8, .y = y + 16, .w = 84, .h = 30 }, "Chord")) for (app.notes[0..3]) |s| playNote(app, s);
    if (cardButton(ui, .{ .x = x + 100, .y = y + 16, .w = 104, .h = 30 }, "chime.wav")) playNote(app, app.chime);
    if (cardButton(ui, .{ .x = x + 212, .y = y + 16, .w = 104, .h = 30 }, "arp.ogg")) playNote(app, app.arp);
    var vb: [64]u8 = undefined;
    ui.labelAt(card1.x + 16, y + 56, std.fmt.bufPrint(&vb, "{d} of {d} voices busy", .{ audio.activeVoices(), audio_mod.max_voices }) catch "", .{ .size = 11, .color = t.dim });
    y += card1.h + 22;

    // A looped sound with pause/resume and its own volume.
    heading(ui, margin, y, "LOOP, PAUSE AND RESUME");
    y += 20;
    const card2: Rect = .{ .x = margin, .y = y, .w = win_w - 2 * margin, .h = 64 };
    ui.list.rrect(card2, 12, t.card);
    const pad_state = audio.voiceState(app.pad_voice);
    const pbtn: Rect = .{ .x = card2.x + 14, .y = y + 14, .w = 36, .h = 36 };
    if (ui.iconButton(pbtn, if (pad_state == .playing) app.icons.pause else app.icons.play, .{ .icon_size = 18, .active = pad_state == .playing }).clicked) {
        switch (pad_state) {
            .playing => audio.pause(app.pad_voice),
            .paused => audio.resumeVoice(app.pad_voice),
            .ended => app.pad_voice = audio.play(app.pad, .{ .loop = true, .volume = app.pad_volume }) catch .none,
        }
    }
    if (ui.iconButton(.{ .x = pbtn.x + 44, .y = y + 14, .w = 36, .h = 36 }, app.icons.stop, .{ .icon_size = 16, .disabled = pad_state == .ended }).clicked) {
        audio.stop(app.pad_voice);
        app.pad_voice = .none;
    }
    ui.labelAt(card2.x + 112, y + 24, "Pad volume", .{ .color = t.dim });
    if (ui.slider(.{ .x = card2.x + 196, .y = y + 19, .w = 200, .h = 26 }, &app.pad_volume, .{}).changed) audio.setVolume(app.pad_voice, app.pad_volume);
    const pos_txt = std.fmt.bufPrint(&vb, "{s} {d:.1} s", .{ switch (pad_state) {
        .playing => "playing",
        .paused => "paused",
        .ended => "stopped",
    }, audio.position(app.pad_voice) }) catch "";
    ui.label(.{ .x = card2.x + card2.w - 16, .y = y + 24, .w = 0, .h = 16 }, pos_txt, .{ .color = t.dim, .@"align" = .right });
    y += card2.h + 22;

    // Recording and the recorded clip.
    heading(ui, margin, y, "RECORD, PLAY BACK, SEEK, SAVE");
    y += 20;
    const card3: Rect = .{ .x = margin, .y = y, .w = win_w - 2 * margin, .h = 200 };
    ui.list.rrect(card3, 12, t.card);
    const recording = audio.isRecording();
    const rbtn: Rect = .{ .x = card3.x + 14, .y = y + 14, .w = 40, .h = 40 };
    if (ui.iconButton(rbtn, if (recording) app.icons.stop else app.icons.mic, .{ .icon_size = 20, .color = if (recording) t.bad else null, .active = recording }).clicked) {
        if (recording) {
            if (audio.stopRecording()) |clip| {
                setClip(app, gpa, clip) catch {};
                app.setStatus("Recorded {d:.1} s", .{audio.soundDuration(clip)});
            } else |e| app.setStatus("Nothing recorded ({s})", .{@errorName(e)});
        } else if (audio.startRecording(.{ .sample_rate = 22050 })) {
            app.setStatus("Recording...", .{});
        } else |e| switch (e) {
            error.PermissionDenied => app.setStatus("Microphone access is denied: allow it in System Settings > Privacy & Security > Microphone", .{}),
            error.NoDevice => app.setStatus("No microphone available", .{}),
            else => app.setStatus("Could not record: {s}", .{@errorName(e)}),
        }
    }
    // Level meter and timer.
    const live = recording or app.synthetic;
    const lvl: f32 = if (app.synthetic) 0.14 else audio.level();
    const secs: f32 = if (app.synthetic) 6.5 else audio.recordingSeconds();
    if (live) ui.list.circle(rbtn.x + rbtn.w + 18, y + 34, 5, t.bad);
    ui.labelAt(rbtn.x + rbtn.w + 32, y + 26, if (live) fmtTime(&nb, secs) else "Ready", .{ .size = 15, .color = if (live) t.text else t.dim });
    ui.bar(.{ .x = card3.x + 170, .y = y + 30, .w = 300, .h = 8 }, if (live) audio_mod.meterScale(lvl, -50) else 0, if (lvl > 0.9) t.bad else t.good);
    ui.labelAt(card3.x + 484, y + 26, "level", .{ .size = 11, .color = t.dim });
    if (recording and audio.recordingState() == .limit_reached) app.setStatus("Time limit reached: press stop", .{});

    // The recorded clip.
    if (app.clip.id != 0) {
        const dur = audio.soundDuration(app.clip);
        const st = audio.voiceState(app.clip_voice);
        const pos: f32 = if (st == .ended) 0 else audio.position(app.clip_voice);
        const play_r: Rect = .{ .x = card3.x + 14, .y = y + 78, .w = 40, .h = 40 };
        if (ui.iconButton(play_r, if (st == .playing) app.icons.pause else app.icons.play, .{ .icon_size = 20, .active = st == .playing }).clicked) {
            switch (st) {
                .playing => audio.pause(app.clip_voice),
                .paused => audio.resumeVoice(app.clip_voice),
                .ended => app.clip_voice = audio.play(app.clip, .{}) catch .none,
            }
        }
        const wf: Rect = .{ .x = card3.x + 68, .y = y + 70, .w = card3.w - 68 - 16, .h = 56 };
        const res = ui.waveform(wf, app.clip_peaks, .{ .progress = if (dur > 0) pos / dur else 0, .bar_width = 3, .gap = 2 });
        if (res.seek) |f| {
            // Seeking a finished clip starts it from there, paused.
            if (st == .ended) {
                app.clip_voice = audio.play(app.clip, .{ .start = f * dur }) catch .none;
                audio.pause(app.clip_voice);
            } else audio.seek(app.clip_voice, f * dur);
        }
        var tb: [32]u8 = undefined;
        var tb2: [32]u8 = undefined;
        ui.labelAt(wf.x, wf.y + wf.h + 8, std.fmt.bufPrint(&tb, "{s} / {s}", .{ fmtTime(&tb2, pos), fmtTime(&nb, dur) }) catch "", .{ .size = 12, .color = t.dim });
        if (cardButton(ui, .{ .x = card3.x + card3.w - 16 - 110, .y = y + 134, .w = 110, .h = 30 }, "Save WAV")) {
            if (audio.saveWav(app.clip, "vass-recording.wav")) {
                app.setStatus("Saved vass-recording.wav in the current folder", .{});
            } else |e| app.setStatus("Could not save: {s}", .{@errorName(e)});
        }
    } else {
        ui.label(.{ .x = card3.x + card3.w / 2, .y = y + 96, .w = 0, .h = 16 }, "Press the microphone, speak, then stop to see the recording here", .{ .color = t.dim, .@"align" = .center });
    }
    ui.label(.{ .x = card3.x + 16, .y = y + card3.h - 34, .w = card3.w - 32, .h = 16 }, app.status[0..app.status_len], .{ .size = 11.5, .color = t.dim });
    y += card3.h + 10;
    var db: [96]u8 = undefined;
    ui.labelAt(margin, y, std.fmt.bufPrint(&db, "Output driver: {s}", .{audio.driverName() orelse "not opened yet"}) catch "", .{ .size = 11, .color = t.dim });
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    var snapshot_dir: ?[]const u8 = null;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--snapshot") and i + 1 < args.len) {
            i += 1;
            snapshot_dir = args[i];
        } else {
            std.debug.print("usage: audio [--snapshot DIR]\n", .{});
            return;
        }
    }

    var win = try vass.platform.Window.init(gpa, .{ .title = "Audio", .width = win_w, .height = win_h });
    defer win.deinit();
    // The silent dummy driver in snapshot mode: nothing is ever played or recorded.
    var app: App = .{ .audio = audio_mod.Audio.init(gpa, .{ .driver = if (snapshot_dir != null) "dummy" else null }) };
    defer app.audio.deinit();
    defer if (app.clip.id != 0) gpa.free(app.clip_peaks);
    try loadSounds(&app, &win, gpa);

    if (snapshot_dir != null) {
        app.synthetic = true;
        const speech = try makeSpeechish(gpa, 6.5, 22050);
        defer gpa.free(speech);
        try setClip(&app, gpa, try app.audio.soundFromSamples(speech, 22050, 1));
        // Part-way through, paused there. The pad is "playing" too.
        app.clip_voice = try app.audio.play(app.clip, .{ .start = 0.4 * 6.5, .volume = 0 });
        app.audio.pause(app.clip_voice);
        app.pad_voice = try app.audio.play(app.pad, .{ .loop = true, .volume = 0 });
        app.audio.pause(app.pad_voice);
        app.master = 0.8;
        app.setStatus("Recorded 6.5 s (synthetic data on the silent dummy driver)", .{});
    }

    var list = vass.DisplayList.init(gpa);
    defer list.deinit();
    const theme: vass.ui.Theme = .{ .card_radius = 12 };
    var input: ui_mod.Input = .{};
    var n: u32 = 0;
    var running = true;
    while (running) : (n += 1) {
        while (vass.platform.pollEvent()) |ev| {
            switch (ev) {
                .quit, .close_requested => running = false,
                else => {},
            }
            if (snapshot_dir == null) input.feed(ev, win.id());
        }
        input.time = if (snapshot_dir != null) 0 else @as(f64, @floatFromInt(vass.platform.ticks())) / 1000.0;
        list.reset();
        var ui = Ui.init(&list, &win, input, theme);
        ui.state = &app.state;
        frame(&app, &ui, gpa);

        const snap = if (snapshot_dir) |dir| n == 3 and dir.len > 0 else false;
        if (snap) win.snapshot_path = try std.fmt.allocPrintSentinel(arena, "{s}/audio.bmp", .{snapshot_dir.?}, 0);
        win.render(&list, theme.bg);
        if (snap) running = false;
        input.endFrame();
        // The loop already redraws every frame, so progress and meters move without input.
        vass.platform.sleepMs(16);
    }
}
