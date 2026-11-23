---
name: security-insights
description: Aggregate open vulnerability findings for the current repo from GitLab, GitHub and Moderne, de-duplicated and ranked, with remediation guidance. Use when the user invokes /security-insights or asks things like "what vulnerabilities does this repo have", "show me the CVEs here", "security findings for this project".
---

# Security Insights

Open vulnerability findings for the current repository from its forge and Moderne, merged by advisory and ranked by severity, with a remediation route per finding.

## Steps

1. **Policy.** Resolve the `deep_budget` policy (`allow`, `deny`, or `ask`):

   ```bash
   policy="${XDG_CONFIG_HOME:-$HOME/.config}/scuba10steve-skills/policy"
   v="$(tr -d '\r' 2>/dev/null < "$policy" | sed -n 's/^[[:space:]]*deep_budget[[:space:]]*=[[:space:]]*//p' | sed 's/[[:space:]]*$//' | tail -n 1)"
   case "$v" in allow|deny|ask) src="$policy" ;; "") v=ask; src=default ;; *) src="default; invalid value '$v' in $policy"; v=ask ;; esac
   echo "Policy: deep_budget=$v ($src)"
   ```

   Print the `Policy:` line. Unset or invalid means `ask`. It governs `--moderne-run` only.

2. **Collect.** Run `bash <skill-dir>/scripts/security-insights.sh`, where `<skill-dir>` is the directory containing this SKILL.md. It emits one JSON document.
   - Non-zero exit: show stderr and stop.
   - A forge source's skip reason containing `x509` or `failed to verify certificate` means the harness sandbox blocked the CLI. The moderne source's reason starting `mod study failed:` with an empty message means the same under a harness that sandboxes shell commands. In both cases say so and re-run this one command with the harness's sandbox bypass, if it has one, rather than reporting the source as having no findings.

3. **Moderne gate.** Applies only when the moderne source's reason starts with `no DependencyVulnerabilityCheck run` or `no Moderne LST`, which means `mod` is installed and the repo is JVM. By `deep_budget`:
   - `allow`: re-run the script with `--moderne-run`.
   - `ask`: say what it costs (minutes, a JVM build, possibly Moderne credits) and ask.
   - `deny`: say the run is available on request.
   - An explicit "include Moderne" or "run the recipe" in the user's request beats `deny`.

4. **Render** in the script's order:

   ```
   ## Critical (n)
   <key>  <sources>  <title>  <package@version → fix_version>  <file[:line]>
   ## High (n) … ## Medium (n) … ## Low (n) … ## Unknown severity (n)
   ## Skipped sources
   <name>: <reason>                       status=skipped
   <name>/<read>: <reason>                each failed read of a status=partial source
   <name>: partial, <reason>              a paginated source that stopped early
   ```

   - Every failure the script recorded appears under Skipped sources. A `partial` source is never rendered as if complete.
   - Render `sources[].name` as a compact set, e.g. `[gitlab,moderne]`.
   - `severity_origin == "policy"`: render the severity with a `(policy)` suffix.
   - `fix_version` null with two or more `package.fix_candidates`: render `→ 1.2.4 | 1.3.0 (sources disagree)`.
   - Omit the package column for `code` and `secret` findings. Omit the location column for dependency findings with no manifest path. A GitHub secret finding has no location: say "location not in the alert".
   - A moderne entry in `sources` whose `as_of` is older than seven days: show that date next to the finding.
   - `findings` empty with at least one source `ok`: say so, and still list skipped sources.

5. **Remediate.** One block per finding in critical and high; medium and low grouped by package when they share a fix version. Use the first route the data supports:
   - **Bump.** `fix_version` present: give the coordinate and version and the step from `version`. Compare dotted numeric segments of `version` and `fix_version` left to right; the first differing segment at index 0 is major, 1 minor, 2 or later patch. If either is not dotted numerics, say the step cannot be classified. If `mod` is installed, name `DependencyVulnerabilityCheck` with `-P maximumUpgradeDelta=<step>` as the one-command route; it edits Maven and Gradle manifests (direct dependencies by default, transitives with `-P overrideTransitive=true`). Naming it is advice; running it is the user's follow-up.
   - **Recipe.** A code finding whose CWE maps to an `org.openrewrite.java.security.*` recipe in the table below. Name it only when all three hold: the location is a `.java` file, `mod` is installed, and `mod config recipes search <id> --json=id` returns that id. Anything unmapped, or any failed condition, falls through to the code-change route.
   - **Code change.** Explain the vulnerability class in two sentences and point at `file:line`. Use the source's `solution` text when present.
   - **Dismissal.** Never inferred.
     - `package.scope` of `development` or `test` is a triage signal that the dependency may not ship: raise it and ask the user to confirm before calling a dismissal appropriate.
     - Nothing in the data supports reachability or secret rotation: ask whether the condition holds.
     - `depth: transitive` alone never justifies a dismissal.
     - When supported, say a dismissal with that justification is the honest move and name where it is recorded: GitLab vulnerability state, or GitHub alert dismissal with a reason.

   Never present applying a fix as done. The skill ends after the report; a follow-up request applies it.

## CWE to recipe

| CWE | Recipe |
|---|---|
| CWE-611 | `org.openrewrite.java.security.XmlParserXXEVulnerability` |
| CWE-22 | `org.openrewrite.java.security.PartialPathTraversalVulnerability` (path checks), `org.openrewrite.java.security.ZipSlip` (archive extraction) |
| CWE-377 | `org.openrewrite.java.security.SecureTempFileCreation`, `org.openrewrite.java.security.UseFilesCreateTempDirectory` |
| CWE-1333 | `org.openrewrite.java.security.RegularExpressionDenialOfService` |
| CWE-338, CWE-330 | `org.openrewrite.java.security.FixCwe338`, `org.openrewrite.java.security.SecureRandom` |
| CWE-250, CWE-269 | `org.openrewrite.java.security.ImproperPrivilegeManagement` |

Verified against `gh 2.104.0`, `glab 1.130.0`, `Moderne CLI 4.12.13`.
