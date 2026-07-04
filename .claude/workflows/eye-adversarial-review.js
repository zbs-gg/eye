// eye-adversarial-review — find→verify code review for a ZBS Eye diff.
//
// Phase "find": three finder agents scan the same diff from different angles
// (correctness, Swift 6 concurrency, data safety). Finders are told to over-report.
// Phase "verify": every finding gets ONE adversarial verifier whose job is to kill it
// against the actual source. Only findings the verifier CONFIRMS survive.
//
// Host contract (Claude Code dynamic workflow runner):
//   default export: async (ctx) => result
//   ctx.agent(opts)  — spawn a subagent; opts = { name, prompt }; resolves to its final text.
//                      (falls back to ctx.runAgent / ctx.task if the runner names it differently)
//   ctx.exec(cmd)    — optional; run a shell command, resolves to stdout. Used to fetch the diff
//                      when ctx.diff is not provided.
//   ctx.diff         — optional; the unified diff to review.
// Deterministic on purpose: no clocks, no randomness — ids come from counters.

export const meta = {
  name: "eye-adversarial-review",
  description:
    "Adversarial find→verify review of a ZBS Eye diff: parallel finders (correctness, concurrency, data-safety) over-report; one hostile verifier per finding confirms or kills it; only confirmed findings are returned.",
  phases: ["find", "verify"],
};

const ANGLES = [
  {
    id: "correctness",
    focus:
      "Plain correctness: wrong logic, inverted conditions, off-by-one, broken error paths, " +
      "silent failure swallowing, dead guards, API misuse (SwiftUI/GRDB/FlyingFox), " +
      "user-facing strings not localized (Localizable.xcstrings, EN key + RU).",
  },
  {
    id: "concurrency",
    focus:
      "Swift 6 strict concurrency (mode: complete): non-Sendable values (CVPixelBuffer, " +
      "CMSampleBuffer, AXUIElement, VNRequest, GRDB Row) escaping their owning actor; new " +
      "@unchecked Sendable or nonisolated(unsafe) without a provable invariant; UI state mutated " +
      "off @MainActor; blocking C calls (AX) on the cooperative pool; racy Task {} captures.",
  },
  {
    id: "data-safety",
    focus:
      "Data safety and product invariants: a second DatabasePool writer (only IngestService writes " +
      "capture data); migrations that erase user data; snippet()/bm25() joined outside the " +
      "WITH-hits subquery pattern (external-content FTS5); live-DB file copies instead of " +
      "pool.backup(to:); retention prune(0) meaning anything but 'forever'; NEW outbound network " +
      "calls (zero-egress: only isLocalOnly localhost LLM endpoints are allowed); server routes " +
      "missing the Bearer check (only /health is open); anything that launches or re-signs the " +
      "installed app (TCC is cdhash-strict).",
  },
];

function finderPrompt(angle, diff) {
  return [
    "You are a FINDER in an adversarial review of the ZBS Eye repo (Swift 6 strict concurrency,",
    "SwiftUI, GRDB, macOS 15+, local-first/zero-egress). Read CLAUDE.md and AGENTS.md for context.",
    "",
    "Your single angle — report ONLY findings of this kind:",
    angle.focus,
    "",
    "Over-reporting is fine (a verifier will kill weak findings); missing a real bug is not.",
    "Inspect the surrounding source of every suspect hunk before reporting (the bug is often in the",
    "declaration, not the hunk). No style nits.",
    "",
    "Return STRICT JSON only, no prose, shaped exactly:",
    '{"findings":[{"file":"path","line":123,"claim":"one sentence","scenario":"concrete failure scenario"}]}',
    'No findings → {"findings":[]}',
    "",
    "## Diff under review",
    "```diff",
    diff,
    "```",
  ].join("\n");
}

function verifierPrompt(finding, diff) {
  return [
    "You are a hostile VERIFIER in an adversarial review of the ZBS Eye repo. A finder claims:",
    "",
    "  file: " + finding.file + ":" + finding.line,
    "  claim: " + finding.claim,
    "  scenario: " + finding.scenario,
    "",
    "Your job is to KILL this finding. Open the actual file, read the surrounding code and callers,",
    "and check whether the failure scenario is truly reachable in this codebase (not in theory).",
    "Reject it if: the code path is unreachable, a guard already covers it, the type/isolation makes",
    "the race impossible, or the claim misreads the diff.",
    "Confirm it ONLY if you can walk the concrete failing path yourself.",
    "",
    "Return STRICT JSON only, shaped exactly:",
    '{"verdict":"CONFIRMED"|"REJECTED","reason":"one sentence","severity":"S1"|"S2"|"S3"}',
    "(S1 = crash/data loss/egress, S2 = correctness under race/misuse, S3 = hygiene.)",
    "",
    "## Diff for reference",
    "```diff",
    diff,
    "```",
  ].join("\n");
}

// Tolerant JSON extraction: agents sometimes wrap JSON in fences or prose.
function parseJSON(text) {
  if (!text) return null;
  const fenced = text.match(/```(?:json)?\s*([\s\S]*?)```/);
  const candidates = [fenced ? fenced[1] : null, text].filter(Boolean);
  for (const c of candidates) {
    const start = c.indexOf("{");
    const end = c.lastIndexOf("}");
    if (start === -1 || end <= start) continue;
    try {
      return JSON.parse(c.slice(start, end + 1));
    } catch (_) {
      /* try next candidate */
    }
  }
  return null;
}

export default async function eyeAdversarialReview(ctx) {
  const spawn = ctx.agent || ctx.runAgent || ctx.task;
  if (typeof spawn !== "function") {
    throw new Error("eye-adversarial-review: runner must provide ctx.agent(opts) (or runAgent/task)");
  }
  const diff =
    ctx.diff ||
    (typeof ctx.exec === "function" ? await ctx.exec("git diff main...HEAD") : "");
  if (!diff || !diff.trim()) {
    return { confirmed: [], rejected: [], note: "empty diff — nothing to review" };
  }

  // ── phase: find ── three angles in parallel over the same diff
  const finderOuts = await Promise.all(
    ANGLES.map((angle) =>
      spawn({ name: "finder-" + angle.id, prompt: finderPrompt(angle, diff) })
    )
  );
  let seq = 0;
  const seen = new Set();
  const findings = [];
  finderOuts.forEach((out, i) => {
    const parsed = parseJSON(typeof out === "string" ? out : out && out.text);
    const list = parsed && Array.isArray(parsed.findings) ? parsed.findings : [];
    for (const f of list) {
      if (!f || !f.file || !f.claim) continue;
      const key = f.file + ":" + (f.line || 0) + ":" + f.claim; // dedup across angles
      if (seen.has(key)) continue;
      seen.add(key);
      seq += 1;
      findings.push({
        id: "F" + seq,
        angle: ANGLES[i].id,
        file: String(f.file),
        line: Number(f.line) || 0,
        claim: String(f.claim),
        scenario: String(f.scenario || ""),
      });
    }
  });
  if (findings.length === 0) {
    return { confirmed: [], rejected: [], note: "finders reported nothing" };
  }

  // ── phase: verify ── one adversarial verifier per finding, in parallel
  const verdicts = await Promise.all(
    findings.map((f) =>
      spawn({ name: "verifier-" + f.id, prompt: verifierPrompt(f, diff) })
    )
  );
  const confirmed = [];
  const rejected = [];
  verdicts.forEach((out, i) => {
    const v = parseJSON(typeof out === "string" ? out : out && out.text) || {};
    const entry = {
      ...findings[i],
      severity: v.severity === "S1" || v.severity === "S2" || v.severity === "S3" ? v.severity : "S2",
      reason: String(v.reason || "no reason returned"),
    };
    // Unparseable verdict → keep the finding (fail closed: a human looks at it).
    if (v.verdict === "REJECTED") rejected.push(entry);
    else confirmed.push(entry);
  });

  const order = { S1: 0, S2: 1, S3: 2 };
  confirmed.sort((a, b) => order[a.severity] - order[b.severity]);
  return {
    confirmed,
    rejected,
    note:
      "confirmed " + confirmed.length + "/" + findings.length +
      " findings across " + ANGLES.length + " angles; fix or explicitly waive each confirmed item before PR",
  };
}
