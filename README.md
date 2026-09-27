# Bankerl

Bankerl is a local Islamic banking demonstrator. Its Erlang/OTP service owns the account ledger and serves a small browser dashboard without third-party Erlang dependencies.

## Run locally

Requirements: Erlang/OTP with `crypto`, and [rebar3](https://rebar3.org/).

```sh
rebar3 compile
rebar3 eunit
rebar3 shell
```

Open [http://127.0.0.1:7474](http://127.0.0.1:7474). Create an account with an email and a password of at least 10 characters. The app assigns a 10-digit customer number; use it with your password to sign in. The first account starts at $0; use **Add funds** to add clearly labeled sandbox funds. The default port and local data file are configured in `src/bankerl.app.src`.

### Run with Docker

```sh
docker build -t bankerl .
docker run --rm --name bankerl-demo -p 127.0.0.1:7474:7474 -v bankerl-data:/data bankerl
```

The container listens internally on all interfaces so Docker can forward requests; the example publishes it only on the host loopback address. The named volume keeps the local demo database between container runs.

## Included flows

- Account registration, customer-number sign-in, salted PBKDF2 password hashes, and expiring HTTP-only sessions.
- Persistent current accounts, a single mudarabah profit-sharing account per user, and a transaction ledger.
- Sandbox deposits, withdrawals with no overdrafts, internal transfers by recipient email, and balance moves between a user's own accounts.
- An illustrative zakat estimate using a user-entered nisab value, plus a disclosed cost-plus Murabaha calculator.
- A responsive browser dashboard served by the Erlang application.

## HTTP API

The machine-readable OpenAPI contract is available at `/openapi.yaml` while the app is running. All write requests accept `application/x-www-form-urlencoded`; authenticated endpoints use the HTTP-only `bankerl_session` cookie issued by registration and sign-in.

Endpoints: `POST /api/register`, `POST /api/login`, `POST /api/logout`, `GET /api/me`, `POST /api/deposit`, `POST /api/withdraw`, `POST /api/transfer`, `POST /api/accounts/savings`, `POST /api/accounts/move`, and `POST /api/zakat`.

## Financial and security limits

This is a learning/demo project, not a bank or production financial service. It does not connect to payment rails, hold real funds, perform identity checks, calculate investment profit/loss, or provide financial or religious advice. Sandbox deposits create demo ledger entries. Zakat eligibility and nisab depend on personal circumstances and current values; the calculator is intentionally only an estimate. The Murabaha illustration is not an offer or a compliant contract.

The native server binds only to `127.0.0.1`. Its built-in HTTP listener has no TLS, distributed deployment, rate limiting, regulatory controls, or production-grade operational hardening. The Docker example binds inside the container and publishes only to host loopback. The local term-format database contains personal data and should not be used for real customer information. Do not expose this demo to a network or use it to store real banking credentials or funds.