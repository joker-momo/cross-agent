import Foundation

enum Prompts {
    private static let rulesNote = "First read this project's rules (AGENTS.md, CLAUDE.md, and/or .agent/) and obey them as the PRIME DIRECTIVE."

    static func planner(task: String, planPath: String) -> String {
        """
        \(rulesNote)

        You are the PLANNER. Produce a concrete, step-by-step implementation plan for the task below. Be specific about files to change and the order of work. Keep it tight - no code yet.

        Write the plan to `\(planPath)` (overwrite if it exists).

        TASK:
        \(task)
        """
    }

    static func implementer(planPath: String, feedback: [String]?) -> String {
        var prompt = """
        \(rulesNote)

        You are the IMPLEMENTER. Read the plan at `\(planPath)` and implement it by editing code in this project. Make all necessary changes. Do not self-certify - a separate reviewer will judge your work.
        """
        if let feedback, !feedback.isEmpty {
            prompt += "\n\nThe reviewer rejected the last iteration. Fix these blocking issues:\n"
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

        ORIGINAL TASK:
        \(task)
        """
    }

    static func reviewer(task: String, diff: String) -> String {
        """
        \(rulesNote)

        You are the REVIEWER. Judge whether the implementation below fully and correctly satisfies the task and the project rules. You alone decide approval.

        Respond with ONLY a JSON object matching this shape:
        {"approved": <bool>, "blocking_issues": [<str>], "minor_notes": [<str>], "reason": <str>}

        Set approved=true only if there are no blocking issues.

        TASK:
        \(task)

        DIFF UNDER REVIEW:
        \(diff)
        """
    }
}
