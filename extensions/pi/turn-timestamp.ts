/**
 * Right-aligned end-of-turn timestamp for Pi.
 *
 * When an agent run settles (Pi stops responding — normally or aborted,
 * with Escape), a dim `HH:MM:SS` timestamp of when it ended is appended to
 * the transcript, right-aligned. It uses the same dim grey as the footer's
 * model name (`theme.fg("dim", ...)`).
 *
 * The timestamp is a session entry, so it is TUI-only (never sent to the
 * LLM) but persists: past timestamps re-render on reload and `/tree`.
 *
 * Usage: pi -e ./extensions/turn-timestamp.ts
 */

import { type ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { type Component, visibleWidth } from "@earendil-works/pi-tui";

/** One-line component that right-aligns its content to the viewport width. */
class RightAlignedLine implements Component {
	private line: (width: number) => string;

	constructor(line: (width: number) => string) {
		this.line = line;
	}

	render(width: number): readonly string[] {
		return [this.line(width)];
	}

	invalidate(): void {}
}

/** Local wall-clock time as HH:MM:SS. */
function clock(ms: number): string {
	const d = new Date(ms);
	const two = (n: number) => String(n).padStart(2, "0");
	return `${two(d.getHours())}:${two(d.getMinutes())}:${two(d.getSeconds())}`;
}

export default function (pi: ExtensionAPI) {
	pi.registerEntryRenderer("turn-timestamp", (entry, _options, theme) => {
		const endedAt = (entry.data as { endedAt: number }).endedAt;
		const time = clock(endedAt);
		return new RightAlignedLine((width) => {
			// Pad by visible width: the themed text carries ANSI codes.
			const pad = " ".repeat(Math.max(1, width - visibleWidth(time)));
			return pad + theme.fg("dim", time);
		});
	});

	// agent_settled, not agent_end: it fires only when Pi will not continue
	// on its own (no retry, compaction or queued follow-up), so the time is
	// when the agent really stopped responding.
	pi.on("agent_settled", async () => {
		pi.appendEntry("turn-timestamp", { endedAt: Date.now() });
	});
}
