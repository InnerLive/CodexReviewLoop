---
name: prompting
description: Create, improve, or review prompts and model instructions, including skills and AGENTS.md. Apply whenever prompt design or wording is part of the task.
---

# Prompting

Write for a capable model. State the intended outcome and add only context
and constraints it cannot reasonably infer or obtain from available sources.
Rely on skills and documents available to the recipient. Reference them rather
than explaining their contents again. Add only task-specific decisions or
context they do not provide.
Let the model choose how to do the work.

Evaluate supplied prompts and examples against this standard. Preserve their
intended task, not unnecessary wording, structure, or assumptions. Apply these
principles unless the user explicitly requests a different approach.

Address actual ambiguity, conflict, or observed failure. Keep necessary
requirements and contracts; remove repetition and routine instructions the
model can supply itself. Length follows the task: use the shortest complete
prompt. A working prompt may need no change.

References when needed: OpenAI's [prompting guidance](https://developers.openai.com/api/docs/guides/reasoning-best-practices#how-to-prompt-reasoning-models-effectively)
and [guidance on skills](https://developers.openai.com/blog/rethinking-skills-and-prompts-for-gpt-6-astra).

## User preference when writing or rewriting prompts

You still explain too much of the model's own work to it. Write the task for a
competent model and trust it to carry out the implementation. Preserve the
user's actual goals and decisions; documents and skills are available to the
recipient. An AI-generated draft is not a standard you must preserve either.
