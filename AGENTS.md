# Writing style guidelines

These guidelines apply to all documentation in `rules_haskell` (`README.md`, `docs/README.md`, `docs/content/**/*.md`, and `examples/**/README.md`).

## Base style guide

Treat the [Google developer documentation style guide](https://developers.google.com/style) (GDDSG) as the base class for all writing in this repository. Follow the GDDSG unless a rule in this document overrides it.

## Voice and tone

- **Address the reader directly.** Use second person ("you"), active voice, and present tense. Use "we" sparingly for project maintainers when stating assumptions or recommendations.
- **Write in plain, conversational, technically precise English.** Use natural contractions (`it's`, `don't`, `you'll`, `here's`, `that's`) rather than stiff academic phrasing.
- **Lead with user value, not file names.** Open paragraphs and sections with what the reader can do, what problem is solved, or a direct definition of the subject. Don't open every paragraph by personifying files, rules, or modules.

  Yes:

  > You can link existing C libraries into Haskell targets with `cc_deps`, without repeating `cc_deps` on downstream binaries.

  No:

  > `haskell/private/rules.bzl` adds `cc_deps` support and `actions.bzl` provides `CcInfo` forwarding.

- **Skip marketing hype and vague idioms.** Avoid buzzwords and empty superlatives ("out-of-the-box", "blazing fast", "seamless", "magic", "world-class"). State the concrete behavior or measurable result instead.
- **Be candid about limitations and sharp edges.** Clearly state what isn't supported, call out trade-offs honestly, and warn readers when *not* to use an option or pattern—along with *why*.
- **Keep paragraphs short.** Aim for 2–4 sentences per paragraph. Break up dense explanations with headings, bulleted lists with bold lead-ins, compact comparison tables, and diagrams.

## Document structure and progressive disclosure

Match each document's structure to the job it does for the reader:

- **Open with scope and signposting.** Start every page with 1–3 sentences explaining what the page covers and who should read it. If a reader might be looking for a sibling doc (such as a quickstart vs. a conceptual overview vs. an API reference), link to it right up front.
- **Quickstarts and tutorials:** Get the reader to a working result quickly. State prerequisites and expectations up front, use concrete numbered steps, show expected terminal output, and end with a brief summary and next steps.
- **How-to guides:** Stay focused on solving one concrete problem concisely. Move deep background, edge cases, and "theory of operation" rationale to dedicated sections or internals pages so practitioners aren't blocked.
- **Conceptual and architecture docs:** Build a mental model first. Define the core idea in 1–2 sentences and explain *why it matters*, include a short summary (and a diagram when illustrating a multi-step flow), then unpack core components one by one anchored in a concrete running example. Compare unfamiliar Haskell or Bazel concepts to familiar ecosystems (Go, Rust, C++, Python) where it clarifies the idea.
- **Reference docs:** Write for the caller, not the maintainer. Document what a rule, attribute, extension, or flag does, its default, preconditions, and caveats. Link to `docs/content/internals/` for implementation details rather than cluttering reference entries.
- **Use callouts purposefully.** Reserve `Note`, `Tip`, `Important`, and `Warning` blockquotes for genuine gotchas, scope boundaries, or high-value shortcuts—not routine prose.

## Headings and capitalization

- **Use sentence case** for all page titles and section headings. Only capitalize the first word, proper nouns, and exact tool or identifier names (such as `Bazel`, `Bzlmod`, `GHC`, `MODULE.bazel`). See [Capitalization in titles and headings](https://developers.google.com/style/capitalization#capitalization-in-titles-and-headings).

  Yes:

  ```markdown
  ## Set up build rules
  ### Why each `.bazelrc` flag is here
  ```

  No:

  ```markdown
  ## Set Up Build Rules
  ### Why Each `.bazelrc` Flag Is Here
  ```

- **Maintain strict heading hierarchy.** Never skip heading levels (don't jump from `##` to `####`).
- **Make headings scannable.** Use imperative verb phrases for task headings (`Generate hackage.lock.json`, `Configure MODULE.bazel`) and clear descriptive phrases for conceptual headings (`Dispatcher: The cooperative scheduler`, `Why deb10 was chosen over musl`).

## Terminology, definitions, and linking

- **Link the first mention of every Bazel concept or term to the official Bazel docs.** On each page, link the first body-text mention of any Bazel concept, file, command, flag, rule, or Starlark API—such as [hermeticity](https://bazel.build/basics/hermeticity), [Bzlmod](https://bazel.build/external/overview), [`MODULE.bazel`](https://bazel.build/external/module), [Starlark](https://bazel.build/rules/language), [sandboxing](https://bazel.build/docs/sandboxing), [runfiles](https://bazel.build/extending/rules#runfiles), [`depset`](https://bazel.build/extending/depsets), [`select()`](https://bazel.build/configure/attributes), [`CcInfo`](https://bazel.build/rules/lib/providers/CcInfo), or [`--incompatible_strict_action_env`](https://bazel.build/reference/command-line-reference#param-no-incompatible-strict-action-env)—to its canonical `https://bazel.build/...` page.
  - Link only the first mention per page; don't repeat the same external link on later mentions.
  - Don't place links inside Markdown headings, YAML frontmatter, or fenced code blocks, and never nest a link inside an existing link.
- **Link other unfamiliar external concepts on first mention.** Link upstream tools and general computer-science concepts (GHC, Cabal, Hackage, Stackage, green threads, cooperative scheduling, etc.) on first mention when a canonical reference helps the reader.
- **Define pivotal terms in plain English.** When a key term carries the weight of a section (such as hermeticity, `$ORIGIN`, or `${pkgroot}`), give a concise inline definition or short note rather than assuming every reader knows it.
- **Avoid clunky acronym expansions and bare URLs.** Use specific, descriptive link text instead of "click here" or raw URLs.
- **Use relative `.md` links for internal docs.** Across `docs/content/**/*.md`, link to sibling pages with relative `.md` paths (for example, `[Quickstart](guide/quickstart.md)`). `docs/site.hs` rewrites `.md` to `.html` at build time so links work both on GitHub and on the published site.

## Code examples, CLI blocks, and formatting

- **Prefer living, verified examples.** Base code examples on real files built and tested in `examples/` or `tests/`—never invent untested snippets. Cite the source file when walking through an in-tree example.
- **Keep examples minimal and complete.** Each example should demonstrate one clear use case without unrelated boilerplate, while including enough context (`load(...)` statements, imports, language pragmas) that a reader can copy-paste it and have it work.
- **Use Yes / No contrast examples** when documenting style rules, common mistakes, or anti-patterns.
- **Keep prose focused instead of cataloging symbols.** Explain the 1–2 primary entry points and why they matter; don't recite long comma-separated lists of helper methods, attributes, or flags in prose when a code block or reference table already lists them.
- **Format CLI commands and outputs clearly.** State working-directory assumptions once in a note rather than repeating `cd` on every step. Show expected terminal output in a separate `text` code block rather than mixing commands and prose.
- **Always tag fenced code blocks** with a language (`starlark`, `haskell`, `bash`, `c`, `ini`, `json`, `text`, `mermaid`). Wrap filenames, flags, Bazel labels, targets, commands, and symbols in inline backticks.
- **Use Mermaid diagrams for flows and architecture.** Prefer `flowchart`, `sequenceDiagram`, and `stateDiagram-v2` to clarify multi-step pipelines and component relationships.

## Authoring and verifying docs in `rules_haskell`

- Author pages under `docs/content/**/*.md` in standard Markdown with YAML frontmatter containing at least `title:`. Don't introduce custom Markdown or Pandoc AST syntax extensions.
- Verify documentation changes with Bazel before finishing:

```bash
bazel build //docs:site
bazel test //docs/...
```

- Preview the rendered site locally at `http://127.0.0.1:8000` with `bazel run //docs:serve`.
