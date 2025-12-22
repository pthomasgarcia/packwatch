# Product Guidelines - Packwatch

## Prose Style & Tone
- **Technical & Concise:** All documentation, commit messages, and user-facing text should be direct and high-information. Avoid fluff or overly conversational language. Assume the user is familiar with Linux CLI conventions and system administration concepts.

## Visual Identity & CLI UX
- **Modern & Semantic Output:** 
    - Use ANSI escape codes for subtle, semantic coloring (e.g., Green for success, Yellow for updates available, Red for errors).
    - Employ standard Unicode symbols (like `✓`, `!`, `➜`) to provide quick visual cues for status.
    - Ensure output is readable and structured, but avoid heavy layouts or TUI frameworks that could break compatibility or piping.

## Error Handling & Logging
- **Fail Fast & Loud:** Packwatch should prioritize correctness over continuity. If a critical step (like a dependency check or a version fetch) fails, the program should terminate immediately.
- **Explicit Stderr:** All error messages and warnings must be sent to `stderr` with clear, actionable context.
- **Zero Ambiguity:** Never leave the user wondering why a task failed. Provide the exact reason (e.g., "Network timeout", "Invalid JSON schema", "Missing GPG key").

## Design Principles
- **Modularity First:** Any new feature should be implemented as a module or extension if possible, keeping the core engine lean and stable.
- **Portability:** Stick to POSIX-compliant shell features or widely available tools (`bash`, `curl`, `jq`) to ensure the tool runs on most Linux distributions without complex setup.
