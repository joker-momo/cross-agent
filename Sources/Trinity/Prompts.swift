import Foundation

enum Prompts {
    private static let rulesNote = "First read this project's rules (AGENTS.md, CLAUDE.md, and/or .agent/) and obey them as the PRIME DIRECTIVE."

    static func planner(task: String, planPath: String) -> String {
        """
        \(rulesNote)

        You are the PLANNER. Produce a concrete implementation plan for the task below. No code yet.

        Plan requirements:
        - Split the work into small, clearly named parts.
        - Each part must have a narrow scope, target files, exact implementation steps, and expected output.
        - Each part must include its own verification step before the next part starts.
        - Verification must name the concrete command(s), manual check, or artifact inspection to run.
        - The implementer must be able to complete Part 1, verify it, then move to Part 2 without guessing.
        - Avoid broad "do everything" steps. If a part touches unrelated concerns, split it smaller.
        - Mark any risky assumption explicitly.
        - The app will execute exactly one part at a time. A reviewer must approve that part before the next part starts.

        Write `\(planPath)` as Markdown plus exactly one fenced JSON block matching this schema:
        ```json
        {
          "parts": [
            {
              "id": "part-1",
              "title": "Short name",
              "scope": "Narrow scope for this part only",
              "files": ["path/to/file"],
              "steps": ["exact implementation step"],
              "verification": ["exact test/build/manual check to run before review"],
              "pass_criteria": ["observable condition for reviewer approval"]
            }
          ]
        }
        ```

        Write the plan to `\(planPath)` (overwrite if it exists).

        TASK:
        \(task)
        """
    }

    static func implementer(part: PlanPart, planPath: String, feedback: [String]?) -> String {
        var prompt = """
        \(rulesNote)

        You are the IMPLEMENTER. Read the plan at `\(planPath)` and implement ONLY the current part below.

        CURRENT PART:
        \(describe(part))

        Requirements:
        - Edit only what is needed for this current part.
        - Do not start any later plan part.
        - Run every verification item listed for this part.
        - If verification fails, fix this part and rerun verification before stopping.
        - In your final output, report the verification command(s) and pass/fail result.
        - Do not create commits, push, stash, reset, or rewrite git history.
        - Do not self-certify final approval - a separate reviewer will judge your work.
        """
        if let feedback, !feedback.isEmpty {
            prompt += "\n\nThe reviewer rejected this same part. Fix these blocking issues before asking for review again:\n"
            prompt += feedback.map { "- \($0)" }.joined(separator: "\n")
        }
        return prompt
    }

    static func replan(task: String, planPath: String, blockingIssues: [String]) -> String {
        """
        \(rulesNote)

        You are the PLANNER. The previous plan led to implementations the reviewer repeatedly rejected. Revise the plan to address these recurring blocking issues:
        \(blockingIssues.map { "- \($0)" }.joined(separator: "\n"))

        Rewrite `\(planPath)` with the improved plan.

        The revised plan must keep the same JSON schema required by the original planner prompt. Each part must list scope, files, implementation steps, verification command(s), and pass criteria. Every part must be verified and approved by reviewer before the implementer moves to the next part.

        ORIGINAL TASK:
        \(task)
        """
    }

    static func reviewer(part: PlanPart, task: String, planPath: String, diff: String, implementerOutput: String) -> String {
        """
        \(rulesNote)

        You are the REVIEWER. Judge whether the implementation correctly satisfies ONLY the current plan part below. You alone decide whether this part can pass.

        Respond with ONLY a JSON object matching this shape:
        {"approved": <bool>, "blocking_issues": [<str>], "minor_notes": [<str>], "reason": <str>}

        Set approved=true only if there are no blocking issues.
        Set approved=false if this part's verification was missing, failed, or not credible.
        Do not approve work for later parts as a substitute for the current part.
        Be extremely skeptical: implementers often hallucinate, over-edit, or miss side effects.
        Inspect every changed file in the diff, including changes the implementer did not mention.
        Check whether the changed files could break existing behavior, contracts, UI state, tests, auth/account handling, git safety, or agent orchestration outside this part.
        Treat unrelated edits, hidden behavior changes, missing regression checks, or untested impact on existing functionality as blocking unless clearly justified.

        TASK:
        \(task)

        PLAN PATH:
        \(planPath)

        CURRENT PART:
        \(describe(part))

        IMPLEMENTER OUTPUT / VERIFICATION CLAIMS:
        \(implementerOutput)

        FULL DIFF FROM RUN BASE:
        \(diff)
        """
    }

    static func finalReviewer(task: String, planPath: String, diff: String) -> String {
        """
        \(rulesNote)

        You are the REVIEWER. All individual plan parts have already been approved. Now perform one final full-plan review.

        Respond with ONLY a JSON object matching this shape:
        {"approved": <bool>, "blocking_issues": [<str>], "minor_notes": [<str>], "reason": <str>}

        Set approved=true only if the full implementation satisfies the task, the full plan at `\(planPath)`, and the project rules.
        Be extremely skeptical: implementers often hallucinate, over-edit, or miss side effects.
        Inspect every changed file in the final diff, including changes the implementer did not mention.
        Check whether any change breaks existing behavior, contracts, UI state, tests, auth/account handling, git safety, or agent orchestration.
        Treat unrelated edits, hidden behavior changes, missing regression checks, or untested impact on existing functionality as blocking unless clearly justified.

        TASK:
        \(task)

        FINAL DIFF UNDER REVIEW:
        \(diff)
        """
    }

    private static func describe(_ part: PlanPart) -> String {
        """
        ID: \(part.id)
        Title: \(part.title)
        Scope: \(part.scope)
        Files: \(part.files.joined(separator: ", "))
        Steps:
        \(part.steps.map { "- \($0)" }.joined(separator: "\n"))
        Verification:
        \(part.verification.map { "- \($0)" }.joined(separator: "\n"))
        Pass criteria:
        \(part.passCriteria.map { "- \($0)" }.joined(separator: "\n"))
        """
    }
}
