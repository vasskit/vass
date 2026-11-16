//! Which parts of a string are emoji. Pure Zig, no font access: the SDL backend uses it to
//! draw each emoji cluster with the colour emoji font and the rest of the text with the UI font.
//!
//! Emoji are found by extended grapheme cluster (see `grapheme.zig`), so a ZWJ family, a flag
//! (two regional indicators), a skin-tone sequence, a keycap and a character with U+FE0F are
//! one unit each. A cluster counts as an emoji when UTS #51 says it is shown as one:
//!
//!   * it contains U+FE0F (emoji presentation selector) or U+20E3 (combining keycap),
//!   * it starts with a regional indicator (a flag),
//!   * it is a tag sequence (a base followed by U+E0020..U+E007F, as in the flag of Scotland),
//!   * it has a skin-tone modifier (U+1F3FB..U+1F3FF) or joins pictographs with a ZWJ,
//!   * or its first code point has Emoji_Presentation (a default-colour emoji such as U+1F600).
//!
//! A pictograph with text presentation by default and no U+FE0F (U+2764 on its own, U+00A9) is
//! not an emoji here; it is drawn with the text fonts. U+FE0E (text presentation selector) also
//! keeps a cluster out. The tables are generated (`tools/gen_emoji.py`, Unicode `unicode_version`).
const std = @import("std");
const grapheme = @import("grapheme.zig");
const data = @import("emoji_data.zig");

pub const unicode_version = data.unicode_version;

const vs15: u21 = 0xFE0E;
const vs16: u21 = 0xFE0F;
const zwj: u21 = 0x200D;
const keycap: u21 = 0x20E3;

fn isRegionalIndicator(cp: u21) bool {
    return cp >= 0x1F1E6 and cp <= 0x1F1FF;
}

fn isSkinTone(cp: u21) bool {
    return cp >= 0x1F3FB and cp <= 0x1F3FF;
}

fn isTag(cp: u21) bool {
    return cp >= 0xE0020 and cp <= 0xE007F;
}

/// Whether `cp` has the Emoji_Presentation property.
pub fn hasEmojiPresentation(cp: u21) bool {
    if (cp < 0x231A) return false;
    var lo: usize = 0;
    var hi: usize = data.emoji_presentation.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const r = data.emoji_presentation[mid];
        if (cp < r[0]) {
            hi = mid;
        } else if (cp > r[1]) {
            lo = mid + 1;
        } else return true;
    }
    return false;
}

/// Whether the grapheme cluster `cluster` is shown as a (colour) emoji. Invalid UTF-8 is not.
pub fn isEmojiCluster(cluster: []const u8) bool {
    if (cluster.len == 0) return false;
    const first_len = std.unicode.utf8ByteSequenceLength(cluster[0]) catch return false;
    if (first_len > cluster.len) return false;
    const first = std.unicode.utf8Decode(cluster[0..first_len]) catch return false;
    var has_vs16 = false;
    var has_zwj = false;
    var has_keycap = false;
    var has_skin = false;
    var has_tag = false;
    var rest = cluster[first_len..];
    while (rest.len > 0) {
        const n = std.unicode.utf8ByteSequenceLength(rest[0]) catch return false;
        if (n > rest.len) return false;
        const cp = std.unicode.utf8Decode(rest[0..n]) catch return false;
        if (cp == vs15) return false;
        if (cp == vs16) has_vs16 = true;
        if (cp == zwj) has_zwj = true;
        if (cp == keycap) has_keycap = true;
        if (isSkinTone(cp)) has_skin = true;
        if (isTag(cp)) has_tag = true;
        rest = rest[n..];
    }
    if (isRegionalIndicator(first)) return true;
    if (has_keycap) return true;
    if (!grapheme.isExtendedPictographic(first) and !isSkinTone(first)) return false;
    return has_vs16 or has_zwj or has_skin or has_tag or hasEmojiPresentation(first) or isSkinTone(first);
}

/// True when `text` might hold an emoji, judged from the bytes alone: some code point is U+2000
/// or above (every emoji sequence has one: the pictographs, U+200D, U+FE0F, U+20E3 and the
/// regional indicators all are). A cheap test for the common all-Latin string.
pub fn mayContainEmoji(text: []const u8) bool {
    for (text) |b| if (b >= 0xE2) return true;
    return false;
}

/// One piece of a string: either a single emoji cluster or a stretch of everything else.
pub const Run = struct {
    start: usize,
    end: usize,
    emoji: bool,

    pub fn slice(r: Run, text: []const u8) []const u8 {
        return text[r.start..r.end];
    }
};

/// Splits a string into `Run`s: each emoji cluster alone, the text between them in one run.
/// The runs tile the string, so their lengths add up to its length.
pub const RunIterator = struct {
    text: []const u8,
    pos: usize = 0,

    pub fn next(it: *RunIterator) ?Run {
        if (it.pos >= it.text.len) return null;
        const start = it.pos;
        const first_end = grapheme.nextBoundary(it.text, start);
        if (isEmojiCluster(it.text[start..first_end])) {
            it.pos = first_end;
            return .{ .start = start, .end = first_end, .emoji = true };
        }
        var end = first_end;
        while (end < it.text.len) {
            const next_end = grapheme.nextBoundary(it.text, end);
            if (isEmojiCluster(it.text[end..next_end])) break;
            end = next_end;
        }
        it.pos = end;
        return .{ .start = start, .end = end, .emoji = false };
    }
};

pub fn runs(text: []const u8) RunIterator {
    return .{ .text = text };
}

// ---- tests ------------------------------------------------------------------

const t = std.testing;

test "single emoji, sequences and presentation selectors are emoji clusters" {
    try t.expect(isEmojiCluster("\u{1F600}")); // grinning face
    try t.expect(isEmojiCluster("\u{1F469}\u{200D}\u{1F469}\u{200D}\u{1F467}")); // family
    try t.expect(isEmojiCluster("\u{1F1F3}\u{1F1EC}")); // flag of Nigeria
    try t.expect(isEmojiCluster("\u{1F1F3}")); // lone regional indicator
    try t.expect(isEmojiCluster("\u{1F44D}\u{1F3FD}")); // thumbs up, medium skin tone
    try t.expect(isEmojiCluster("1\u{FE0F}\u{20E3}")); // keycap 1
    try t.expect(isEmojiCluster("1\u{20E3}")); // keycap without the selector
    try t.expect(isEmojiCluster("\u{2764}\u{FE0F}")); // red heart
    try t.expect(isEmojiCluster("\u{26BD}")); // soccer ball: Emoji_Presentation, BMP
    try t.expect(isEmojiCluster("\u{1F3F4}\u{E0067}\u{E0062}\u{E0073}\u{E0063}\u{E0074}\u{E007F}")); // flag of Scotland
    try t.expect(isEmojiCluster("\u{1F468}\u{200D}\u{1F4BB}")); // man technologist
}

test "text, text-presentation pictographs and broken input are not emoji clusters" {
    try t.expect(!isEmojiCluster(""));
    try t.expect(!isEmojiCluster("a"));
    try t.expect(!isEmojiCluster("\u{E9}"));
    try t.expect(!isEmojiCluster("1"));
    try t.expect(!isEmojiCluster("#"));
    try t.expect(!isEmojiCluster("\u{2764}")); // heart, text presentation by default
    try t.expect(!isEmojiCluster("\u{A9}"));
    try t.expect(!isEmojiCluster("\u{2764}\u{FE0E}")); // explicit text presentation
    try t.expect(!isEmojiCluster("\u{4E2D}"));
    try t.expect(!isEmojiCluster("\xF0\x9F")); // truncated
    try t.expect(!isEmojiCluster("\xFF"));
}

test "mayContainEmoji only needs the bytes" {
    try t.expect(!mayContainEmoji("hello, caf\u{E9}"));
    try t.expect(mayContainEmoji("\u{1F600}"));
    try t.expect(mayContainEmoji("\u{2764}"));
}

test "runs tile the string with each emoji cluster alone" {
    const s = "caf\u{E9} \u{1F469}\u{200D}\u{1F469}\u{200D}\u{1F467} \u{1F1F3}\u{1F1EC}\u{1F1F3}\u{1F1EC}x";
    var it = runs(s);
    var pos: usize = 0;
    var n: usize = 0;
    var emoji_runs: usize = 0;
    while (it.next()) |r| : (n += 1) {
        try t.expectEqual(pos, r.start);
        try t.expect(r.end > r.start);
        pos = r.end;
        if (r.emoji) emoji_runs += 1;
    }
    try t.expectEqual(s.len, pos);
    // "café ", family, " ", flag, flag, "x"
    try t.expectEqual(@as(usize, 6), n);
    try t.expectEqual(@as(usize, 3), emoji_runs);
}

test "Emoji_Presentation lookup" {
    try t.expect(hasEmojiPresentation(0x1F600));
    try t.expect(hasEmojiPresentation(0x231A));
    try t.expect(hasEmojiPresentation(0x1FAE0));
    try t.expect(!hasEmojiPresentation(0x41));
    try t.expect(!hasEmojiPresentation(0x2764));
    try t.expect(!hasEmojiPresentation(0x231B + 1));
}
