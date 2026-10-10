# Tests

Regression tests are separate from application code in `src/`.
Run from the repository root. On Windows, use an MSVC-initialized terminal.

```sh
odin test tests/dsl -out:build/dsl_tests.exe
odin test tests/optimizer -out:build/optimizer_tests.exe
odin test tests/app -out:build/app_tests.exe
```

Create `build/` first if it does not exist. Each command runs its tests.
