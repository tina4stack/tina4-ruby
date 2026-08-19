# `tina4 routes` safe discovery — 3.13.105

## Contract

`tina4 routes` is a read-only inspection command. It discovers canonical route
files, prints the registered method/path/auth data, and exits zero. It must not
execute the project's server entrypoint, open a browser, bind or take over a
port, or remain running.

## Implementation

- Reproduce with a real child CLI process and an `app.rb` that must not run.
- Load canonical source directories without loading `app.rb` or `index.rb`.
- Keep existing route output stable.
- Run the targeted regression and the complete suite on the lab host as root.

## Verification

- Targeted route contract: 1 example, 0 failures.
- Full suite: 5,451 examples; 39 failures from unavailable MySQL/MSSQL services
  and the missing optional `mysql2` driver. No route-discovery regression.

## Parity

The same observable contract is locked in Python, PHP, and Node.js. Language
internals may differ; all four commands must remain finite and network-free.
