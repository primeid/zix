# Security Policy

ZIX is an independent implementation of the Nix expression language. It
parses untrusted input (Nix expressions) and can execute build scripts, so
security matters.

## Supported versions

Only the latest commit on `main` is supported. ZIX has not shipped a 1.0
release yet; security fixes land on `main` and are noted in
[CHANGELOG.md](CHANGELOG.md).

## Reporting a vulnerability

**Do not open a public issue for security vulnerabilities.** Instead, email
the maintainers at the address listed on the GitHub profile, or — if you
prefer — open a private advisory via
[GitHub Security Advisories](https://github.com/primeid/zix/security/advisories/new).

Please include:

- a description of the issue and its impact,
- the affected version/commit,
- a minimal reproduction (an expression or builder invocation),
- any suggested fix, if you have one.

We aim to acknowledge reports within 3 business days and to respond with a
plan within 10 business days.

## What we consider a security issue

- Memory-safety violations (use-after-free, out-of-bounds, stack overflow
  from untrusted input) in the lexer, parser, evaluator, NAR codec or
  builder launcher.
- Sandbox escapes: a `zix build --sandbox` builder reading or writing outside
  its permitted paths, or reaching the network.
- Store-path collision or hash-verification bypass in
  fixed-output/content-addressed derivations.
- Denial of service via pathological input (unbounded recursion, resource
  exhaustion) that is not handled gracefully.

## Sandboxing notes

The sandbox relies on [bubblewrap](https://github.com/containers/bubblewrap)
and requires the privileges bubblewrap needs (user namespaces). Without a
privileged setup, `zix build` runs builders unsandboxed by default — treat
unsandboxed builds of untrusted derivations as untrusted code execution.

## Thanks

We appreciate responsible disclosure.
