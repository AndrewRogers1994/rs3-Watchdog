# Watchdog

Watchdog creates custom alerts using node-based graphs. Triggers monitor game events, while actions produce visible or audible notifications. Connecting a trigger to an action executes that action whenever the trigger activates.

## Installation

Depends on [LibNodeGraph](https://github.com/adamk33n3r/rs3-LibNodeGraph), [LibNodeGraphStd](https://github.com/adamk33n3r/rs3-LibNodeGraphStd), [RestrictedAreas](https://github.com/adamk33n3r/rs3-RestrictedAreas), and [PrettyUI](https://github.com/PrettyRS/prettyui).

## Usage

### Accessing the Manager

- Hotkey: Press F8 to open the Watchdog manager. You can unbind or change this shortcut on the Settings page.
- Content Panel: Click the Toggle button on the Watchdog content panel to open the manager.

### Creating & Editing Alerts

1. Select New Alert on the alert list to start from scratch or copy a preset.
2. Open an alert to access its node graph.
3. Double-click any empty space to add a node.
4. Drag connections between pins to link nodes together.
5. Toggle the alert on in the list (newly created alerts are enabled by default).

Please report bugs and suggestions on the [issue tracker](https://github.com/adamk33n3r/rs3-Watchdog/issues).

## Tests

From this folder:

```shell
lua tests/run.lua
```

## Contributing

### LLM/AI Usage Policy

When contributing to Watchdog we permit the use of AI tools to assist in writing code. However, all contributions must be reviewed and approved by a human maintainer to ensure quality and adherence to project standards.

**DO NOT**

- Let LLMs generate your documentation for you.
- Submit Pull Requests generated solely by LLMs without human review.
- Have an LLM generate your Pull Request body.
