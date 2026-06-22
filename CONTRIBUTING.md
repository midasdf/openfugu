# Contributing

Use Zig 0.16.0 and run:

```sh
zig build
zig build test
zig fmt --check .
```

Do not add direct vendor API integrations, credential extraction, token reuse,
or limit-bypass behavior.
