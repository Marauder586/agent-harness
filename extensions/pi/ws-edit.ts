/**
 * Whitespace-insensitive `edit` tool for Pi. Overrides the built-in `edit`.
 *
 * Matching order per edit:
 *   1. Exact substring match (same as built-in).
 *   2. Line-based match ignoring all leading/trailing whitespace and collapsing
 *      internal whitespace runs. oldText must then cover whole lines.
 * On a line-based match, newText is re-indented by the difference between the
 * file's indent and oldText's indent on the first matched line.
 *
 * Usage: pi -e ./extensions/ws-edit.ts
 */

import type { TextContent } from "@earendil-works/pi-ai";
import { type ExtensionAPI, withFileMutationQueue } from "@earendil-works/pi-coding-agent";
import { readFile, writeFile } from "fs/promises";
import { resolve } from "path";
import { Type } from "typebox";

const normLine = (l: string) => l.trim().replace(/\s+/g, " ");
const indentOf = (l: string) => /^[ \t]*/.exec(l)![0];

export function wsInsensitiveReplace(content: string, oldText: string, newText: string): string {
	// 1. Exact match, must be unique.
	const exactCount = content.split(oldText).length - 1;
	if (exactCount === 1) return content.replace(oldText, () => newText);
	if (exactCount > 1) throw new Error(`oldText matches ${exactCount} locations exactly; add more context.`);

	// 2. Whitespace-insensitive, line-based match.
	const eol = content.includes("\r\n") ? "\r\n" : "\n";
	const lines = content.split(/\r?\n/);
	const oldLines = oldText.split(/\r?\n/);
	while (oldLines.length && !oldLines[0].trim()) oldLines.shift();
	while (oldLines.length && !oldLines[oldLines.length - 1].trim()) oldLines.pop();
	if (!oldLines.length) throw new Error("oldText is empty or whitespace only.");

	const target = oldLines.map(normLine);
	const hits: number[] = [];
	for (let i = 0; i + target.length <= lines.length; i++) {
		if (target.every((t, j) => normLine(lines[i + j]) === t)) hits.push(i);
	}
	if (hits.length === 0) throw new Error("oldText not found, even ignoring whitespace.");
	if (hits.length > 1) throw new Error(`oldText matches ${hits.length} locations ignoring whitespace; add more context.`);

	const start = hits[0];
	// Map each oldText indent to the file's real indent on the paired line.
	const indentMap = new Map<string, string>();
	oldLines.forEach((l, j) => {
		if (l.trim() && !indentMap.has(indentOf(l))) indentMap.set(indentOf(l), indentOf(lines[start + j]));
	});
	const fileIndent = indentOf(lines[start]);
	const oldIndent = indentOf(oldLines[0]);
	const newLines = newText.split(/\r?\n/).map((l) => {
		if (!l.trim()) return "";
		const ind = indentOf(l);
		const mapped = indentMap.get(ind);
		if (mapped !== undefined) return mapped + l.slice(ind.length);
		// Indent not seen in oldText: shift by the first line's delta.
		return l.startsWith(oldIndent) ? fileIndent + l.slice(oldIndent.length) : l;
	});
	lines.splice(start, target.length, ...newLines);
	return lines.join(eol);
}

const editSchema = Type.Object({
	path: Type.String({ description: "Path to the file to edit (relative or absolute)" }),
	edits: Type.Array(
		Type.Object({
			oldText: Type.String({
				description:
					"Text to replace. Must be unique in the file. Whitespace and indentation differences are ignored; when they differ, oldText must cover whole lines.",
			}),
			newText: Type.String({ description: "Replacement text." }),
		}),
		{ description: "One or more replacements, applied in order." },
	),
});

export default function (pi: ExtensionAPI) {
	pi.registerTool({
		name: "edit", // Same name as built-in: overrides it.
		label: "edit (whitespace-insensitive)",
		description:
			"Edit a file by replacing text. Matching ignores whitespace and indentation differences; newText is re-indented to fit.",
		parameters: editSchema,

		async execute(_toolCallId, params, _signal, _onUpdate, ctx) {
			const absolutePath = resolve(ctx.cwd, params.path);
			try {
				await withFileMutationQueue(absolutePath, async () => {
					let content = await readFile(absolutePath, "utf-8");
					for (const e of params.edits) content = wsInsensitiveReplace(content, e.oldText, e.newText);
					await writeFile(absolutePath, content, "utf-8");
				});
				return {
					content: [{ type: "text", text: `Applied ${params.edits.length} edit(s) to ${params.path}` }] as TextContent[],
					details: {},
				};
			} catch (error: any) {
				return {
					content: [{ type: "text", text: `Edit failed: ${error.message}` }] as TextContent[],
					details: { error: true },
				};
			}
		},
	});
}
