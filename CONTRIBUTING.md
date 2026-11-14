# Contributing

Thanks for contributing to Atlas.nvim.

## Pull requests

- Open pull requests against `dev`.
- Keep each PR focused on a single change. Avoid unrelated refactoring.
- Follow [Conventional Commits](https://www.conventionalcommits.org/en/v1.0.0/) for PR titles, for example `fix: handle a missing repository`.
- For significant changes or new features, consider opening an issue first.
- Describe what changed, why, and how you tested it. Include screenshots for UI changes when useful.

## Code quality

- Follow existing patterns and prefer simple, readable code. Reuse existing helpers before adding abstractions or dependencies.
- Keep comments focused on non-obvious reasoning.
- Update documentation when changing user-facing behavior.

## Testing

- Test meaningful behavior, non-trivial logic, and regressions.
- Avoid redundant tests, excessive mocking, and tests that merely verify implementation details.
- Extend existing tests where possible instead of duplicating coverage.

Install Lua, [Busted](https://github.com/lunarmodules/busted), [StyLua](https://github.com/JohnnyMorganz/StyLua), and [Selene](https://github.com/Kampfkarren/selene), then run from the repository root:

```bash
make check
```

CI uses these Make targets too. You can also run `make test`, `make lint`, or `make format` separately.

## AI-assisted contributions

AI-assisted contributions are welcome, but you are responsible for the result.

- Review and understand all generated code before submitting.
- Remove unnecessary code, tests, comments, and documentation.
- Don't submit unreviewed, one-shot AI-generated PRs.
- Keep PR descriptions concise and focused on what changed and why.
