# Contributing

Thanks for contributing to Atlas.nvim.

## Pull requests

Open pull requests against `dev` and keep each one focused on a single change. Pull request titles must follow [Conventional Commits](https://www.conventionalcommits.org/en/v1.0.0/), for example `fix: handle a missing repository` or `feat: add GitHub issue forms`.

Add or update tests and documentation when relevant.

## Testing

Atlas uses [busted](https://github.com/lunarmodules/busted) for testing. Run the test suite from the repository root before opening a pull request:

```bash
busted
stylua --check lua spec
selene lua spec
```
